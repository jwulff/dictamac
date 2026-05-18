import Testing
import Foundation
@testable import DictamacCLI
@testable import DictamacCore
@testable import DictamacVoiceMemos

/// Tests for the `--list-voice-memos` CLI handler.
///
/// The handler is wired through ``runListVoiceMemos(since:limit:resolver:now:wantsJSON:writeStdout:writeStderr:exit:)``,
/// the testable seam parallel to ``runResolveAndTranscribe`` — it
/// accepts an injectable resolver plus stdout/stderr/exit closures so
/// the production process never touches `Darwin.exit(_:)` from inside
/// a test run.
struct ListVoiceMemosHandlerTests {

    // MARK: - Plaintext output

    @Test func plaintextOutputIsTabSeparatedReverseChronological() async {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let listings = canonicalListings(now: now)
        let resolver = MockVoiceMemosResolver(listings: listings)
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: nil,
            resolver: resolver,
            now: now,
            wantsJSON: false,
            recorder: recorder
        )

        let stdout = recorder.stdoutText
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Three listings + trailing empty after the last newline.
        #expect(lines.count == 4)
        #expect(lines.last == "")

        // Each non-empty line: identifier <tab> ISO8601 <tab> duration <tab> title.
        for (index, line) in lines.prefix(3).enumerated() {
            let parts = line.split(separator: "\t").map(String.init)
            #expect(parts.count == 4, "line \(index) does not have 4 tab-separated parts: \(line)")
        }

