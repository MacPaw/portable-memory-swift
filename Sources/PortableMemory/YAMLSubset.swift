import Foundation

/// Minimal YAML reader — the subset the Engram Specification and PLUR's files use.
///
/// The SDK stays Foundation-only, so this is a small, tolerant, deterministic reader for
/// the YAML that memory tools actually write — not a general YAML 1.2 implementation:
///  * block mappings and block sequences (including a sequence at the same indent as its
///    key, and `- key: value` items whose mapping starts inline);
///  * block scalars `|`, `|-`, `|+`, `>`, `>-`, `>+` (literal / folded, chomping);
///  * single-line and multi-line flow collections `[a, b]` / `{k: v}`;
///  * double-quoted (JSON escapes) and single-quoted strings; plain scalars typed by the
///    YAML 1.2 core schema (`null`/`~`, `true`/`false`, integers, floats — dates stay
///    strings); multi-line plain scalars;
///  * comments, and `---` / `...` document markers (a multi-document stream yields an array).
///
/// Anything outside the subset degrades to strings rather than throwing. Mirrored
/// line-for-line by the Python `portable_memory/_yaml.py` so both SDKs read a file
/// identically. Values are produced as `JSONValue` so canonical encoding is shared.
enum YAMLSubset {
    private static let digits: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
    /// Nesting deeper than this degrades to a string — keeps hostile input from exhausting
    /// the stack (mirrored in Python so both SDKs agree on where they give up).
    private static let maxDepth = 64

    /// Parse a YAML stream. One document → its value; several → `.array` of values;
    /// nothing → `.null`.
    static func load(_ text: String) -> JSONValue {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var docs: [JSONValue] = []
        var current: [String] = []
        var started = false
        for line in lines {
            let c = content(line)
            if !started, c.hasPrefix("%") { continue }              // a directive before the first document
            if c == "---" || c.hasPrefix("--- ") {
                if started || !current.isEmpty { docs.append(parseDocument(current)) }
                current = []
                started = true
                let rest = trim(String(c.dropFirst(3)))
                if !rest.isEmpty { current.append(rest) }
                continue
            }
            if c == "..." {
                docs.append(parseDocument(current))
                current = []
                started = false
                continue
            }
            if !c.isEmpty { started = true }
            current.append(line)
        }
        if !current.isEmpty || docs.isEmpty { docs.append(parseDocument(current)) }
        while docs.count > 1, docs.last == .null { docs.removeLast() }
        while docs.count > 1, docs.first == .null { docs.removeFirst() }
        return docs.count == 1 ? docs[0] : .array(docs)
    }

    // MARK: - Lines

    static func indent(_ line: String) -> Int {
        var n = 0
        for ch in line { if ch == " " { n += 1 } else { break } }
        return n
    }

    private static func opensQuote(_ chars: [Character], _ idx: Int) -> Bool {
        if idx == 0 { return true }
        return [" ", "\t", ":", "[", "{", ","].contains(chars[idx - 1])
    }

    static func stripComment(_ line: String) -> String {
        let chars = Array(line)
        var inSingle = false, inDouble = false
        var idx = 0
        while idx < chars.count {
            let ch = chars[idx]
            if inDouble {
                if ch == "\\" { idx += 1 } else if ch == "\"" { inDouble = false }
            } else if inSingle {
                if ch == "'" {
                    if idx + 1 < chars.count, chars[idx + 1] == "'" { idx += 1 }   // '' is an escaped quote
                    else { inSingle = false }
                }
            } else if ch == "\"", opensQuote(chars, idx) {
                inDouble = true
            } else if ch == "'", opensQuote(chars, idx) {
                inSingle = true
            } else if ch == "#", idx == 0 || chars[idx - 1] == " " || chars[idx - 1] == "\t" {
                return String(chars[0..<idx])
            }
            idx += 1
        }
        return line
    }

    static func content(_ line: String) -> String { trim(stripComment(line)) }

    static func skipBlank(_ lines: [String], _ start: Int) -> Int {
        var i = start
        while i < lines.count, content(lines[i]).isEmpty { i += 1 }
        return i
    }

    static func isSeqItem(_ c: String) -> Bool { c == "-" || c.hasPrefix("- ") }

    // MARK: - Block structure

    static func parseDocument(_ input: [String]) -> JSONValue {
        var lines = input
        let i = skipBlank(lines, 0)
        if i >= lines.count { return .null }
        return parseBlock(&lines, i, indent(lines[i])).0
    }

