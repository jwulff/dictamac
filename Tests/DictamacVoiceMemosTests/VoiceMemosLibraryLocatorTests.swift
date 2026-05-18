import Foundation
import Testing
@testable import DictamacCore
@testable import DictamacVoiceMemos

/// Tests for ``DefaultVoiceMemosLibraryLocator``.
///
/// Each test scaffolds a fresh fixture HOME inside `NSTemporaryDirectory()`
/// and injects a `homeProvider` returning that URL. The locator's
/// production path computation (`<home>/Library/Group Containers/...`
/// vs `<home>/Library/Application Support/...`) is exercised end-to-end
/// against real on-disk directories rather than mocked file APIs — the
/// detection logic IS the filesystem call, so faking that defeats the
/// test's purpose (see CLAUDE.md "Debugging Discipline §2").
@Suite struct VoiceMemosLibraryLocatorTests {
    // MARK: - Fixture helpers

    /// Returns a temp directory unique to this test plus its two
    /// candidate Voice Memos subdirectories. The caller chooses which
    /// (if either) to populate, then runs the locator against the temp
    /// directory's URL.
    private static func makeFixtureHome() throws -> Fixture {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-voicememos-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        return Fixture(home: home)
    }

    private struct Fixture {
        let home: URL

        var groupContainersPath: URL {
            home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Group Containers", isDirectory: true)
                .appendingPathComponent("group.com.apple.VoiceMemos.shared", isDirectory: true)
                .appendingPathComponent("Recordings", isDirectory: true)
        }

        var applicationSupportPath: URL {
            home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("com.apple.voicememos", isDirectory: true)
                .appendingPathComponent("Recordings", isDirectory: true)
        }

        func createGroupContainersPath() throws {
            try FileManager.default.createDirectory(
                at: groupContainersPath,
                withIntermediateDirectories: true
            )
        }

        func createApplicationSupportPath() throws {
            try FileManager.default.createDirectory(
                at: applicationSupportPath,
                withIntermediateDirectories: true
            )
        }

        /// Creates a regular file (not a directory) at the Group
        /// Containers candidate path. Used to exercise the locator's
        /// "is it actually a directory?" guard — a stray file at the
        /// candidate path should be treated as missing, not as a
        /// TCC-denied directory.
        func createGroupContainersAsFile() throws {
            try FileManager.default.createDirectory(
                at: groupContainersPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: groupContainersPath)
        }

        /// Symmetric helper: regular file at the fallback candidate
        /// path. Exercises the same guard on the second probe.
        func createApplicationSupportAsFile() throws {
            try FileManager.default.createDirectory(
                at: applicationSupportPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: applicationSupportPath)
        }

