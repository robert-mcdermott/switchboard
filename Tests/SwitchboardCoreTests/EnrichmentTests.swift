import Foundation
import Testing

@testable import SwitchboardCore

/// Builds MaxMind DB files, so the reader can be tested against something whose contents are known.
struct MMDBWriter {
    var recordSize = 24
    var ipVersion = 6
    var databaseType = "Test-City"
    /// Bytes at the start of the data section, for values that records point to.
    var preamble: [UInt8] = []
    private var entries: [(bits: [Bool], data: [UInt8])] = []

    init(recordSize: Int = 24, ipVersion: Int = 6, databaseType: String = "Test-City") {
        self.recordSize = recordSize
        self.ipVersion = ipVersion
        self.databaseType = databaseType
    }

    mutating func add(_ cidr: String, _ value: MMDBReader.Value) { add(cidr, raw: Self.encode(value)) }

    mutating func add(_ cidr: String, raw: [UInt8]) {
        let network = Network(cidr)!
        var bytes = network.address.networkBytes
        var length = network.bits
        if ipVersion == 6, bytes.count == 4 {
            bytes = [UInt8](repeating: 0, count: 12) + bytes
            length += 96
        }
        entries.append(((0..<length).map { (bytes[$0 / 8] >> UInt8(7 - $0 % 8)) & 1 == 1 }, raw))
    }

    static func encode(_ value: MMDBReader.Value) -> [UInt8] {
        func header(_ type: Int, _ size: Int) -> [UInt8] {
            var sizeBits = size
            var extra: [UInt8] = []
            if size >= 29 {
                precondition(size < 285)
                sizeBits = 29
                extra = [UInt8(size - 29)]
            }
            return type <= 7 ? [UInt8(type << 5 | sizeBits)] + extra : [UInt8(sizeBits), UInt8(type - 7)] + extra
        }
        func big(_ number: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: number >> UInt64(8 * (count - 1 - $0))) } }
        switch value {
        case .string(let text): return header(2, text.utf8.count) + Array(text.utf8)
        case .double(let number): return header(3, 8) + big(number.bitPattern, 8)
        case .bytes(let bytes): return header(4, bytes.count) + bytes
        case .unsigned(let number):
            if number <= 0xffff { return header(5, 2) + big(number, 2) }
            return number <= 0xffff_ffff ? header(6, 4) + big(number, 4) : header(9, 8) + big(number, 8)
        case .signed(let number): return header(8, 4) + big(UInt64(UInt32(bitPattern: Int32(number))), 4)
        case .boolean(let flag): return header(14, flag ? 1 : 0)
        case .array(let items): return header(11, items.count) + items.flatMap(encode)
        case .map(let map):
            return header(7, map.count) + map.sorted { $0.key < $1.key }.flatMap { encode(.string($0.key)) + encode($0.value) }
        }
    }

    func build() -> Data {
        // The tree. A record is a node index, -1 for "nothing here", or -2 - n for entry n.
        var nodes: [[Int]] = [[-1, -1]]
        var data = preamble
        var offsets: [Int] = []
        for entry in entries {
            offsets.append(data.count)
            data += entry.data
        }
        for (index, entry) in entries.enumerated() {
            var node = 0
            for (position, bit) in entry.bits.enumerated() {
                let side = bit ? 1 : 0
                if position == entry.bits.count - 1 {
                    nodes[node][side] = -2 - index
                } else {
                    if nodes[node][side] < 0 {
                        nodes.append([-1, -1])
                        nodes[node][side] = nodes.count - 1
                    }
                    node = nodes[node][side]
                }
            }
        }
        func record(_ value: Int) -> Int {
            if value >= 0 { return value }
            return value == -1 ? nodes.count : nodes.count + 16 + offsets[-2 - value]
        }
        var file: [UInt8] = []
        for node in nodes {
            let left = record(node[0]), right = record(node[1])
            func bytes(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * (count - 1 - $0))) } }
            switch recordSize {
            case 24: file += bytes(left, 3) + bytes(right, 3)
            case 28: file += bytes(left, 3) + [UInt8((left >> 24) << 4 | (right >> 24) & 0x0f)] + bytes(right, 3)
            default: file += bytes(left, 4) + bytes(right, 4)
            }
        }
        file += [UInt8](repeating: 0, count: 16)
        file += data
        file += MMDBReader.marker
        file += Self.encode(.map([
            "node_count": .unsigned(UInt64(nodes.count)), "record_size": .unsigned(UInt64(recordSize)),
            "ip_version": .unsigned(UInt64(ipVersion)), "database_type": .string(databaseType),
            "build_epoch": .unsigned(1_790_000_000), "binary_format_major_version": .unsigned(2),
        ]))
        return Data(file)
    }

    static func city(_ country: String, _ city: String, _ latitude: Double, _ longitude: Double) -> MMDBReader.Value {
        .map([
            "country": .map(["iso_code": .string(country)]),
            "city": .map(["names": .map(["en": .string(city), "de": .string("—")])]),
            "location": .map(["latitude": .double(latitude), "longitude": .double(longitude)]),
        ])
    }

    static func network(_ number: UInt64, _ organisation: String) -> MMDBReader.Value {
        .map(["autonomous_system_number": .unsigned(number), "autonomous_system_organization": .string(organisation)])
    }
}