    static func parseBlock(_ lines: inout [String], _ i: Int, _ ind: Int, _ depth: Int = 0) -> (JSONValue, Int) {
        let c = content(lines[i])
        if depth > maxDepth { return (scalar(c), i + 1) }
        if isSeqItem(c) { return parseSequence(&lines, i, ind, depth) }
        if splitKey(c) != nil { return parseMapping(&lines, i, ind, depth) }
        return parseInlineValue(&lines, i, ind - 1, c)
    }

    static func parseSequence(_ lines: inout [String], _ start: Int, _ ind: Int, _ depth: Int = 0) -> (JSONValue, Int) {
        var items: [JSONValue] = []
        var i = start
        let n = lines.count
        while true {
            i = skipBlank(lines, i)
            if i >= n { break }
            let lineInd = indent(lines[i])
            let c = content(lines[i])
            if lineInd < ind { break }
            if lineInd > ind { i += 1; continue }               // a stray deeper line — tolerate
            if !isSeqItem(c) { break }
            var value: JSONValue
            if c == "-" {
                let j = skipBlank(lines, i + 1)
                if j < n, indent(lines[j]) > ind {
                    (value, i) = parseBlock(&lines, j, indent(lines[j]), depth + 1)
                } else {
                    value = .null; i = j
                }
            } else {
                let rest = lstrip(String(c.dropFirst(2)))
                let col = ind + (c.count - rest.count)
                if splitKey(rest) != nil {
                    lines[i] = String(repeating: " ", count: col) + rest   // re-read as a mapping at `col`
                    (value, i) = parseMapping(&lines, i, col, depth + 1)
                } else {
                    (value, i) = parseInlineValue(&lines, i, ind, rest)
                }
            }
            items.append(value)
        }
        return (.array(items), i)
    }

    static func parseMapping(_ lines: inout [String], _ start: Int, _ ind: Int, _ depth: Int = 0) -> (JSONValue, Int) {
        var result: [String: JSONValue] = [:]
        var i = start
        let n = lines.count
        while true {
            i = skipBlank(lines, i)
            if i >= n { break }
            let lineInd = indent(lines[i])
            let c = content(lines[i])
            if lineInd < ind { break }
            if lineInd > ind { i += 1; continue }
            if isSeqItem(c) { break }
            guard let kv = splitKey(c) else { break }
            let (key, rest) = kv
            var value: JSONValue
            if rest.isEmpty {
                let j = skipBlank(lines, i + 1)
                if j < n, indent(lines[j]) > ind {
                    (value, i) = parseBlock(&lines, j, indent(lines[j]), depth + 1)
                } else if j < n, indent(lines[j]) == ind, isSeqItem(content(lines[j])) {
                    (value, i) = parseSequence(&lines, j, ind, depth + 1)    // a sequence at the key's own indent
                } else {
                    value = .null; i = j
                }
            } else {
                (value, i) = parseInlineValue(&lines, i, ind, rest)
            }
            result[key] = value
        }
        return (.object(result), i)
    }

    /// `key: rest` → (key, rest) when `c` is a mapping entry, else nil.
    static func splitKey(_ c: String) -> (String, String)? {
        guard let first = c.first, first != "[", first != "{" else { return nil }
        let chars = Array(c)
        if first == "\"" || first == "'" {
            let (key, after) = readQuoted(chars, 0)
            var pos = after
            while pos < chars.count, chars[pos] == " " || chars[pos] == "\t" { pos += 1 }
            if pos < chars.count, chars[pos] == ":",
               pos + 1 == chars.count || chars[pos + 1] == " " || chars[pos + 1] == "\t" {
                return (key, trim(String(chars[(pos + 1)...])))
            }
            return nil
        }
        for (idx, ch) in chars.enumerated() where ch == ":" {
            if idx + 1 == chars.count || chars[idx + 1] == " " || chars[idx + 1] == "\t" {
                let key = trim(String(chars[0..<idx]))
                return key.isEmpty ? nil : (key, trim(String(chars[(idx + 1)...])))
            }
        }
        return nil
    }

    // MARK: - Values

    static func isBlockIndicator(_ rest: String) -> Bool {
        guard let first = rest.first, first == "|" || first == ">" else { return false }
        return rest.dropFirst().allSatisfy { $0 == "+" || $0 == "-" || digits.contains($0) }
    }

    static func parseInlineValue(_ lines: inout [String], _ i: Int, _ ind: Int, _ rest: String) -> (JSONValue, Int) {
        let n = lines.count
        guard let first = rest.first else { return (.null, i + 1) }
        if isBlockIndicator(rest) { return parseBlockScalar(lines, i, ind, rest) }
        if first == "[" || first == "{" {
            var text = rest
            var j = i + 1
            while !flowBalanced(text), j < n { text += " " + content(lines[j]); j += 1 }
            return (parseFlow(Array(text), 0).0, j)
        }
        if first == "\"" || first == "'" { return (scalar(rest), i + 1) }
        var text = rest
        var j = i + 1
        while j < n {
            let cj = content(lines[j])
            if cj.isEmpty || indent(lines[j]) <= ind || isSeqItem(cj) || splitKey(cj) != nil { break }
            text += " " + cj                                      // a plain scalar continued on a deeper line
            j += 1
        }
        return (scalar(text), j)
    }

