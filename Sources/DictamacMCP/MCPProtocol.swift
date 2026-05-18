import Foundation

/// MCP protocol version this server speaks. Pin in ONE place; bumping
/// this constant is the only mechanism for advertising a new revision.
///
/// See `docs/PLAN.md` §9 "Open Questions & Risks" — MCP protocol-version
/// drift is a tracked medium-likelihood risk and the mitigation is
/// exactly the pattern below: a single named constant, plus a snapshot /
/// drift test in `Tests/DictamacMCPTests/` that fails loudly when the
/// constant changes. Updating the version is then a deliberate,
/// reviewable act rather than an accidental drift.
///
/// The currently pinned value is the latest stable Model Context Protocol
/// spec revision the implementer validated against:
/// <https://spec.modelcontextprotocol.io/>.
public let mcpProtocolVersion: String = "2025-06-18"

/// Server identity advertised in the `initialize` response.
///
/// These three fields constitute the server's contract with any MCP
/// client: they identify the implementation, the publisher, and the
/// build. Kept as a single struct so handlers and tests reference the
/// same source of truth instead of duplicating string literals.
public struct MCPServerIdentity: Sendable, Equatable {
    public let name: String
    public let version: String
    public let vendor: String

    public init(name: String, version: String, vendor: String) {
        self.name = name
        self.version = version
        self.vendor = vendor
    }

    /// Canonical identity used by `dictamac --mcp`. The version string
    /// matches the `CommandConfiguration(version:)` value in
    /// `Sources/DictamacCLI/Dictamac.swift`. The two will drift unless
    /// kept in lockstep; a follow-up issue (see PR description) will
    /// extract a single package-version constant so this duplication
    /// can be removed.
    public static let dictamac = MCPServerIdentity(
        name: "dictamac",
        version: "0.0.0-dev",
        vendor: "jwulff"
    )
}
