import Testing
import Foundation
import AVFoundation
@testable import DictamacCore

struct AudioFileResolverTests {

    // MARK: - Error paths (exit code contract)

    @Test func missingFileMapsToFileNotFoundWithExitCode64() async throws {
        let resolver = DefaultAudioFileResolver()
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-no-such-file-\(UUID().uuidString).m4a")

        // Single invocation — capture the thrown error and inspect both
        // its specific case and its exit code in one pass.
        do {
            _ = try await resolver.resolve(source: .path(missing.path))
            Issue.record("expected resolve to throw")
        } catch let error as DictamacError {
            guard case .fileNotFound(let url) = error else {
                Issue.record("expected .fileNotFound, got \(error)")
                return
            }
            #expect(url.path == missing.standardizedFileURL.path)
            #expect(error.exitCode == 64)
        }
    }

    // MARK: - Stdin intake (issue #12)

    @Test func stdinEmptyMapsToAudioDecodeFailedWithExitCode65() async throws {
        // Zero-byte stdin (e.g. `: | dictamac -`) is not a valid audio
        // file. Surface as exit 65 with a stderr message explaining stdin
        // was empty rather than letting AVAudioFile produce a confusing
        // codec error against a zero-byte file.
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()  // EOF immediately.
        let resolver = DefaultAudioFileResolver(
            stdinProvider: { pipe.fileHandleForReading }
        )

        do {
            _ = try await resolver.resolve(source: .stdin)
            Issue.record("expected resolve to throw for empty stdin")
        } catch let error as DictamacError {
            guard case .audioDecodeFailed(_, let underlying) = error else {
                Issue.record("expected .audioDecodeFailed, got \(error)")
                return
            }
            #expect(error.exitCode == 65)
            // Stderr-bound message must explain that stdin was empty.
            #expect(error.description.lowercased().contains("stdin"))
            #expect(error.description.lowercased().contains("empty"))
            #expect(underlying.localizedDescription.lowercased().contains("stdin"))
        }
    }

