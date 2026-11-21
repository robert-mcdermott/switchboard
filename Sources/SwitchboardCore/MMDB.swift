import Foundation

/// A reader for MaxMind DB files (`.mmdb`), the format DB-IP Lite and GeoLite2 ship in.
///
/// Written here rather than taken from a library: the format is small, and Switchboard
/// links no third-party code. The file is read-only and comes from outside, so every
/// offset is checked and pointer chains are bounded; a damaged file makes a lookup fail,
/// never crash.
public struct MMDBReader: Sendable {
    public indirect enum Value: Sendable, Equatable {
        case string(String)
        case double(Double)
        case unsigned(UInt64)
        case signed(Int64)
        case boolean(Bool)
        case bytes([UInt8])
        case array([Value])
        case map([String: Value])

        public subscript(key: String) -> Value? {
            if case .map(let map) = self { return map[key] }
            return nil
        }

        public var string: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        public var unsigned: UInt64? {
            if case .unsigned(let value) = self { return value }
            return nil
        }

        public var double: Double? {
            switch self {
            case .double(let value): value
            case .unsigned(let value): Double(value)
            case .signed(let value): Double(value)
            default: nil
            }
        }
    }

    public enum MMDBError: Error, CustomStringConvertible {
        case notADatabase(String)

        public var description: String {
            switch self {
            case .notADatabase(let reason): "not a usable MaxMind DB file: \(reason)"
            }
        }
    }

    /// The file's bytes, mapped from disk rather than read: a city database is over 100 MB,
    /// and only the pages lookups touch need ever be in memory.
    private let storage: Storage
    private var bytes: UnsafeRawBufferPointer { storage.bytes }
    private let nodeCount: Int
    private let recordSize: Int
    private let ipVersion: Int
    private let treeSize: Int
    /// What the file says it is, such as `DBIP-City-Lite` or `GeoLite2-ASN`.
    public let databaseType: String
    public let buildEpoch: UInt64