@Suite struct MMDBTests {
    @Test(arguments: [24, 28, 32]) func findsTheNetworkAnAddressIsIn(recordSize: Int) throws {
        var writer = MMDBWriter(recordSize: recordSize)
        writer.add("8.8.8.0/24", MMDBWriter.city("US", "Mountain View", 37.4, -122.08))
        writer.add("9.0.0.0/9", MMDBWriter.city("US", "Monroe", 32.5, -92.1))
        writer.add("185.60.216.0/22", MMDBWriter.city("IE", "Dublin", 53.3, -6.2))
        writer.add("2a00:1450::/29", MMDBWriter.city("CH", "Zürich", 47.4, 8.5))
        // Enough networks that node numbers need more than a few bits.
        for index in 0..<300 { writer.add("11.\(index / 250).\(index % 250).0/24", .map(["n": .unsigned(UInt64(index))])) }
        let reader = try MMDBReader(data: writer.build())
        #expect(reader.databaseType == "Test-City")
        #expect(reader.buildEpoch == 1_790_000_000)

        #expect(reader.lookup(IPAddress("8.8.8.8")!)?["city"]?["names"]?["en"]?.string == "Mountain View")
        #expect(reader.lookup(IPAddress("8.8.8.255")!)?["country"]?["iso_code"]?.string == "US")
        #expect(reader.lookup(IPAddress("9.127.0.1")!)?["city"]?["names"]?["en"]?.string == "Monroe")
        #expect(reader.lookup(IPAddress("9.128.0.1")!) == nil)
        #expect(reader.lookup(IPAddress("185.60.219.35")!)?["location"]?["latitude"]?.double == 53.3)
        #expect(reader.lookup(IPAddress("185.60.220.1")!) == nil)
        #expect(reader.lookup(IPAddress("2a00:1450:4001:81b::200e")!)?["city"]?["names"]?["en"]?.string == "Zürich")
        #expect(reader.lookup(IPAddress("2a00:1458::1")!) == nil)
        #expect(reader.lookup(IPAddress("11.1.49.200")!)?["n"]?.unsigned == 299)
        #expect(reader.lookup(IPAddress("1.1.1.1")!) == nil)
    }

    @Test func readsEveryKindOfValue() throws {
        let everything = MMDBReader.Value.map([
            "text": .string(String(repeating: "long ", count: 20)), "double": .double(-12.5), "small": .unsigned(443),
            "medium": .unsigned(4_200_000_000), "large": .unsigned(1 << 40), "negative": .signed(-7), "yes": .boolean(true),
            "no": .boolean(false), "bytes": .bytes([1, 2, 3]), "list": .array([.string("a"), .unsigned(2), .map(["k": .boolean(true)])]),
        ])
        var writer = MMDBWriter()
        writer.add("203.0.113.0/24", everything)
        #expect(try MMDBReader(data: writer.build()).lookup(IPAddress("203.0.113.9")!) == everything)
    }

