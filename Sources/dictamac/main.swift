import ArgumentParser
import DictamacCore

struct Dictamac: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictamac",
        abstract: "Transcribe audio via Apple's on-device SpeechAnalyzer.",
        version: "0.0.0-dev"
    )

    func run() throws {
        print("dictamac v0.0.0-dev — see https://github.com/jwulff/dictamac")
    }
}

Dictamac.main()
