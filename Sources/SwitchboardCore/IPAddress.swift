import Darwin

/// An IPv4 or IPv6 address held as plain integers so it is cheap to hash and compare.
public enum IPAddress: Hashable, Sendable {
    /// Numeric value with the first octet in the most significant byte.
    case v4(UInt32)
    /// The 128-bit address split into its high and low halves, most significant byte first.
    case v6(hi: UInt64, lo: UInt64)

    /// Builds an address from 4 (IPv4) or 16 (IPv6) bytes in network order.
    public init?(networkBytes bytes: some Collection<UInt8>) {
        switch bytes.count {
        case 4:
            self = .v4(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case 16:
            let hi = bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let lo = bytes.dropFirst(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            self = .v6(hi: hi, lo: lo)
        default:
            return nil
        }
    }

    public var isIPv6: Bool {
        if case .v6 = self { return true }
        return false
    }

    /// The all-zero wildcard address (`0.0.0.0` or `::`).
    public var isUnspecified: Bool {
        switch self {
        case .v4(let value): value == 0
        case .v6(let hi, let lo): hi == 0 && lo == 0
        }
    }

    public var isLoopback: Bool {
        switch self {
        case .v4(let value): value >> 24 == 127
        case .v6(let hi, let lo): hi == 0 && lo == 1
        }
    }

    /// The address as bytes in network order.
    public var networkBytes: [UInt8] {
        func bytes(of value: UInt64, count: Int) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: count)
            for index in 0..<count {
                let shift = UInt64(8 * (count - 1 - index))
                result[index] = UInt8(truncatingIfNeeded: value >> shift)
            }
            return result
        }
        switch self {
        case .v4(let value):
            return bytes(of: UInt64(value), count: 4)
        case .v6(let hi, let lo):
            return bytes(of: hi, count: 8) + bytes(of: lo, count: 8)
        }
    }
}

extension IPAddress: CustomStringConvertible {
    public var description: String {
        switch self {
        case .v4(let value):
            return "\(value >> 24).\((value >> 16) & 0xff).\((value >> 8) & 0xff).\(value & 0xff)"
        case .v6:
            var address = in6_addr()
            let bytes = networkBytes
            withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return buffer.withUnsafeMutableBufferPointer { text in
                guard inet_ntop(AF_INET6, &address, text.baseAddress, socklen_t(text.count)) != nil,
                      let base = text.baseAddress
                else { return "?" }
                return String(cString: base)
            }
        }
    }
}

extension IPAddress {
    /// Parses dotted-quad IPv4 or any textual IPv6 form.
    public init?(_ text: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self.init(networkBytes: withUnsafeBytes(of: v4) { Array($0) })
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            self.init(networkBytes: withUnsafeBytes(of: v6) { Array($0) })
            return
        }
        return nil
    }
}

extension IPAddress: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let address = IPAddress(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an IP address: \(text)"))
        }
        self = address
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
