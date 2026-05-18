import Foundation
import AVFoundation
import Darwin

/// Walks a Voice Memos library directory and produces ``VoiceMemoMetadata``
/// values for every `*.m4a` asset on disk.
///
/// This is the resilience seam called out in `docs/PLAN.md` §9 risk row
/// "CloudRecordings.db schema changes in macOS 27": when the private
/// SQLite reader (issue #17) fails or its schema drifts, the filesystem
/// scanner still surfaces every recording Voice Memos has written. The
/// trade-off is fidelity — we lose Apple-curated titles and the
/// canonical `recordedAt` timestamp — but the user keeps a working
/// `list_voice_memos` and `--voice-memo` flow.
///
/// The protocol exists so the future merge/preference layer (issue #25)
/// can test the SQLite-vs-filesystem precedence rules without touching
/// the real `~/Library/.../Recordings/` directory.
public protocol FilesystemRecordingsScanner: Sendable {
    /// Walks `libraryURL` and returns one ``VoiceMemoMetadata`` per
    /// `*.m4a` asset successfully opened.
    ///
    /// - Throws: An error if `libraryURL` itself cannot be enumerated
    ///   (the directory was deleted between locator and scanner, the
    ///   process lacks read permission, etc.). Per-entry failures
    ///   (corrupt audio, missing xattrs) are surfaced via the injected
    ///   diagnostic sink — they never abort the scan.
    func scan(libraryURL: URL) throws -> [VoiceMemoMetadata]
}

/// Production implementation: enumerates `*.m4a` files recursively
/// under the library directory, probes extended attributes, and falls
/// back to filesystem dates. See the **Recursion** section below for
/// the exact enumerator options used.
///
/// ## Probe order for `recordedAt`
///
/// 1. `getxattr(2)` for `com.apple.metadata:kMDItemContentCreationDate`
///    (binary-plist-encoded `Date` — the same value Spotlight surfaces)
/// 2. `URL.resourceValues(forKeys: [.creationDateKey])`
/// 3. `URL.resourceValues(forKeys: [.contentModificationDateKey])`
///
/// ## Probe order for `title`
///
/// 1. `getxattr(2)` for `com.apple.metadata:kMDItemTitle`
/// 2. Filename stem (e.g. `New Recording 42` for
///    `New Recording 42.m4a`)
///
/// ## Per-entry failures
///
/// If `AVAudioFile(forReading:)` throws on a given asset (corrupt
/// container, zero-byte placeholder, unsupported codec), the scanner
/// emits a warning through the injected ``diagnosticSink`` and skips
/// that entry. The scan continues with the remaining files. The caller
/// is responsible for routing the sink to `stderr` only when
/// `--verbose` is set; the scanner itself never writes to stdout or
/// stderr directly (stdout discipline — CLAUDE.md).
///
/// ## `.icloud` placeholders
///
/// Files with an `.icloud` extension are iCloud-evicted placeholders;
/// reading them would normally trigger a Files Provider download.
/// This scanner does **NOT** trigger iCloud downloads — it silently
/// skips any entry whose name ends in `.icloud`. iCloud download
/// orchestration is out of scope for the epic (#4); revisit when a
/// user reports a real eviction.
///
/// ## Recursion
///
/// The scanner walks `libraryURL` **recursively** via
/// `FileManager.enumerator(at:includingPropertiesForKeys:options:errorHandler:)`,
/// collecting every `*.m4a` asset under the library — including those
/// nested under per-account or per-date subdirectories that Voice
/// Memos may use on newer macOS releases. Hidden files / directories
/// are ignored (`.skipsHiddenFiles`, e.g. `.Trash`) and the walk does
/// not descend into bundle/package contents
/// (`.skipsPackageDescendants` — defensive; voice memos are not
/// packages today). Symbolic links are filtered out by inspecting
/// `URLResourceKey.isSymbolicLinkKey` on each yielded URL —
/// `DirectoryEnumerationOptions` has no native "skip symlinks" flag,
/// but discarding them after the fact protects against an aliased
/// asset double-counting under recursion. This matches the
/// filesystem-fallback contract in `docs/PLAN.md` §7 U6.
public final class DefaultFilesystemRecordingsScanner: FilesystemRecordingsScanner {
    /// Names of the extended attributes the scanner probes. Public for
    /// test verification — production callers should not need these.
    public enum XattrName {
        public static let creationDate = "com.apple.metadata:kMDItemContentCreationDate"
        public static let title = "com.apple.metadata:kMDItemTitle"
    }

