import SwitchboardCore

/// The SQLite log arrives in M5 (docs/ROADMAP.md). GRDB becomes a dependency of this
/// target then, and of no other.
public enum SwitchboardStore {
    public static let directoryName = "Switchboard"
}
