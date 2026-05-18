import Foundation
import Testing
import AVFoundation
import Darwin
@testable import DictamacVoiceMemos

/// Tests for ``DefaultFilesystemRecordingsScanner``.
///
/// Each test scaffolds a fresh fixture directory inside
/// `NSTemporaryDirectory()`, populates it with synthesized silent
/// `.m4a` assets (and, where the test calls for it, sets extended
/// attributes via `setxattr(2)`), and exercises the scanner against
/// that on-disk shape. The xattr probe order and the per-entry
/// don't-throw invariant are filesystem-level behaviors, so the
/// integration tests touch real files in a real temp directory rather
/// than mocking the filesystem (see CLAUDE.md "Debugging Discipline §2").
@Suite struct FilesystemRecordingsScannerTests {

    // MARK: - Fixture helpers

    /// Creates a unique temp directory for a single test. Caller is
    /// responsible for tearing it down via ``Fixture/tearDown()``.
    private static func makeFixture() throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-fs-scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return Fixture(directory: directory)
    }

    private struct Fixture {
        let directory: URL

        func tearDown() {
            try? FileManager.default.removeItem(at: directory)
        }

        /// Writes a tiny silent AAC-in-M4A file at `<directory>/<stem>.m4a`
        /// and returns its URL.
        @discardableResult
        func writeSilentM4A(stem: String, duration: Double = 0.05) throws -> URL {
            let url = directory.appendingPathComponent("\(stem).m4a")
            try synthesizeSilentM4A(at: url, duration: duration)
            return url
        }

        /// Writes a zero-byte placeholder that masquerades as an m4a
        /// asset. Used to exercise the corrupt-audio skip path.
        @discardableResult
        func writeCorruptM4A(stem: String) throws -> URL {
            let url = directory.appendingPathComponent("\(stem).m4a")
            try Data().write(to: url)
            return url
        }

        /// Writes an `.icloud` placeholder — empty file with the
        /// double extension `.m4a.icloud` — to verify the scanner
        /// skips them without attempting iCloud download.
        @discardableResult
        func writeICloudPlaceholder(stem: String) throws -> URL {
            let url = directory.appendingPathComponent("\(stem).m4a.icloud")
            try Data().write(to: url)
            return url
        }
    }

    // MARK: - Empty directory → empty array

    @Test
    func emptyDirectoryReturnsEmptyArray() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }

        let scanner = DefaultFilesystemRecordingsScanner()
        let results = try scanner.scan(libraryURL: fixture.directory)

        #expect(results.isEmpty)
    }

    // MARK: - One m4a, no xattrs → title falls back to filename stem

    @Test
    func singleEntryWithoutXattrsFallsBackToFilenameStem() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let asset = try fixture.writeSilentM4A(stem: "memo-alpha")

        let scanner = DefaultFilesystemRecordingsScanner()
        let results = try scanner.scan(libraryURL: fixture.directory)

        #expect(results.count == 1)
        guard let entry = results.first else { return }
        #expect(entry.identifier == "memo-alpha")
        #expect(entry.title == "memo-alpha")
        // `contentsOfDirectory` resolves `/var/...` to `/private/var/...`
        // on macOS, so the URL may not be byte-identical to the URL we
        // just wrote. Compare via standardized paths instead.
        #expect(entry.assetPath.standardizedFileURL.path
                == asset.standardizedFileURL.path)
        #expect(entry.durationSeconds > 0)
    }

    // MARK: - One m4a with title xattr → title from xattr

    @Test
    func titleXattrOverridesFilenameStem() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let asset = try fixture.writeSilentM4A(stem: "memo-bravo")
        try setStringXattr(
            name: DefaultFilesystemRecordingsScanner.XattrName.title,
            value: "Standup with the team",
            at: asset
        )

        let scanner = DefaultFilesystemRecordingsScanner()
        let results = try scanner.scan(libraryURL: fixture.directory)

        #expect(results.count == 1)
        #expect(results.first?.title == "Standup with the team")
        // identifier is still the stem — it is the stable filesystem key.
        #expect(results.first?.identifier == "memo-bravo")
    }

    // MARK: - One m4a with creation-date xattr → recordedAt matches

    @Test
    func creationDateXattrIsUsedForRecordedAt() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let asset = try fixture.writeSilentM4A(stem: "memo-charlie")

        // Pick a date far from "now" so a stray filesystem fallback
        // doesn't accidentally match.
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        try setDateXattr(
            name: DefaultFilesystemRecordingsScanner.XattrName.creationDate,
            value: expected,
            at: asset
        )

        let scanner = DefaultFilesystemRecordingsScanner()
        let results = try scanner.scan(libraryURL: fixture.directory)

        #expect(results.count == 1)
        guard let entry = results.first else { return }
        // PropertyListSerialization round-trips Date with millisecond
        // precision; allow a tiny tolerance.
        let delta = abs(entry.recordedAt.timeIntervalSince(expected))
        #expect(delta < 0.001)
    }

    // MARK: - Corrupt audio file → entry skipped, sink called, scan continues

    @Test
    func corruptAudioFileIsSkippedWithDiagnostic() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        try fixture.writeCorruptM4A(stem: "broken")

        let warnings = WarningSink()
        let scanner = DefaultFilesystemRecordingsScanner(
            diagnosticSink: warnings.callback
        )
        let results = try scanner.scan(libraryURL: fixture.directory)

        #expect(results.isEmpty)
        let captured = warnings.snapshot()
        #expect(captured.count == 1)
        #expect(captured.first?.contains("broken.m4a") == true)
    }

    // MARK: - Mixed: 2 valid + 1 corrupt → returns 2, sink called once

    @Test
    func mixedDirectoryReturnsValidEntriesAndSkipsCorruptOne() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        try fixture.writeSilentM4A(stem: "alpha")
        try fixture.writeSilentM4A(stem: "bravo")
        try fixture.writeCorruptM4A(stem: "zeta-broken")

        let warnings = WarningSink()
        let scanner = DefaultFilesystemRecordingsScanner(
            diagnosticSink: warnings.callback
        )
        let results = try scanner.scan(libraryURL: fixture.directory)

        #expect(results.count == 2)
        let ids = Set(results.map(\.identifier))
        #expect(ids == ["alpha", "bravo"])

        let captured = warnings.snapshot()
        #expect(captured.count == 1)
        #expect(captured.first?.contains("zeta-broken.m4a") == true)
    }

    // MARK: - .icloud placeholders are skipped silently

    @Test
    func iCloudPlaceholdersAreSkippedSilently() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        try fixture.writeSilentM4A(stem: "real-memo")
        try fixture.writeICloudPlaceholder(stem: "evicted-memo")

        let warnings = WarningSink()
        let scanner = DefaultFilesystemRecordingsScanner(
            diagnosticSink: warnings.callback
        )
        let results = try scanner.scan(libraryURL: fixture.directory)

        // Only the real memo surfaces.
        #expect(results.count == 1)
        #expect(results.first?.identifier == "real-memo")
        // .icloud placeholders are filtered by extension — no warning.
        #expect(warnings.snapshot().isEmpty)
    }

    // MARK: - Missing-library directory throws

    @Test
    func missingLibraryDirectoryThrows() {
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "dictamac-fs-scanner-missing-\(UUID().uuidString)"
            )

        let scanner = DefaultFilesystemRecordingsScanner()
        var didThrow = false
        do {
            _ = try scanner.scan(libraryURL: bogus)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }
}