    /// Callback invoked once per per-entry failure with a short
    /// human-readable warning. The caller routes this to stderr under
    /// `--verbose` (production CLI) or captures it in tests. Defaults
    /// to `nil` — silent skip.
    private let diagnosticSink: (@Sendable (String) -> Void)?

    public init(diagnosticSink: (@Sendable (String) -> Void)? = nil) {
        self.diagnosticSink = diagnosticSink
    }

    public func scan(libraryURL: URL) throws -> [VoiceMemoMetadata] {
        let fileManager = FileManager.default

        // Validate the library root up front so a missing or
        // not-a-directory path raises a concrete error instead of
        // silently yielding an empty walk. `FileManager.enumerator(at:...)`
        // returns `nil` for both "no such directory" and "not a
        // directory", which would be indistinguishable from "empty
        // library". A `fileExists(atPath:isDirectory:)` probe is O(1)
        // — no scan of children — versus `contentsOfDirectory` which
        // materializes every immediate child only to discard it.
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: libraryURL.path, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            // Mirror `contentsOfDirectory`'s NSCocoaErrorDomain shape so
            // existing callers and tests that pattern-match on the
            // thrown error stay correct.
            throw CocoaError(
                .fileReadNoSuchFile,
                userInfo: [NSFilePathErrorKey: libraryURL.path]
            )
        }

        // `enumerator(at:...)` recurses by default. Skipping hidden
        // files drops `.Trash` and similar Apple-managed hidden trees;
        // skipping package descendants is defensive (voice memos are
        // flat `.m4a` files today, but a future bundle-shaped asset
        // shouldn't be drilled into blindly). `DirectoryEnumerationOptions`
        // does not expose a "skip symbolic links" flag, so symlinks are
        // filtered out below by resource-key inspection — an aliased
        // root would otherwise risk re-entering itself.
        guard let enumerator = fileManager.enumerator(
            at: libraryURL,
            includingPropertiesForKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [
                .skipsHiddenFiles,
                .skipsPackageDescendants,
            ],
            errorHandler: { [diagnosticSink] url, error in
                // Returning `true` keeps the walk going past per-entry
                // failures (unreadable subdirectory, transient I/O
                // error). The sink routes the warning to `--verbose`
                // stderr; callers without a sink get a silent skip.
                diagnosticSink?(
                    "filesystem-scanner: enumeration error at \(url.path) — \(error.localizedDescription)"
                )
                return true
            }
        ) else {
            // Already validated above; enumerator failure here is
            // pathological. Return empty rather than crashing.
            return []
        }