    @Test func followsPointersToSharedValues() throws {
        // Real databases store a repeated string once and point to it.
        var writer = MMDBWriter(databaseType: "Test-ASN")
        writer.preamble = MMDBWriter.encode(.string("Example Networks"))
        let pointer: [UInt8] = [0x20, 0x00]  // a pointer, size 0, to offset 0
        writer.add("198.51.100.0/24", raw: [0xE2] + MMDBWriter.encode(.string("autonomous_system_organization")) + pointer
            + MMDBWriter.encode(.string("autonomous_system_number")) + MMDBWriter.encode(.unsigned(64_500)))
        let record = try MMDBReader(data: writer.build()).lookup(IPAddress("198.51.100.7")!)
        #expect(record == MMDBWriter.network(64_500, "Example Networks"))
    }

    @Test func anIPv4DatabaseHasNothingOnIPv6() throws {
        var writer = MMDBWriter(ipVersion: 4)
        writer.add("8.8.8.0/24", MMDBWriter.city("US", "Mountain View", 37.4, -122.08))
        let reader = try MMDBReader(data: writer.build())
        #expect(reader.lookup(IPAddress("8.8.8.8")!) != nil)
        #expect(reader.lookup(IPAddress("2001:4860:4860::8888")!) == nil)
    }

    @Test func refusesWhatIsNotADatabase() {
        #expect(throws: MMDBReader.MMDBError.self) { try MMDBReader(data: Data()) }
        #expect(throws: MMDBReader.MMDBError.self) { try MMDBReader(data: Data("just some text, not a database".utf8)) }
        #expect(throws: MMDBReader.MMDBError.self) { try MMDBReader(data: Data(MMDBReader.marker)) }
        // A node count no file could hold.
        let huge = MMDBReader.marker + MMDBWriter.encode(.map([
            "node_count": .unsigned(UInt64.max), "record_size": .unsigned(24), "ip_version": .unsigned(6),
        ]))
        #expect(throws: MMDBReader.MMDBError.self) { try MMDBReader(data: Data([UInt8](repeating: 0, count: 64) + huge)) }
    }

    @Test func damagedFilesNeverCrash() throws {
        var writer = MMDBWriter(recordSize: 28)
        for index in 0..<200 { writer.add("\(20 + index % 200).\(index).0.0/16", MMDBWriter.city("US", "City \(index)", 1, 2)) }
        writer.add("2a00:1450::/29", MMDBWriter.city("CH", "Zürich", 47.4, 8.5))
        let good = [UInt8](writer.build())
        var random = SplitMix64(seed: 0xDA7A)
        let probes = (0..<40).map { _ in IPAddress.v4(UInt32(truncatingIfNeeded: random.next())) } + [IPAddress("2a00:1450::1")!]
        var opened = 0
        for round in 0..<600 {
            var bytes = good
            switch round % 3 {
            case 0:
                for _ in 0..<(1 + random.below(8)) { bytes[random.below(bytes.count)] = UInt8(truncatingIfNeeded: random.next()) }
            case 1:
                bytes.removeLast(random.below(bytes.count))
            default:
                // Damage aimed at the metadata, which decides how everything else is read.
                bytes[bytes.count - 1 - random.below(90)] = UInt8(truncatingIfNeeded: random.next())
            }
            guard let reader = try? MMDBReader(data: Data(bytes)) else { continue }
            opened += 1
            for probe in probes { _ = reader.lookup(probe) }
        }
        // Most damage leaves a file that still opens; those are the ones that test the lookups.
        #expect(opened > 100)
    }
}

@Suite struct AddressClassTests {
    @Test func tellsTheKindsOfAddressApart() {
        let expected: [(String, AddressClass)] = [
            ("127.0.0.1", .loopback), ("::1", .loopback), ("10.1.2.3", .private), ("172.16.0.1", .private),
            ("172.31.255.255", .private), ("172.32.0.1", .public), ("192.168.1.1", .private), ("192.169.1.1", .public),
            ("169.254.10.1", .linkLocal), ("100.64.0.1", .cgnat), ("100.127.255.255", .cgnat), ("100.128.0.1", .public),
            ("224.0.0.251", .multicast), ("255.255.255.255", .multicast), ("8.8.8.8", .public),
            ("fd12:3456::1", .private), ("fc00::1", .private), ("fe80::1", .linkLocal), ("ff02::fb", .multicast),
            ("2606:4700::1111", .public),
        ]
        for (text, kind) in expected { #expect(AddressClass(IPAddress(text)!) == kind, "\(text)") }
    }
}

@Suite struct TagListTests {
    @Test func parsesListsWithAndWithoutAColour() {
        let parsed = TagList.parse("""
            # my lists
            office #5cf2a5: 10.0.0.0/8, 192.168.1.0/24

            watch list: 203.0.113.7, 2001:db8::/32
            """)
        #expect(parsed.problems.isEmpty)
        #expect(parsed.lists.map(\.name) == ["office", "watch list"])
        #expect(parsed.lists[0].color == "#5CF2A5")
        #expect(parsed.lists[1].color == nil)
        #expect(parsed.lists[0].networks.count == 2)
        #expect(parsed.lists[1].networks[0].bits == 32)
    }