    static func parseBlockScalar(_ lines: [String], _ i: Int, _ ind: Int, _ indicator: String) -> (JSONValue, Int) {
        let literal = indicator.first == "|"
        let chomp = indicator.contains("-") ? "strip" : (indicator.contains("+") ? "keep" : "clip")
        let explicit = String(indicator.dropFirst().filter { digits.contains($0) })
        var blockIndent: Int? = explicit.isEmpty ? nil : ind + (Int(explicit) ?? 0)
        var collected: [String] = []
        var j = i + 1
        let n = lines.count
        while j < n {
            let raw = lines[j]
            if trim(raw).isEmpty { collected.append(""); j += 1; continue }
            let lineInd = indent(raw)
            if blockIndent == nil {
                if lineInd <= ind { break }
                blockIndent = lineInd
            }
            if lineInd < blockIndent! { break }
            collected.append(String(raw.dropFirst(blockIndent!)))
            j += 1
        }
        var trailing = 0
        while let last = collected.last, last.isEmpty { collected.removeLast(); trailing += 1 }
        let body: String
        if literal {
            body = collected.joined(separator: "\n")
        } else {
            var parts: [String] = []
            for ln in collected {
                if ln.isEmpty {
                    parts.append("\n")
                } else {
                    if let last = parts.last, last != "\n" { parts.append(" ") }
                    parts.append(ln)
                }
            }
            body = parts.joined()
        }
        switch chomp {
        case "strip": return (.string(body), j)
        case "keep": return (.string(body + String(repeating: "\n", count: 1 + trailing)), j)
        default: return (.string(body.isEmpty ? "" : body + "\n"), j)
        }
    }

    static func flowBalanced(_ text: String) -> Bool {
        var depth = 0
        var inSingle = false, inDouble = false
        let chars = Array(text)
        var idx = 0
        while idx < chars.count {
            let ch = chars[idx]
            if inDouble {
                if ch == "\\" { idx += 1 } else if ch == "\"" { inDouble = false }
            } else if inSingle {
                if ch == "'" {
                    if idx + 1 < chars.count, chars[idx + 1] == "'" { idx += 1 } else { inSingle = false }
                }
            } else if ch == "\"" {
                inDouble = true
            } else if ch == "'" {
                inSingle = true
            } else if ch == "[" || ch == "{" {
                depth += 1
            } else if ch == "]" || ch == "}" {
                depth -= 1
            }
            idx += 1
        }
        return depth <= 0
    }

    private static func ws(_ t: [Character], _ start: Int) -> Int {
        var p = start
        while p < t.count, t[p] == " " || t[p] == "\t" || t[p] == "\n" { p += 1 }
        return p
    }

    static func parseFlow(_ t: [Character], _ start: Int, _ depth: Int = 0) -> (JSONValue, Int) {
        var pos = ws(t, start)
        if pos >= t.count { return (.null, pos) }
        if depth > maxDepth { return (.string(trim(String(t[pos...]))), t.count) }   // too deep — the rest is a string
        let ch = t[pos]
        if ch == "[" {
            var items: [JSONValue] = []
            pos += 1
            while true {
                pos = ws(t, pos)
                if pos >= t.count { return (.array(items), pos) }
                if t[pos] == "]" { return (.array(items), pos + 1) }
                if t[pos] == "," { pos += 1; continue }
                let (v, p) = parseFlowValue(t, pos, "]", depth)
                items.append(v); pos = p
            }
        }
        if ch == "{" {
            var obj: [String: JSONValue] = [:]
            pos += 1
            while true {
                pos = ws(t, pos)
                if pos >= t.count { return (.object(obj), pos) }
                if t[pos] == "}" { return (.object(obj), pos + 1) }
                if t[pos] == "," { pos += 1; continue }
                let (key, p1) = flowKey(t, pos)
                pos = ws(t, p1)
                if pos < t.count, t[pos] == ":" { pos += 1 }
                pos = ws(t, pos)
                if pos >= t.count || t[pos] == "," || t[pos] == "}" {
                    obj[key] = .null
                } else {
                    let (v, p) = parseFlowValue(t, pos, "}", depth)
                    obj[key] = v; pos = p
                }
            }
        }
        return parseFlowValue(t, pos, nil, depth)
    }

