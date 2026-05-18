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

/// Production implementation: enumerates `*.m4a` files non-recursively,
/// probes extended attributes, and falls back to filesystem dates.
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
/// Voice Memos as of macOS 26 writes all `.m4a` assets flat at the top
/// of `Recordings/`. The scanner does **not** descend into
/// subdirectories. If a future macOS release nests by date, this
/// behavior changes and the doc-comment is the canonical record of
/// what the scanner does today.
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
        let entries = try fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        )

        // Sort by path for deterministic ordering. Directory enumeration
        // order is filesystem-dependent (HFS+ vs APFS), and unit tests
        // need a stable shape to assert against.
        let m4aEntries = entries
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .sorted { $0.path < $1.path }

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
