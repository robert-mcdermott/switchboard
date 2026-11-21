import Foundation
import Security
import SwitchboardCore

/// Who signed a program, checked with the system's own code-signing machinery. No
/// entitlement is needed to ask.
public enum CodeSignature {
    public struct Verdict: Sendable, Equatable {
        public var status: SigningStatus
        public var teamID: String?
    }

    /// Checks the signature of the program at `path`. Takes from a millisecond to a few
    /// tens of milliseconds, so call it off the main thread.
    public static func evaluate(path: String) -> Verdict {
        var code: SecStaticCode?
        // Through a symbolic link into an app, the bundle around the program is not found
        // and a good signature reads as broken; the real path is what gets checked.
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return Verdict(status: .unknown, teamID: nil)
        }
        // Resources are not re-hashed: for a large app that takes seconds, and the
        // question here is who signed the code, not whether every image is intact.
        // Every architecture in the file is checked, not only the one this process happens
        // to be: the system may run a different slice than we would.
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSCheckAllArchitectures)
        let validity = SecStaticCodeCheckValidity(code, flags, nil)
        if validity == errSecCSUnsigned { return Verdict(status: .unsigned, teamID: nil) }
        // Not being able to read something is not the same as finding it tampered with:
        // only a signature that was checked and failed is called invalid.
        let unreadable = [errSecCSStaticCodeNotFound, errSecCSInfoPlistFailed, errSecCSResourceDirectoryFailed, errSecCSInternalError]
        if unreadable.contains(validity) || (100_000..<100_200).contains(validity) { return Verdict(status: .unknown, teamID: nil) }
        guard validity == errSecSuccess else { return Verdict(status: .invalid, teamID: nil) }

        var information: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        let details = information as? [String: Any] ?? [:]
        let teamID = details[kSecCodeInfoTeamIdentifier as String] as? String
        // Ad hoc: a signature with no certificate behind it, as a local build has.
        if let signatureFlags = details[kSecCodeInfoFlags as String] as? UInt32, signatureFlags & 0x2 != 0 {
            return Verdict(status: .adHoc, teamID: nil)
        }

        func satisfies(_ requirement: String) -> Bool {
            var compiled: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled else { return false }
            return SecStaticCodeCheckValidity(code, flags, compiled) == errSecSuccess
        }
        // Apple's own software.
        if satisfies("anchor apple") { return Verdict(status: .apple, teamID: nil) }
        // Developer ID, or the Mac App Store: an identified developer, vouched for by Apple.
        if satisfies("anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.13] exists or certificate leaf[field.1.2.840.113635.100.6.1.9] exists)") {
            return Verdict(status: .developerID, teamID: teamID)
        }
        // Validly signed by a certificate that fits neither: self-signed, or a development certificate.
        return Verdict(status: .adHoc, teamID: teamID)
    }
}

/// Remembers signature checks, and runs new ones in the background.
///
/// A check is keyed by the file's path and modification time, so an updated program is
/// checked again and an unchanged one never is.
public final class TrustCache: @unchecked Sendable {
    private struct Key: Hashable {
        var path: String
        var modified: Double
    }

    private let lock = NSLock()
    private var verdicts: [Key: CodeSignature.Verdict] = [:]
    private var pending = Set<Key>()
    private let queue = DispatchQueue(label: "switchboard.trust", qos: .utility)

    public init() {}

    /// The verdict for the program at `path` if it is already known. If not, a check is
    /// started and `nil` is returned; ask again shortly.
    public func verdict(forPath path: String) -> CodeSignature.Verdict? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = Key(path: path, modified: modified)
        lock.lock()
        defer { lock.unlock() }
        if let known = verdicts[key] { return known }
        if pending.insert(key).inserted {
            queue.async { [self] in
                let verdict = CodeSignature.evaluate(path: path)
                lock.lock()
                verdicts[key] = verdict
                pending.remove(key)
                if verdicts.count > 5000 { verdicts.removeAll() }
                lock.unlock()
            }
        }
        return nil
    }
}

/// Reverse DNS lookups, for addresses nothing else has named.
///
/// This is the one thing in Switchboard that sends packets of its own, so it exists only
/// when the user has chosen "Active" hostname resolution. Lookups go through the system
/// resolver, are rate-limited, and each address is asked about once.
public final class ReverseResolver: CaptureProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var asked = Set<IPAddress>()
    private var results: [CaptureObservation] = []
    private var recent: [Double] = []
    private let queue = DispatchQueue(label: "switchboard.rdns", qos: .utility, attributes: .concurrent)
    /// At most this many lookups are started per second.
    public let perSecond: Int
    public private(set) var lookups = 0

    private let resolve: @Sendable (IPAddress) -> String?

    /// `lookup` is replaceable so tests need not touch the network.
    public init(perSecond: Int = 5, lookup: @escaping @Sendable (IPAddress) -> String? = ReverseResolver.lookup) {
        self.perSecond = perSecond
        resolve = lookup
    }

    /// Asks for a name for `address`, unless it has been asked about before or the rate
    /// limit has been reached, in which case it will be considered again next time.
    public func request(_ address: IPAddress, now: Double = Date().timeIntervalSince1970) {
        // The names of loopback and multicast addresses are of no interest.
        let kind = AddressClass(address)
        guard kind != .loopback, kind != .multicast else { return }
        lock.lock()
        recent.removeAll { now - $0 >= 1 }
        guard !asked.contains(address), recent.count < perSecond else {
            lock.unlock()
            return
        }
        asked.insert(address)
        recent.append(now)
        lookups += 1
        if asked.count > 20_000 { asked.removeAll() }
        lock.unlock()

        queue.async { [self] in
            guard let name = resolve(address) else { return }
            lock.withLock { results.append(.reverse(address: address, name: name)) }
        }
    }

    public func pollCapture(now: EngineTime) -> [CaptureObservation] {
        lock.lock()
        defer { lock.unlock() }
        let drained = results
        results.removeAll(keepingCapacity: true)
        return drained
    }

    /// One blocking PTR lookup. Returns `nil` when there is no name.
    public static func lookup(_ address: IPAddress) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let bytes = address.networkBytes
        let result: Int32
        if bytes.count == 4 {
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            withUnsafeMutableBytes(of: &socketAddress.sin_addr) { $0.copyBytes(from: bytes) }
            result = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        } else {
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            withUnsafeMutableBytes(of: &socketAddress.sin6_addr) { $0.copyBytes(from: bytes) }
            result = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        }
        guard result == 0 else { return nil }
        let name = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return name.isEmpty ? nil : name
    }
}
