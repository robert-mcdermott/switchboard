import Foundation

/// Finds this module's resources whether the code runs from `swift run` or from inside
/// `Switchboard.app`.
///
/// SwiftPM's generated `Bundle.module` looks beside the executable and then falls back
/// to an absolute path inside the build directory. In a hand-assembled app bundle the
/// first location is wrong (resources belong in `Contents/Resources`) and the second
/// only exists on the machine that built it, so the app location is checked first.
public enum RenderResources {
    public enum Origin: String, Sendable {
        /// `Switchboard.app/Contents/Resources`
        case appBundle
        /// SwiftPM's own lookup
        case swiftPM
    }

    static let bundleName = "Switchboard_SwitchboardRender.bundle"

    public static let located: (bundle: Bundle, origin: Origin) = {
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent(bundleName)),
           bundle.url(forResource: "Shaders", withExtension: nil) != nil
        {
            return (bundle, .appBundle)
        }
        return (Bundle.module, .swiftPM)
    }()

    public static func shaderSource(named name: String) throws -> String {
        guard let url = located.bundle.url(forResource: name, withExtension: "metal", subdirectory: "Shaders") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Shaders/\(name).metal"])
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
