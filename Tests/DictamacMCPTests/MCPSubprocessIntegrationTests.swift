import Foundation
import Darwin
import Testing
@testable import DictamacMCP

/// End-to-end integration test that spawns the built `dictamac --mcp`
/// binary as a real subprocess and drives a full JSON-RPC handshake
/// across its stdin/stdout pipes.
///
/// This is the only test that exercises the MCP transport the way a real
/// MCP client (an agent harness, Claude, etc.) does — process boundary,
/// real `\n`-framed line buffering, real stdout vs. stderr separation,
/// and real process lifecycle. The in-process tests in
/// ``MCPServerTests``, ``InitializeHandlerTests``, ``ToolsListHandlerTests``,
/// and ``ToolsCallTests`` cover the protocol shape but cannot catch
/// regressions in signing / entitlement breakage or process lifecycle.
///
/// ## Why we send all requests up-front then close stdin
///
/// On macOS 26 + Swift 6.3 there is a Foundation regression where
/// `FileHandle.read(upToCount:)` (the call ``MCPServer`` uses to peel
/// JSON-RPC lines off stdin) does NOT return as soon as bytes are
/// available on a pipe; it blocks until either the buffer fills (~4096
/// bytes) or the writer closes the pipe. That mirrors how a real MCP
/// client driving the binary via a shell pipe (`echo … | dictamac
/// --mcp`) works — the shell closes stdin immediately after writing —
/// but it means a streaming-write-then-read pattern from a test
/// driver hangs.
///
/// The integration test bundles all three requests into a single batch
/// write, closes stdin, then drains stdout once the subprocess exits.
/// That is the same I/O pattern every in-process test in this target
/// uses (see ``MCPServerTests.dispatchesRegisteredHandlerAndWritesSuccessResponse``),
/// and it is sufficient to exercise the process boundary, the signing
/// /entitlement requirements, and stdout/stderr discipline that the
/// in-process tests cannot catch.
///
/// The pipe-draining side of the same regression is handled inline by
/// ``drainPipeToEnd(_:)``, which uses posix `Darwin.read(_:_:_:)` on
/// the underlying file descriptor rather than
/// `FileHandle.readDataToEndOfFile()` (which shares the same blocking
/// codepath). See the doc comment on that helper for the EINTR retry
/// rationale.
///
/// ## Skip semantics
///
/// The test **skips by default**: it only runs when
/// `DICTAMAC_RUN_MCP_SUBPROCESS_TEST=1` is set in the environment. The
/// canonical invocation is `make test-integration`, which depends on
/// `make build` (so the binary is freshly compiled + signed) and sets
/// the env var on the way through. Running `make test` or `swift test`
/// directly skips the test — important because the `.build/release/dictamac`
/// binary may be stale from an earlier checkout, and running this test
/// against a stale binary would mask MCP regressions or cause spurious
/// failures after a protocol/schema change.
///
/// Additional skip guards (defensive, all paired with `.warning`
/// severity so they surface in test output without flipping the suite
/// red):
///
/// - The built binary at `<repo>/.build/release/dictamac` does not
///   exist. Surfaced as a hint to run `make test-integration` (which
///   guarantees a fresh build).
/// - The repo root cannot be located by walking up from
///   `Bundle.module.bundleURL` looking for `Package.swift`. This
///   shouldn't happen in practice but the lookup is defensive.
///
/// ## Why we don't just `swift run`
///
/// `swift run` skips code-signing. The `SpeechAnalyzer` framework
/// requires the `disable-library-validation` + `allow-jit` entitlements
/// to be present at launch or the binary takes a `SIGTRAP` on first
/// touch. `make build` runs `codesign --entitlements …` after the link
/// step; the test depends on that artifact being present.
///
/// ## Timeout
///
/// The whole subprocess lifetime is bounded to 10 seconds. If the
/// subprocess hangs (e.g. the locale model needs to download on a
/// slow link, or the in-process MCP loop deadlocks) the test kills
/// it forcefully and reports a clear failure rather than hanging CI.
/// A warm en-US model produces the full 3-request exchange in well
/// under half a second on developer hardware; first-run / cold-model
/// scenarios that need more than 10s should just stay opted out
/// (don't set `DICTAMAC_RUN_MCP_SUBPROCESS_TEST=1`) — the test only
/// makes sense for environments where the model is already installed.
@Suite(.serialized)
struct MCPSubprocessIntegrationTests {

    /// Hard cap on the whole subprocess exchange. Documented at the
    /// type level; pulled out as a constant so the same value is used
    /// for both the kill-deadline and the timeout error message.
    private static let subprocessTimeout: DispatchTimeInterval = .seconds(10)

    // MARK: - Top-level integration test

