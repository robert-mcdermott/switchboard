/// Project-wide constants.
public enum Switchboard {
    public static let version = "0.1.1"

    /// Reverse-DNS prefix for the bundle identifier (`<prefix>.app`) and the collector's
    /// LaunchDaemon label (`<prefix>.collector`).
    public static let identifierPrefix = "io.github.robert-mcdermott.switchboard"

    /// The prefix builds before 0.1.0 used, whose settings and collector are carried over.
    public static let previousIdentifierPrefix = "local.switchboard"

    public static let collectorSocketPath = "/var/run/switchboard.sock"
}

public enum TransportProtocol: String, Sendable, Hashable, CaseIterable, Codable {
    case tcp
    case udp
}