        var m4aEntries: [URL] = []
        for case let url as URL in enumerator
            where url.pathExtension.lowercased() == "m4a" {
            // Defensive: filter symbolic links so an aliased asset
            // can't double-count under recursive enumeration.
            // `resourceValues(forKeys:)` is the documented way to
            // inspect link status; a failure here is treated as
            // "not a symlink" (the asset will be probed normally by
            // `AVAudioFile` and skipped if it's actually broken).
            let isSymlink = (try? url.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ).isSymbolicLink) ?? false
            if isSymlink { continue }
            m4aEntries.append(url)
        }

        // Sort by path for deterministic ordering. Enumeration order is
        // filesystem-dependent (HFS+ vs APFS) and depth-first traversal
        // can interleave subdirectories arbitrarily, so unit tests need
        // a stable shape to assert against.
        m4aEntries.sort { $0.path < $1.path }

        var results: [VoiceMemoMetadata] = []
        results.reserveCapacity(m4aEntries.count)

        for entry in m4aEntries {
            if let metadata = makeMetadata(for: entry) {
                results.append(metadata)
            }
        }
        return results
    }

    /// Builds a ``VoiceMemoMetadata`` for one asset, or returns `nil`
    /// (with a warning routed through ``diagnosticSink``) when the
    /// audio file cannot be opened.
    private func makeMetadata(for url: URL) -> VoiceMemoMetadata? {
        let stem = url.deletingPathExtension().lastPathComponent

        let duration: TimeInterval
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let sampleRate = audioFile.processingFormat.sampleRate
            if sampleRate > 0 {
                duration = Double(audioFile.length) / sampleRate
            } else {
                duration = 0
            }
        } catch {
            diagnosticSink?(
                "filesystem-scanner: skipping \(url.lastPathComponent) — \(error.localizedDescription)"
            )
            return nil
        }

        let title = readStringXattr(XattrName.title, at: url) ?? stem
        let recordedAt = recordedAtDate(for: url)

        return VoiceMemoMetadata(
            identifier: stem,
            title: title,
            recordedAt: recordedAt,
            durationSeconds: duration,
            assetPath: url
        )
    }

    /// Resolves `recordedAt` by walking the documented probe order. If
    /// every probe fails, returns the Unix epoch — a deterministic
    /// placeholder. The fall-through is exotic (a filesystem that
    /// reports neither a creation nor a modification date), so this
    /// case mainly exists so the function is total.
    private func recordedAtDate(for url: URL) -> Date {
        if let xattrDate = readDateXattr(XattrName.creationDate, at: url) {
            return xattrDate
        }
        if let creationDate = resourceDate(for: .creationDateKey, at: url) {
            return creationDate
        }
        if let modificationDate = resourceDate(
            for: .contentModificationDateKey,
            at: url
        ) {
            return modificationDate
        }
        return Date(timeIntervalSince1970: 0)
    }

    private func resourceDate(for key: URLResourceKey, at url: URL) -> Date? {
        do {
            let values = try url.resourceValues(forKeys: [key])
            switch key {
            case .creationDateKey:
                return values.creationDate
            case .contentModificationDateKey:
                return values.contentModificationDate
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    // MARK: - xattr helpers

    /// Reads the raw bytes of an extended attribute, or `nil` when the
    /// attribute is absent or unreadable. `getxattr(2)` returning `-1`
    /// is the normal "no such attribute" case (errno=ENOATTR) — not an
    /// error worth surfacing.
    private func readXattr(_ name: String, at url: URL) -> Data? {
        return url.withUnsafeFileSystemRepresentation { pathPointer -> Data? in
            guard let pathPointer else { return nil }
            // First call: ask for the size of the attribute.
            let size = getxattr(pathPointer, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }

            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { rawBuffer -> ssize_t in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return getxattr(pathPointer, name, base, size, 0, 0)
            }
            guard read > 0 else { return nil }
            if read < size {
                buffer = buffer.prefix(read)
            }
            return buffer
        }
    }

    /// Decodes an xattr whose payload is a binary-plist-encoded `Date`.
    /// Returns `nil` for any decoding failure — the caller falls back
    /// to filesystem dates.
    private func readDateXattr(_ name: String, at url: URL) -> Date? {
        guard let data = readXattr(name, at: url) else { return nil }
        let value: Any
        do {
            value = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            return nil
        }
        if let date = value as? Date {
            return date
        }
        return nil
    }

    /// Decodes an xattr whose payload is a binary-plist-encoded
    /// `String`. Returns `nil` for any decoding failure.
    private func readStringXattr(_ name: String, at url: URL) -> String? {
        guard let data = readXattr(name, at: url) else { return nil }
        let value: Any
        do {
            value = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            return nil
        }
        if let string = value as? String {
            return string
        }
        return nil
    }
}
