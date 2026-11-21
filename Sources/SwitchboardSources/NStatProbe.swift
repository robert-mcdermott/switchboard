import Foundation
import SwitchboardCore

/// Spike S2: can we use the private NetworkStatistics framework (the one behind `nettop`)
/// to learn about flows as events, without entitlements?
///
/// The framework is loaded with `dlopen` and its functions resolved with `dlsym`, never
/// linked. If a symbol disappears in a future macOS the probe reports it and the rest of
/// Switchboard keeps working.
public enum NStatProbe {
    private typealias Ref = UnsafeMutableRawPointer
    private typealias SourceAddedBlock = @convention(block) (Ref?, UnsafeMutableRawPointer?) -> Void
    private typealias DictionaryBlock = @convention(block) (CFDictionary?) -> Void
    private typealias VoidBlock = @convention(block) () -> Void

    private typealias CreateFn = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer, SourceAddedBlock) -> Ref?
    private typealias ManagerFn = @convention(c) (Ref) -> Void
    private typealias ManagerQueryFn = @convention(c) (Ref, VoidBlock?) -> Void
    private typealias SourceSetDictionaryFn = @convention(c) (Ref, DictionaryBlock) -> Void
    private typealias SourceSetVoidFn = @convention(c) (Ref, VoidBlock) -> Void
    private typealias SourceFn = @convention(c) (Ref) -> Void

    static let frameworkPath = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        var added = 0
        var described = 0
        var removed = 0
        var countEvents = 0
        var descriptionKeys = Set<String>()
        var countKeys = Set<String>()
        var samples: [String] = []
        var countSample: String?
        var testPort: UInt16 = 0
        var testSources = Set<UInt>()
        var testSourcesRemoved = Set<UInt>()
        var sourceOwners: [UInt: pid_t] = [:]
        var providers: [String: Int] = [:]

        func sync<T>(_ body: (Collector) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }

    public static func run() -> (lines: [String], usable: Bool) {
        var lines: [String] = []
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            return (["dlopen failed: \(reason)"], false)
        }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let address = dlsym(handle, name) else {
                lines.append("missing symbol: \(name)")
                return nil
            }
            return unsafeBitCast(address, to: type)
        }

        guard
            let create = symbol("NStatManagerCreate", as: CreateFn.self),
            let destroy = symbol("NStatManagerDestroy", as: ManagerFn.self),
            let addAllTCP = symbol("NStatManagerAddAllTCP", as: ManagerFn.self),
            let addAllUDP = symbol("NStatManagerAddAllUDP", as: ManagerFn.self),
            let queryAllCounts = symbol("NStatManagerQueryAllSources", as: ManagerQueryFn.self),
            let queryAllDescriptions = symbol("NStatManagerQueryAllSourcesDescriptions", as: ManagerQueryFn.self),
            let setDescriptionBlock = symbol("NStatSourceSetDescriptionBlock", as: SourceSetDictionaryFn.self),
            let setCountsBlock = symbol("NStatSourceSetCountsBlock", as: SourceSetDictionaryFn.self),
            let setRemovedBlock = symbol("NStatSourceSetRemovedBlock", as: SourceSetVoidFn.self),
            let queryDescription = symbol("NStatSourceQueryDescription", as: SourceFn.self)
        else {
            return (lines, false)
        }
        lines.append("framework loaded, all 10 symbols resolved")

        let collector = Collector()
        guard let listener = Loopback.listen() else {
            return (lines + ["could not open a loopback listener for the short-flow test"], false)
        }
        defer { close(listener.fd) }
        collector.testPort = listener.port

        let queue = DispatchQueue(label: "switchboard.nstat-probe")
        let sourceAdded: SourceAddedBlock = { source, _ in
            guard let source else { return }
            let id = UInt(bitPattern: source)
            collector.sync { $0.added += 1 }

            let onDescription: DictionaryBlock = { dictionary in
                guard let dictionary = dictionary as NSDictionary? else { return }
                record(description: dictionary, source: id, into: collector)
            }
            setDescriptionBlock(source, onDescription)

            let onCounts: DictionaryBlock = { dictionary in
                guard let dictionary = dictionary as NSDictionary? else { return }
                collector.sync {
                    $0.countEvents += 1
                    for key in dictionary.allKeys { $0.countKeys.insert("\(key)") }
                    if $0.countSample == nil { $0.countSample = render(dictionary) }
                }
            }
            setCountsBlock(source, onCounts)

            let onRemoved: VoidBlock = {
                collector.sync {
                    $0.removed += 1
                    if $0.testSources.contains(id) { $0.testSourcesRemoved.insert(id) }
                }
            }
            setRemovedBlock(source, onRemoved)

            queryDescription(source)
        }

        guard let manager = create(nil, Unmanaged.passUnretained(queue).toOpaque(), sourceAdded) else {
            return (lines + ["NStatManagerCreate returned NULL"], false)
        }
        addAllTCP(manager)
        addAllUDP(manager)
        queryAllDescriptions(manager, nil)

        Thread.sleep(forTimeInterval: 1.5)
        let initial = collector.sync { ($0.added, $0.described, Set($0.sourceOwners.values), $0.providers) }
        lines.append("initial inventory: \(initial.0) sources added, \(initial.1) described (uid \(getuid()))")
        lines.append("by provider: \(initial.3.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")

        // Whose sockets are we being shown?
        var owners: [String: Int] = [:]
        for pid in initial.2 {
            let label: String
            if let basic = ProcessTable.basicInfo(of: pid) {
                label = basic.uid == getuid() ? "own user" : (basic.uid == 0 ? "root" : "other accounts")
            } else {
                label = "gone"
            }
            owners[label, default: 0] += 1
        }
        lines.append(
            "owning processes: \(initial.2.count) — \(owners.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))"
        )

        // Three loopback connections that each live for well under a millisecond of work.
        var durations: [Double] = []
        for _ in 0..<3 {
            if let elapsed = Loopback.flow(to: listener) { durations.append(elapsed * 1000) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 1.0)
        queryAllCounts(manager, nil)
        Thread.sleep(forTimeInterval: 1.0)

        let result = collector.sync { c in
            (
                added: c.added, described: c.described, removed: c.removed, countEvents: c.countEvents,
                descriptionKeys: c.descriptionKeys.sorted(), countKeys: c.countKeys.sorted(),
                samples: c.samples, countSample: c.countSample,
                testSources: c.testSources.count, testRemoved: c.testSourcesRemoved.count
            )
        }
        destroy(manager)

        let formatted = durations.map { String(format: "%.2f ms", $0) }.joined(separator: ", ")
        lines.append("after test: \(result.added) added, \(result.described) described, \(result.removed) removed")
        lines.append("short loopback flows opened: \(durations.count) (lifetimes \(formatted))")
        lines.append(
            "short flows observed: \(result.testSources) sources mentioning port \(listener.port) with a peer, \(result.testRemoved) of them later removed"
        )
        lines.append("count callbacks after a manager-wide query: \(result.countEvents)")
        lines.append("description keys (\(result.descriptionKeys.count)): \(result.descriptionKeys.joined(separator: ", "))")
        lines.append("count keys (\(result.countKeys.count)): \(result.countKeys.joined(separator: ", "))")
        for sample in result.samples { lines.append("sample description: \(sample)") }
        if let sample = result.countSample { lines.append("sample counts: \(sample)") }

        let usable = result.described > 0
        return (lines, usable)
    }

    private static func record(description: NSDictionary, source: UInt, into collector: Collector) {
        var ports: [UInt16] = []
        for value in description.allValues {
            if let data = value as? Data, let endpoint = endpoint(from: data) { ports.append(endpoint.port) }
        }
        let rendered = render(description)
        let owner = (description["processID"] as? NSNumber)?.int32Value
        let provider = description["provider"] as? String
        collector.sync {
            $0.described += 1
            if $0.sourceOwners[source] == nil {
                if let owner { $0.sourceOwners[source] = owner }
                if let provider { $0.providers[provider, default: 0] += 1 }
            }
            for key in description.allKeys { $0.descriptionKeys.insert("\(key)") }
            if $0.samples.count < 2 { $0.samples.append(rendered) }
            // A flow of ours has the test port on one side and a real port on the other.
            // The listener itself has only the test port.
            if ports.contains($0.testPort), ports.contains(where: { $0 != 0 && $0 != collector.testPort }) {
                $0.testSources.insert(source)
            }
        }
    }

    private static func render(_ dictionary: NSDictionary) -> String {
        dictionary.allKeys.map { "\($0)" }.sorted().map { key in
            let value = dictionary[key]
            if let data = value as? Data {
                if let endpoint = endpoint(from: data) { return "\(key)=\(endpoint.address):\(endpoint.port)" }
                return "\(key)=<\(data.count) bytes>"
            }
            return "\(key)=\(value.map { "\($0)" } ?? "nil")"
        }.joined(separator: " ")
    }

    /// Decodes a `sockaddr_in` or `sockaddr_in6` held in a data blob.
    private static func endpoint(from data: Data) -> (address: IPAddress, port: UInt16)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else { return nil }
        let port = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        if bytes[1] == UInt8(AF_INET), let address = IPAddress(networkBytes: bytes[4..<8]) {
            return (address, port)
        }
        if bytes[1] == UInt8(AF_INET6), bytes.count >= 24, let address = IPAddress(networkBytes: bytes[8..<24]) {
            return (address, port)
        }
        return nil
    }
}
