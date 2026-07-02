import Foundation

/// Anthropic / Claude. Claude's memory is a *directory of files* — a `MEMORY.md`
/// entrypoint plus topic files (markdown, commonly with YAML frontmatter), as used by the
/// Claude Code auto-memory and the API memory tool. This adapter maps each memory file
/// onto one portable episode: the file body becomes the episode text, and the frontmatter
/// (`name`, `description`, `metadata.type`) plus the file path are preserved into
/// `metadata` (namespaced `claude_*`) so a later `.mem` export stays lossless.
///
/// Input is the memory files themselves (not JSON), since Claude leaves the storage
/// format to the host. Adapters are pure: files in, `[PortableEpisode]` out — no I/O.
public enum ClaudeAdapter {
    /// Index/entrypoint files, tagged `claude_role: index` so a host can treat them
    /// specially (e.g. skip or pin them).
    private static let indexFiles: Set<String> = ["MEMORY.md", "CLAUDE.md"]

    /// Map memory files — `(path, content)` pairs — onto portable episodes.
    public static func parseEpisodes(files: [(path: String, content: String)]) -> [PortableEpisode] {
        files.compactMap { mapFile(path: $0.path, content: $0.content) }
    }

    static func mapFile(path: String, content: String) -> PortableEpisode? {
        let (frontmatter, body) = splitFrontmatter(content)
        let text = (body ?? content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let base = path.isEmpty ? "" : (path as NSString).lastPathComponent
        let stem = base.hasSuffix(".md") ? String(base.dropLast(3)) : base
        let name = frontmatter["name"] ?? (stem.isEmpty ? nil : stem)
        let description = frontmatter["description"]
        let ctype = frontmatter["metadata.type"] ?? frontmatter["type"]

        // Summary: the description, else the first non-empty line, else the name.
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let summary = String((description ?? (firstLine.isEmpty ? (name ?? "") : firstLine)).prefix(120))

        var meta: [String: String] = [:]
        put(&meta, "claude_path", path.isEmpty ? nil : path)
        put(&meta, "claude_name", name)
        put(&meta, "claude_type", ctype)
        put(&meta, "claude_description", description)
        if indexFiles.contains(base) { meta["claude_role"] = "index" }

        let now = Date()
        return PortableEpisode(
            id: name ?? (stem.isEmpty ? "ep_\(UUID().uuidString.prefix(16))" : stem),
            eventTime: now, mentionTime: now, ingestionTime: now,
            sourceType: "note", sourceID: path.isEmpty ? nil : path, actors: [],
            summary: summary, details: text, sensitivity: "low",
            deletedAt: nil, metadata: meta, contextID: nil,
            categories: ctype.map { [$0] } ?? [],
            importance: 0.5, confidence: 0.7, lifecycleState: "HOT", extractionState: "done",
            lastAccessed: nil, accessCount: 0, pinned: false, expirationDate: nil,
            vaultRefs: [], speaker: nil)
    }

    /// Parse a leading `---` YAML frontmatter block into a flat dictionary (nested keys
    /// as `parent.child`) plus the remaining body. Returns `([:], nil)` when there is
    /// none — the caller then uses the whole content as the body.
    ///
    /// A minimal, dependency-free parser for the `key: value` subset the memory format
    /// uses (Claude leaves the format to the host; the SDK stays dependency-light).
    /// Anything it can't parse is left in the body, never dropped.
    static func splitFrontmatter(_ content: String) -> (frontmatter: [String: String], body: String?) {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([:], nil) }
        guard let end = (1..<lines.count).first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == "---"
        }) else { return ([:], nil) }

        var fm: [String: String] = [:]
        var parent: String?
        for raw in lines[1..<end] {
            let stripped = raw.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.hasPrefix("#") { continue }
            guard let colon = stripped.firstIndex(of: ":") else { continue }
            let key = String(stripped[..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(stripped[stripped.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let indented = raw.hasPrefix(" ") || raw.hasPrefix("\t")
            if indented, let parent {
                fm["\(parent).\(key)"] = val
            } else if val.isEmpty {
                parent = key  // a nested block follows
            } else {
                fm[key] = val
                parent = nil
            }
        }
        return (fm, lines[(end + 1)...].joined(separator: "\n"))
    }

    private static func put(_ meta: inout [String: String], _ key: String, _ value: String?) {
        if let value, !value.isEmpty { meta[key] = value }
    }
}
