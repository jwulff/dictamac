import Foundation
import DictamacCore
import DictamacVoiceMemos

/// `--voice-memo` CLI handler — the testable seam parallel to
/// ``runResolveAndTranscribe(source:resolver:transcriber:localeIdentifier:wantsJSON:verbose:writeStdout:writeStderr:exit:)``
/// and ``runListVoiceMemos(since:limit:resolver:now:wantsJSON:writeStdout:writeStderr:exit:)``.
///
/// Behavior contract (PLAN.md §4 / §5 / §7 U6 / U9):
///
/// 1. Trims `query` and rejects whitespace-only / empty input as
///    ``DictamacError/argumentError(_:)`` (exit 2) BEFORE touching the
///    resolver. This mirrors the MCP `transcribe_voice_memo` tool's
///    `-32602` guard so the two transports stay aligned on
///    "malformed invocation" vs "memo not found".
/// 2. Parses the trimmed query via ``VoiceMemoQuery/parse(_:)``.
/// 3. Calls ``VoiceMemosResolver/resolve(_:now:)``. Any
///    ``DictamacError`` (`voiceMemoNotFound`, `voiceMemoLibraryMissing`,
///    `permissionDenied`, etc.) is mapped to its
///    ``DictamacError/formattedStderrLine`` + exit code — matching the
///    MCP envelope's `mcpToolErrorText` so the two transports surface
///    the same diagnostic verbatim.
/// 4. Hands the memo's `assetPath` through the shared
///    ``AudioFileResolver`` so the codec-validation seam
///    (`fileNotFound` exit 64 / `audioDecodeFailed` exit 65) is
///    identical to the file-path handler.
/// 5. Builds a ``TranscriptionRequest`` with
///    `.voiceMemo(identifier:, title:, url:)` and the caller-supplied
///    locale + format. Calls ``Transcriber/transcribe(_:)``. The
///    `.voiceMemo` request source — not `.file` — ensures the emitted
///    transcript's ``Transcript/source`` carries the memo's identifier
///    and title rather than the opaque asset path inside the Voice
///    Memos library (PR #57 review feedback). The MCP path uses the
///    same variant for byte-identical JSON across transports.
/// 6. Renders the transcript via ``PlaintextFormatter`` or
///    ``JSONFormatter`` and writes to `writeStdout`. The
///    ``ResolvedAudio/cleanup()`` hook fires on every exit path
///    (success and failure) before `exit(_:)`, matching the MCP
///    handler's `defer { resolved.cleanup() }`.
///
/// `writeStdout` / `writeStderr` / `exit` are injectable so tests can
/// drive the handler without touching `FileHandle.standardOutput` or
/// `Darwin.exit(_:)`. Production captures the real handles.
///
/// The `now` parameter exists so tests can pin a deterministic time
/// anchor when validating that `--voice-memo "yesterday"` resolves to
/// a specific Date. Production callers pass `Date()` at call time.
public func runVoiceMemo(
    query: String,
    voiceMemosResolver: any VoiceMemosResolver,
    transcriber: any Transcriber,
    audioResolver: any AudioFileResolver,
    localeIdentifier: String,
    wantsJSON: Bool,
    now: Date = Date(),
    writeStdout: @Sendable @escaping (String) -> Void = { string in
        FileHandle.standardOutput.write(Data(string.utf8))
    },
    writeStderr: @Sendable @escaping (String) -> Void = { string in
        FileHandle.standardError.write(Data(string.utf8))
    },
    exit: @Sendable @escaping (Int32) -> Void = { code in
        Foundation.exit(code)
    }
) async {
    // 1. Trim + emptiness check. Mirrors the MCP handler: a
    //    whitespace-only query is a malformed invocation, not a "memo
    //    not found" — without the trim, `VoiceMemoQuery.parse("   ")`
    //    returns `.fuzzyTitle("")` and the resolver would surface a
    //    misleading `voiceMemoNotFound` instead.
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
        let error = DictamacError.argumentError(
            "--voice-memo requires a non-empty query."
        )
        writeStderr(error.formattedStderrLine)
        exit(error.exitCode)
        return
    }

    // 2. Parse the query through the shared classifier so the CLI and
    //    MCP transports route identical inputs the same way.
    let parsedQuery = VoiceMemoQuery.parse(trimmedQuery)

    // 3. Resolve the query to a specific memo.
    let memo: VoiceMemoMetadata
    do {
        memo = try voiceMemosResolver.resolve(parsedQuery, now: now)
    } catch let error as DictamacError {
        writeStderr(error.formattedStderrLine)
        exit(error.exitCode)
        return
    } catch {
        let wrapped = DictamacError.internalFailure(error)
        writeStderr(wrapped.formattedStderrLine)
        exit(wrapped.exitCode)
        return
    }

    // 4. Hand the memo's asset path through the shared audio
    //    resolver. fileNotFound (exit 64) and audioDecodeFailed (exit
    //    65) originate here — same boundary as the file-path handler.
    let resolved: ResolvedAudio
    do {
        resolved = try await audioResolver.resolve(
            source: .path(memo.assetPath.path)
        )
    } catch let error as DictamacError {
        writeStderr(error.formattedStderrLine)
        exit(error.exitCode)
        return
    } catch {
        let wrapped = DictamacError.internalFailure(error)
        writeStderr(wrapped.formattedStderrLine)
        exit(wrapped.exitCode)
        return
    }

    // 5. Build the request and transcribe. Cleanup MUST run on every
    //    exit path past this point, so each branch invokes
    //    `resolved.cleanup()` before reporting the error or success.
    //
    //    The request carries the `.voiceMemo` source variant — not
    //    `.file` — so the emitted transcript stamps the memo's
    //    identifier + title into ``Transcript.source`` instead of the
    //    opaque asset URL. Without this, `--json --voice-memo` would
    //    emit `source.type == "file"` with the memo's asset path,
    //    making it indistinguishable from a raw file transcription
    //    (PR #57 review). The MCP handler mirrors this exactly.
    let request = TranscriptionRequest(
        source: .voiceMemo(
            identifier: memo.identifier,
            title: memo.title,
            url: resolved.url
        ),
        locale: Locale(identifier: localeIdentifier),
        format: wantsJSON ? .json : .text
    )

    let transcript: Transcript
    do {
        transcript = try await transcriber.transcribe(request)
    } catch let error as DictamacError {
        resolved.cleanup()
        writeStderr(error.formattedStderrLine)
        exit(error.exitCode)
        return
    } catch {
        resolved.cleanup()
        let wrapped = DictamacError.internalFailure(error)
        writeStderr(wrapped.formattedStderrLine)
        exit(wrapped.exitCode)
        return
    }

    // 6. Render + write + cleanup + exit 0.
    let rendered = wantsJSON
        ? JSONFormatter.format(transcript)
        : PlaintextFormatter.format(transcript)
    writeStdout(rendered)
    resolved.cleanup()
    exit(0)
}
