import Foundation
import Testing
@testable import DictamacCore

/// Tests for `DictamacVersion` — the single source of truth for the
/// CLI banner and the MCP `serverInfo.version` (issue #32).
///
/// Two responsibilities are exercised:
///
/// 1. **Runtime contract.** `DictamacVersion.current` always returns a
///    non-empty string. Under `swift test` the embedded Info.plist is
///    not reachable through `Bundle.main` (the test runner is the main
///    bundle), so the value should be the documented fallback
///    `"0.0.0-unknown"`.
/// 2. **Drift guard.** The value the binary will report at runtime is
///    whatever `Resources/Info.plist` says — so this suite also reads
///    `Resources/Info.plist` directly off disk and asserts that
///    `CFBundleShortVersionString` and `CFBundleVersion` are both
///    set and match. If a future agent bumps one but forgets the
///    other (the exact bug this issue exists to prevent), the test
///    fails loudly.
struct DictamacVersionTests {

    // MARK: - Runtime contract

    @Test func currentIsNeverEmpty() {
        #expect(!DictamacVersion.current.isEmpty)
    }

    @Test func unknownFallbackIsExposedAndStable() {
        // The fallback value is part of the public contract — both as
        // a constant tests can assert against and as the documented
        // behavior under `swift test`. Pinning the literal value here
        // means a bump shows up in code review.
        #expect(DictamacVersion.unknown == "0.0.0-unknown")
    }

    @Test func currentMatchesFallbackUnderSwiftTest() {
        // Under `swift test`, `Bundle.main` is the test runner — not
        // the dictamac executable — so the embedded Info.plist is not
        // reachable and `DictamacVersion.current` must fall through to
        // the documented fallback. If this assertion ever fails it
        // means either: (a) the test runner started shipping a
        // CFBundleShortVersionString of its own, or (b) the lookup
        // logic regressed. Either way it needs investigation.
        #expect(DictamacVersion.current == DictamacVersion.unknown)
    }

    // MARK: - Drift guard against Resources/Info.plist on disk

    @Test func resourcesInfoPlistHasMatchingShortAndBuildVersions() throws {
        // Walk up from this source file to the repository root, then
        // load `Resources/Info.plist`. Using `#filePath` keeps the
        // assertion stable regardless of where `swift test` is invoked
        // from (CI vs. local checkout vs. worktree).
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent() // DictamacCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <repo>
        let plistURL = repoRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("Info.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let dict = plist as? [String: Any] else {
            Issue.record("Info.plist did not decode to a dictionary")
            return
        }

        let shortVersion = dict["CFBundleShortVersionString"] as? String
        let bundleVersion = dict["CFBundleVersion"] as? String

        #expect(shortVersion != nil, "CFBundleShortVersionString is required")
        #expect(bundleVersion != nil, "CFBundleVersion is required")
        #expect(shortVersion?.isEmpty == false)
        #expect(bundleVersion?.isEmpty == false)

        // The drift guard: the two version keys in Info.plist must
        // agree. The Makefile uses `-sectcreate __TEXT __info_plist`
        // to embed this exact file into the release binary, so any
        // drift here is what gets shipped.
        if shortVersion != bundleVersion {
            let short = shortVersion ?? "nil"
            let build = bundleVersion ?? "nil"
            Issue.record("CFBundleShortVersionString and CFBundleVersion must agree; found short=\(short) build=\(build)")
        }
    }
}
