import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardStore

/// Places the simulator's addresses by their first byte, so there is something to search for.
private struct ByFirstByte: AddressEnricher {
    func facts(for address: IPAddress) -> AddressFacts {
        var facts = AddressFacts()
        guard AddressClass(address) == .public, let first = address.networkBytes.first else { return facts }
        if first % 3 == 0 {
            facts.country = "US"
            facts.city = "Ashburn"
            facts.asn = 14618
            facts.org = "Amazon.com, Inc."
        } else if first % 3 == 1 {
            facts.country = "DE"
            facts.asn = 3320
            facts.org = "Deutsche Telekom AG"
        }
        if first % 5 == 0 { facts.tags = ["watch", "fives"] }
        return facts
    }
}

@Suite struct EnrichmentLogTests {
    private func enriched(seconds: Double) throws -> Fixture {
        let fixture = try Fixture()
        fixture.engine.enricher = ByFirstByte()
        let source = SimulatorSource(scenario: .developer)
        let statuses: [SigningStatus] = [.apple, .developerID, .adHoc, .unsigned, .unknown]
        SteppedRun.run(sources: [source], engine: fixture.engine, until: seconds) { time in
            // Signatures arrive a little after a process is first seen, as they do in the app.
            if time == 3 {
                for pid in fixture.engine.processes.keys.sorted() {
                    fixture.engine.setSigning(pid: pid, status: statuses[Int(pid) % statuses.count], teamID: pid % 5 == 1 ? "TEAM\(pid)" : nil)
                }
            }
            for flow in fixture.engine.flows.values { fixture.everSeen[flow.id] = flow }
            if time == time.rounded() { fixture.store.record(fixture.engine.snapshot()) }
        }
        fixture.store.flush()
        return fixture
    }

    @Test func keepsPlaceOwnerListsAndSignatureWithEachConnection() throws {
        let fixture = try enriched(seconds: 30)
        let result = try fixture.store.query(.all, from: fixture.all.from, to: fixture.all.to, limit: 100_000)
        let logged = Dictionary(grouping: result.entries) { "\($0.flow.pid) \($0.flow.key.local) \($0.flow.key.remote)" }
        var withCountry = 0, withTags = 0
        for flow in fixture.everSeen.values {
            let entry = try #require(logged["\(flow.pid) \(flow.key.local) \(flow.key.remote)"]?.first)
            #expect(entry.flow.country == flow.country && entry.flow.city == flow.city)
            #expect(entry.flow.asn == flow.asn && entry.flow.org == flow.org)
            #expect(entry.flow.tags == flow.tags)
            if flow.country != nil { withCountry += 1 }
            if !flow.tags.isEmpty { withTags += 1 }
        }
        #expect(withCountry > 50 && withTags > 10)
        // A signature that arrived after the connection was first written is still recorded,
        // for connections that were still open then.
        let late = result.entries.filter { $0.flow.closedAt.map { $0 > fixture.origin + 5 } ?? true }
        let signed = late.filter { $0.process.signing != .unknown }
        #expect(late.count > 50 && signed.count > late.count / 2)
        #expect(signed.contains { $0.process.signing == .developerID && $0.process.teamID != nil })
    }