    @Test func subprocessHandshakeListsToolsAndTranscribesFixture() async throws {
        // ── Preflight ────────────────────────────────────────────────
        // Skip semantics: every guard below records a `.warning`
        // severity issue (not `.error`) so the test surfaces a clear
        // diagnostic line in CI without flipping the suite red. A
        // warning is reported in the test output and visible to the
        // operator but does not fail the run — Swift Testing treats
        // `severity: .warning` issues as informational. See
        // `SpeechAPILocaleModelCheckerIntegrationTests` for the
        // companion pattern on the speech track.
        // Opt-in by design: skip unless DICTAMAC_RUN_MCP_SUBPROCESS_TEST=1
        // is set. This guards against running against a stale
        // .build/release/dictamac when invoked via plain `swift test` —
        // see the type-level doc comment. `make test-integration` does
        // a fresh build + sign, then sets this env var.
        if ProcessInfo.processInfo.environment["DICTAMAC_RUN_MCP_SUBPROCESS_TEST"] != "1" {
            Issue.record(
                """
                skipped: DICTAMAC_RUN_MCP_SUBPROCESS_TEST=1 not set. \
                Use `make test-integration` for a fresh-build run, or \
                set the env var explicitly if you've just rebuilt the \
                binary.
                """,
                severity: .warning
            )
            return
        }

        guard let repoRoot = locateRepoRoot() else {
            Issue.record(
                """
                skipped: could not locate repo root from \
                Bundle.module.bundleURL (\(Bundle.module.bundleURL.path)). \
                Expected to find Package.swift by walking up.
                """,
                severity: .warning
            )
            return
        }

        let binaryURL = repoRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("release")
            .appendingPathComponent("dictamac")

        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            Issue.record(
                """
                skipped: \(binaryURL.path) not found — run `make build` \
                first. `swift test` alone does not build (or sign) the \
                dictamac executable target.
                """,
                severity: .warning
            )
            return
        }

        let fixtureURL = repoRoot
            .appendingPathComponent("Tests")
            .appendingPathComponent("DictamacSpeechTests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("hello-world.m4a")

        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            Issue.record(
                "skipped: en-US fixture missing at \(fixtureURL.path)",
                severity: .warning
            )
            return
        }

        // ── Build the request batch ─────────────────────────────────
        let initializeRequest =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let toolsListRequest =
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#