    @Test func stdinValidM4APipedThroughResolves() async throws {
        // The happy path: bytes from a valid .m4a file are piped through
        // an injected FileHandle. Resolver drains them to a temp file
        // and validates with AVAudioFile.
        let m4a = try writeSilentM4A(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: m4a) }
        let bytes = try Data(contentsOf: m4a)

        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: bytes)
        try pipe.fileHandleForWriting.close()  // signal EOF
        let resolver = DefaultAudioFileResolver(
            stdinProvider: { pipe.fileHandleForReading }
        )

        let resolved = try await resolver.resolve(source: .stdin)
        // The returned URL must live under NSTemporaryDirectory and have
        // a .m4a extension per the documented default container.
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .standardizedFileURL
        #expect(resolved.url.standardizedFileURL.path.hasPrefix(tempRoot.path))
        #expect(resolved.url.pathExtension == "m4a")
        #expect(FileManager.default.fileExists(atPath: resolved.url.path))

        // Cleanup removes the temp file deterministically.
        let pathBeforeCleanup = resolved.url.path
        resolved.cleanup()
        #expect(!FileManager.default.fileExists(atPath: pathBeforeCleanup))
    }

    @Test func stdinGarbageBytesMapToAudioDecodeFailedWithExitCode65() async throws {
        // Arbitrary garbage should fail AVAudioFile validation and surface
        // as exit 65 — same shape as the corrupt-file branch on the file
        // path. The temp file the resolver staged must be removed before
        // the error propagates (no leaks on the error path).
        let garbage = Data((0..<128).map { _ in UInt8.random(in: 0...255) })

        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: garbage)
        try pipe.fileHandleForWriting.close()

        let leakCheck = TempFileLeakChecker()
        let resolver = DefaultAudioFileResolver(
            stdinProvider: { pipe.fileHandleForReading },
            tempFileObserver: { url in leakCheck.record(url) }
        )

        do {
            _ = try await resolver.resolve(source: .stdin)
            Issue.record("expected resolve to throw for garbage stdin")
        } catch let error as DictamacError {
            guard case .audioDecodeFailed = error else {
                Issue.record("expected .audioDecodeFailed, got \(error)")
                return
            }
            #expect(error.exitCode == 65)
        }

        // The temp file must NOT exist after the resolver throws.
        let observed = try #require(leakCheck.url)
        #expect(!FileManager.default.fileExists(atPath: observed.path))
    }

    @Test func stdinSuccessfulResolveCleansUpWhenCleanupCalled() async throws {
        // Verifies the documented contract: when transcription completes,
        // the caller invokes resolved.cleanup() and the temp file is gone.
        // Run many times to guard against leaks across invocations.
        let m4a = try writeSilentM4A(duration: 0.25)
        defer { try? FileManager.default.removeItem(at: m4a) }
        let bytes = try Data(contentsOf: m4a)

        var observedURLs: [URL] = []
        for _ in 0..<8 {
            let pipe = Pipe()
            try pipe.fileHandleForWriting.write(contentsOf: bytes)
            try pipe.fileHandleForWriting.close()
            let resolver = DefaultAudioFileResolver(
                stdinProvider: { pipe.fileHandleForReading }
            )
            let resolved = try await resolver.resolve(source: .stdin)
            observedURLs.append(resolved.url)
            resolved.cleanup()
        }

        // Every URL should be unique (avoid temp-name collisions).
        let unique = Set(observedURLs.map { $0.path })
        #expect(unique.count == observedURLs.count)

        // None of the temp files should still exist.
        for url in observedURLs {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func stdinThrownErrorAlsoCleansUpTempFile() async throws {
        // Even when AVAudioFile fails, the resolver must remove the
        // temp file it staged from stdin — no leaks on the error path.
        let leakCheck = TempFileLeakChecker()
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        try pipe.fileHandleForWriting.close()
        let resolver = DefaultAudioFileResolver(
            stdinProvider: { pipe.fileHandleForReading },
            tempFileObserver: { url in leakCheck.record(url) }
        )

        _ = try? await resolver.resolve(source: .stdin)
        let observed = try #require(leakCheck.url)
        #expect(!FileManager.default.fileExists(atPath: observed.path))
    }

    @Test func stdinCleanupFailureDoesNotThrow() async throws {
        // Cleanup must be idempotent and tolerant: calling cleanup twice,
        // or on an already-deleted file, must NOT throw — the caller
        // relies on defer semantics with no error-handling boilerplate.
        let m4a = try writeSilentM4A(duration: 0.25)
        defer { try? FileManager.default.removeItem(at: m4a) }
        let bytes = try Data(contentsOf: m4a)

        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: bytes)
        try pipe.fileHandleForWriting.close()
        let resolver = DefaultAudioFileResolver(
            stdinProvider: { pipe.fileHandleForReading }
        )

        let resolved = try await resolver.resolve(source: .stdin)
        // Delete behind the resolver's back.
        try FileManager.default.removeItem(at: resolved.url)
        // Cleanup must still complete without throwing or crashing.
        resolved.cleanup()
        resolved.cleanup()  // double-call must be safe
    }

    @Test func corruptFileMapsToAudioDecodeFailedWithExitCode65() async throws {
        let resolver = DefaultAudioFileResolver()
        let corruptURL = try writeCorruptFile()
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        do {
            _ = try await resolver.resolve(source: .path(corruptURL.path))
            Issue.record("expected resolve to throw for corrupt file")
        } catch let error as DictamacError {
            guard case .audioDecodeFailed(let url, _) = error else {
                Issue.record("expected .audioDecodeFailed, got \(error)")
                return
            }
            #expect(url.path == corruptURL.standardizedFileURL.path)
            #expect(error.exitCode == 65)
        }
    }

    // MARK: - Happy path — file formats AVAudioFile can read

    @Test func resolvesValidWAVFixture() async throws {
        let resolver = DefaultAudioFileResolver()
        let wav = try writeSilentWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: wav) }

        let resolved = try await resolver.resolve(source: .path(wav.path))
        #expect(resolved.url.path == wav.standardizedFileURL.path)
        // Path branch must NOT delete the original on cleanup.
        resolved.cleanup()
        #expect(FileManager.default.fileExists(atPath: wav.path))
    }

    @Test func resolvesValidM4AFixture() async throws {
        let resolver = DefaultAudioFileResolver()
        let m4a = try writeSilentM4A(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: m4a) }

        let resolved = try await resolver.resolve(source: .path(m4a.path))
        #expect(resolved.url.path == m4a.standardizedFileURL.path)
        resolved.cleanup()
        #expect(FileManager.default.fileExists(atPath: m4a.path))
    }

    // MARK: - processingFormat capture (for --verbose plumbing)

    @Test func captureProcessingFormatViaReporter() async throws {
        let captured = FormatCaptureBox()
        let resolver = DefaultAudioFileResolver { summary in
            captured.set(summary)
        }
        let wav = try writeSilentWAV(duration: 0.25, sampleRate: 22050, channels: 1)
        defer { try? FileManager.default.removeItem(at: wav) }

        _ = try await resolver.resolve(source: .path(wav.path))

        let summary = try #require(captured.get())
        #expect(summary.sampleRate == 22050)
        #expect(summary.channelCount == 1)
    }

    @Test func processingFormatSummaryRendersHumanReadable() {
        let summary = ProcessingFormatSummary(sampleRate: 44100, channelCount: 2)
        #expect(summary.summary == "sampleRate=44100.0 Hz, channels=2")
    }

    @Test func reporterNotInvokedWhenFileMissing() async throws {
        let captured = FormatCaptureBox()
        let resolver = DefaultAudioFileResolver { summary in
            captured.set(summary)
        }
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-no-such-file-\(UUID().uuidString).m4a")

        _ = try? await resolver.resolve(source: .path(missing.path))
        #expect(captured.get() == nil)
    }

    @Test func reporterNotInvokedWhenFileCorrupt() async throws {
        let captured = FormatCaptureBox()
        let resolver = DefaultAudioFileResolver { summary in
            captured.set(summary)
        }
        let corruptURL = try writeCorruptFile()
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        _ = try? await resolver.resolve(source: .path(corruptURL.path))
        #expect(captured.get() == nil)
    }

    // MARK: - Path expansion + edge cases

    @Test func tildePrefixedPathExpandsHome() async throws {
        // Verify the resolver expands `~` before consulting FileManager —
        // otherwise users would see a misleading file-not-found error for
        // an obviously-present file.
        let resolver = DefaultAudioFileResolver()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stagedURL = home.appendingPathComponent("dictamac-test-\(UUID().uuidString).wav")
        try makeSilentWAV(at: stagedURL, duration: 0.1)
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        let tildePath = "~/\(stagedURL.lastPathComponent)"
        let resolved = try await resolver.resolve(source: .path(tildePath))
        #expect(resolved.url.path == stagedURL.standardizedFileURL.path)
    }

    // MARK: - DictamacError surface

    @Test func errorDescriptionsIncludePath() {
        let url = URL(fileURLWithPath: "/tmp/missing.m4a")
        #expect(DictamacError.fileNotFound(url).description.contains("/tmp/missing.m4a"))

        struct LowLevel: Error, LocalizedError {
            var errorDescription: String? { "codec unsupported" }
        }
        let decoded = DictamacError.audioDecodeFailed(url, underlying: LowLevel())
        #expect(decoded.description.contains("/tmp/missing.m4a"))
        #expect(decoded.description.contains("codec unsupported"))
    }

    @Test func exitCodesMatchStableContract() {
        // PLAN.md §4: exit codes are stable across versions. Pin them.
        #expect(DictamacError.fileNotFound(URL(fileURLWithPath: "/x")).exitCode == 64)
        #expect(
            DictamacError.audioDecodeFailed(
                URL(fileURLWithPath: "/x"),
                underlying: NSError(domain: "x", code: 0)
            ).exitCode == 65
        )
    }

    // MARK: - Helpers (synthesize fixtures at runtime — no PII, no committed binaries)

    /// Thread-safe box for the `@Sendable` format-reporter closure to
    /// write into.
    private final class FormatCaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ProcessingFormatSummary?

        func set(_ summary: ProcessingFormatSummary) {
            lock.lock(); defer { lock.unlock() }
            value = summary
        }

        func get() -> ProcessingFormatSummary? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    /// Thread-safe box for capturing the temp file the resolver staged
    /// during a stdin intake, so tests can assert cleanup happened on
    /// both the success and error paths.
    private final class TempFileLeakChecker: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: URL?

        func record(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            captured = url
        }

        var url: URL? {
            lock.lock(); defer { lock.unlock() }
            return captured
        }
    }

    private func writeCorruptFile() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-corrupt-\(UUID().uuidString).m4a")
        // 64 bytes of garbage — definitely not a valid audio container.
        let bytes = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        try bytes.write(to: url)
        return url
    }

    private func writeSilentWAV(
        duration: Double,
        sampleRate: Double = 44100,
        channels: AVAudioChannelCount = 1
    ) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-silent-\(UUID().uuidString).wav")
        try makeSilentWAV(at: url, duration: duration, sampleRate: sampleRate, channels: channels)
        return url
    }

    private func makeSilentWAV(
        at url: URL,
        duration: Double,
        sampleRate: Double = 44100,
        channels: AVAudioChannelCount = 1
    ) throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channels
        )!
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Silent buffer — channelData is zero-initialized.

        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings
        )
        try audioFile.write(from: buffer)
    }

    /// Synthesizes a tiny silent AAC-in-M4A file. Uses AVAssetWriter
    /// because `AVAudioFile(forWriting:)` only supports linear PCM
    /// containers — AAC requires the asset-writer pipeline.
    private func writeSilentM4A(duration: Double) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-silent-\(UUID().uuidString).m4a")
        // Defensive cleanup — AVAssetWriter refuses to overwrite.
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
                domain: "AudioFileResolverTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter rejected AAC input"]
            )
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let pcmFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Silent buffer.

        guard let sampleBuffer = buffer.toCMSampleBuffer() else {
            throw NSError(
                domain: "AudioFileResolverTests",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "PCM → CMSampleBuffer conversion failed"]
            )
        }
        input.append(sampleBuffer)
        input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        // Bounded wait so a stuck completion can never hang the suite.
        // 10s is generous for ~half a second of silent AAC.
        if semaphore.wait(timeout: .now() + .seconds(10)) == .timedOut {
            throw NSError(
                domain: "AudioFileResolverTests",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter.finishWriting timed out after 10s"]
            )
        }

        if writer.status != .completed {
            throw writer.error ?? NSError(
                domain: "AudioFileResolverTests",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter failed with status \(writer.status.rawValue)"]
            )
        }
        return url
    }
}

// MARK: - PCM → CMSampleBuffer bridge

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
