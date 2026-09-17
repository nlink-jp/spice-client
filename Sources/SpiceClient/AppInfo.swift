import Foundation

/// The product name and version shown to people. `make build` writes `git describe`
/// output into the bundle's Info.plist; no source file states a version.
enum AppInfo {
    static let name = "Spice Client"
    static var version: String {
        version(fromBundleValue: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }
    static var versionLine: String { name + " " + version }
    /// The display rule, separate from the bundle lookup so it can be tested.
    /// Shown verbatim: a `-dirty` or `-N-g<sha>` suffix identifies the exact build.
    static func version(fromBundleValue value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "dev" }
        return value
    }
}
