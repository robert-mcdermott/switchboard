import Foundation
import Testing

@testable import SwitchboardCore

private func makeFlow(
    process: String = "Slack Helper", pid: Int32 = 2144, user: String = "robert", proto: TransportProtocol = .tcp,
    remote: String = "52.21.130.202", remotePort: UInt16 = 443, localPort: UInt16 = 51_000,
    rateIn: Double = 0, rateOut: Double = 0, bytesIn: UInt64 = 0, bytesOut: UInt64 = 0, firstSeen: Double = 0,
    state: FlowState = .active, service: String? = "HTTPS", rtt: Double? = nil
) -> (Flow, ProcessRecord) {
    let flow = Flow(
        id: 1,
        key: FlowKey(
            proto: proto, local: Endpoint(address: IPAddress("10.0.0.36")!, port: localPort),
            remote: Endpoint(address: IPAddress(remote)!, port: remotePort)),
        pid: pid, direction: .outbound, interface: "en0", state: state, tcpState: .established,
        firstSeen: firstSeen, lastSeen: 100, lastActive: 100, closedAt: nil, ageExact: true,
        bytesIn: bytesIn, bytesOut: bytesOut, packetsIn: 0, packetsOut: 0, rateIn: rateIn, rateOut: rateOut,
        rttMS: rtt, retransmittedBytes: nil, service: service, serviceBasis: .port, hostname: nil, attribution: "test")
    return (flow, ProcessRecord(pid: pid, name: process, path: "/Applications/Slack.app/Contents/MacOS/\(process)", username: user))
}

private func matches(_ text: String, _ subject: (Flow, ProcessRecord), now: Double = 100) throws -> Bool {
    try FlowFilter(text).matches(subject.0, process: subject.1, now: now)
}

@Suite struct FlowFilterTests {
    @Test func anEmptyFilterMatchesEverything() throws {
        #expect(try FlowFilter("").isEmpty)
        #expect(try FlowFilter("   # only a comment").isEmpty)
        #expect(try matches("", makeFlow()))
        #expect(FlowFilter.all.matches(makeFlow().0, process: nil, now: 0))
    }

    @Test func matchesTextByContainmentEqualityAndWildcard() throws {
        let slack = makeFlow()
        #expect(try matches("process:slack", slack))
        #expect(try matches("process:\"Slack Helper\"", slack))
        #expect(try !matches("process=slack", slack))
        #expect(try matches("process=\"slack helper\"", slack))
        #expect(try matches("process!=Safari", slack))
        #expect(try matches("process:*helper", slack))
        #expect(try matches("process=s?ack*", slack))
        #expect(try !matches("process=*Safari*", slack))
        #expect(try matches("user:robert proto:tcp service=https state:active direction:outbound iface:en0", slack))
        #expect(try matches("path:/Applications/Slack.app", slack))
    }

    @Test func comparesNumbersWithUnits() throws {
        let busy = makeFlow(rateIn: 1_400_000, rateOut: 150_000, bytesIn: 80_000_000, bytesOut: 2_000_000, firstSeen: 100 - 8040, rtt: 31)
        #expect(try matches("rate_out>100KB/s", busy))
        #expect(try !matches("rate_out>200KB/s", busy))
        #expect(try matches("rate>1.5MB/s rate<1.6MB", busy))
        #expect(try matches("bytes>=82MB bytes_in=80mb bytes_out<=2000000", busy))
        #expect(try matches("age>2h age<3h age>=8040s", busy))
        #expect(try matches("rtt<50 rtt>=31ms rtt<0.05s", busy))
        #expect(try matches("pid:2144 r_port=443 l_port!=443 port:443 port:51000", busy))
        #expect(try !matches("port!=443", busy))
        #expect(try matches("port!=80", busy))
        // No measurement, no match, whichever way the comparison points.
        #expect(try !matches("rtt<1000", makeFlow()))
        #expect(try !matches("rtt>=0", makeFlow()))
    }

    @Test func matchesAddressesExactlyByNetworkAndByPattern() throws {
        let subject = makeFlow(remote: "10.20.30.40")
        #expect(try matches("remote:10.20.30.40", subject))
        #expect(try matches("remote:10.0.0.0/8 local=10.0.0.36", subject))
        #expect(try !matches("remote:192.168.0.0/16", subject))
        #expect(try matches("remote!=192.168.0.0/16", subject))
        #expect(try matches("remote:0.0.0.0/0", subject))
        #expect(try matches("r_ip:10.20.*", subject))

        let v6 = makeFlow(remote: "2606:4700::6812:1a30")
        #expect(try matches("remote:2606:4700::/32", v6))
        #expect(try matches("remote:2606:4700::6812:1a30", v6))
        #expect(try !matches("remote:2606:4701::/32", v6))
        #expect(try !matches("remote:10.0.0.0/8", v6))
        #expect(try matches("remote:2606:4700::6812:1a00/120", v6))
    }

