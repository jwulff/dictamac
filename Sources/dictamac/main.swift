import DictamacCLI

// The CLI surface lives in the `DictamacCLI` library target so it can
// be unit-tested without going through an executable target (which
// would force every test to spawn a subprocess). The executable is a
// one-line wrapper that hands argv to `Dictamac.main()`.
//
// See `Sources/DictamacCLI/Dictamac.swift` for the concurrency-shape
// rationale (ParsableCommand + Task {} + dispatchMain()).
Dictamac.main()
