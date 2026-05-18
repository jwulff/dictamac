import Testing
import ArgumentParser
import Foundation
@testable import DictamacCLI

/// Pure argument-parser tests: assert that argv strings produce the right
/// `Dictamac` value (or the right error) WITHOUT actually running
/// `run()`. The parser surface is what every other CLI-track issue
/// depends on, so we exhaustively cover every flag and every
/// mutual-exclusivity rule from PLAN §4 / §7 U3.
struct DictamacParsingTests {

    // MARK: - Happy-path flag parsing

    @Test func positionalPathOnlyParses() throws {
        let cmd = try Dictamac.parse(["/tmp/audio.m4a"])
        #expect(cmd.path == "/tmp/audio.m4a")
        #expect(cmd.locale == "en-US")
        #expect(cmd.json == false)
        #expect(cmd.verbose == false)
        #expect(cmd.mcp == false)
        #expect(cmd.listVoiceMemos == false)
        #expect(cmd.voiceMemo == nil)
        #expect(cmd.since == nil)
        #expect(cmd.limit == nil)
    }

    @Test func jsonFlagParses() throws {
        let cmd = try Dictamac.parse(["--json", "/tmp/audio.m4a"])
        #expect(cmd.json == true)
        #expect(cmd.path == "/tmp/audio.m4a")
    }

    @Test func localeFlagParses() throws {
        let cmd = try Dictamac.parse(["--locale", "ja-JP", "/tmp/audio.m4a"])
        #expect(cmd.locale == "ja-JP")
    }

    @Test func verboseFlagParses() throws {
        let cmd = try Dictamac.parse(["--verbose", "/tmp/audio.m4a"])
        #expect(cmd.verbose == true)
    }

    @Test func dashPositionalIsAcceptedAsStdinMarker() throws {
        let cmd = try Dictamac.parse(["-"])
        #expect(cmd.path == "-")
    }

    @Test func voiceMemoFlagParses() throws {
        let cmd = try Dictamac.parse(["--voice-memo", "yesterday standup"])
        #expect(cmd.voiceMemo == "yesterday standup")
        #expect(cmd.path == nil)
    }

    @Test func listVoiceMemosFlagParses() throws {
        let cmd = try Dictamac.parse(["--list-voice-memos"])
        #expect(cmd.listVoiceMemos == true)
        #expect(cmd.path == nil)
    }

    @Test func listVoiceMemosWithSinceParses() throws {
        let cmd = try Dictamac.parse(["--list-voice-memos", "--since", "7d"])
        #expect(cmd.listVoiceMemos == true)
        #expect(cmd.since == "7d")
    }

    @Test func listVoiceMemosWithLimitParses() throws {
        let cmd = try Dictamac.parse(["--list-voice-memos", "--limit", "5"])
        #expect(cmd.listVoiceMemos == true)
        #expect(cmd.limit == 5)
    }

    @Test func mcpFlagParses() throws {
        let cmd = try Dictamac.parse(["--mcp"])
        #expect(cmd.mcp == true)
        #expect(cmd.path == nil)
    }

    @Test func combinedFlagsParse() throws {
        let cmd = try Dictamac.parse([
            "--json", "--locale", "en-US", "--verbose", "/tmp/a.m4a"
        ])
        #expect(cmd.json == true)
        #expect(cmd.locale == "en-US")
        #expect(cmd.verbose == true)
        #expect(cmd.path == "/tmp/a.m4a")
    }

    // MARK: - Mode detection (post-parse)

    @Test func modeIsMCPWhenMCPFlagSet() throws {
        let cmd = try Dictamac.parse(["--mcp"])
        let mode = try cmd.resolveMode()
        if case .mcp = mode {} else {
            Issue.record("expected .mcp mode, got \(mode)")
        }
    }

    @Test func modeIsListVoiceMemosWhenFlagSet() throws {
        let cmd = try Dictamac.parse(["--list-voice-memos"])
        let mode = try cmd.resolveMode()
        if case .listVoiceMemos(let since, let limit) = mode {
            #expect(since == nil)
            #expect(limit == nil)
        } else {
            Issue.record("expected .listVoiceMemos mode, got \(mode)")
        }
    }

    @Test func listVoiceMemosModePropagatesSinceAndLimit() throws {
        // The parser validates `--since` / `--limit` as gated to
        // `--list-voice-memos`; the resolved mode must also carry them
        // through to the dispatch seam so a future real handler can
        // honor the requested filters (see PR #42 review feedback).
        let cmd = try Dictamac.parse([
            "--list-voice-memos", "--since", "14d", "--limit", "20",
        ])
        let mode = try cmd.resolveMode()
        if case .listVoiceMemos(let since, let limit) = mode {
            #expect(since == "14d")
            #expect(limit == 20)
        } else {
            Issue.record("expected .listVoiceMemos mode, got \(mode)")
        }
    }

    @Test func modeIsVoiceMemoWhenQueryProvided() throws {
        let cmd = try Dictamac.parse(["--voice-memo", "standup"])
        let mode = try cmd.resolveMode()
        if case .voiceMemo(let q) = mode {
            #expect(q == "standup")
        } else {
            Issue.record("expected .voiceMemo mode, got \(mode)")
        }
    }

    @Test func modeIsStdinWhenDashGiven() throws {
        let cmd = try Dictamac.parse(["-"])
        let mode = try cmd.resolveMode()
        if case .stdin = mode {} else {
            Issue.record("expected .stdin mode, got \(mode)")
        }
    }

