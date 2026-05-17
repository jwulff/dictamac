import Foundation
import Testing
@testable import DictamacCore

/// Tests covering the central error-to-exit-code mapping for
/// ``DictamacError``.
///
/// The exit codes are part of the agent-facing contract (PLAN.md §4) and
/// the mapping is shared by both transports (CLI and the future MCP
/// server) so behavior parity is enforced by the same data.
struct DictamacErrorTests {

    // MARK: - Exit code table (PLAN.md §4)

    /// Table-driven: every case maps to its documented exit code.
    @Test func exitCodeTableMatchesPlanSection4() {
        let url = URL(fileURLWithPath: "/tmp/example.m4a")
        let underlying = NSError(domain: "test", code: 0)
        let cases: [(DictamacError, Int32)] = [
            (.argumentError("bad flag"), 2),
            (.fileNotFound(url), 64),
            (.audioDecodeFailed(url, underlying: underlying), 65),
            (.voiceMemoNotFound(query: "standup"), 66),
            (.speechAnalyzerUnavailable(reason: "model missing"), 67),
            (.permissionDenied(domain: "Speech Recognition", deepLink: nil), 73),
            (.voiceMemoLibraryMissing(searched: []), 74),
            (.internalFailure(underlying), 1),
        ]
        for (error, expected) in cases {
            #expect(
                error.exitCode == expected,
                "expected exit code \(expected) for \(error), got \(error.exitCode)"
            )
        }
    }

    // MARK: - Stderr messages

    @Test func argumentErrorMessageIncludesDetail() {
        let error = DictamacError.argumentError("--mcp conflicts with --voice-memo")
        #expect(error.description.contains("--mcp conflicts with --voice-memo"))
    }

    @Test func fileNotFoundMessageIncludesPath() {
        let url = URL(fileURLWithPath: "/tmp/missing.m4a")
        #expect(DictamacError.fileNotFound(url).description.contains("/tmp/missing.m4a"))
    }

    @Test func audioDecodeFailedMessageIncludesPathAndUnderlying() {
        let url = URL(fileURLWithPath: "/tmp/bad.m4a")
        struct LowLevel: Error, LocalizedError {
            var errorDescription: String? { "codec unsupported" }
        }
        let error = DictamacError.audioDecodeFailed(url, underlying: LowLevel())
        #expect(error.description.contains("/tmp/bad.m4a"))
        #expect(error.description.contains("codec unsupported"))
    }

    @Test func voiceMemoNotFoundMessageIncludesQuery() {
        let error = DictamacError.voiceMemoNotFound(query: "yesterday's standup")
        #expect(error.description.contains("yesterday's standup"))
    }

    @Test func speechAnalyzerUnavailableMessageIncludesReason() {
        let error = DictamacError.speechAnalyzerUnavailable(reason: "en-US model not installed")
        #expect(error.description.contains("en-US model not installed"))
    }

    @Test func permissionDeniedMessageIncludesDomain() {
        let error = DictamacError.permissionDenied(domain: "Speech Recognition", deepLink: nil)
        #expect(error.description.contains("Speech Recognition"))
    }

    /// Acceptance criterion: when a deep link is supplied, the stderr
    /// message MUST include the URL string verbatim so the user can
    /// click it from a terminal that linkifies `x-apple.systempreferences:` URLs.
    @Test func permissionDeniedMessageIncludesDeepLinkURL() {
        let deepLink = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        #expect(deepLink != nil)
        guard let deepLink else { return }
        let error = DictamacError.permissionDenied(
            domain: "Speech Recognition",
            deepLink: deepLink
        )
        #expect(error.description.contains(deepLink.absoluteString))
    }

    @Test func permissionDeniedMessageOmitsDeepLinkSectionWhenNil() {
        let error = DictamacError.permissionDenied(domain: "Speech Recognition", deepLink: nil)
        // The deep-link URL scheme should not appear if no link was provided.
        #expect(!error.description.contains("x-apple.systempreferences:"))
    }

    @Test func voiceMemoLibraryMissingMessageListsSearchedPaths() {
        let searched = [
            URL(fileURLWithPath: "/Users/test/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"),
            URL(fileURLWithPath: "/Users/test/Library/Application Support/com.apple.voicememos/Recordings"),
        ]
        let error = DictamacError.voiceMemoLibraryMissing(searched: searched)
        for url in searched {
            #expect(
                error.description.contains(url.path),
                "expected description to mention \(url.path)"
            )
        }
    }

    @Test func voiceMemoLibraryMissingMessageHandlesEmptyList() {
        let error = DictamacError.voiceMemoLibraryMissing(searched: [])
        #expect(!error.description.isEmpty)
    }

    @Test func internalFailureMessageIncludesUnderlyingDescription() {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "the wheels came off" }
        }
        let error = DictamacError.internalFailure(Boom())
        #expect(error.description.contains("the wheels came off"))
    }

    // MARK: - description non-empty for every variant

    @Test func everyVariantProducesNonEmptyDescription() {
        let url = URL(fileURLWithPath: "/tmp/x.m4a")
        let underlying = NSError(domain: "x", code: 0)
        let variants: [DictamacError] = [
            .argumentError("x"),
            .fileNotFound(url),
            .audioDecodeFailed(url, underlying: underlying),
            .voiceMemoNotFound(query: "x"),
            .speechAnalyzerUnavailable(reason: "x"),
            .permissionDenied(domain: "x", deepLink: nil),
            .voiceMemoLibraryMissing(searched: [url]),
            .internalFailure(underlying),
        ]
        for variant in variants {
            #expect(!variant.description.isEmpty, "empty description for \(variant)")
        }
    }

    // MARK: - Exit helper writes to stderr (does NOT call exit() in tests)

    /// The exit helper is split so the side-effect-free piece is unit
    /// testable: the formatter emits exactly the bytes that would land
    /// on stderr in production. The full `exit(_:)` helper that calls
    /// `Foundation.exit()` is exercised only at compile time here — we
    /// never invoke it in tests because that would terminate the test
    /// runner.
    @Test func formattedStderrLineEndsWithNewline() {
        let error = DictamacError.argumentError("missing input")
        let line = error.formattedStderrLine
        #expect(line.hasSuffix("\n"))
        #expect(line.contains("missing input"))
    }

    @Test func writeStderrLineSendsBytesToProvidedHandle() throws {
        let pipe = Pipe()
        let error = DictamacError.fileNotFound(URL(fileURLWithPath: "/tmp/nope.m4a"))
        error.writeStderrLine(to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("/tmp/nope.m4a"))
        #expect(text.hasSuffix("\n"))
    }
}
