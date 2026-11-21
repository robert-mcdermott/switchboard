import Foundation

/// What kind of address this is, from its number alone.
public enum AddressClass: String, Sendable, Codable, CaseIterable {
    case loopback, `private`, linkLocal, cgnat, multicast, `public`

    public init(_ address: IPAddress) {
        if address.isLoopback {
            self = .loopback
            return
        }
        switch address {
        case .v4(let value):
            let a = value >> 24, b = (value >> 16) & 0xff
            if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) {
                self = .private
            } else if a == 169 && b == 254 {
                self = .linkLocal
            } else if a == 100 && (64...127).contains(b) {
                self = .cgnat
            } else if a >= 224 {
                self = .multicast
            } else {
                self = .public
            }
        case .v6(let hi, _):
            if hi >> 57 == 0x7e {
                self = .private  // fc00::/7, unique local
            } else if hi >> 54 == 0x3fa {
                self = .linkLocal  // fe80::/10
            } else if hi >> 56 == 0xff {
                self = .multicast
            } else {
                self = .public
            }
        }
    }

    public var label: String {
        switch self {
        case .loopback: "loopback"
        case .private: "private network"
        case .linkLocal: "link-local"
        case .cgnat: "carrier-grade NAT"
        case .multicast: "multicast"
        case .public: "public address"
        }
    }
}

/// What is known about an address beyond the address itself.
public struct AddressFacts: Sendable, Equatable {
    /// Two-letter country code.
    public var country: String?
    public var city: String?
    public var asn: UInt32?
    /// The organisation that announces the address.
    public var org: String?
    public var latitude: Double?
    public var longitude: Double?
    /// Names of the user's lists this address is on.
    public var tags: [String] = []

    public init() {}
}

public protocol AddressEnricher: Sendable {
    func facts(for address: IPAddress) -> AddressFacts
}

/// A network in CIDR form: an address and how many leading bits identify it.
public struct Network: Sendable, Equatable {
    public var address: IPAddress
    public var bits: Int

    /// Parses `10.0.0.0/8`, `2001:db8::/32`, or a single address.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let slash = trimmed.firstIndex(of: "/") {
            guard let address = IPAddress(String(trimmed[..<slash])), let bits = Int(trimmed[trimmed.index(after: slash)...]),
                  bits >= 0, bits <= (address.isIPv6 ? 128 : 32)
            else { return nil }
            self.address = address
            self.bits = bits
        } else {
            guard let address = IPAddress(trimmed) else { return nil }
            self.address = address
            bits = address.isIPv6 ? 128 : 32
        }
    }

    public func contains(_ other: IPAddress) -> Bool {
        switch (address, other) {
        case (.v4(let a), .v4(let b)):
            return bits == 0 || (a ^ b) >> UInt32(32 - bits) == 0
        case (.v6(let ah, let al), .v6(let bh, let bl)):
            if bits == 0 { return true }
            if bits <= 64 { return bits == 64 ? ah == bh : (ah ^ bh) >> UInt64(64 - bits) == 0 }
            return ah == bh && (bits == 128 ? al == bl : (al ^ bl) >> UInt64(128 - bits) == 0)
        default:
            return false
        }
    }
}

/// One of the user's named lists of addresses, such as "corporate" or "watchlist".
public struct TagList: Sendable, Equatable {
    public var name: String
    /// `#RRGGBB`, if the list should colour its destinations.
    public var color: String?
    public var networks: [Network]