    @Test func combinesTermsWithTheRightPrecedence() throws {
        let slack = makeFlow(), safari = makeFlow(process: "Safari", pid: 501, remotePort: 80, service: "HTTP")
        // AND binds tighter than OR; adjacency means AND.
        #expect(try matches("process:safari r_port:80 OR process:slack r_port:443", slack))
        #expect(try matches("process:safari r_port:80 OR process:slack r_port:443", safari))
        #expect(try !matches("process:safari AND (r_port:443 OR process:slack)", safari))
        #expect(try matches("NOT process:safari", slack))
        #expect(try !matches("NOT (process:slack OR process:safari)", slack))
        #expect(try matches("not process:safari and not r_port:80", slack))
        #expect(try matches("r_port:443 NOT process:*Safari*   # trailing comment", slack))
    }

    @Test func matchesBareWordsAgainstNameAddressAndService() throws {
        let slack = makeFlow()
        #expect(try matches("slack", slack))
        #expect(try matches("52.21", slack))
        #expect(try matches("https", slack))
        #expect(try !matches("safari", slack))
        #expect(try matches("\"Slack Helper\"", slack))
        #expect(try matches("2606:4700::6812:1a30", makeFlow(remote: "2606:4700::6812:1a30")))
    }

    @Test func explainsWhatIsWrong() {
        func error(_ text: String) -> FilterError? {
            do {
                _ = try FlowFilter(text)
                return nil
            } catch {
                return error
            }
        }
        #expect(error("colour:red")?.message == "Unknown field 'colour'")
        #expect(error("process:slack colour:red")?.position == 14)
        #expect(error("process>slack")?.message == "process is text; use : = or !=")
        #expect(error("rate>fast")?.message.contains("needs a number") == true)
        #expect(error("pid:12KB") != nil)
        #expect(error("remote:10.0.0.0/40") != nil)
        #expect(error("remote>10.0.0.1") != nil)
        #expect(error("(process:slack")?.message == "Missing )")
        #expect(error("process:slack)")?.message == "Unmatched )")
        #expect(error("process:\"slack")?.message == "Missing closing quote")
        #expect(error("process:slack OR")?.message == "Expected a term")
        #expect(error("AND process:slack") != nil)
        #expect(error("process:") != nil)
    }

    /// Random expressions, rendered to text, must parse back to something that agrees
    /// with evaluating the expression directly, on every flow of a simulated machine.
    @Test func agreesWithDirectEvaluationOnRandomExpressions() throws {
        indirect enum Expression {
            case leaf(Int)
            case and(Expression, Expression)
            case or(Expression, Expression)
            case not(Expression)
        }
        let leaves: [(text: String, test: @Sendable (Flow, ProcessRecord?) -> Bool)] = [
            ("proto:tcp", { flow, _ in flow.key.proto == .tcp }),
            ("r_port:443", { flow, _ in flow.key.remote.port == 443 }),
            ("rate>50KB/s", { flow, _ in flow.rateTotal > 50_000 }),
            ("bytes_in<1MB", { flow, _ in flow.bytesIn < 1_000_000 }),
            ("process:helper", { _, process in process?.name.lowercased().contains("helper") ?? false }),
            ("state=active", { flow, _ in flow.state == .active }),
            ("pid>=2500", { flow, _ in flow.pid >= 2500 }),
            ("service!=HTTPS", { flow, _ in (flow.service ?? "").lowercased() != "https" }),
        ]

        var random = SplitMix64(seed: 0xF117E4)
        func generate(depth: Int) -> Expression {
            if depth == 0 || random.below(4) == 0 { return .leaf(random.below(leaves.count)) }
            switch random.below(3) {
            case 0: return .and(generate(depth: depth - 1), generate(depth: depth - 1))
            case 1: return .or(generate(depth: depth - 1), generate(depth: depth - 1))
            default: return .not(generate(depth: depth - 1))
            }
        }
        func render(_ expression: Expression) -> String {
            switch expression {
            case .leaf(let index): leaves[index].text
            // Fully parenthesised, so the text means exactly what the tree says; AND is
            // sometimes left implicit to exercise both spellings.
            case .and(let a, let b): "(\(render(a))\(random.below(2) == 0 ? " AND " : " ")\(render(b)))"
            case .or(let a, let b): "(\(render(a)) OR \(render(b)))"
            case .not(let a): "NOT (\(render(a)))"
            }
        }
        func evaluate(_ expression: Expression, _ flow: Flow, _ process: ProcessRecord?) -> Bool {
            switch expression {
            case .leaf(let index): leaves[index].test(flow, process)
            case .and(let a, let b): evaluate(a, flow, process) && evaluate(b, flow, process)
            case .or(let a, let b): evaluate(a, flow, process) || evaluate(b, flow, process)
            case .not(let a): !evaluate(a, flow, process)
            }
        }

        let engine = FlowEngine()
        SteppedRun.run(sources: [SimulatorSource(scenario: .developer)], engine: engine, until: 15)
        let flows = Array(engine.flows.values)
        #expect(flows.count > 100)

        var decisions = 0, accepted = 0
        for _ in 0..<300 {
            let expression = generate(depth: 4)
            let filter = try FlowFilter(render(expression))
            for flow in flows {
                let process = engine.processes[flow.pid]
                let expected = evaluate(expression, flow, process)
                #expect(filter.matches(flow, process: process, now: engine.now) == expected, "\(filter.text)")
                decisions += 1
                if expected { accepted += 1 }
            }
        }
        // The expressions must actually discriminate, or the test proves nothing.
        #expect(accepted > decisions / 10 && accepted < decisions * 9 / 10)
    }
}
