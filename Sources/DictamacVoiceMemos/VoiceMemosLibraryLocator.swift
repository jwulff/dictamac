import Foundation
import DictamacCore

/// The output of a successful ``VoiceMemosLibraryLocator/locate()`` call.
///
/// Exposes both the chosen library directory and the full set of paths
/// the locator attempted, in probe order — downstream diagnostics (and
/// `--verbose` output) show "we tried A then B; chose B" without having
/// to re-derive the candidate list.
public struct VoiceMemosLibraryLocation: Sendable, Equatable {
    /// The first existing Voice Memos library directory.
    public let url: URL

    /// Every path the locator probed, in the order it tried them.
    /// Always a stable, deterministic list — even on success — so
    /// callers can surface "searched in A, B, … chose B".
    public let probedPaths: [URL]

    public init(url: URL, probedPaths: [URL]) {
        self.url = url
        self.probedPaths = probedPaths
    }
}

/// Resolves which Voice Memos library directory exists on this host
/// (PLAN.md §7 U6). Voice Memos uses one of two paths depending on
/// macOS version and iCloud sync state; this seam picks the first that
/// exists, or surfaces a deterministic ``DictamacError`` for the two
/// failure modes (missing on all paths, or TCC-denied on the first
/// candidate that exists).
///
/// The protocol exists so downstream indexers and the CLI's
/// `--list-voice-memos` mode (issue #25) can mock the discovery step in
/// tests without touching the user's real Voice Memos library.
public protocol VoiceMemosLibraryLocator: Sendable {
    /// Returns the URL of the first existing Voice Memos library
    /// directory along with the full probe list.
    ///
    /// - Throws:
    ///   - ``DictamacError/voiceMemoLibraryMissing(searched:)`` when
    ///     none of the candidate paths exist on disk (exit code 74).
    ///   - ``DictamacError/permissionDenied(domain:deepLink:)`` when a
    ///     candidate directory exists but cannot be read — typically a
    ///     TCC denial on the Files & Folders prompt (exit code 73).
    func locate() throws -> VoiceMemosLibraryLocation
}

/// Production implementation: probes the two well-known Voice Memos
/// library paths and returns the first that exists and is readable.
///
/// ## Probe order
///
/// 1. `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/`
///    — the modern macOS path; required when iCloud sync is enabled.
/// 2. `~/Library/Application Support/com.apple.voicememos/Recordings/`
///    — the older path; some older macOS releases or pre-iCloud
///    installs still land here.
///
/// ## TCC detection
///
/// A directory whose `fileExists` check returns `true` but which the
/// process can't read is treated as TCC-denied. The detector calls
/// ``FileManager/isReadableFile(atPath:)`` first because it doesn't
/// throw; agent-spawned processes routinely hit this case without ever
/// seeing the UI prompt (PLAN.md §9 risks table), so the locator's
/// stderr output is the user's only escape hatch — surface the
/// `Privacy_FilesAndFolders` deep-link verbatim per CLAUDE.md §"Required
/// TCC permissions".
///
/// `homeProvider` is injectable so tests can point the candidate-path
/// computation at a fixture directory rather than the user's real
/// `$HOME`. Defaults to ``NSHomeDirectory`` (which respects `$HOME` in
/// `swift test` runs).
public struct DefaultVoiceMemosLibraryLocator: VoiceMemosLibraryLocator {
    public typealias HomeProvider = @Sendable () -> URL

    /// Deep-link surfaced on ``DictamacError/permissionDenied`` when a
    /// candidate directory is TCC-denied. Matches PLAN.md §7 U6.
    static let filesAndFoldersDeepLink = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    )

    private let homeProvider: HomeProvider

    public init(
        homeProvider: @escaping HomeProvider = { URL(fileURLWithPath: NSHomeDirectory()) }
    ) {
        self.homeProvider = homeProvider
    }

    public func locate() throws -> VoiceMemosLibraryLocation {
        let candidates = candidatePaths()
        let fileManager = FileManager.default

        for candidate in candidates {
            // A non-directory item (regular file, symlink to a file,
            // device node) at the candidate path is treated as missing
            // — there is no library here, so probe the next candidate.
            // Without this check, the downstream readability probe
            // would mis-classify a stray file as TCC-denied and throw
            // `.permissionDenied`, which is misleading.
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            )
            guard exists, isDirectory.boolValue else {
                continue
            }
            // The directory exists. Confirm we can actually read it
            // before declaring victory — a TCC-denied directory still
            // reports as existing.
            if !isReadable(at: candidate, fileManager: fileManager) {
                throw DictamacError.permissionDenied(
                    domain: "Files & Folders",
                    deepLink: Self.filesAndFoldersDeepLink
                )
            }
            return VoiceMemosLibraryLocation(
                url: candidate,
                probedPaths: candidates
            )
        }

        throw DictamacError.voiceMemoLibraryMissing(searched: candidates)
    }

    /// The ordered candidate paths the locator probes. Exposed so
    /// diagnostics (and the default-init smoke test) can see what would
    /// be probed without invoking ``locate()``.
    public func candidatePaths() -> [URL] {
        let home = homeProvider()
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let groupContainers = library
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent("group.com.apple.VoiceMemos.shared", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        let applicationSupport = library
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.apple.voicememos", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        return [groupContainers, applicationSupport]
    }

    /// Returns `true` when the current process can both read the
    /// directory's metadata and list its contents.
    ///
    /// ``FileManager/isReadableFile(atPath:)`` is the cheap check (a
    /// `stat(2)` plus permission bits) and catches `chmod 000`. The
    /// follow-up ``contentsOfDirectory(at:...)`` call catches TCC
    /// denials where the kernel returns `EPERM` despite the POSIX
    /// permission bits being open — Apple's sandbox layer doesn't show
    /// up in `isReadableFile`'s answer. Either failing means the user
    /// can't list the Voice Memos library; both checks together cover
    /// `chmod`-simulated denials in tests AND real TCC denials in
    /// production.
    private func isReadable(at url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.isReadableFile(atPath: url.path) else {
            return false
        }
        do {
            _ = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
            return true
        } catch {
            return false
        }
    }
}