    @Test func searchesTheNewFieldsExactlyAsTheFilterDoes() throws {
        let fixture = try enriched(seconds: 40)
        let now = fixture.origin + 40
        let terms = [
            "country=US", "country:de", "country!=US", "NOT country=DE", "cc:u*", "asn=14618", "asn:AS3320", "asn!=3320",
            "asn>5000", "org:amazon", "org=\"deutsche telekom ag\"", "NOT org:amazon", "org:*telekom*", "tag:watch",
            "tag!=watch", "NOT tag:fives", "class:public", "class=private", "NOT class:loopback", "signing=apple",
            "signing!=apple", "signing=unknown", "NOT signing=unknown", "signing=unsigned OR signing=invalid", "trust:adhoc",
            "country=US signing=developerid", "country=US OR tag:watch", "NOT (country=US OR signing=apple)",
        ]
        var narrowed = 0
        let total = try fixture.store.stats().flows
        for text in terms {
            let filter = try FlowFilter(text)
            let result = try fixture.store.query(filter, from: fixture.all.from, to: fixture.all.to, limit: 1_000_000, now: now)
            let expected = try LogQueryTests.reference(fixture, filter, now: now)
            #expect(Set(result.entries.map(\.id)) == expected, "\(text)")
            #expect(result.matched == expected.count, "\(text)")
            if result.scanned < total { narrowed += 1 }
        }
        #expect(narrowed > 8)
        // The terms select something, and not everything, or the comparison proves little.
        for text in ["country=US", "asn=3320", "org:amazon", "tag:watch", "signing=apple", "signing=unknown"] {
            let count = try fixture.store.query(try FlowFilter(text), from: fixture.all.from, to: fixture.all.to, limit: 1, now: now).matched
            #expect(count > 0 && count < total, "\(text): \(count) of \(total)")
        }

        var random = SplitMix64(seed: 0x6E0)
        func expression(_ depth: Int) -> String {
            if depth == 0 || random.below(4) == 0 { return terms[random.below(terms.count)] }
            switch random.below(3) {
            case 0: return "(\(expression(depth - 1)) AND \(expression(depth - 1)))"
            case 1: return "(\(expression(depth - 1)) OR \(expression(depth - 1)))"
            default: return "NOT (\(expression(depth - 1)))"
            }
        }
        for _ in 0..<120 {
            let filter = try FlowFilter(expression(3))
            let result = try fixture.store.query(filter, from: fixture.all.from, to: fixture.all.to, limit: 1_000_000, now: now)
            let expected = try LogQueryTests.reference(fixture, filter, now: now)
            #expect(Set(result.entries.map(\.id)) == expected, "\(filter.text): \(result.entries.count) for \(expected.count)")
        }
    }

    @Test func exportsTheNewColumns() throws {
        let fixture = try enriched(seconds: 20)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sb-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try fixture.store.export(try FlowFilter("country=US"), from: fixture.all.from, to: fixture.all.to, format: .csv, redactHostnames: false, to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines[0].contains("country,city,asn,network_owner,tags,signing"))
        #expect(lines.count > 5)
        #expect(lines.dropFirst().allSatisfy { $0.contains("US,Ashburn,14618,\"Amazon.com, Inc.\"") })
    }

    @Test func opensALogWrittenBeforeTheseColumnsExisted() throws {
        let fixture = try Fixture()
        fixture.run(seconds: 20)
        let before = try fixture.store.query(.all, from: fixture.all.from, to: fixture.all.to, limit: 100_000)
        fixture.store.flush()
        // Put the file back to how version 1 left it.
        do {
            let old = try Database(path: fixture.url.path)
            try old.execute("DROP INDEX flow_country")
            for column in ["country", "city", "asn", "org", "tags", "signing", "team"] { try old.execute("ALTER TABLE flow DROP COLUMN \(column)") }
            try old.execute("PRAGMA user_version = 1")
        }
        try fixture.reopen()
        let after = try fixture.store.query(.all, from: fixture.all.from, to: fixture.all.to, limit: 100_000)
        #expect(after.matched == before.matched && after.matched > 100)
        #expect(after.entries.allSatisfy { $0.flow.country == nil && $0.flow.tags.isEmpty && $0.process.signing == .unknown })
        // Old rows know nothing: they are in no country, and their signature is unknown.
        let now = fixture.origin + 20
        for text in ["country=US", "country!=US", "NOT org:amazon", "signing=unknown", "signing!=apple", "asn!=1", "NOT asn=1"] {
            let filter = try FlowFilter(text)
            let result = try fixture.store.query(filter, from: fixture.all.from, to: fixture.all.to, limit: 1_000_000, now: now)
            #expect(Set(result.entries.map(\.id)) == (try LogQueryTests.reference(fixture, filter, now: now)), "\(text)")
        }
        #expect(try fixture.store.query(try FlowFilter("signing=unknown"), from: fixture.all.from, to: fixture.all.to, limit: 1, now: now).matched == after.matched)
        // And new connections are written with the new columns alongside them.
        fixture.engine.enricher = ByFirstByte()
        fixture.run(seconds: 30)
        #expect(try fixture.store.query(try FlowFilter("country=US"), from: fixture.all.from, to: fixture.all.to, limit: 1).matched > 0)
        // Opening it a third time changes nothing.
        try fixture.reopen()
        #expect(try fixture.store.stats().flows >= after.matched)
    }
}
