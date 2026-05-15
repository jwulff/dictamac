import ArgumentParser
import Foundation

struct Dictamac: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictamac",
        abstract: "Transcribe audio via Apple's on-device SpeechAnalyzer.",
        version: "0.0.0-dev"
    )

    func run() throws {
        // stdout is reserved for transcript content (see docs/PLAN.md §4).
        // Diagnostic/banner output goes to stderr.
        let banner = "dictamac v0.0.0-dev — see https://github.com/jwulff/dictamac\n"
        FileHandle.standardError.write(Data(banner.utf8))
    }
}

Dictamac.main()