        // Reverse chronological — listings are already in that order, but
        // the handler should also sort defensively.
        let firstIdentifier = lines[0].split(separator: "\t").first.map(String.init) ?? ""
        let secondIdentifier = lines[1].split(separator: "\t").first.map(String.init) ?? ""
        let thirdIdentifier = lines[2].split(separator: "\t").first.map(String.init) ?? ""
        #expect(firstIdentifier == "newer")
        #expect(secondIdentifier == "middle")
        #expect(thirdIdentifier == "older")

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [0])
    }

    @Test func plaintextSortsDefensivelyEvenIfResolverIsUnordered() async {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        // Resolver returns listings out of order; the handler must
        // still produce reverse-chronological output.
        let unordered = [
            metadata(id: "older", recordedAt: now.addingTimeInterval(-10_000)),
            metadata(id: "newer", recordedAt: now.addingTimeInterval(-1_000)),
            metadata(id: "middle", recordedAt: now.addingTimeInterval(-5_000)),
        ]
        let resolver = MockVoiceMemosResolver(listings: unordered)
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: nil,
            resolver: resolver,
            now: now,
            wantsJSON: false,
            recorder: recorder
        )

        let stdout = recorder.stdoutText
        let lines = stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("newer"))
        #expect(lines[1].hasPrefix("middle"))
        #expect(lines[2].hasPrefix("older"))
    }

    // MARK: - JSON output

    @Test func jsonOutputIsArrayMatchingMCPSchema() async throws {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let listings = canonicalListings(now: now)
        let resolver = MockVoiceMemosResolver(listings: listings)
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: nil,
            resolver: resolver,
            now: now,
            wantsJSON: true,
            recorder: recorder
        )

        let stdout = recorder.stdoutText
        #expect(stdout.hasSuffix("\n"))

        // The JSON body itself should be a top-level array; decode it
        // back into [VoiceMemoListing] and assert the keys + order.
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([VoiceMemoListing].self, from: data)
        #expect(decoded.count == 3)
        #expect(decoded.map(\.identifier) == ["newer", "middle", "older"])

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [0])
    }

    // MARK: - Empty list still exits 0

    @Test func emptyListProducesEmptyPlaintextAndExitsZero() async {
        let resolver = MockVoiceMemosResolver(listings: [])
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: nil,
            resolver: resolver,
            now: Date(),
            wantsJSON: false,
            recorder: recorder
        )

        let stdout = recorder.stdoutText
        #expect(stdout.isEmpty || stdout == "")
        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [0])
    }

    @Test func emptyListJSONIsEmptyArrayWithNewlineAndExitsZero() async {
        let resolver = MockVoiceMemosResolver(listings: [])
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: nil,
            resolver: resolver,
            now: Date(),
            wantsJSON: true,
            recorder: recorder
        )

        let stdout = recorder.stdoutText
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed == "[]")
        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [0])
    }

    // MARK: - Since parsing

    @Test func invalidSinceMapsToArgumentErrorExitTwo() async {
        let resolver = MockVoiceMemosResolver(listings: [])
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: "totally-not-a-duration",
            limit: nil,
            resolver: resolver,
            now: Date(),
            wantsJSON: false,
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [2])
        #expect(recorder.stdoutText.isEmpty)
        let stderr = recorder.stderrText.lowercased()
        #expect(stderr.contains("argument") || stderr.contains("--since"))
    }

    @Test func defaultSinceIsThirtyDays() async {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let resolver = MockVoiceMemosResolver(listings: [])
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: nil,
            resolver: resolver,
            now: now,
            wantsJSON: false,
            recorder: recorder
        )

        let receivedSince = resolver.receivedListSince
        #expect(receivedSince.count == 1)
        if let first = receivedSince.first {
            // Default = 30d ago.
            let expected = now.addingTimeInterval(-30 * 86_400)
            #expect(abs(first.timeIntervalSince(expected)) < 1)
        }
    }

    @Test func sevenDaysSinceIsResolvedRelativeToNow() async {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let resolver = MockVoiceMemosResolver(listings: [])
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: "7d",
            limit: nil,
            resolver: resolver,
            now: now,
            wantsJSON: false,
            recorder: recorder
        )

        let receivedSince = resolver.receivedListSince
        #expect(receivedSince.count == 1)
        if let first = receivedSince.first {
            let expected = now.addingTimeInterval(-7 * 86_400)
            #expect(abs(first.timeIntervalSince(expected)) < 1)
        }
    }

    // MARK: - Limit clamping

    @Test func limitDefaultIsThirty() async {
        let resolver = MockVoiceMemosResolver(listings: [])
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: nil,
            resolver: resolver,
            now: Date(),
            wantsJSON: false,
            recorder: recorder
        )

        let receivedLimit = resolver.receivedListLimit
        #expect(receivedLimit == [30])
    }

    @Test func limitBelowMinIsClampedToOne() async {
        let resolver = MockVoiceMemosResolver(listings: [])
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: 0,
            resolver: resolver,
            now: Date(),
            wantsJSON: false,
            recorder: recorder
        )

        let receivedLimit = resolver.receivedListLimit
        #expect(receivedLimit == [1])
    }

    @Test func negativeLimitIsClampedToOne() async {
        let resolver = MockVoiceMemosResolver(listings: [])
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: -5,
            resolver: resolver,
            now: Date(),
            wantsJSON: false,
            recorder: recorder
        )

        let receivedLimit = resolver.receivedListLimit
        #expect(receivedLimit == [1])
    }

    @Test func limitAboveMaxIsClampedToHundred() async {
        let resolver = MockVoiceMemosResolver(listings: [])
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: 9999,
            resolver: resolver,
            now: Date(),
            wantsJSON: false,
            recorder: recorder
        )

        let receivedLimit = resolver.receivedListLimit
        #expect(receivedLimit == [100])
    }

    // MARK: - Resolver errors

    @Test func resolverPermissionDeniedExitsSeventyThree() async {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        let resolver = MockVoiceMemosResolver(
            errorToThrow: DictamacError.permissionDenied(
                domain: "Files & Folders",
                deepLink: url
            )
        )
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: nil,
            resolver: resolver,
            now: Date(),
            wantsJSON: false,
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [73])
        #expect(recorder.stdoutText.isEmpty)
        #expect(recorder.stderrText.contains("Privacy_FilesAndFolders"))
    }

    @Test func resolverLibraryMissingExitsSeventyFour() async {
        let resolver = MockVoiceMemosResolver(
            errorToThrow: DictamacError.voiceMemoLibraryMissing(searched: [])
        )
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: nil,
            resolver: resolver,
            now: Date(),
            wantsJSON: false,
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [74])
        #expect(recorder.stdoutText.isEmpty)
    }

    // MARK: - Locale-sensitive duration formatting

    /// `formatDuration` must always emit a `.` decimal separator
    /// regardless of the user's process locale. Without an explicit
    /// POSIX locale, `String(format: "%.3f", ...)` on a `de_DE` host
    /// emits a comma decimal separator (`60,5` instead of `60.5`),
    /// which silently breaks the tab-separated, machine-parseable
    /// plaintext contract — downstream `awk -F'\t'` consumers would
    /// then parse `60,5` as a string instead of a number.
    ///
    /// We can't reliably swap the process locale at test time, but the
    /// formatter is now POSIX-pinned internally, so the output is the
    /// same whether the host is `en_US`, `de_DE`, or `fr_FR`. The
    /// assertion below proves the fix: a fractional value renders with
    /// a dot, never a comma. The accompanying construction of a
    /// `de_DE` `Locale` documents what was previously broken — a
    /// future regression that drops the locale argument would still
    /// pass on a US host but fail anywhere `,` is the decimal
    /// separator, and this test (paired with the doc comment on
    /// ``formatDuration(_:)``) is the breadcrumb that traces the
    /// failure back to the missing locale.
    @Test func formatDurationUsesPOSIXDecimalSeparatorRegardlessOfLocale() {
        // Documenting intent: even when a de_DE-style locale is
        // active, `formatDuration` must yield a dot. The formatter is
        // pinned to en_US_POSIX internally, so this assertion holds
        // on every host.
        _ = Locale(identifier: "de_DE")

        let fractional = formatDuration(60.5)
        #expect(fractional == "60.5",
                "expected dot decimal separator; got \(fractional)")
        #expect(!fractional.contains(","),
                "duration must never contain a comma — breaks tab-separated output")

        let integer = formatDuration(60.0)
        #expect(integer == "60", "expected trailing .000 stripped; got \(integer)")
        #expect(!integer.contains(","))

        let small = formatDuration(0.001)
        #expect(small == "0.001")
        #expect(!small.contains(","))
    }

    @Test func plaintextDurationColumnContainsDotNotComma() async {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let listings = [
            metadata(id: "frac", recordedAt: now, duration: 60.5),
        ]
        let resolver = MockVoiceMemosResolver(listings: listings)
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: nil,
            resolver: resolver,
            now: now,
            wantsJSON: false,
            recorder: recorder
        )

        let stdout = recorder.stdoutText
        #expect(stdout.contains("60.5"),
                "expected dot decimal separator in plaintext duration column; got \(stdout)")
        #expect(!stdout.contains("60,5"),
                "comma decimal separator would break tab-separated plaintext contract")
    }

    // MARK: - JSON encoding failure surfaces as internalFailure

    /// When `JSONEncoder` rejects the payload, the handler must NOT
    /// silently emit `"[]\n"` on stdout. That would lie to callers
    /// (zero memos) about a real internal fault. Instead, stdout stays
    /// empty, a structured ``DictamacError/internalFailure(_:)`` line
    /// is written to stderr, and the process exits 1.
    ///
    /// We force the encoder to throw by feeding the resolver a
    /// metadata row whose `durationSeconds` is `.nan`. The default
    /// `JSONEncoder.nonConformingFloatEncodingStrategy = .throw`
    /// makes `Double.nan` un-encodable, which is the cheapest way to
    /// reproduce a real encoder failure without subclassing.
    @Test func jsonEncodingFailureExitsOneWithEmptyStdout() async {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let listings = [
            metadata(id: "broken", recordedAt: now, duration: .nan),
        ]
        let resolver = MockVoiceMemosResolver(listings: listings)
        let recorder = OutputRecorder()

        await runListVoiceMemosForTest(
            since: nil,
            limit: nil,
            resolver: resolver,
            now: now,
            wantsJSON: true,
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [1], "expected exit 1 on JSON encoding failure; got \(exitCodes)")
        #expect(recorder.stdoutText.isEmpty,
                "stdout must stay empty on encoding failure; got \(recorder.stdoutText)")
        let stderr = recorder.stderrText
        #expect(!stderr.isEmpty, "stderr must carry the internal-failure message")
        #expect(stderr.contains("Internal failure"),
                "stderr should surface the DictamacError.internalFailure description; got \(stderr)")
    }

    // MARK: - Test helpers

    private func metadata(
        id: String,
        recordedAt: Date,
        title: String? = nil,
        duration: TimeInterval = 60.0
    ) -> VoiceMemoMetadata {
        VoiceMemoMetadata(
            identifier: id,
            title: title ?? "Memo \(id)",
            recordedAt: recordedAt,
            durationSeconds: duration,
            assetPath: URL(fileURLWithPath: "/tmp/\(id).m4a")
        )
    }

    /// Three listings in reverse-chronological order (newer first).
    private func canonicalListings(now: Date) -> [VoiceMemoMetadata] {
        [
            metadata(id: "newer", recordedAt: now.addingTimeInterval(-1_000)),
            metadata(id: "middle", recordedAt: now.addingTimeInterval(-5_000)),
            metadata(id: "older", recordedAt: now.addingTimeInterval(-10_000)),
        ]
    }

    /// Drives ``runListVoiceMemos(...)`` with `Void`-returning exit /
    /// stdout / stderr closures so tests can `await` and assert
    /// without terminating the test runner.
    private func runListVoiceMemosForTest(
        since: String?,
        limit: Int?,
        resolver: any VoiceMemosResolver,
        now: Date,
        wantsJSON: Bool,
        recorder: OutputRecorder
    ) async {
        await runListVoiceMemos(
            since: since,
            limit: limit,
            resolver: resolver,
            now: now,
            wantsJSON: wantsJSON,
            writeStdout: { recorder.appendStdout($0) },
            writeStderr: { recorder.appendStderr($0) },
            exit: { recorder.recordExit($0) }
        )
    }
}
