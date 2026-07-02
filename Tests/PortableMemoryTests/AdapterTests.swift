import XCTest
@testable import PortableMemory

/// OpenAI (ChatGPT `conversations.json`) and Claude (memory files) adapter tests —
/// mirrors the Python suite (`tests/test_adapters_openai_claude.py`) so the two SDKs'
/// mappings stay at parity.
final class AdapterTests: XCTestCase {

    // MARK: - OpenAI

    private var chatGPTExport: String {
        """
        [{
          "title": "Trip planning",
          "conversation_id": "conv_1",
          "create_time": 1700000000.0,
          "mapping": {
            "root": {"id": "root", "message": null, "parent": null, "children": ["a"]},
            "a": {"id": "a", "parent": "root", "children": ["b"], "message": {
              "id": "m_sys", "author": {"role": "system"},
              "content": {"content_type": "text", "parts": [""]}, "create_time": null}},
            "c": {"id": "c", "parent": "b", "children": [], "message": {
              "id": "m_asst", "author": {"role": "assistant"},
              "content": {"content_type": "text", "parts": ["Sure! Here is a plan..."]},
              "metadata": {"model_slug": "gpt-4o"}, "create_time": 1700000200.0}},
            "b": {"id": "b", "parent": "a", "children": ["c"], "message": {
              "id": "m_user", "author": {"role": "user"},
              "content": {"content_type": "text", "parts": ["Plan a trip to Kyoto"]},
              "create_time": 1700000100.0}},
            "d": {"id": "d", "parent": "c", "children": [], "message": {
              "id": "m_hidden", "author": {"role": "assistant"},
              "content": {"content_type": "text", "parts": ["hidden"]},
              "metadata": {"is_visually_hidden_from_conversation": true},
              "create_time": 1700000300.0}}
          }
        }]
        """
    }

    func testOpenAIConversationsExport() throws {
        let eps = try OpenAIAdapter.parseEpisodes(Data(chatGPTExport.utf8))
        // system + hidden dropped; user + assistant kept, ordered by create_time.
        XCTAssertEqual(eps.map(\.id), ["m_user", "m_asst"])
        XCTAssertEqual(eps.map(\.speaker), ["user", "assistant"])
        XCTAssertTrue(eps.allSatisfy { $0.sourceType == "chat" })
        XCTAssertTrue(eps.allSatisfy { $0.contextID == "conv_1" })

        let user = eps[0]
        XCTAssertEqual(user.details, "Plan a trip to Kyoto")
        XCTAssertEqual(user.eventTime, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(user.metadata["openai_conversation_title"], "Trip planning")
        XCTAssertEqual(user.metadata["openai_role"], "user")
        XCTAssertNil(user.metadata["openai_model"])
        XCTAssertEqual(user.metadata["openai_create_time"], "2023-11-14T22:15:00Z")

        let asst = eps[1]
        XCTAssertEqual(asst.metadata["openai_model"], "gpt-4o")
        XCTAssertEqual(asst.metadata["openai_message_id"], "m_asst")
    }

    func testOpenAIAcceptsSingleConversation() throws {
        let single = chatGPTExport.trimmingCharacters(in: .whitespacesAndNewlines)
        let inner = String(single.dropFirst().dropLast())   // strip the outer [ ]
        let eps = try OpenAIAdapter.parseEpisodes(Data(inner.utf8))
        XCTAssertEqual(eps.count, 2)
    }

    func testOpenAISavedMemoriesFallback() throws {
        let json = #"["I prefer metric units.", {"id": "mem_2", "memory": "Lives in Kyiv."}]"#
        let eps = try OpenAIAdapter.parseEpisodes(Data(json.utf8))
        XCTAssertEqual(eps.count, 2)
        XCTAssertEqual(eps[0].sourceType, "note")
        XCTAssertEqual(eps[0].metadata["openai_source"], "memory")
        XCTAssertEqual(eps[1].id, "mem_2")
        XCTAssertEqual(eps[1].details, "Lives in Kyiv.")
    }

    func testOpenAIEmptyAndGarbage() throws {
        XCTAssertEqual(try OpenAIAdapter.parseEpisodes(Data("[]".utf8)).count, 0)
        XCTAssertEqual(try OpenAIAdapter.parseEpisodes(Data("{}".utf8)).count, 0)
    }

    // MARK: - Claude

    private var claudeFiles: [(path: String, content: String)] {
        [
            ("memory/MEMORY.md", "# Memory index\n- project-x: launch\n"),
            ("memory/project-x.md",
             "---\nname: project-x\ndescription: X launch plan\nmetadata:\n  type: project\n---\n"
             + "Ship X on Pi Day. Owner: Ada.\n"),
            ("memory/empty.md", "---\n---\n   \n"),
        ]
    }

    func testClaudeMemoryFiles() {
        let eps = ClaudeAdapter.parseEpisodes(files: claudeFiles)
        let byID = Dictionary(uniqueKeysWithValues: eps.map { ($0.id, $0) })
        XCTAssertNil(byID["empty"], "empty body dropped")
        XCTAssertEqual(Set(byID.keys), ["MEMORY", "project-x"])

        let px = try! XCTUnwrap(byID["project-x"])
        XCTAssertEqual(px.sourceType, "note")
        XCTAssertEqual(px.summary, "X launch plan")
        XCTAssertEqual(px.details, "Ship X on Pi Day. Owner: Ada.")
        XCTAssertEqual(px.categories, ["project"])
        XCTAssertEqual(px.metadata["claude_type"], "project")
        XCTAssertEqual(px.metadata["claude_name"], "project-x")
        XCTAssertEqual(px.metadata["claude_path"], "memory/project-x.md")
        XCTAssertEqual(px.metadata["claude_description"], "X launch plan")

        let idx = try! XCTUnwrap(byID["MEMORY"])
        XCTAssertEqual(idx.metadata["claude_role"], "index")
        XCTAssertTrue(idx.details.contains("Memory index"))
    }

    func testClaudeNoFrontmatter() {
        let eps = ClaudeAdapter.parseEpisodes(files: [("notes.md", "Just a plain note.")])
        XCTAssertEqual(eps[0].details, "Just a plain note.")
        XCTAssertEqual(eps[0].summary, "Just a plain note.")
        XCTAssertEqual(eps[0].categories, [])
        XCTAssertEqual(eps[0].id, "notes")
    }
}