    /// Parses the settings format, one list per line:
    ///
    ///     corporate #5CF2A5: 10.0.0.0/8, 192.168.0.0/16
    ///     watchlist #FF3B5C: 203.0.113.0/24, 198.51.100.7
    ///
    /// Blank lines and lines starting with `#` are ignored. Returns the lists and a
    /// message for each line that could not be read.
    public static func parse(_ text: String) -> (lists: [TagList], problems: [String]) {
        var lists: [TagList] = []
        var problems: [String] = []
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // A colour starts with # too, so a comment is a # at the very start of a line with no colon-separated list.
            guard !line.isEmpty, !(line.hasPrefix("#") && !line.contains(":")) else { continue }
            guard let colon = line.firstIndex(of: ":") else {
                problems.append("line \(number + 1): expected 'name: networks'")
                continue
            }
            var words = line[..<colon].split(separator: " ").map(String.init)
            var color: String?
            if let last = words.last, last.hasPrefix("#"), last.count == 7, UInt32(last.dropFirst(), radix: 16) != nil {
                color = last.uppercased()
                words.removeLast()
            }
            let name = words.joined(separator: " ")
            guard !name.isEmpty else {
                problems.append("line \(number + 1): the list has no name")
                continue
            }
            var networks: [Network] = []
            for item in line[line.index(after: colon)...].split(separator: ",") {
                if let network = Network(String(item)) {
                    networks.append(network)
                } else {
                    problems.append("line \(number + 1): '\(item.trimmingCharacters(in: .whitespaces))' is not an address or network")
                }
            }
            lists.append(TagList(name: name, color: color, networks: networks))
        }
        return (lists, problems)
    }
}

/// Location and network owner from MaxMind-format databases, plus the user's tag lists.
///
/// It reads whatever `.mmdb` files it is given and takes what each offers, so a city
/// database and an ASN database together give both. It never fetches anything.
public final class GeoDatabase: AddressEnricher, @unchecked Sendable {
    private let readers: [MMDBReader]
    private let tags: [TagList]
    private let lock = NSLock()
    private var cache: [IPAddress: AddressFacts] = [:]

    /// The database types loaded, for display.
    public let sources: [String]

    /// Asked for what the databases do not know. Used to give simulated addresses
    /// invented places, so a simulation looks like a real machine.
    private let fallback: (any AddressEnricher)?

    public init(readers: [MMDBReader] = [], tags: [TagList] = [], fallback: (any AddressEnricher)? = nil) {
        self.readers = readers
        self.tags = tags
        self.fallback = fallback
        sources = readers.map(\.databaseType) + (fallback == nil ? [] : ["invented places for simulated traffic"])
    }

    /// Loads every `.mmdb` file in a folder. Files that cannot be read are skipped and named.
    public static func load(directory: URL, tags: [TagList] = []) -> (database: GeoDatabase, problems: [String]) {
        var readers: [MMDBReader] = []
        var problems: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "mmdb" {
            do { readers.append(try MMDBReader(url: file)) } catch { problems.append("\(file.lastPathComponent): \(error)") }
        }
        return (GeoDatabase(readers: readers, tags: tags), problems)
    }

    public var isEmpty: Bool { readers.isEmpty && tags.isEmpty && fallback == nil }
    public var tagLists: [TagList] { tags }

    public func facts(for address: IPAddress) -> AddressFacts {
        if let cached = lock.withLock({ cache[address] }) { return cached }
        var facts = AddressFacts()
        facts.tags = tags.filter { list in list.networks.contains { $0.contains(address) } }.map(\.name)

        // Only public addresses are in these databases.
        if AddressClass(address) == .public {
            for reader in readers {
                guard let record = reader.lookup(address) else { continue }
                // City and country databases; the key names are shared by DB-IP and GeoLite2.
                if facts.country == nil { facts.country = record["country"]?["iso_code"]?.string }
                if facts.city == nil { facts.city = record["city"]?["names"]?["en"]?.string }
                if facts.latitude == nil, let location = record["location"] {
                    facts.latitude = location["latitude"]?.double
                    facts.longitude = location["longitude"]?.double
                }
                // ASN databases.
                if facts.asn == nil, let number = record["autonomous_system_number"]?.unsigned {
                    facts.asn = UInt32(truncatingIfNeeded: number)
                }
                if facts.org == nil { facts.org = record["autonomous_system_organization"]?.string }
            }
            if facts.country == nil, facts.asn == nil, let fallback {
                let invented = fallback.facts(for: address)
                let tags = facts.tags
                facts = invented
                facts.tags = tags
            }
        }
        lock.withLock {
            if cache.count > 50_000 { cache.removeAll() }
            cache[address] = facts
        }
        return facts
    }
}
