import Foundation

/// The filter language shared by the graph, the tables, and (later) the log.
///
///     process:Slack rate_out>100KB/s
///     user:root service:SSH
///     r_port:443 NOT process:*Helper*
///     age>1h bytes<10KB                      # long-lived, low-volume
///     remote:10.0.0.0/8 OR remote:192.168.0.0/16
///
/// Terms are joined by AND unless OR is written. `:` means "contains" for text and
/// "equals" for numbers; text also takes `=`, `!=`, and `*` `?` wildcards; numbers take
/// `=` `!=` `>` `>=` `<` `<=` and units. A bare word matches process name, remote address,
/// or service. Text containing spaces is quoted.
public struct FlowFilter: Sendable, Equatable {
    public let text: String
    private let root: Node?

    /// Matches everything.
    public static let all = FlowFilter()

    private init() {
        text = ""
        root = nil
    }

    public init(_ text: String) throws(FilterError) {
        self.text = text
        var parser = Parser(tokens: try Tokenizer.tokenize(text))
        root = try parser.parseQuery()
    }

    public var isEmpty: Bool { root == nil }

    public func matches(_ flow: Flow, process: ProcessRecord?, now: EngineTime) -> Bool {
        guard let root else { return true }
        return root.evaluate(flow, process, now)
    }

    /// Field names, for help and completion.
    public static let fields: [(name: String, help: String)] = [
        ("process", "process name"), ("pid", "process id"), ("user", "account name"), ("path", "executable path"),
        ("proto", "tcp or udp"), ("service", "service label"), ("state", "new, active, idle, closing, closed"),
        ("direction", "outbound or inbound"), ("iface", "network interface"), ("host", "hostname"),
        ("remote", "remote address or CIDR"), ("local", "local address or CIDR"), ("r_port", "remote port"),
        ("l_port", "local port"), ("port", "either port"), ("rate", "total rate, e.g. 100KB/s"),
        ("rate_in", "receive rate"), ("rate_out", "send rate"), ("bytes", "total bytes, e.g. 10MB"),
        ("bytes_in", "bytes received"), ("bytes_out", "bytes sent"), ("age", "connection age, e.g. 1h"),
        ("rtt", "round-trip time in ms"),
    ]

    // MARK: - Syntax tree

    indirect enum Node: Sendable, Equatable {
        case and(Node, Node)
        case or(Node, Node)
        case not(Node)
        case term(Term)

        func evaluate(_ flow: Flow, _ process: ProcessRecord?, _ now: EngineTime) -> Bool {
            switch self {
            case .and(let a, let b): a.evaluate(flow, process, now) && b.evaluate(flow, process, now)
            case .or(let a, let b): a.evaluate(flow, process, now) || b.evaluate(flow, process, now)
            case .not(let a): !a.evaluate(flow, process, now)
            case .term(let term): term.evaluate(flow, process, now)
            }
        }
    }

    enum Comparison: String, Sendable, Equatable {
        case has = ":", equal = "=", notEqual = "!=", greater = ">", greaterOrEqual = ">=", less = "<", lessOrEqual = "<="
    }

    enum TextField: String, Sendable, CaseIterable {
        case process, user, path, proto, service, state, direction, iface, host
    }

    enum NumberField: String, Sendable, CaseIterable {
        case pid, r_port, l_port, port, rate, rate_in, rate_out, bytes, bytes_in, bytes_out, age, rtt
    }

    enum AddressField: String, Sendable, CaseIterable {
        case remote, local
    }

    enum Term: Sendable, Equatable {
        case text(TextField, negated: Bool, TextPattern)
        case number(NumberField, Comparison, Double)
        case address(AddressField, negated: Bool, AddressPattern)
        case bare(TextPattern)