// MARK: - Thread-safe warning capture

/// Concurrency-safe sink that accumulates warnings emitted by the
/// scanner. Tests inspect the captured list after `scan` returns.
///
/// The scanner declares its diagnostic callback as
/// `@Sendable (String) -> Void`, so the wrapper has to satisfy
/// `Sendable` too — hence the lock-guarded mutable state and the
/// `final class` + unchecked-Sendable shape.
private final class WarningSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var callback: @Sendable (String) -> Void {
        return { [weak self] message in
            self?.lock.lock()
            defer { self?.lock.unlock() }
            self?.storage.append(message)
        }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - xattr write helpers (test-only)

/// Writes `value` as a binary-plist-encoded `String` to the given
/// extended attribute. Tests use this to fake the Spotlight metadata
/// that Voice Memos would normally set.
private func setStringXattr(name: String, value: String, at url: URL) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: value as NSString,
        format: .binary,
        options: 0
    )
    try setRawXattr(name: name, data: data, at: url)
}

/// Writes `value` as a binary-plist-encoded `Date` to the given
/// extended attribute.
private func setDateXattr(name: String, value: Date, at url: URL) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: value as NSDate,
        format: .binary,
        options: 0
    )
    try setRawXattr(name: name, data: data, at: url)
}

/// Raw `setxattr(2)` wrapper for tests. Mirrors the scanner's
/// `getxattr(2)` pattern but throws on failure (in production we never
/// write xattrs — only Voice Memos does — but tests need the symmetric
/// operation).
private func setRawXattr(name: String, data: Data, at url: URL) throws {
    try url.withUnsafeFileSystemRepresentation { pathPointer in
        guard let pathPointer else {
            throw NSError(
                domain: "FilesystemRecordingsScannerTests",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Path is not representable",
                ]
            )
        }
        let result = data.withUnsafeBytes { rawBuffer -> Int32 in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return setxattr(pathPointer, name, base, data.count, 0, 0)
        }
        if result != 0 {
            let posixError = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(posixError),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "setxattr(\(name)) failed: \(String(cString: strerror(posixError)))",
                ]
            )
        }
    }
}

