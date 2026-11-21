/// Project-wide constants.
public enum Switchboard {
    public static let version = "0.0.1"

    /// Reverse-DNS prefix for the bundle identifier and LaunchDaemon label.
    /// Placeholder until the owner picks one (docs/SPEC.md §16).
    public static let identifierPrefix = "local.switchboard"

    public static let collectorSocketPath = "/var/run/switchboard.sock"
}

public enum TransportProtocol: String, Sendable, Hashable, CaseIterable, Codable {
    case tcp
    case udp
}