        func evaluate(_ flow: Flow, _ process: ProcessRecord?, _ now: EngineTime) -> Bool {
            switch self {
            case .text(let field, let negated, let pattern):
                let value: String
                switch field {
                case .process: value = process?.name ?? ""
                case .user: value = process?.username ?? ""
                case .path: value = process?.path ?? ""
                case .proto: value = flow.key.proto.rawValue
                case .service: value = flow.service ?? ""
                case .state: value = flow.state.rawValue
                case .direction: value = flow.direction.rawValue
                case .iface: value = flow.interface ?? ""
                case .host: value = flow.hostname ?? ""
                }
                return pattern.matches(value) != negated

            case .number(let field, let comparison, let wanted):
                func compare(_ actual: Double) -> Bool {
                    switch comparison {
                    case .has, .equal: actual == wanted
                    case .notEqual: actual != wanted
                    case .greater: actual > wanted
                    case .greaterOrEqual: actual >= wanted
                    case .less: actual < wanted
                    case .lessOrEqual: actual <= wanted
                    }
                }
                switch field {
                case .pid: return compare(Double(flow.pid))
                case .r_port: return compare(Double(flow.key.remote.port))
                case .l_port: return compare(Double(flow.key.local.port))
                case .port:
                    // "Either port": true if either satisfies it, except that "not equal" means neither equals.
                    let remote = compare(Double(flow.key.remote.port)), local = compare(Double(flow.key.local.port))
                    return comparison == .notEqual ? remote && local : remote || local
                case .rate: return compare(flow.rateTotal)
                case .rate_in: return compare(flow.rateIn)
                case .rate_out: return compare(flow.rateOut)
                case .bytes: return compare(Double(flow.bytesTotal))
                case .bytes_in: return compare(Double(flow.bytesIn))
                case .bytes_out: return compare(Double(flow.bytesOut))
                case .age: return compare(flow.age(at: now))
                case .rtt:
                    // A flow with no measurement satisfies nothing.
                    guard let rtt = flow.rttMS else { return false }
                    return compare(rtt)
                }

            case .address(let field, let negated, let pattern):
                let address = field == .remote ? flow.key.remote.address : flow.key.local.address
                return pattern.matches(address) != negated

            case .bare(let pattern):
                return pattern.matches(process?.name ?? "") || pattern.matches(flow.key.remote.address.description)
                    || pattern.matches(flow.service ?? "") || pattern.matches(flow.hostname ?? "")
            }
        }
    }

    /// Case-insensitive text matching: a substring, the whole value, or a wildcard pattern.
    enum TextPattern: Sendable, Equatable {
        case contains(String)
        case exactly(String)
        case glob([Character])

        init(_ raw: String, exact: Bool) {
            let lowered = raw.lowercased()
            if lowered.contains("*") || lowered.contains("?") {
                // A wildcard pattern describes the whole value; `:` wraps it so it may match anywhere.
                self = .glob(Array(exact ? lowered : "*" + lowered + "*"))
            } else {
                self = exact ? .exactly(lowered) : .contains(lowered)
            }
        }

        func matches(_ value: String) -> Bool {
            let lowered = value.lowercased()
            switch self {
            case .contains(let needle): return lowered.contains(needle)
            case .exactly(let wanted): return lowered == wanted
            case .glob(let pattern): return Self.glob(pattern[...], Array(lowered)[...])
            }
        }

        /// `*` matches any run of characters, `?` exactly one.
        private static func glob(_ pattern: ArraySlice<Character>, _ text: ArraySlice<Character>) -> Bool {
            var p = pattern.startIndex, t = text.startIndex
            var star: Int?, mark = t
            while t < text.endIndex {
                if p < pattern.endIndex, pattern[p] == "?" || pattern[p] == text[t] {
                    p += 1
                    t += 1
                } else if p < pattern.endIndex, pattern[p] == "*" {
                    star = p
                    mark = t
                    p += 1
                } else if let back = star {
                    p = back + 1
                    mark += 1
                    t = mark
                } else {
                    return false
                }
            }
            while p < pattern.endIndex, pattern[p] == "*" { p += 1 }
            return p == pattern.endIndex
        }
    }

    enum AddressPattern: Sendable, Equatable {
        case exactly(IPAddress)
        /// A network and how many leading bits must match.
        case network(IPAddress, bits: Int)
        case text(TextPattern)

        func matches(_ address: IPAddress) -> Bool {
            switch self {
            case .exactly(let wanted):
                return address == wanted
            case .network(let network, let bits):
                switch (network, address) {
                case (.v4(let a), .v4(let b)):
                    return bits == 0 || (a ^ b) >> UInt32(32 - bits) == 0
                case (.v6(let ah, let al), .v6(let bh, let bl)):
                    if bits == 0 { return true }
                    if bits <= 64 { return bits == 64 ? ah == bh : (ah ^ bh) >> UInt64(64 - bits) == 0 }
                    return ah == bh && (bits == 128 ? al == bl : (al ^ bl) >> UInt64(128 - bits) == 0)
                default:
                    return false
                }
            case .text(let pattern):
                return pattern.matches(address.description)
            }
        }
    }
}

public struct FilterError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// Character offset in the filter text where the problem starts.
    public var position: Int

    public var description: String { message }
}

// MARK: - Tokenizer