    @Test func namesWhatItCannotRead() {
        let parsed = TagList.parse("office: 10.0.0.0/8, ten.zero, 10.0.0.0/40\nno colon here\n#FF0000: 1.2.3.4")
        #expect(parsed.lists.map(\.name) == ["office"])
        #expect(parsed.lists[0].networks.count == 1)
        #expect(parsed.problems.count == 4)
        #expect(parsed.problems[0].contains("ten.zero"))
        #expect(parsed.problems[2].hasPrefix("line 2"))
        #expect(parsed.problems[3].contains("no name"))
    }

    @Test func aNetworkContainsExactlyItsAddresses() {
        let cases: [(String, String, Bool)] = [
            ("10.0.0.0/8", "10.255.255.255", true), ("10.0.0.0/8", "11.0.0.0", false), ("0.0.0.0/0", "8.8.8.8", true),
            ("192.168.1.7", "192.168.1.7", true), ("192.168.1.7", "192.168.1.8", false),
            ("192.168.1.128/25", "192.168.1.127", false), ("192.168.1.128/25", "192.168.1.128", true),
            ("2001:db8::/32", "2001:db8:ffff::1", true), ("2001:db8::/32", "2001:db9::1", false),
            ("2001:db8::/64", "2001:db8::ffff", true), ("2001:db8::/64", "2001:db8:0:1::1", false),
            ("2001:db8::100/120", "2001:db8::1ff", true), ("2001:db8::100/120", "2001:db8::200", false),
            ("::/0", "2001:db8::1", true), ("10.0.0.0/8", "::ffff:a00:1", false), ("2001:db8::1", "2001:db8::1", true),
        ]
        for (network, address, inside) in cases {
            #expect(Network(network)!.contains(IPAddress(address)!) == inside, "\(address) in \(network)")
        }
        #expect(Network("10.0.0.0/33") == nil)
        #expect(Network("nonsense/8") == nil)
    }
}

/// Knows two networks, as the tests need them.
struct FakeEnricher: AddressEnricher {
    var tag = "watch"
    func facts(for address: IPAddress) -> AddressFacts {
        var facts = AddressFacts()
        if Network("8.8.0.0/16")!.contains(address) {
            facts.country = "US"
            facts.city = "Mountain View"
            facts.asn = 15169
            facts.org = "Google LLC"
        } else if Network("185.60.216.0/22")!.contains(address) {
            facts.country = "IE"
            facts.asn = 32934
            facts.org = "Facebook Inc"
        }
        if Network("203.0.113.0/24")!.contains(address) || Network("10.0.0.0/8")!.contains(address) { facts.tags = [tag] }
        return facts
    }
}

@Suite struct GeoDatabaseTests {
    @Test func combinesACityFileAnAsnFileAndTheUsersLists() throws {
        var city = MMDBWriter(databaseType: "Test-City")
        city.add("8.8.8.0/24", MMDBWriter.city("US", "Mountain View", 37.4, -122.08))
        city.add("10.0.0.0/8", MMDBWriter.city("ZZ", "Nowhere", 0, 0))
        var asn = MMDBWriter(recordSize: 32, databaseType: "Test-ASN")
        asn.add("8.8.8.0/24", MMDBWriter.network(15169, "Google LLC"))
        asn.add("2001:4860::/32", MMDBWriter.network(15169, "Google LLC"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sb-geo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try city.build().write(to: directory.appendingPathComponent("b-city.mmdb"))
        try asn.build().write(to: directory.appendingPathComponent("a-asn.mmdb"))
        try Data("not a database".utf8).write(to: directory.appendingPathComponent("broken.mmdb"))
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        let lists = TagList.parse("office: 10.0.0.0/8\ndns: 8.8.8.8, 10.0.0.53").lists
        let loaded = GeoDatabase.load(directory: directory, tags: lists)
        #expect(loaded.database.sources == ["Test-ASN", "Test-City"])
        #expect(loaded.problems.count == 1 && loaded.problems[0].hasPrefix("broken.mmdb"))

        let google = loaded.database.facts(for: IPAddress("8.8.8.8")!)
        #expect(google.country == "US" && google.city == "Mountain View" && google.asn == 15169 && google.org == "Google LLC")
        #expect(google.latitude == 37.4 && google.longitude == -122.08)
        #expect(google.tags == ["dns"])
        #expect(loaded.database.facts(for: IPAddress("2001:4860:4860::8888")!).asn == 15169)
        #expect(loaded.database.facts(for: IPAddress("2001:4860:4860::8888")!).country == nil)
        // A private address is never looked up, whatever a file claims, but it can be on a list.
        let inside = loaded.database.facts(for: IPAddress("10.0.0.53")!)
        #expect(inside.country == nil && inside.tags == ["office", "dns"])
        #expect(loaded.database.facts(for: IPAddress("1.1.1.1")!) == AddressFacts())
        // The second answer comes from the cache and is the same.
        #expect(loaded.database.facts(for: IPAddress("8.8.8.8")!) == google)

        let nothing = GeoDatabase.load(directory: directory.appendingPathComponent("missing"))
        #expect(nothing.database.isEmpty && nothing.problems.isEmpty)
    }
}

@Suite struct EngineEnrichmentTests {
    private func seen(_ id: UInt64, _ remote: String) -> SourceEvent {
        .seen(SocketObservation(
            sourceID: id, proto: .tcp, local: Endpoint(address: IPAddress("10.0.0.36")!, port: UInt16(50_000 + id)),
            remote: Endpoint(address: IPAddress(remote)!, port: 443), pid: 100, processName: "app", tcpState: .established))
    }

    @Test func describesEachConnectionAsItAppearsAndAgainWhenTheDataChanges() {
        let engine = FlowEngine()
        engine.enricher = FakeEnricher()
        engine.ingest([seen(1, "8.8.4.4"), seen(2, "203.0.113.9"), seen(3, "1.1.1.1")], from: "test", at: 0)
        func flow(_ remote: String) -> Flow { engine.flows.values.first { $0.key.remote.address == IPAddress(remote)! }! }
        #expect(flow("8.8.4.4").country == "US" && flow("8.8.4.4").asn == 15169 && flow("8.8.4.4").org == "Google LLC")
        #expect(flow("8.8.4.4").city == "Mountain View" && flow("8.8.4.4").tags.isEmpty)
        #expect(flow("203.0.113.9").tags == ["watch"] && flow("203.0.113.9").country == nil)
        #expect(flow("1.1.1.1").country == nil && flow("1.1.1.1").tags.isEmpty)
        #expect(engine.snapshot().flows.contains { $0.org == "Google LLC" })

        engine.enricher = FakeEnricher(tag: "renamed")
        engine.refreshEnrichment()
        #expect(flow("203.0.113.9").tags == ["renamed"])

        engine.enricher = nil
        engine.refreshEnrichment()
        #expect(flow("8.8.4.4").country == nil && flow("203.0.113.9").tags.isEmpty)
    }

    @Test func recordsWhoSignedAProcess() {
        let engine = FlowEngine()
        engine.ingest([seen(1, "8.8.4.4")], from: "test", at: 0)
        #expect(engine.processes[100]?.signing == .unknown)
        engine.setSigning(pid: 100, status: .developerID, teamID: "ABCDE12345")
        engine.setSigning(pid: 999, status: .unsigned, teamID: nil)  // not a process we know: ignored
        let record = engine.snapshot().processes.first { $0.pid == 100 }
        #expect(record?.signing == .developerID && record?.teamID == "ABCDE12345")
        #expect(engine.processes[999] == nil)
    }

    @Test func aReverseLookupNamesOnlyWhatHasNoName() {
        let engine = FlowEngine()
        engine.ingest([seen(1, "8.8.4.4"), seen(2, "1.1.1.1")], from: "test", at: 0)
        func flow(_ remote: String) -> Flow { engine.flows.values.first { $0.key.remote.address == IPAddress(remote)! }! }
        engine.observe([.reverse(address: IPAddress("8.8.4.4")!, name: "dns.google")], at: 1)
        #expect(flow("8.8.4.4").hostname == "dns.google" && flow("8.8.4.4").hostnameSource == .ptr)
        #expect(flow("1.1.1.1").hostname == nil)
        // A connection opened later to the same address is named too.
        engine.ingest([seen(3, "8.8.4.4")], from: "test", at: 2)
        #expect(engine.flows.values.filter { $0.hostname == "dns.google" }.count == 2)
    }
}

@Suite struct EnrichmentFilterTests {
    private func subject(_ remote: String, signing: SigningStatus = .apple) -> (Flow, ProcessRecord) {
        let facts = FakeEnricher().facts(for: IPAddress(remote)!)
        let flow = Flow(
            id: 1,
            key: FlowKey(
                proto: .tcp, local: Endpoint(address: IPAddress("10.0.0.36")!, port: 51_000),
                remote: Endpoint(address: IPAddress(remote)!, port: 443)),
            pid: 7, direction: .outbound, interface: "en0", state: .active, tcpState: .established, firstSeen: 0, lastSeen: 1,
            lastActive: 1, closedAt: nil, ageExact: true, bytesIn: 0, bytesOut: 0, packetsIn: 0, packetsOut: 0, rateIn: 0,
            rateOut: 0, rttMS: nil, retransmittedBytes: nil, service: "HTTPS", serviceBasis: .port, hostname: nil,
            attribution: "test", country: facts.country, city: facts.city, asn: facts.asn, org: facts.org, tags: facts.tags)
        return (flow, ProcessRecord(pid: 7, name: "curl", path: "/usr/bin/curl", signing: signing))
    }

    private func matches(_ text: String, _ subject: (Flow, ProcessRecord)) throws -> Bool {
        try FlowFilter(text).matches(subject.0, process: subject.1, now: 1)
    }

    @Test func selectsByPlaceAndOwner() throws {
        let google = subject("8.8.8.8"), unknown = subject("1.1.1.1")
        #expect(try matches("country=US", google))
        #expect(try matches("country:us cc=us", google))
        #expect(try !matches("country=IE", google))
        #expect(try matches("country!=IE", google))
        #expect(try matches("asn=15169 asn:AS15169 as=as15169", google))
        #expect(try !matches("asn=32934", google))
        #expect(try matches("org:google org=\"google llc\"", google))
        #expect(try !matches("org:facebook", google))
        // Nothing is known about this one: it is in no country and on no network.
        #expect(try !matches("country=US", unknown))
        #expect(try !matches("asn=15169", unknown))
        #expect(try !matches("asn>0", unknown))
        #expect(try matches("NOT country:us", unknown))
    }

    @Test func selectsByKindOfAddressListAndSignature() throws {
        #expect(try matches("class:public", subject("8.8.8.8")))
        #expect(try matches("class=private", subject("10.1.2.3")))
        #expect(try matches("class=cgnat", subject("100.64.0.9")))
        #expect(try matches("class=linklocal", subject("169.254.1.1")))
        #expect(try !matches("class:private", subject("8.8.8.8")))
        #expect(try matches("tag:watch tag=watch", subject("203.0.113.9")))
        #expect(try !matches("tag:watch", subject("8.8.8.8")))
        #expect(try matches("NOT tag:watch", subject("8.8.8.8")))
        #expect(try matches("tag!=watch", subject("8.8.8.8")))
        #expect(try !matches("tag!=watch", subject("203.0.113.9")))
        #expect(try matches("signing=apple signed:apple trust=apple", subject("8.8.8.8")))
        #expect(try matches("signing=adhoc", subject("8.8.8.8", signing: .adHoc)))
        #expect(try matches("signing=developerid", subject("8.8.8.8", signing: .developerID)))
        #expect(try matches("signing=unsigned OR signing=invalid", subject("8.8.8.8", signing: .invalid)))
        #expect(try !matches("signing=unsigned OR signing=invalid", subject("8.8.8.8", signing: .unknown)))
    }
}
