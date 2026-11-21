import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct NameAndServiceTests {
    static let local = Endpoint(address: IPAddress("10.0.0.36")!, port: 52_551)
    static let remote = Endpoint(address: IPAddress("93.184.216.34")!, port: 443)

    static func open(_ id: UInt64, pid: Int32 = 100, localPort: UInt16 = 52_551, remotePort: UInt16 = 443, proto: TransportProtocol = .tcp) -> SourceEvent {
        .seen(SocketObservation(
            sourceID: id, proto: proto, local: Endpoint(address: local.address, port: localPort),
            remote: Endpoint(address: remote.address, port: remotePort), pid: pid, processName: "app",
            tcpState: proto == .tcp ? .established : nil))
    }

    @Test func aConnectionOpenedAfterTheLookupTakesItsName() {
        let engine = FlowEngine()
        engine.observe([.resolved(name: "example.com", addresses: [Self.remote.address], pid: nil)], at: 0)
        let id = engine.ingest([Self.open(1)], from: "test", at: 1).opened[0]
        #expect(engine.flows[id]?.hostname == "example.com")
        #expect(engine.flows[id]?.hostnameSource == .dns)
    }

    @Test func aConnectionAlreadyOpenTakesTheNameWhenItArrives() {
        let engine = FlowEngine()
        let id = engine.ingest([Self.open(1)], from: "test", at: 0).opened[0]
        #expect(engine.flows[id]?.hostname == nil)
        engine.observe([.resolved(name: "example.com", addresses: [Self.remote.address], pid: nil)], at: 1)
        #expect(engine.flows[id]?.hostname == "example.com")
    }

    @Test func eachProcessGetsTheNameItAskedFor() {
        // Two names on one address, as with a CDN.
        let engine = FlowEngine()
        engine.observe([
            .resolved(name: "shop.example", addresses: [Self.remote.address], pid: 1),
            .resolved(name: "news.example", addresses: [Self.remote.address], pid: 2),
        ], at: 0)
        let opened = engine.ingest([Self.open(1, pid: 1), Self.open(2, pid: 2, localPort: 52_552), Self.open(3, pid: 3, localPort: 52_553)], from: "test", at: 1).opened
        #expect(engine.flows[opened[0]]?.hostname == "shop.example")
        #expect(engine.flows[opened[1]]?.hostname == "news.example")
        // A process that asked nothing gets the most recent answer for that address.
        #expect(engine.flows[opened[2]]?.hostname == "news.example")
    }

    @Test func aTLSServerNameBeatsDNSAndIsReadEitherWayRound() {
        let engine = FlowEngine()
        engine.observe([.resolved(name: "cdn.example", addresses: [Self.remote.address], pid: nil)], at: 0)
        let id = engine.ingest([Self.open(1)], from: "test", at: 1).opened[0]
        // Seen in the server-to-client direction: the engine still finds the connection.
        engine.observe([.serverName(proto: .tcp, from: Self.remote, to: Self.local, name: "exact.example")], at: 2)
        #expect(engine.flows[id]?.hostname == "exact.example")
        #expect(engine.flows[id]?.hostnameSource == .sni)
        // A later DNS answer does not take the more specific name away.
        engine.observe([.resolved(name: "other.example", addresses: [Self.remote.address], pid: nil)], at: 3)
        #expect(engine.flows[id]?.hostname == "exact.example")

        // Known before the socket is: applied when the socket appears.
        let later = Endpoint(address: Self.local.address, port: 60_000)
        engine.observe([.serverName(proto: .tcp, from: later, to: Self.remote, name: "early.example")], at: 4)
        let second = engine.ingest([Self.open(2, localPort: 60_000)], from: "test", at: 5).opened[0]
        #expect(engine.flows[second]?.hostname == "early.example")
    }

    @Test func observedServicesConfirmOrReplaceGuesses() {
        let engine = FlowEngine()
        let https = engine.ingest([Self.open(1)], from: "test", at: 0).opened[0]
        #expect(engine.flows[https]?.serviceBasis == .port)
        engine.observe([.service(proto: .tcp, from: Self.local, to: Self.remote, service: "TLS")], at: 1)
        // Still HTTPS, but now seen rather than assumed.
        #expect(engine.flows[https]?.service == "HTTPS")
        #expect(engine.flows[https]?.serviceBasis == .observed)

        // TLS on a port with no name of its own is simply TLS.
        let odd = engine.ingest([Self.open(2, localPort: 52_600, remotePort: 9443)], from: "test", at: 2).opened[0]
        #expect(engine.flows[odd]?.service == nil)
        let oddRemote = Endpoint(address: Self.remote.address, port: 9443)
        engine.observe([.service(proto: .tcp, from: Endpoint(address: Self.local.address, port: 52_600), to: oddRemote, service: "TLS")], at: 3)
        #expect(engine.flows[odd]?.service == "TLS")
        #expect(engine.flows[odd]?.serviceBasis == .observed)

        // Known before the socket appears.
        let quicLocal = Endpoint(address: Self.local.address, port: 50_566)
        engine.observe([.service(proto: .udp, from: quicLocal, to: Self.remote, service: "QUIC")], at: 4)
        let quic = engine.ingest([Self.open(3, localPort: 50_566, proto: .udp)], from: "test", at: 5).opened[0]
        #expect(engine.flows[quic]?.service == "QUIC")
        #expect(engine.flows[quic]?.serviceBasis == .observed)
    }

    @Test func keepsABoundedLogOfLookups() {
        let engine = FlowEngine()
        for index in 0..<350 {
            engine.observe([.resolved(name: "host-\(index).example", addresses: [.v4(UInt32(index + 1))], pid: 7)], at: Double(index))
        }
        #expect(engine.dnsLog.count == 200)
        #expect(engine.dnsLog.first?.name == "host-150.example")
        #expect(engine.dnsLog.last?.name == "host-349.example")
        #expect(engine.snapshot().dns.count == 200)
        // Empty answers are not worth logging.
        engine.observe([.resolved(name: "nothing.example", addresses: [], pid: nil), .resolved(name: "", addresses: [.v4(9)], pid: nil)], at: 400)
        #expect(engine.dnsLog.last?.name == "host-349.example")
    }

    @Test func theSimulatorNamesItsTraffic() {
        let engine = FlowEngine()
        SteppedRun.run(sources: [SimulatorSource(scenario: .developer)], engine: engine, until: 20)
        let flows = engine.flows.values
        let named = flows.filter { $0.hostname != nil }
        #expect(named.count == flows.count)
        #expect(flows.contains { $0.hostnameSource == .sni })
        #expect(flows.contains { $0.hostnameSource == .dns })
        #expect(flows.contains { $0.service == "QUIC" && $0.serviceBasis == .observed })
        #expect(flows.contains { $0.service == "HTTPS" && $0.serviceBasis == .observed })
        #expect(!engine.dnsLog.isEmpty)
        // Invented names stay inside domains reserved for examples.
        #expect(named.allSatisfy { $0.hostname!.hasSuffix(".example") || $0.hostname!.contains(".example.") })
        // And the filter can use them.
        let filter = try! FlowFilter("host:*.example.com")
        #expect(flows.contains { filter.matches($0, process: nil, now: engine.now) })
    }
}