private enum Token: Equatable {
    case open, close, and, or, not
    /// A term such as `rate>10KB/s` or a bare word, with quotes already removed from its value.
    case word(field: String?, comparison: FlowFilter.Comparison?, value: String)
}

private struct Positioned {
    var token: Token
    var position: Int
}

private enum Tokenizer {
    static func tokenize(_ text: String) throws(FilterError) -> [Positioned] {
        let characters = Array(text)
        var tokens: [Positioned] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character == "#" {
                break  // comment to end of line
            } else if character == "(" {
                tokens.append(Positioned(token: .open, position: index))
                index += 1
            } else if character == ")" {
                tokens.append(Positioned(token: .close, position: index))
                index += 1
            } else {
                let start = index
                var raw = ""
                var quoted = false
                var hadQuote = false
                while index < characters.count {
                    let current = characters[index]
                    if current == "\"" {
                        quoted.toggle()
                        hadQuote = true
                        raw.append(current)
                    } else if !quoted, current.isWhitespace || current == "(" || current == ")" {
                        break
                    } else {
                        raw.append(current)
                    }
                    index += 1
                }
                guard !quoted else { throw FilterError(message: "Missing closing quote", position: start) }
                switch raw.uppercased() {
                case "AND" where !hadQuote: tokens.append(Positioned(token: .and, position: start))
                case "OR" where !hadQuote: tokens.append(Positioned(token: .or, position: start))
                case "NOT" where !hadQuote: tokens.append(Positioned(token: .not, position: start))
                default: tokens.append(Positioned(token: split(raw), position: start))
                }
            }
        }
        return tokens
    }

    /// Splits `field<op>value` at the first operator outside quotes.
    private static func split(_ raw: String) -> Token {
        let characters = Array(raw)
        var quoted = false
        for (offset, character) in characters.enumerated() {
            if character == "\"" { quoted.toggle() }
            guard !quoted else { continue }
            let next: Character? = offset + 1 < characters.count ? characters[offset + 1] : nil
            var symbol: String?
            switch character {
            case "!" where next == "=": symbol = "!="
            case ">": symbol = next == "=" ? ">=" : ">"
            case "<": symbol = next == "=" ? "<=" : "<"
            case ":", "=": symbol = String(character)
            default: break
            }
            if let symbol, let comparison = FlowFilter.Comparison(rawValue: symbol) {
                let field = String(characters[..<offset])
                let value = String(characters[(offset + symbol.count)...])
                return .word(field: field, comparison: comparison, value: unquote(value))
            }
        }
        return .word(field: nil, comparison: nil, value: unquote(raw))
    }

    private static func unquote(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "")
    }
}

// MARK: - Parser

private struct Parser {
    let tokens: [Positioned]
    var index = 0

    private var current: Positioned? { index < tokens.count ? tokens[index] : nil }

    mutating func parseQuery() throws(FilterError) -> FlowFilter.Node? {
        guard !tokens.isEmpty else { return nil }
        let node = try parseOr()
        if let extra = current {
            throw FilterError(message: extra.token == .close ? "Unmatched )" : "Unexpected text", position: extra.position)
        }
        return node
    }

    private mutating func parseOr() throws(FilterError) -> FlowFilter.Node {
        var node = try parseAnd()
        while current?.token == .or {
            index += 1
            node = .or(node, try parseAnd())
        }
        return node
    }

    private mutating func parseAnd() throws(FilterError) -> FlowFilter.Node {
        var node = try parseUnary()
        while let next = current, next.token != .or, next.token != .close {
            if next.token == .and { index += 1 }
            node = .and(node, try parseUnary())
        }
        return node
    }

    private mutating func parseUnary() throws(FilterError) -> FlowFilter.Node {
        guard let token = current else {
            throw FilterError(message: "Expected a term", position: tokens.last.map { $0.position + 1 } ?? 0)
        }
        switch token.token {
        case .not:
            index += 1
            return .not(try parseUnary())
        case .open:
            index += 1
            let inner = try parseOr()
            guard current?.token == .close else { throw FilterError(message: "Missing )", position: token.position) }
            index += 1
            return inner
        case .close:
            throw FilterError(message: "Unmatched )", position: token.position)
        case .and, .or:
            throw FilterError(message: "Expected a term before \(token.token == .and ? "AND" : "OR")", position: token.position)
        case .word(let field, let comparison, let value):
            index += 1
            return .term(try Self.term(field: field, comparison: comparison, value: value, at: token.position))
        }
    }