    private static func flowKey(_ t: [Character], _ start: Int) -> (String, Int) {
        if t[start] == "\"" || t[start] == "'" { return readQuoted(t, start) }
        var pos = start
        while pos < t.count, t[pos] != ":", t[pos] != ",", t[pos] != "}" { pos += 1 }
        return (trim(String(t[start..<pos])), pos)
    }

    private static func parseFlowValue(_ t: [Character], _ start: Int, _ closer: Character?, _ depth: Int = 0) -> (JSONValue, Int) {
        if t[start] == "[" || t[start] == "{" { return parseFlow(t, start, depth + 1) }
        if t[start] == "\"" || t[start] == "'" {
            let (s, p) = readQuoted(t, start)
            return (.string(s), p)
        }
        var pos = start
        while pos < t.count, t[pos] != ",", closer == nil || t[pos] != closer! { pos += 1 }
        return (scalar(String(t[start..<pos])), pos)
    }

    /// Read a quoted scalar starting at `t[start]`; returns (value, index after the closing
    /// quote). An unterminated quote consumes the rest of the text.
    static func readQuoted(_ t: [Character], _ start: Int) -> (String, Int) {
        let quote = t[start]
        var pos = start + 1
        var out = ""
        if quote == "'" {
            while pos < t.count {
                let ch = t[pos]
                if ch == "'" {
                    if pos + 1 < t.count, t[pos + 1] == "'" { out.append("'"); pos += 2; continue }
                    return (out, pos + 1)
                }
                out.append(ch); pos += 1
            }
            return (out, pos)
        }
        while pos < t.count {
            let ch = t[pos]
            if ch == "\\", pos + 1 < t.count {
                let esc = t[pos + 1]
                pos += 2
                switch esc {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{8}")
                case "f": out.append("\u{C}")
                case "0": out.append("\0")
                case "u" where pos + 4 <= t.count && t[pos..<(pos + 4)].allSatisfy({ $0.isHexDigit }):
                    let cp = UInt32(String(t[pos..<(pos + 4)]), radix: 16)!
                    // A lone surrogate is not encodable as UTF-8 — substitute U+FFFD (Python does the same).
                    out.append(Character(UnicodeScalar(cp) ?? UnicodeScalar(0xFFFD)!))
                    pos += 4
                default: out.append(esc)                            // \" \\ \/ and anything unknown → the character
                }
                continue
            }
            if ch == "\"" { return (out, pos + 1) }
            out.append(ch); pos += 1
        }
        return (out, pos)
    }

    static func scalar(_ raw: String) -> JSONValue {
        let s = trim(raw)
        guard let first = s.first else { return .null }
        if first == "\"" || first == "'" { return .string(readQuoted(Array(s), 0).0) }
        switch s {
        case "null", "Null", "NULL", "~": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        if isInt(s) {
            if let v = Int(s) { return .int(v) }
            if let u = UInt64(s) { return .uint(u) }
            return .string(s)
        }
        if isFloat(s), let d = Double(s) { return .double(d) }
        return .string(s)
    }

    static func isInt(_ s: String) -> Bool {
        let body = (s.first == "+" || s.first == "-") ? String(s.dropFirst()) : s
        return !body.isEmpty && body.allSatisfy { digits.contains($0) }
    }

    static func isFloat(_ s: String) -> Bool {
        let body = Array((s.first == "+" || s.first == "-") ? String(s.dropFirst()) : s)
        guard let first = body.first, digits.contains(first) else { return false }
        var i = 0
        while i < body.count, digits.contains(body[i]) { i += 1 }
        var sawFraction = false, sawExponent = false
        if i < body.count, body[i] == "." {
            i += 1
            let start = i
            while i < body.count, digits.contains(body[i]) { i += 1 }
            if i == start { return false }
            sawFraction = true
        }
        if i < body.count, body[i] == "e" || body[i] == "E" {
            i += 1
            if i < body.count, body[i] == "+" || body[i] == "-" { i += 1 }
            let start = i
            while i < body.count, digits.contains(body[i]) { i += 1 }
            if i == start { return false }
            sawExponent = true
        }
        return i == body.count && (sawFraction || sawExponent)
    }

    // MARK: - Helpers (space/tab trimming only — YAML structure never spans newlines)

    static func trim(_ s: String) -> String {
        var sub = Substring(s)
        while let f = sub.first, f == " " || f == "\t" { sub = sub.dropFirst() }
        while let l = sub.last, l == " " || l == "\t" { sub = sub.dropLast() }
        return String(sub)
    }

    static func lstrip(_ s: String) -> String {
        String(s.drop(while: { $0 == " " || $0 == "\t" }))
    }
}
