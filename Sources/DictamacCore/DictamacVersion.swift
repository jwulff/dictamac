import Foundation

/// Single source of truth for the dictamac version string.
///
/// The release binary embeds `Resources/Info.plist` into its
/// `__TEXT,__info_plist` section via the `-sectcreate` linker flag (see
/// PLAN.md §7 U11 and the `Makefile`). At runtime, `Bundle.main` exposes
/// that embedded plist through `infoDictionary`, so reading
/// `CFBundleShortVersionString` from `Bundle.main` gives us the same
/// version the OS uses for the bundle. Both the CLI's
/// `--version` flag and the MCP `initialize` response's
/// `serverInfo.version` field read from this constant, so they cannot
/// drift from the plist or from each other.
///
/// ## Test bundles intentionally fall through to "unknown"
///
/// When running under `swift test`, `Bundle.main` is the test runner —
/// **not** the dictamac executable — and its Info.plist does not
/// describe dictamac. `infoDictionary?["CFBundleShortVersionString"]`
/// either returns `nil` (no key) or returns the test runner's version,
/// neither of which is meaningful for dictamac. The fallback value
/// `"0.0.0-unknown"` exists for that case; consumers that care about
/// the real version should observe it from the signed release binary,
/// not from a test process.
///
/// See `Tests/DictamacCoreTests/DictamacVersionTests.swift` for the
/// drift guard that asserts `Resources/Info.plist` and this constant
/// stay aligned at build time.
public enum DictamacVersion {

    /// Fallback version reported when the embedded Info.plist is not
    /// reachable (notably, when running inside `swift test`). Exposed
    /// so tests can assert the documented fallback behavior.
    public static let unknown: String = "0.0.0-unknown"

    /// Version string read from the binary's embedded Info.plist at
    /// startup. Computed once via a static let initializer so the
    /// `Bundle.main` lookup happens only once per process.
    public static let current: String = {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty {
            return version
        }
        return unknown
    }()
}