    private static func term(
        field: String?, comparison: FlowFilter.Comparison?, value: String, at position: Int
    ) throws(FilterError) -> FlowFilter.Term {
        guard let field, let comparison else {
            guard !value.isEmpty else { throw FilterError(message: "Empty term", position: position) }
            return .bare(FlowFilter.TextPattern(value, exact: false))
        }
        let name = aliases[field.lowercased()] ?? field.lowercased()

        if let text = FlowFilter.TextField(rawValue: name) {
            guard !value.isEmpty else { throw FilterError(message: "\(field) needs a value", position: position) }
            switch comparison {
            case .has: return .text(text, negated: false, FlowFilter.TextPattern(value, exact: false))
            case .equal: return .text(text, negated: false, FlowFilter.TextPattern(value, exact: true))
            case .notEqual: return .text(text, negated: true, FlowFilter.TextPattern(value, exact: true))
            default: throw FilterError(message: "\(field) is text; use : = or !=", position: position)
            }
        }
        if let number = FlowFilter.NumberField(rawValue: name) {
            guard let parsed = Self.number(value, for: number) else {
                throw FilterError(message: "\(field) needs a number\(Self.unitHint(number)), not '\(value)'", position: position)
            }
            return .number(number, comparison, parsed)
        }
        if let address = FlowFilter.AddressField(rawValue: name) {
            let negated: Bool
            switch comparison {
            case .has, .equal: negated = false
            case .notEqual: negated = true
            default: throw FilterError(message: "\(field) is an address; use : = or !=", position: position)
            }
            return .address(address, negated: negated, try Self.address(value, field: field, at: position))
        }
        // `2606:4700::1` on its own is an address, not a field called 2606.
        let whole = field + comparison.rawValue + value
        if IPAddress(whole) != nil { return .bare(FlowFilter.TextPattern(whole, exact: false)) }
        throw FilterError(message: "Unknown field '\(field)'", position: position)
    }

    private static let aliases = [
        "r_ip": "remote", "ip": "remote", "dst": "remote", "l_ip": "local", "src": "local", "hostname": "host",
        "interface": "iface", "protocol": "proto", "name": "process", "bytes_total": "bytes", "rate_total": "rate",
        "rport": "r_port", "lport": "l_port",
    ]

    private static func address(_ value: String, field: String, at position: Int) throws(FilterError) -> FlowFilter.AddressPattern {
        if let slash = value.firstIndex(of: "/") {
            guard let network = IPAddress(String(value[..<slash])), let bits = Int(value[value.index(after: slash)...]),
                  bits >= 0, bits <= (network.isIPv6 ? 128 : 32)
            else { throw FilterError(message: "'\(value)' is not a network like 10.0.0.0/8", position: position) }
            return .network(network, bits: bits)
        }
        if let exact = IPAddress(value) { return .exactly(exact) }
        guard !value.isEmpty else { throw FilterError(message: "\(field) needs an address", position: position) }
        return .text(FlowFilter.TextPattern(value, exact: false))
    }

    private static func unitHint(_ field: FlowFilter.NumberField) -> String {
        switch field {
        case .rate, .rate_in, .rate_out: " such as 100KB/s"
        case .bytes, .bytes_in, .bytes_out: " such as 10MB"
        case .age: " such as 30s or 1h"
        case .rtt: " of milliseconds"
        default: ""
        }
    }

    /// A number with an optional unit: `100KB/s`, `10MB`, `1h`, `250ms`.
    private static func number(_ text: String, for field: FlowFilter.NumberField) -> Double? {
        var digits = text.lowercased()
        if digits.hasSuffix("/s") { digits.removeLast(2) }
        var unit = ""
        while let last = digits.last, last.isLetter {
            unit.insert(last, at: unit.startIndex)
            digits.removeLast()
        }
        guard let value = Double(digits), value.isFinite else { return nil }

        switch field {
        case .pid, .r_port, .l_port, .port:
            return unit.isEmpty ? value : nil
        case .rate, .rate_in, .rate_out, .bytes, .bytes_in, .bytes_out:
            let scale: [String: Double] = ["": 1, "b": 1, "kb": 1e3, "k": 1e3, "mb": 1e6, "m": 1e6, "gb": 1e9, "g": 1e9, "tb": 1e12]
            return scale[unit].map { value * $0 }
        case .age:
            let scale: [String: Double] = ["": 1, "s": 1, "ms": 0.001, "m": 60, "min": 60, "h": 3600, "d": 86_400]
            return scale[unit].map { value * $0 }
        case .rtt:
            let scale: [String: Double] = ["": 1, "ms": 1, "s": 1000]
            return scale[unit].map { value * $0 }
        }
    }
}
