import Foundation

/// Method-handler signature: takes the request's raw `params`
/// (already decoded as a ``JSONValue``) and returns the
/// JSON-RPC `result` payload.
///
/// Throw ``MCPProtocolError/invalidParams(_:)`` to surface a
/// `-32602 Invalid params` response. Any other thrown error becomes
/// `-32603 Internal error`. Successful returns become a
/// ``JSONRPCResponse/success(id:result:)`` response.
public typealias MCPMethodHandler = @Sendable (JSONValue?) async throws -> JSONValue

/// JSON-RPC 2.0 stdio server. Owns the read loop, dispatch table, and
/// response-write discipline that all later MCP method handlers
/// (initialize / tools/list / tools/call) plug into.
///
/// ## Stream discipline
///
/// **stdout is the JSON-RPC channel and nothing else.** All diagnostic
/// output — log lines, debug prints, errors that don't belong in a
/// JSON-RPC envelope — must go through ``logToStandardError(_:)`` or
/// be written directly to `FileHandle.standardError`. A stray `print()`
/// in the dispatch path will poison the channel.
///
/// ## Concurrency
///
/// The server is an actor so handler registration is race-free without
/// callers having to coordinate. The read loop awaits each handler
/// sequentially: MCP does not promise concurrent dispatch and parallel
/// handlers would let a slow `tools/call` race a fast `tools/list`
/// onto the wire out of order.
///
/// ## Line framing
///
/// Each JSON-RPC request is one JSON object on one line, terminated by
/// `\n`. The server buffers incoming bytes and splits on `\n`; partial
/// lines wait for more data. EOF on stdin terminates the loop cleanly.
public actor MCPServer {

    // MARK: - Dependencies

    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle

    // MARK: - Handler registry

    private var handlers: [String: MCPMethodHandler] = [:]

    // MARK: - Read-loop state

    /// Holds bytes consumed from `input` that haven't yet completed a
    /// `\n`-terminated line. The loop reads in 4096-byte chunks, appends
    /// to this buffer, then peels off completed lines one by one.
    private var lineBuffer = Data()

    /// Chunk size for `read(upToCount:)`. A page is a reasonable
    /// trade-off between syscall count and memory pressure for the
    /// agent-driven traffic pattern (sub-KB requests).
    private let readChunkSize = 4096

    // MARK: - Init

    /// Construct an MCP server bound to a set of file handles.
    ///
    /// In production all three default to the process's standard
    /// handles. Tests inject `Pipe()` ends for input/output so they can
    /// assert exact bytes on the wire without forking a subprocess; the
    /// `errorOutput` parameter lets the same tests assert that
    /// diagnostics never bleed onto the JSON-RPC channel.
    public init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        errorOutput: FileHandle = .standardError
    ) {
        self.input = input
        self.output = output
        self.errorOutput = errorOutput
    }

    // MARK: - Handler registration

    /// Register a handler for the given JSON-RPC `method` name.
    ///
    /// Re-registering an existing method replaces the previous handler.
    /// Method names are matched verbatim — no namespacing, no glob
    /// patterns. Later issues add the `initialize`, `tools/list`, and
    /// `tools/call` handlers via this entry point.
    public func register(method: String, handler: @escaping MCPMethodHandler) {
        handlers[method] = handler
    }

    /// True iff a handler has been registered for `method`.
    /// Surfaced for tests; the run loop just hits the dictionary.
    public func hasHandler(for method: String) -> Bool {
        handlers[method] != nil
    }

    // MARK: - Serve loop

    /// Run the JSON-RPC dispatch loop. Returns when stdin reaches EOF.
    ///
    /// One line per iteration: read until newline, decode, dispatch,
    /// write a response (unless the request was a notification), flush
    /// the output handle. On any decode failure the loop emits a
    /// `-32700 Parse error` response with `id: null` and continues —
    /// the channel stays open after a single bad line so an agent that
    /// recovers can keep talking.
    public func serve() async {
        while let line = readNextLine() {
            await handleLine(line)
        }
    }

    // MARK: - Per-line dispatch

    /// Decode one line and route it to a handler. Extracted so tests
    /// can drive the dispatch path with a single hand-crafted line
    /// without standing up a Pipe.
    func handleLine(_ line: Data) async {
        // Skip blank lines silently — they're not protocol traffic and
        // the spec doesn't require a response for them.
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) || line.isEmpty {
            return
        }

        let decoder = JSONDecoder()

        // Step 1: does it parse as JSON at all? If not, the spec
        // requires a `-32700 Parse error` response with `id: null`.
        guard let request = try? decoder.decode(JSONRPCRequest.self, from: line) else {
            writeResponse(
                .failure(id: nil, error: .parseError())
            )
            return
        }

        // Step 2: notification? Execute the handler if registered, but
        // produce no response — that is the entire definition of a
        // notification in JSON-RPC 2.0.
        if request.id == nil {
            if let handler = handlers[request.method] {
                _ = try? await handler(request.params)
            }
            // Unknown notification methods are silently dropped per
            // spec §4.1 — notifications by definition cannot fail
            // back to the client.
            return
        }

        // Step 3: regular request. Dispatch, map throws to the
        // canonical error codes, serialize the response.
        guard let handler = handlers[request.method] else {
            writeResponse(
                .failure(
                    id: request.id,
                    error: .methodNotFound("Method not found: \(request.method)")
                )
            )
            return
        }

        do {
            let result = try await handler(request.params)
            writeResponse(.success(id: request.id, result: result))
        } catch let MCPProtocolError.invalidParams(message) {
            writeResponse(
                .failure(id: request.id, error: .invalidParams(message))
            )
        } catch {
            // Anything not modeled as a protocol error becomes
            // `-32603 Internal error`. The underlying description is
            // surfaced so an agent has a fighting chance to diagnose.
            writeResponse(
                .failure(
                    id: request.id,
                    error: .internalError(String(describing: error))
                )
            )
        }
    }

    // MARK: - Line reader

    /// Pull one `\n`-terminated line off `input`. Returns `nil` on EOF
    /// (i.e. when no more bytes can be read AND the buffer has no
    /// complete line). The trailing `\n` is stripped from the returned
    /// data; a trailing `\r` (CRLF line endings) is stripped too as a
    /// belt-and-braces measure even though MCP transports are unix-LF
    /// by convention.
    func readNextLine() -> Data? {
        while true {
            // Look for a newline in whatever we already have buffered
            // before doing another read.
            if let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                let line = lineBuffer.prefix(upTo: newlineIndex)
                lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
                // Strip a trailing CR if present (CRLF tolerance).
                if line.last == 0x0D {
                    return line.dropLast()
                }
                return Data(line)
            }

            // No newline buffered — read more from the input handle.
            // `read(upToCount:)` returns an empty Data at EOF.
            let chunk: Data
            do {
                chunk = try input.read(upToCount: readChunkSize) ?? Data()
            } catch {
                // I/O error reading stdin — treat it like EOF rather
                // than crashing; report once via stderr for debugging.
                logToStandardError(
                    "MCPServer: read error on input handle: \(error)"
                )
                chunk = Data()
            }

            if chunk.isEmpty {
                // EOF. If anything is still buffered without a newline,
                // hand it back as the final line so a missing trailing
                // newline doesn't silently swallow the last request.
                if !lineBuffer.isEmpty {
                    let tail = lineBuffer
                    lineBuffer.removeAll()
                    if tail.last == 0x0D {
                        return tail.dropLast()
                    }
                    return tail
                }
                return nil
            }

            lineBuffer.append(chunk)
        }
    }

    // MARK: - Response writer

    /// Serialize a response and write it as a single `\n`-terminated
    /// line to `output`. Writing happens through ``FileHandle/write(_:)``
    /// which is synchronous on the underlying file descriptor; for the
    /// process's standard output (a pipe to whatever spawned us) this
    /// is delivered immediately.
    private func writeResponse(_ response: JSONRPCResponse) {
        let encoder = JSONEncoder()
        // Compact, deterministic key order — the tests rely on this for
        // exact-string assertions, and agents want predictable byte
        // streams.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data: Data
        do {
            data = try encoder.encode(response)
        } catch {
            // Encoding a fully-typed `JSONRPCResponse` should never
            // fail, but if it does we report via stderr and drop the
            // response — better than poisoning the channel with a
            // half-written line.
            logToStandardError(
                "MCPServer: failed to encode response: \(error)"
            )
            return
        }

        var line = data
        line.append(0x0A)  // trailing newline framing

        do {
            try output.write(contentsOf: line)
        } catch {
            logToStandardError(
                "MCPServer: failed to write response: \(error)"
            )
        }
    }

    // MARK: - Diagnostic output

    /// Write a diagnostic line to `errorOutput`. Used for the rare
    /// transport-level events that warrant visibility but don't belong
    /// in a JSON-RPC response (I/O errors, encoding failures).
    ///
    /// **Never** call `print()` or write to `output` for diagnostics —
    /// see "Stream discipline" in the type doc.
    private func logToStandardError(_ message: String) {
        let line = message + "\n"
        if let data = line.data(using: .utf8) {
            try? errorOutput.write(contentsOf: data)
        }
    }
}
