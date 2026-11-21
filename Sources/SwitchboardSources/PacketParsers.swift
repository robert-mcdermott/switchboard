import SwitchboardCore

// Parsers for the two things packet capture is for: DNS answers and TLS server names.
// Both take untrusted bytes off the wire, so every read is bounds-checked and every
// loop is bounded.

@inline(__always) private func be16(_ bytes: [UInt8], _ at: Int) -> Int {
    Int(bytes[at]) << 8 | Int(bytes[at + 1])
}

public enum DNSParser {
    public struct Message: Sendable {
        public var isResponse: Bool
        /// Name in the first question.
        public var question: String?
        public var addresses: [(name: String, address: IPAddress, ttl: UInt32)]
    }

    public static func parse(_ message: [UInt8]) -> Message? {
        guard message.count >= 12 else { return nil }
        let flags = be16(message, 2)
        let questions = be16(message, 4)
        let answers = be16(message, 6)
        guard questions <= 16, answers <= 256 else { return nil }

        var offset = 12
        var question: String?
        for index in 0..<questions {
            guard let (name, next) = readName(message, offset), next + 4 <= message.count else { return nil }
            if index == 0 { question = name }
            offset = next + 4
        }

        var addresses: [(name: String, address: IPAddress, ttl: UInt32)] = []
        for _ in 0..<answers {
            guard let (name, next) = readName(message, offset), next + 10 <= message.count else { break }
            let type = be16(message, next)
            let ttl = UInt32(be16(message, next + 4)) << 16 | UInt32(be16(message, next + 6))
            let dataLength = be16(message, next + 8)
            let data = next + 10
            guard data + dataLength <= message.count else { break }
            let isA = type == 1 && dataLength == 4
            let isAAAA = type == 28 && dataLength == 16
            if isA || isAAAA, let address = IPAddress(networkBytes: message[data..<(data + dataLength)]) {
                addresses.append((name, address, ttl))
            }
            offset = data + dataLength
        }
        return Message(isResponse: flags & 0x8000 != 0, question: question, addresses: addresses)
    }

    /// Reads a possibly compressed name. Returns the name and the offset just past it.
    static func readName(_ message: [UInt8], _ start: Int) -> (String, Int)? {
        var labels: [String] = []
        var offset = start
        var resume: Int?
        var jumps = 0
        while true {
            guard offset < message.count else { return nil }
            let length = Int(message[offset])
            if length == 0 {
                offset += 1
                break
            }
            if length & 0xC0 == 0xC0 {
                guard offset + 1 < message.count else { return nil }
                if resume == nil { resume = offset + 2 }
                offset = (length & 0x3F) << 8 | Int(message[offset + 1])
                jumps += 1
                guard jumps <= 16 else { return nil }
                continue
            }
            guard length < 64, offset + 1 + length <= message.count, labels.count < 127 else { return nil }
            labels.append(String(decoding: message[(offset + 1)..<(offset + 1 + length)], as: UTF8.self))
            offset += 1 + length
        }
        return (labels.joined(separator: "."), resume ?? offset)
    }
}

public enum TLSParser {
    public enum ServerName: Sendable, Equatable {
        /// The name, and the byte offset within the TCP payload where its extension starts.
        case found(String, extensionOffset: Int)
        /// A ClientHello with no server-name extension.
        case absent
        /// A ClientHello that continues past the bytes supplied.
        case truncated
        case notClientHello
    }

    /// Looks for the server name in the first bytes of a TCP stream.
    public static func serverName(inTCPPayload payload: [UInt8]) -> ServerName {
        // Record header (5): type 0x16 handshake, version 3.x. Handshake header (4): type 1 ClientHello.
        guard payload.count >= 6, payload[0] == 0x16, payload[1] == 0x03, payload[5] == 0x01 else {
            return .notClientHello
        }
        var offset = 5 + 4 + 2 + 32  // headers, client version, random
        guard offset < payload.count else { return .truncated }
        offset += 1 + Int(payload[offset])  // session id
        guard offset + 2 <= payload.count else { return .truncated }
        offset += 2 + be16(payload, offset)  // cipher suites
        guard offset + 1 <= payload.count else { return .truncated }
        offset += 1 + Int(payload[offset])  // compression methods
        guard offset + 2 <= payload.count else { return .truncated }
        let end = offset + 2 + be16(payload, offset)
        offset += 2

        while offset + 4 <= min(end, payload.count) {
            let type = be16(payload, offset)
            let length = be16(payload, offset + 2)
            let body = offset + 4
            if type == 0 {
                // list length (2), name type (1), name length (2), name
                guard body + 5 <= payload.count else { return .truncated }
                let nameLength = be16(payload, body + 3)
                guard body + 5 + nameLength <= payload.count else { return .truncated }
                let name = String(decoding: payload[(body + 5)..<(body + 5 + nameLength)], as: UTF8.self)
                return .found(name, extensionOffset: offset)
            }
            offset = body + length
        }
        return end > payload.count ? .truncated : .absent
    }
}