        func tearDown() {
            // Restore readable permissions before removing in case a
            // test simulated TCC denial via chmod 000.
            let candidates = [groupContainersPath, applicationSupportPath]
            for url in candidates {
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o700],
                        ofItemAtPath: url.path
                    )
                }
            }
            try? FileManager.default.removeItem(at: home)
        }
    }

    // MARK: - both-present prefers Group Containers

    @Test
    func bothPathsPresentPrefersGroupContainers() throws {
        let fixture = try Self.makeFixtureHome()
        defer { fixture.tearDown() }
        try fixture.createGroupContainersPath()
        try fixture.createApplicationSupportPath()

        let locator = DefaultVoiceMemosLibraryLocator(
            homeProvider: { fixture.home }
        )

        let location = try locator.locate()

        #expect(location.url == fixture.groupContainersPath)
        #expect(location.probedPaths == [
            fixture.groupContainersPath,
            fixture.applicationSupportPath,
        ])
        #expect(FileManager.default.fileExists(atPath: location.url.path))
    }

    // MARK: - only-fallback-present

    @Test
    func onlyFallbackPresentReturnsApplicationSupport() throws {
        let fixture = try Self.makeFixtureHome()
        defer { fixture.tearDown() }
        try fixture.createApplicationSupportPath()

        let locator = DefaultVoiceMemosLibraryLocator(
            homeProvider: { fixture.home }
        )

        let location = try locator.locate()

        #expect(location.url == fixture.applicationSupportPath)
        // probedPaths still exposes both candidates so diagnostics can
        // see what was attempted, in order.
        #expect(location.probedPaths == [
            fixture.groupContainersPath,
            fixture.applicationSupportPath,
        ])
        #expect(FileManager.default.fileExists(atPath: location.url.path))
    }

    // MARK: - only-group-containers-present

    @Test
    func onlyGroupContainersPresentReturnsGroupContainers() throws {
        let fixture = try Self.makeFixtureHome()
        defer { fixture.tearDown() }
        try fixture.createGroupContainersPath()

        let locator = DefaultVoiceMemosLibraryLocator(
            homeProvider: { fixture.home }
        )

        let location = try locator.locate()

        #expect(location.url == fixture.groupContainersPath)
        #expect(FileManager.default.fileExists(atPath: location.url.path))
    }

    // MARK: - neither-present → voiceMemoLibraryMissing (exit 74)

    @Test
    func neitherPathPresentThrowsVoiceMemoLibraryMissing() throws {
        let fixture = try Self.makeFixtureHome()
        defer { fixture.tearDown() }

        let locator = DefaultVoiceMemosLibraryLocator(
            homeProvider: { fixture.home }
        )

        do {
            _ = try locator.locate()
            Issue.record("Expected DictamacError.voiceMemoLibraryMissing")
        } catch let error as DictamacError {
            guard case .voiceMemoLibraryMissing(let searched) = error else {
                Issue.record("Expected .voiceMemoLibraryMissing, got \(error)")
                return
            }
            #expect(searched == [
                fixture.groupContainersPath,
                fixture.applicationSupportPath,
            ])
            #expect(error.exitCode == 74)
        }
    }

    // MARK: - unreadable directory → permissionDenied (exit 73)

    @Test
    func unreadableDirectoryThrowsPermissionDeniedWithDeepLink() throws {
        let fixture = try Self.makeFixtureHome()
        defer { fixture.tearDown() }
        try fixture.createGroupContainersPath()

        // Simulate a TCC denial by stripping read/execute permission on
        // the candidate directory. The locator should detect the
        // directory exists but is unreadable and surface
        // .permissionDenied rather than a successful locate.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.groupContainersPath.path
        )

        let locator = DefaultVoiceMemosLibraryLocator(
            homeProvider: { fixture.home }
        )

        do {
            _ = try locator.locate()
            Issue.record("Expected DictamacError.permissionDenied")
        } catch let error as DictamacError {
            guard case .permissionDenied(let domain, let deepLink) = error else {
                Issue.record("Expected .permissionDenied, got \(error)")
                return
            }
            #expect(domain == "Files & Folders")
            #expect(deepLink?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
            #expect(error.exitCode == 73)
            // The formatted stderr line should embed the deep-link so a
            // user can click it in a linkifying terminal.
            #expect(error.formattedStderrLine.contains("Privacy_FilesAndFolders"))
        }
    }

    // MARK: - unreadable fallback when group-containers absent

    @Test
    func unreadableFallbackPathAlsoThrowsPermissionDenied() throws {
        let fixture = try Self.makeFixtureHome()
        defer { fixture.tearDown() }
        try fixture.createApplicationSupportPath()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.applicationSupportPath.path
        )

        let locator = DefaultVoiceMemosLibraryLocator(
            homeProvider: { fixture.home }
        )

        do {
            _ = try locator.locate()
            Issue.record("Expected DictamacError.permissionDenied")
        } catch let error as DictamacError {
            guard case .permissionDenied(let domain, let deepLink) = error else {
                Issue.record("Expected .permissionDenied, got \(error)")
                return
            }
            #expect(domain == "Files & Folders")
            #expect(deepLink?.absoluteString.contains("Privacy_FilesAndFolders") == true)
        }
    }

    // MARK: - regular file at candidate path → voiceMemoLibraryMissing
    //
    // Regression for Copilot review thread on PR #45: a non-directory
    // item sitting at a candidate path used to be mis-classified as a
    // TCC-denied directory (readability probe failed → permissionDenied).
    // The locator now guards the existence check with isDirectory==true
    // so the offending path is treated as missing and probing continues.

    @Test
    func regularFileAtGroupContainersPathTreatedAsMissing() throws {
        let fixture = try Self.makeFixtureHome()
        defer { fixture.tearDown() }
        // Plant a regular file (not a directory) at the Group Containers
        // path; leave the fallback path absent. Expectation: the
        // locator skips the file, finds nothing at the fallback, and
        // throws .voiceMemoLibraryMissing — NOT .permissionDenied.
        try fixture.createGroupContainersAsFile()

        let locator = DefaultVoiceMemosLibraryLocator(
            homeProvider: { fixture.home }
        )

        do {
            _ = try locator.locate()
            Issue.record("Expected DictamacError.voiceMemoLibraryMissing")
        } catch let error as DictamacError {
            guard case .voiceMemoLibraryMissing(let searched) = error else {
                Issue.record("Expected .voiceMemoLibraryMissing, got \(error)")
                return
            }
            #expect(searched == [
                fixture.groupContainersPath,
                fixture.applicationSupportPath,
            ])
            #expect(error.exitCode == 74)
        }
    }

    @Test
    func regularFileAtFallbackPathTreatedAsMissing() throws {
        let fixture = try Self.makeFixtureHome()
        defer { fixture.tearDown() }
        // Symmetric case: Group Containers absent, fallback path
        // occupied by a regular file. Same expectation — neither
        // candidate yields a directory, so .voiceMemoLibraryMissing.
        try fixture.createApplicationSupportAsFile()

        let locator = DefaultVoiceMemosLibraryLocator(
            homeProvider: { fixture.home }
        )

        do {
            _ = try locator.locate()
            Issue.record("Expected DictamacError.voiceMemoLibraryMissing")
        } catch let error as DictamacError {
            guard case .voiceMemoLibraryMissing(let searched) = error else {
                Issue.record("Expected .voiceMemoLibraryMissing, got \(error)")
                return
            }
            #expect(searched == [
                fixture.groupContainersPath,
                fixture.applicationSupportPath,
            ])
            #expect(error.exitCode == 74)
        }
    }

    // MARK: - default HOME provider compiles against NSHomeDirectory

    @Test
    func defaultHomeProviderUsesNSHomeDirectory() {
        // Smoke test that the default initializer is callable and the
        // probedPaths shape is derivable without invoking locate()
        // (which would touch the real user's home).
        let locator = DefaultVoiceMemosLibraryLocator()
        let expectedProbes = locator.candidatePaths()
        #expect(expectedProbes.count == 2)
        // First candidate is always the Group Containers path.
        #expect(expectedProbes[0].path.contains("Group Containers/group.com.apple.VoiceMemos.shared/Recordings"))
        #expect(expectedProbes[1].path.contains("Application Support/com.apple.voicememos/Recordings"))
    }
}