    static let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)

    /// Owns the bytes: a mapping of the file, or a copy of data given directly.
    final class Storage: @unchecked Sendable {
        let bytes: UnsafeRawBufferPointer
        private let mapped: Bool

        init(copying data: Data) {
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(data.count, 1), alignment: 8)
            _ = data.copyBytes(to: buffer.bindMemory(to: UInt8.self))
            bytes = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(buffer)[0..<data.count])
            mapped = false
        }

        init?(mapping url: URL) {
            let descriptor = open(url.path, O_RDONLY)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_size > 0 else { return nil }
            let size = Int(status.st_size)
            guard let address = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0), address != MAP_FAILED else { return nil }
            bytes = UnsafeRawBufferPointer(start: address, count: size)
            mapped = true
        }

        deinit {
            guard let base = bytes.baseAddress else { return }
            if mapped {
                munmap(UnsafeMutableRawPointer(mutating: base), bytes.count)
            } else {
                UnsafeMutableRawPointer(mutating: base).deallocate()
            }
        }
    }

    public init(data: Data) throws {
        try self.init(storage: Storage(copying: data))
    }

    private init(storage: Storage) throws {
        self.storage = storage
        let bytes = storage.bytes
        // The metadata sits at the very end, after the last occurrence of the marker.
        let searchFrom = max(0, bytes.count - 131_072)
        var found: Int?
        var index = bytes.count - Self.marker.count
        while index >= max(searchFrom, 0) {
            if bytes[index] == Self.marker[0], bytes[index..<(index + Self.marker.count)].elementsEqual(Self.marker) {
                found = index
                break
            }
            index -= 1
        }
        guard let found else { throw MMDBError.notADatabase("no metadata marker") }

        var decoder = Decoder(bytes: bytes, base: found + Self.marker.count)
        guard let metadata = decoder.value(at: 0)?.value else { throw MMDBError.notADatabase("unreadable metadata") }
        guard let nodes = metadata["node_count"]?.unsigned, let record = metadata["record_size"]?.unsigned,
              let version = metadata["ip_version"]?.unsigned
        else { throw MMDBError.notADatabase("metadata is missing the tree's shape") }
        // No real database comes near this; a larger claim is damage, and would overflow below.
        guard nodes < 1 << 32 else { throw MMDBError.notADatabase("implausible node count") }
        guard [24, 28, 32].contains(record), version == 4 || version == 6 else {
            throw MMDBError.notADatabase("unsupported record size \(record) or IP version \(version)")
        }
        nodeCount = Int(nodes)
        recordSize = Int(record)
        ipVersion = Int(version)
        treeSize = nodeCount * recordSize * 2 / 8
        guard nodeCount > 0, treeSize + 16 <= found else { throw MMDBError.notADatabase("the search tree does not fit the file") }
        databaseType = metadata["database_type"]?.string ?? ""
        buildEpoch = metadata["build_epoch"]?.unsigned ?? 0
    }

    public init(url: URL) throws {
        guard let storage = Storage(mapping: url) else { throw MMDBError.notADatabase("could not open \(url.lastPathComponent)") }
        try self.init(storage: storage)
    }

    /// The record for an address, or `nil` if the database has nothing on it.
    public func lookup(_ address: IPAddress) -> Value? {
        var bits = address.networkBytes
        if ipVersion == 6, bits.count == 4 {
            // IPv4 lives in the IPv6 tree under ::/96.
            bits = [UInt8](repeating: 0, count: 12) + bits
        } else if ipVersion == 4, bits.count == 16 {
            return nil
        }

        var node = 0
        for bit in 0..<(bits.count * 8) {
            guard node < nodeCount else { break }
            let right = (bits[bit / 8] >> UInt8(7 - bit % 8)) & 1 == 1
            guard let next = record(node: node, right: right) else { return nil }
            node = next
        }
        // A value equal to the node count means "no data"; larger points into the data section.
        guard node > nodeCount else { return nil }
        let offset = node - nodeCount - 16
        guard offset >= 0 else { return nil }
        var decoder = Decoder(bytes: bytes, base: treeSize + 16)
        return decoder.value(at: offset)?.value
    }

    private func record(node: Int, right: Bool) -> Int? {
        let base = node * recordSize * 2 / 8
        guard base + recordSize * 2 / 8 <= treeSize else { return nil }
        func byte(_ offset: Int) -> Int { Int(bytes[base + offset]) }
        switch recordSize {
        case 24:
            return right ? byte(3) << 16 | byte(4) << 8 | byte(5) : byte(0) << 16 | byte(1) << 8 | byte(2)
        case 28:
            // The two records share the middle byte, four bits each.
            return right
                ? (byte(3) & 0x0f) << 24 | byte(4) << 16 | byte(5) << 8 | byte(6)
                : (byte(3) >> 4) << 24 | byte(0) << 16 | byte(1) << 8 | byte(2)
        default:
            return right
                ? byte(4) << 24 | byte(5) << 16 | byte(6) << 8 | byte(7)
                : byte(0) << 24 | byte(1) << 16 | byte(2) << 8 | byte(3)
        }
    }

    /// Decodes the self-describing values of a data section.
    private struct Decoder {
        let bytes: UnsafeRawBufferPointer
        /// Where the section starts; offsets and pointers are relative to this.
        let base: Int
        /// Values decoded so far for one lookup: a guard against a file built to make us loop.
        var budget = 20_000

        mutating func value(at offset: Int, depth: Int = 0) -> (value: Value, next: Int)? {
            budget -= 1
            guard budget > 0, depth < 32, offset >= 0, base + offset < bytes.count else { return nil }
            var cursor = base + offset
            let control = bytes[cursor]
            cursor += 1
            var type = Int(control >> 5)

            if type == 1 {
                // A pointer to a value elsewhere in the section.
                let size = Int(control >> 3) & 0x3
                guard cursor + size + 1 <= bytes.count else { return nil }
                let low = Int(control & 0x7)
                let target: Int
                switch size {
                case 0: target = low << 8 | Int(bytes[cursor])
                case 1: target = (low << 16 | Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])) + 2048
                case 2: target = (low << 24 | Int(bytes[cursor]) << 16 | Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2])) + 526_336
                default: target = Int(bytes[cursor]) << 24 | Int(bytes[cursor + 1]) << 16 | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
                }
                guard let pointed = value(at: target, depth: depth + 1) else { return nil }
                // The value is elsewhere; reading carries on after the pointer itself.
                return (pointed.value, cursor + size + 1 - base)
            }

            if type == 0 {
                guard cursor < bytes.count else { return nil }
                type = 7 + Int(bytes[cursor])
                cursor += 1
            }

            var size = Int(control & 0x1f)
            switch size {
            case 29:
                guard cursor + 1 <= bytes.count else { return nil }
                size = 29 + Int(bytes[cursor])
                cursor += 1
            case 30:
                guard cursor + 2 <= bytes.count else { return nil }
                size = 285 + (Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1]))
                cursor += 2
            case 31:
                guard cursor + 3 <= bytes.count else { return nil }
                size = 65_821 + (Int(bytes[cursor]) << 16 | Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2]))
                cursor += 3
            default:
                break
            }

            func integer(_ count: Int) -> UInt64? {
                guard count <= 8, cursor + count <= bytes.count else { return nil }
                return bytes[cursor..<(cursor + count)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            }

            switch type {
            case 2:
                guard cursor + size <= bytes.count else { return nil }
                return (.string(String(decoding: bytes[cursor..<(cursor + size)], as: UTF8.self)), cursor + size - base)
            case 3:
                guard size == 8, let bits = integer(8) else { return nil }
                return (.double(Double(bitPattern: bits)), cursor + 8 - base)
            case 4:
                guard cursor + size <= bytes.count else { return nil }
                return (.bytes(Array(bytes[cursor..<(cursor + size)])), cursor + size - base)
            case 5, 6, 9:
                guard let number = integer(size) else { return nil }
                return (.unsigned(number), cursor + size - base)
            case 10:
                // 128-bit integers do not occur in the fields we use; keep the low 64 bits.
                guard cursor + size <= bytes.count, size <= 16 else { return nil }
                let low = bytes[cursor..<(cursor + size)].suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                return (.unsigned(low), cursor + size - base)
            case 8:
                guard size <= 4, let number = integer(size) else { return nil }
                return (.signed(Int64(Int32(truncatingIfNeeded: number))), cursor + size - base)
            case 7:
                var map: [String: Value] = [:]
                var next = cursor - base
                guard size <= 100_000 else { return nil }
                for _ in 0..<size {
                    guard let key = value(at: next, depth: depth + 1), case .string(let name) = key.value,
                          let item = value(at: key.next, depth: depth + 1)
                    else { return nil }
                    map[name] = item.value
                    next = item.next
                }
                return (.map(map), next)
            case 11:
                var items: [Value] = []
                var next = cursor - base
                guard size <= 100_000 else { return nil }
                for _ in 0..<size {
                    guard let item = value(at: next, depth: depth + 1) else { return nil }
                    items.append(item.value)
                    next = item.next
                }
                return (.array(items), next)
            case 14:
                // A boolean keeps its value where the size would be.
                return (.boolean(size != 0), cursor - base)
            case 15:
                guard size == 4, let bits = integer(4) else { return nil }
                return (.double(Double(Float(bitPattern: UInt32(bits)))), cursor + 4 - base)
            default:
                return nil
            }
        }
    }
}