        // Encode the tools/call request via JSONEncoder so the absolute
        // fixture path is properly escaped if it contains anything
        // surprising. Single-line JSON, no pretty-printing — that's the
        // wire format the MCP framing depends on.
        let callRequestPayload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(3),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("transcribe_file"),
                "arguments": .object([
                    "path": .string(fixtureURL.path),
                ]),
            ]),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let callRequestData = try encoder.encode(JSONValue.object(callRequestPayload))
        let callRequest = String(decoding: callRequestData, as: UTF8.self)

        let sentRequests = [initializeRequest, toolsListRequest, callRequest]
        let stdinPayload = (sentRequests.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()

        // ── Spawn ───────────────────────────────────────────────────
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["--mcp"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            Issue.record("failed to spawn \(binaryURL.path): \(error)")
            return
        }

        // Belt-and-braces: even if a `#expect` triggers an early return
        // path, ensure the subprocess is reaped before the test exits.
        defer {
            if process.isRunning {
                process.terminate()
                usleep(100_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        // Write all requests at once, then close stdin so the
        // subprocess's read loop sees EOF and drains. Closing the
        // writer signals end-of-input to the MCPServer's `readNextLine`,
        // which then returns the final request from its internal
        // buffer.
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: stdinPayload)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            Issue.record("failed to write/close subprocess stdin: \(error)")
            return
        }

        // ── Wait for the subprocess to exit (bounded) ────────────────
        let exited = waitForProcessExit(process, timeout: Self.subprocessTimeout)
        if !exited {
            Issue.record("""
                subprocess did not exit within \(Self.subprocessTimeout); \
                forcing kill. If this fires repeatedly the en-US locale \
                model may be missing — leave DICTAMAC_RUN_MCP_SUBPROCESS_TEST \
                unset to skip until the model is installed.
                """)
            process.terminate()
            usleep(100_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return
        }

        // ── Drain pipes after exit ──────────────────────────────────
        // Use posix `read(2)` on the underlying fd — see
        // ``drainPipeToEnd(_:)`` for why we don't use
        // `FileHandle.readDataToEndOfFile()` on macOS 26.
        let stdoutData = drainPipeToEnd(stdoutPipe.fileHandleForReading)
        let stderrData = drainPipeToEnd(stderrPipe.fileHandleForReading)

        let stdoutString = String(decoding: stdoutData, as: UTF8.self)
        let stderrString = String(decoding: stderrData, as: UTF8.self)

        // Diagnostic transcript: surface every JSON-RPC byte the test
        // saw to make failure investigation cheap. Always print so the
        // exchange is right there in the Swift Testing output when the
        // test breaks two years from now.
        print("--- subprocess JSON-RPC exchange ---")
        for (i, sent) in sentRequests.enumerated() {
            print("→ [\(i + 1)] \(sent)")
        }
        print("--- subprocess stdout (\(stdoutData.count) bytes) ---")
        print(stdoutString.isEmpty ? "<empty>" : stdoutString)
        if !stderrString.isEmpty {
            print("--- subprocess stderr (\(stderrData.count) bytes) ---")
            print(stderrString)
        }
        print("--- subprocess exit ---")
        print("terminationStatus=\(process.terminationStatus) terminationReason=\(process.terminationReason.rawValue)")

        // ── Decode and assert ────────────────────────────────────────
        let stdoutLines = stdoutString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        // Stdout discipline: every line on stdout must be a valid
        // JSON-RPC envelope. A stray diagnostic on stdout would corrupt
        // the channel for any real MCP client.
        let decoder = JSONDecoder()
        var responses: [JSONRPCResponse] = []
        for line in stdoutLines {
            do {
                let response = try decoder.decode(
                    JSONRPCResponse.self,
                    from: Data(line.utf8)
                )
                responses.append(response)
            } catch {
                Issue.record(
                    """
                    stdout discipline violated: line did not parse as a \
                    JSON-RPC response: \(line). Decode error: \(error)
                    """
                )
            }
        }

        #expect(
            responses.count == sentRequests.count,
            "expected \(sentRequests.count) JSON-RPC responses; got \(responses.count). Lines: \(stdoutLines)"
        )

        guard responses.count >= sentRequests.count else {
            // Subsequent assertions would index past the end. We've
            // already recorded the count mismatch above; bail.
            return
        }

        // ── 1. initialize ───────────────────────────────────────────
        let initializeResponse = responses[0]
        #expect(initializeResponse.id == .int(1))
        #expect(initializeResponse.error == nil)

        guard case .object(let initResult) = initializeResponse.result else {
            Issue.record("initialize result must be an object; got \(String(describing: initializeResponse.result))")
            return
        }
        #expect(initResult["protocolVersion"] == .string(mcpProtocolVersion))

        guard case .object(let serverInfo) = initResult["serverInfo"] else {
            Issue.record("initialize result missing serverInfo")
            return
        }
        #expect(serverInfo["name"] == .string("dictamac"))
        #expect(serverInfo["vendor"] == .string("jwulff"))

        guard case .object(let capabilities) = initResult["capabilities"] else {
            Issue.record("initialize result missing capabilities")
            return
        }
        // Capabilities must declare ONLY `tools`. Negative-space
        // assertion: any future addition (resources/prompts/sampling)
        // must update this list deliberately.
        #expect(
            capabilities.keys.sorted() == ["tools"],
            "expected only `tools` capability; got keys \(capabilities.keys.sorted())"
        )

        // ── 2. tools/list ──────────────────────────────────────────
        let toolsListResponse = responses[1]
        #expect(toolsListResponse.id == .int(2))
        #expect(toolsListResponse.error == nil)

        guard case .object(let toolsResult) = toolsListResponse.result,
              case .array(let tools) = toolsResult["tools"] else {
            Issue.record("tools/list result malformed: \(String(describing: toolsListResponse.result))")
            return
        }
        let names: [String] = tools.compactMap { tool in
            if case .object(let obj) = tool,
               case .string(let name) = obj["name"] {
                return name
            }
            return nil
        }
        #expect(
            names == ["transcribe_file", "transcribe_voice_memo", "list_voice_memos"],
            "tools/list must advertise all three tools in spec order; got \(names)"
        )

        // Each tool entry must carry the JSON-Schema triplet.
        for tool in tools {
            guard case .object(let obj) = tool else {
                Issue.record("tool entry not an object")
                continue
            }
            #expect(obj["name"] != nil, "tool missing 'name'")
            #expect(obj["description"] != nil, "tool missing 'description'")
            #expect(obj["inputSchema"] != nil, "tool missing 'inputSchema'")
        }

        // ── 3. tools/call transcribe_file against the fixture ──────
        let callResponse = responses[2]
        #expect(callResponse.id == .int(3))
        #expect(callResponse.error == nil, "tools/call returned JSON-RPC error: \(String(describing: callResponse.error))")

        guard case .object(let callResult) = callResponse.result else {
            Issue.record("tools/call result not an object: \(String(describing: callResponse.result))")
            return
        }
        // isError must NOT be true (default is absent/false).
        if case .bool(true) = callResult["isError"] ?? .null {
            Issue.record("tools/call returned isError:true envelope: \(callResult)")
        }
        guard case .array(let content) = callResult["content"] else {
            Issue.record("tools/call result missing content array")
            return
        }
        #expect(content.count >= 1, "expected at least one content item")

        // Find the first text content item and assert it contains at
        // least one of the expected tokens (case-insensitive). Model
        // output varies between runs — capitalization, punctuation,
        // word substitutions — but the lexical content is stable.
        var textBlob = ""
        var sawTextContent = false
        for item in content {
            if case .object(let obj) = item,
               case .string("text") = obj["type"] ?? .null,
               case .string(let text) = obj["text"] ?? .null {
                textBlob += text
                sawTextContent = true
            }
        }
        #expect(sawTextContent, "expected at least one content item of type=text")

        let lowered = textBlob.lowercased()
        let expectedTokens = ["hello", "world", "test"]
        let foundToken = expectedTokens.first(where: { lowered.contains($0) })
        #expect(
            foundToken != nil,
            "transcript text \"\(textBlob)\" did not contain any of \(expectedTokens)"
        )

        // ── Stderr discipline ─────────────────────────────────────
        // Stderr is allowed to carry locale-model progress lines,
        // diagnostics, etc. — we don't assert on its content. But it
        // MUST NOT contain a JSON-RPC envelope: that would mean the
        // transport mis-routed a response onto the wrong channel.
        if !stderrString.isEmpty {
            for line in stderrString.split(separator: "\n", omittingEmptySubsequences: true) {
                if let lineData = line.data(using: .utf8),
                   (try? decoder.decode(JSONRPCResponse.self, from: lineData)) != nil {
                    Issue.record(
                        "stderr leaked a JSON-RPC response envelope: \(line)"
                    )
                }
            }
        }

        // ── Clean exit assertion ──────────────────────────────────
        #expect(process.terminationStatus == 0,
                "expected clean exit (0); got \(process.terminationStatus) (reason \(process.terminationReason.rawValue))")
    }

    // MARK: - Helpers — pipe drain

    /// Drain a pipe's read end to EOF using posix `read(2)`. The
    /// equivalent `FileHandle.readDataToEndOfFile()` shares the same
    /// blocking-quirk codepath as `FileHandle.read(upToCount:)` on
    /// macOS 26: it does NOT return as soon as bytes are available on
    /// a pipe; it blocks until the buffer fills (~4096 bytes) or the
    /// writer closes the pipe. Using `Darwin.read(_:_:_:)` on the raw
    /// fd sidesteps that codepath. Returns immediately if the writer
    /// end is closed and the pipe is empty.
    ///
    /// `read(2)` can return `-1` with `errno == EINTR` when a signal
    /// interrupts the call before any bytes are transferred — that's
    /// recoverable, so we loop and retry rather than treating it as
    /// EOF (treating EINTR as EOF would silently truncate captured
    /// stdout/stderr). Any other `errno` is treated as terminal: the
    /// fd is unlikely to recover and the test is in cleanup. See
    /// `man 2 read` on macOS for the full errno surface.
    private func drainPipeToEnd(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        var collected = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.read(fd, base, ptr.count)
            }
            if n > 0 {
                collected.append(Data(buf[0..<n]))
            } else if n == 0 {
                // Real EOF: writer end is closed and the pipe is empty.
                break
            } else {
                // n < 0 — inspect errno to distinguish recoverable
                // EINTR from a terminal error.
                let err = errno
                if err == EINTR {
                    continue
                }
                // Any other errno is terminal in this context. The fd
                // is unlikely to recover; surface a diagnostic on
                // stderr so a future test failure isn't blind, then
                // bail.
                FileHandle.standardError.write(Data(
                    "drainPipeToEnd: read(\(fd)) failed with errno=\(err) (\(String(cString: strerror(err))))\n"
                        .utf8
                ))
                break
            }
        }
        return collected
    }

    // MARK: - Helpers — process exit

    /// Wait up to `timeout` for the subprocess to exit. Returns true
    /// if it exited, false if the timeout elapsed.
    ///
    /// Uses polling instead of `terminationHandler` to sidestep the
    /// race where setting the handler post-`run()` misses an exit that
    /// already happened. 50ms polling is fine — this only fires after
    /// the test has finished its JSON-RPC exchange and is in cleanup.
    private func waitForProcessExit(
        _ process: Process,
        timeout: DispatchTimeInterval
    ) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while process.isRunning {
            if DispatchTime.now() >= deadline {
                return false
            }
            usleep(50_000)  // 50ms
        }
        return true
    }

    // MARK: - Helpers — repo root discovery

    /// Walk up from the test bundle URL looking for `Package.swift`.
    /// Returns the first directory that contains it, or nil if no
    /// ancestor up to the filesystem root carries the marker.
    private func locateRepoRoot() -> URL? {
        var directory = Bundle.module.bundleURL.deletingLastPathComponent()
        let manifestName = "Package.swift"
        for _ in 0..<16 {
            let candidate = directory.appendingPathComponent(manifestName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }
}