    @Test func modeIsFileWhenPathGiven() throws {
        let cmd = try Dictamac.parse(["/tmp/audio.m4a"])
        let mode = try cmd.resolveMode()
        if case .file(let path) = mode {
            #expect(path == "/tmp/audio.m4a")
        } else {
            Issue.record("expected .file mode, got \(mode)")
        }
    }

    // MARK: - Mutual-exclusivity rules (PLAN §7 U3)

    @Test func mcpWithPathFailsValidation() throws {
        let cmd = try Dictamac.parse(["--mcp", "/tmp/a.m4a"])
        #expect(throws: DictamacCLIError.self) {
            try cmd.resolveMode()
        }
    }

    @Test func mcpWithVoiceMemoFailsValidation() throws {
        let cmd = try Dictamac.parse(["--mcp", "--voice-memo", "x"])
        #expect(throws: DictamacCLIError.self) {
            try cmd.resolveMode()
        }
    }

    @Test func mcpWithListVoiceMemosFailsValidation() throws {
        let cmd = try Dictamac.parse(["--mcp", "--list-voice-memos"])
        #expect(throws: DictamacCLIError.self) {
            try cmd.resolveMode()
        }
    }

    @Test func listVoiceMemosWithPathFailsValidation() throws {
        let cmd = try Dictamac.parse(["--list-voice-memos", "/tmp/a.m4a"])
        #expect(throws: DictamacCLIError.self) {
            try cmd.resolveMode()
        }
    }

    @Test func listVoiceMemosWithVoiceMemoFailsValidation() throws {
        let cmd = try Dictamac.parse(["--list-voice-memos", "--voice-memo", "x"])
        #expect(throws: DictamacCLIError.self) {
            try cmd.resolveMode()
        }
    }

    @Test func pathAndVoiceMemoTogetherFailValidation() throws {
        let cmd = try Dictamac.parse(["--voice-memo", "x", "/tmp/a.m4a"])
        #expect(throws: DictamacCLIError.self) {
            try cmd.resolveMode()
        }
    }

    @Test func dashAndVoiceMemoTogetherFailValidation() throws {
        let cmd = try Dictamac.parse(["--voice-memo", "x", "-"])
        #expect(throws: DictamacCLIError.self) {
            try cmd.resolveMode()
        }
    }

    @Test func noInputAndNoModeFailsValidation() throws {
        // Bare `dictamac` with no flags and no input.
        let cmd = try Dictamac.parse([])
        #expect(throws: DictamacCLIError.self) {
            try cmd.resolveMode()
        }
    }

    // MARK: - --since / --limit gated by --list-voice-memos

    @Test func sinceWithoutListVoiceMemosFailsValidation() throws {
        // --since is meaningless without --list-voice-memos.
        let cmd = try Dictamac.parse(["--since", "7d", "/tmp/a.m4a"])
        #expect(throws: DictamacCLIError.self) {
            try cmd.resolveMode()
        }
    }

    @Test func limitWithoutListVoiceMemosFailsValidation() throws {
        let cmd = try Dictamac.parse(["--limit", "5", "/tmp/a.m4a"])
        #expect(throws: DictamacCLIError.self) {
            try cmd.resolveMode()
        }
    }

    @Test func sinceWithMCPFailsValidation() throws {
        let cmd = try Dictamac.parse(["--mcp", "--since", "7d"])
        #expect(throws: DictamacCLIError.self) {
            try cmd.resolveMode()
        }
    }

    // MARK: - Error message content

    @Test func argumentErrorMessageMentionsConflict() throws {
        let cmd = try Dictamac.parse(["--mcp", "/tmp/a.m4a"])
        do {
            _ = try cmd.resolveMode()
            Issue.record("expected validation error")
        } catch let DictamacCLIError.argumentError(message) {
            #expect(!message.isEmpty)
        } catch {
            Issue.record("expected DictamacCLIError.argumentError, got \(error)")
        }
    }

    // MARK: - --version short-circuits

    @Test func versionStringMatchesConfiguration() {
        // The version string is the source of truth for `--version`
        // output and the `dictamac --version` integration test in the
        // PR description. Pin its value here so a bump shows up in
        // code review.
        #expect(Dictamac.configuration.version == "0.0.0-dev")
    }

    @Test func versionFlagIsRecognizedByParser() {
        // ArgumentParser handles `--version` by throwing an internal
        // parser error that `.main()` catches and turns into a
        // stdout print + exit(0). The error type is not part of the
        // public API, so we treat the test as "the parser does NOT
        // accept --version as a normal arg" plus "the rendered
        // message matches the configured version string" — both
        // surfaceable without naming the internal error type.
        do {
            _ = try Dictamac.parse(["--version"])
            Issue.record(
                "expected --version to throw a parser error so .main() can render the version"
            )
        } catch {
            let rendered = Dictamac.message(for: error)
            #expect(
                rendered == Dictamac.configuration.version,
                "expected message(for:) to render the configured version; got: \(rendered)"
            )
        }
    }

    // MARK: - Help text covers every flag

    @Test func helpTextMentionsEveryFlag() {
        let help = Dictamac.helpMessage()
        let requiredFlags = [
            "--locale",
            "--json",
            "--voice-memo",
            "--list-voice-memos",
            "--mcp",
            "--verbose",
            "--since",
            "--limit",
            "--version",
            "--help",
        ]
        for flag in requiredFlags {
            #expect(
                help.contains(flag),
                "expected help text to mention \(flag); got:\n\(help)"
            )
        }
    }
}
