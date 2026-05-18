import Testing
import Foundation
@testable import DictamacVoiceMemos

/// Tests for ``VoiceMemoListing`` — the wire shape returned by
/// `--list-voice-memos --json` and the MCP `list_voice_memos` tool.
/// One shape, two transports.
struct VoiceMemoListingTests {

    @Test func initFromMetadataCopiesFields() {
        let recordedAt = Date(timeIntervalSince1970: 1_715_000_000)
        let metadata = VoiceMemoMetadata(
            identifier: "abc123",
            title: "Standup notes",
            recordedAt: recordedAt,
            durationSeconds: 184.3,
            assetPath: URL(fileURLWithPath: "/tmp/example.m4a")
        )

        let listing = VoiceMemoListing(from: metadata)

        #expect(listing.identifier == "abc123")
        #expect(listing.title == "Standup notes")
        #expect(listing.recordedAt == recordedAt)
        #expect(listing.durationSeconds == 184.3)
    }

    @Test func encodesToJSONMatchingMCPSchema() throws {
        let recordedAt = Date(timeIntervalSince1970: 1_715_000_000)
        let listing = VoiceMemoListing(
            identifier: "42",
            title: "Walk",
            recordedAt: recordedAt,
            durationSeconds: 60.5
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(listing)
        let json = String(data: data, encoding: .utf8) ?? ""

        // PLAN.md §5 mandates these four keys exactly.
        #expect(json.contains("\"durationSeconds\":60.5"))
        #expect(json.contains("\"identifier\":\"42\""))
        #expect(json.contains("\"title\":\"Walk\""))
        // ISO8601 form of the recordedAt instant.
        let iso = ISO8601DateFormatter().string(from: recordedAt)
        #expect(json.contains("\"recordedAt\":\"\(iso)\""))
    }

    @Test func arrayEncodesAsJSONArray() throws {
        let listings: [VoiceMemoListing] = [
            VoiceMemoListing(
                identifier: "1",
                title: "A",
                recordedAt: Date(timeIntervalSince1970: 1_715_000_000),
                durationSeconds: 1
            ),
            VoiceMemoListing(
                identifier: "2",
                title: "B",
                recordedAt: Date(timeIntervalSince1970: 1_715_001_000),
                durationSeconds: 2
            ),
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(listings)
        let json = String(data: data, encoding: .utf8) ?? ""

        #expect(json.hasPrefix("["))
        #expect(json.hasSuffix("]"))
        #expect(json.contains("\"A\""))
        #expect(json.contains("\"B\""))
    }
}
