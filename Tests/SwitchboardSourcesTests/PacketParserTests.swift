import Testing

@testable import SwitchboardSources

@Suite struct DNSParserTests {
    /// A response for `example.com` with one A record, using a compression pointer for the answer name.
    static let response: [UInt8] = {
        var bytes: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        bytes.append(7)
        bytes.append(contentsOf: Array("example".utf8))
        bytes.append(3)
        bytes.append(contentsOf: Array("com".utf8))
        bytes.append(0)
        bytes.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        bytes.append(contentsOf: [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04])
        bytes.append(contentsOf: [93, 184, 216, 34])
        return bytes
    }()

    @Test func readsQuestionAndAnswer() throws {
        let message = try #require(DNSParser.parse(Self.response))
        #expect(message.isResponse)
        #expect(message.question == "example.com")
        #expect(message.addresses.count == 1)
        #expect(message.addresses.first?.name == "example.com")
        #expect(message.addresses.first?.address.description == "93.184.216.34")
        #expect(message.addresses.first?.ttl == 300)
    }

    @Test func survivesEveryTruncation() {
        for length in 0..<Self.response.count {
            _ = DNSParser.parse(Array(Self.response.prefix(length)))
        }
    }

    @Test func rejectsPointerLoops() {
        // A name that points at itself.
        let looping: [UInt8] = [0, 0, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0, 1, 0, 1]
        #expect(DNSParser.parse(looping) == nil)
    }
}

@Suite struct TLSParserTests {
    /// A minimal ClientHello carrying one padding-like extension and then the server name.
    static func clientHello(serverName: String) -> [UInt8] {
        let name = Array(serverName.utf8)

        var extensions: [UInt8] = [0x00, 0x17, 0x00, 0x00]  // an unrelated, empty extension first
        extensions.append(contentsOf: [0x00, 0x00])  // server name
        extensions.append(contentsOf: be16(name.count + 5))
        extensions.append(contentsOf: be16(name.count + 3))
        extensions.append(0x00)
        extensions.append(contentsOf: be16(name.count))
        extensions.append(contentsOf: name)

        var body: [UInt8] = [0x03, 0x03]
        body.append(contentsOf: [UInt8](repeating: 0xAB, count: 32))
        body.append(0x00)  // session id
        body.append(contentsOf: [0x00, 0x02, 0x13, 0x01])  // cipher suites
        body.append(contentsOf: [0x01, 0x00])  // compression
        body.append(contentsOf: be16(extensions.count))
        body.append(contentsOf: extensions)

        var record: [UInt8] = [0x16, 0x03, 0x01]
        record.append(contentsOf: be16(body.count + 4))
        record.append(contentsOf: [0x01, 0x00])
        record.append(contentsOf: be16(body.count))
        record.append(contentsOf: body)
        return record
    }

    static func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xff)] }

    @Test func findsServerName() {
        let hello = Self.clientHello(serverName: "switchboard.example")
        guard case .found(let name, _) = TLSParser.serverName(inTCPPayload: hello) else {
            Issue.record("server name not found")
            return
        }
        #expect(name == "switchboard.example")
    }

    @Test func reportsTruncationInsteadOfGuessing() {
        let hello = Self.clientHello(serverName: "switchboard.example")
        for length in 6..<hello.count {
            let result = TLSParser.serverName(inTCPPayload: Array(hello.prefix(length)))
            #expect(result == .truncated, "prefix of \(length) bytes gave \(result)")
        }
    }

    @Test func ignoresOtherTraffic() {
        #expect(TLSParser.serverName(inTCPPayload: Array("GET / HTTP/1.1\r\n".utf8)) == .notClientHello)
        #expect(TLSParser.serverName(inTCPPayload: []) == .notClientHello)
    }
}