// MARK: - Silent M4A synthesis
//
// AVAssetWriter is the only API path that produces AAC-in-M4A files;
// `AVAudioFile(forWriting:)` only writes linear PCM. The pattern is
// copied from `Tests/DictamacCoreTests/AudioFileResolverTests.swift`
// (which writes the same kind of silent fixture for the resolver
// tests). Both copies stay small — 50ms of silence is enough for the
// scanner to compute a non-zero duration.

private func synthesizeSilentM4A(at url: URL, duration: Double) throws {
    // AVAssetWriter refuses to overwrite an existing file; clear any
    // leftover artifact from a previous test before starting.
    try? FileManager.default.removeItem(at: url)

    let sampleRate: Double = 22050
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32000,
    ]
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
        throw NSError(
            domain: "FilesystemRecordingsScannerTests",
            code: -2,
            userInfo: [
                NSLocalizedDescriptionKey: "AVAssetWriter rejected AAC input",
            ]
        )
    }
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    guard let pcmFormat = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: 1
    ) else {
        throw NSError(
            domain: "FilesystemRecordingsScannerTests",
            code: -3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "AVAudioFormat construction failed",
            ]
        )
    }
    let frameCount = AVAudioFrameCount(duration * sampleRate)
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: pcmFormat,
        frameCapacity: frameCount
    ) else {
        throw NSError(
            domain: "FilesystemRecordingsScannerTests",
            code: -4,
            userInfo: [
                NSLocalizedDescriptionKey: "AVAudioPCMBuffer alloc failed",
            ]
        )
    }
    buffer.frameLength = frameCount
    // Channel data is zero-initialized — silent buffer.

    guard let sampleBuffer = buffer.toCMSampleBuffer() else {
        throw NSError(
            domain: "FilesystemRecordingsScannerTests",
            code: -5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "PCM -> CMSampleBuffer conversion failed",
            ]
        )
    }
    input.append(sampleBuffer)
    input.markAsFinished()

    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    if semaphore.wait(timeout: .now() + .seconds(10)) == .timedOut {
        throw NSError(
            domain: "FilesystemRecordingsScannerTests",
            code: -6,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "AVAssetWriter.finishWriting timed out after 10s",
            ]
        )
    }

    if writer.status != .completed {
        throw writer.error ?? NSError(
            domain: "FilesystemRecordingsScannerTests",
            code: -7,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "AVAssetWriter failed with status \(writer.status.rawValue)",
            ]
        )
    }
}

// MARK: - PCM -> CMSampleBuffer bridge (test-only)

private extension AVAudioPCMBuffer {
    func toCMSampleBuffer() -> CMSampleBuffer? {
        let audioFormat = self.format
        var asbd = audioFormat.streamDescription.pointee
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(audioFormat.sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(self.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: self.audioBufferList
        ) == noErr else {
            return nil
        }

        return sampleBuffer
    }
}
