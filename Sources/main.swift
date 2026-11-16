// Claude Config Map — shows which Claude Code instruction/config files apply where.
// Read-only: this program never writes to any file it scans. The only file it
// writes is its own list of scan folders (~/Library/Application Support/ClaudeConfigMap/config.json).

import Cocoa
import WebKit

// MARK: - Environment (overridable for demos/tests)

let env = ProcessInfo.processInfo.environment
let fm = FileManager.default
let HOME: String = env["CCM_HOME"] ?? NSHomeDirectory()
let CLAUDE_DIR = HOME + "/.claude"
let MANAGED_DIR = env["CCM_MANAGED_DIR"] ?? "/Library/Application Support/ClaudeCode"
let CONFIG_DIR = env["CCM_CONFIG_DIR"] ?? (NSHomeDirectory() + "/Library/Application Support/ClaudeConfigMap")
let CONFIG_FILE = CONFIG_DIR + "/config.json"

let MAX_CONTENT_BYTES = 200_000
let MAX_DEPTH = 6
let MEMORY_MAX_LINES = 200
let MEMORY_MAX_BYTES = 25_000
let SKIP_DIRS: Set<String> = ["node_modules", "build", "dist", "out", "target", "Pods", "DerivedData",
                              "vendor", "venv", "__pycache__", "Library", "Applications", "Carthage"]
let SKIP_EXT: Set<String> = ["app", "framework", "bundle", "xcassets", "xcodeproj", "xcworkspace", "photoslibrary"]

// MARK: - File helpers

func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
func isFile(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && !d.boolValue }
func join(_ a: String, _ b: String) -> String { (a as NSString).appendingPathComponent(b) }
func parentOf(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
func baseName(_ p: String) -> String { (p as NSString).lastPathComponent }
func isSymlink(_ p: String) -> Bool {
    ((try? fm.attributesOfItem(atPath: p))?[.type] as? FileAttributeType) == .typeSymbolicLink
}
func children(_ p: String) -> [String] {
    ((try? fm.contentsOfDirectory(atPath: p)) ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}
func readText(_ p: String) -> (String, Bool) {
    guard let h = FileHandle(forReadingAtPath: p) else { return ("", false) }
    defer { try? h.close() }
    let data = h.readData(ofLength: MAX_CONTENT_BYTES + 1)
    let truncated = data.count > MAX_CONTENT_BYTES
    return (String(decoding: data.prefix(MAX_CONTENT_BYTES), as: UTF8.self), truncated)
}
func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }
func tokenEstimate(_ s: String) -> Int { Int((Double(wordCount(s)) / 0.75).rounded()) }
let isoFormatter = ISO8601DateFormatter()
func modified(_ p: String) -> String? {
    guard let d = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date else { return nil }
    return isoFormatter.string(from: d)
}
func fileSize(_ p: String) -> Int { ((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.intValue ?? 0 }
func tilde(_ p: String) -> String { p == HOME ? "~" : (p.hasPrefix(HOME + "/") ? "~" + p.dropFirst(HOME.count) : p) }

/// Claude Code names per-project folders in ~/.claude/projects by replacing every
/// character that isn't a letter or digit with "-".
func encodeProjectPath(_ p: String) -> String {
    String(p.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
}

/// Best-effort reverse of encodeProjectPath by walking the real file system.
func decodeProjectName(_ name: String) -> String? {
    func search(_ dir: String, _ rest: String, _ depth: Int) -> String? {
        if depth > 30 { return nil }
        for c in children(dir) {
            let e = encodeProjectPath(c)
            let p = join(dir, c)
            if rest == e && isDir(p) { return p }
            if rest.hasPrefix(e + "-") && isDir(p) && !isSymlink(p) {
                if let r = search(p, String(rest.dropFirst(e.count + 1)), depth + 1) { return r }
            }
        }
        return nil
    }
    guard name.hasPrefix("-") else { return nil }
    return search("/", String(name.dropFirst()), 0)
}

func frontmatter(_ s: String) -> [String: String] {
    guard s.hasPrefix("---") else { return [:] }
    var out: [String: String] = [:]
    var lastKey: String? = nil
    for l in s.components(separatedBy: "\n").dropFirst() {
        if l.trimmingCharacters(in: .whitespaces) == "---" { break }
        let indented = l.hasPrefix(" ") || l.hasPrefix("\t")
        if !indented, let r = l.range(of: ":") {
            let k = String(l[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            var v = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(v) { v = "" }
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            out[k] = v; lastKey = k
        } else if let k = lastKey {
            out[k] = ((out[k] ?? "") + " " + l.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces)
        }
    }
    return out
}

func gitRoot(_ f: String) -> String? {
    var d = f
    while true {
        if fm.fileExists(atPath: join(d, ".git")) { return d }
        let p = parentOf(d)
        if p == d || p.isEmpty { return nil }
        d = p
    }
}

/// "/" ... f, inclusive, root first.
func ancestors(_ f: String) -> [String] {
    var out: [String] = []
    var d = (f as NSString).standardizingPath
    while true {
        out.append(d)
        let p = parentOf(d)
        if p == d || p.isEmpty { break }
        d = p
    }
    return out.reversed()
}

func mdFiles(in dir: String, recursive: Bool) -> [String] {
    guard isDir(dir) else { return [] }
    var out: [String] = []
    for c in children(dir) where !c.hasPrefix(".") {
        let p = join(dir, c)
        if isDir(p) { if recursive { out += mdFiles(in: p, recursive: true) } }
        else if c.lowercased().hasSuffix(".md") { out.append(p) }
    }
    return out
}

// MARK: - File records

enum Load: String {
    case everyChat = "every-chat"       // full text in every session's context
    case description = "description"    // name+description every chat; body on demand (skills, agents)
    case onDemand = "on-demand"         // read only when needed
    case notInContext = "not-in-context" // configures Claude Code; never sent to the model
    case notLoaded = "not-loaded"       // personal notes; not loaded unless asked
}

func formatFor(_ p: String) -> String {
    let l = p.lowercased()
    if l.hasSuffix(".md") { return "md" }
    if l.hasSuffix(".json") { return "json" }
    return "text"
}

func fileRecord(_ path: String, scope: String, level: String, kind: String, load: Load,
                applies: String, note: String? = nil, perChatText: String? = nil) -> [String: Any] {
    let (content, truncated) = readText(path)
    var perChat = 0
    switch load {
    case .everyChat: perChat = tokenEstimate(perChatText ?? content)
    case .description: perChat = tokenEstimate(perChatText ?? "")
    default: perChat = 0
    }
    var r: [String: Any] = [
        "id": kind + ":" + path, "path": path, "display": tilde(path), "name": baseName(path),
        "scope": scope, "level": level, "kind": kind, "load": load.rawValue, "appliesTo": applies,
        "size": fileSize(path), "words": wordCount(content), "tokens": tokenEstimate(content),
        "perChat": perChat, "content": content, "truncated": truncated, "format": formatFor(path),
    ]
    if let m = modified(path) { r["modified"] = m }
    if let n = note { r["note"] = n }
    return r
}

let importRegex = try! NSRegularExpression(pattern: #"(?:^|\s)@((?:\\ |[^\s`])+)"#)

func importsOf(_ path: String, _ content: String) -> [String] {
    var out: [String] = []
    var inFence = false
    for rawLine in content.components(separatedBy: "\n") {
        let t = rawLine.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); continue }
        if inFence { continue }
        var line = rawLine
        while let a = line.range(of: "`"), let b = line.range(of: "`", range: a.upperBound..<line.endIndex) {
            line.removeSubrange(a.lowerBound..<b.upperBound)
        }
        let ns = line as NSString
        for m in importRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            var p = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\\ ", with: " ")
            while let last = p.last, ".,;:)]}!?\"'".contains(last) { p.removeLast() }
            if p.isEmpty { continue }
            let resolved: String
            if p.hasPrefix("~/") { resolved = HOME + String(p.dropFirst(1)) }
            else if p.hasPrefix("/") { resolved = p }
            else { resolved = join(parentOf(path), p) }
            let std = (resolved as NSString).standardizingPath
            if isFile(std) && std != path { out.append(std) }
        }
    }
    return out
}

/// A CLAUDE.md-style file plus everything it @imports (max 4 hops, per the docs).
func withImports(_ path: String, scope: String, level: String, kind: String, load: Load, applies: String,
                 note: String? = nil, seen: inout Set<String>, depth: Int = 0) -> [[String: Any]] {
    if seen.contains(path) { return [] }
    seen.insert(path)
    let rec = fileRecord(path, scope: scope, level: level, kind: kind, load: load, applies: applies, note: note)
    var out = [rec]
    if depth < 4 {
        for imp in importsOf(path, rec["content"] as? String ?? "") {
            out += withImports(imp, scope: scope, level: level, kind: "import", load: load, applies: applies,
                               note: "Imported with @ by \(tilde(path)), so it loads together with it.",
                               seen: &seen, depth: depth + 1)
        }
    }
    return out
}

func rulesRecords(_ dir: String, scope: String, level: String, applies: String, forceOnDemand: Bool = false) -> [[String: Any]] {
    mdFiles(in: dir, recursive: true).map { p in
        let fmx = frontmatter(readText(p).0)
        let conditional = fmx["paths"] != nil
        return fileRecord(p, scope: scope, level: level, kind: "rule",
                          load: (conditional || forceOnDemand) ? .onDemand : .everyChat, applies: applies,
                          note: conditional ? "Has `paths:` frontmatter, so it loads only when Claude works with matching files (\(fmx["paths"]!))." : nil)
    }
}

func skillRecords(_ dir: String, scope: String, level: String, applies: String, nested: Bool = false) -> [[String: Any]] {
    guard isDir(dir) else { return [] }
    var out: [[String: Any]] = []
    for c in children(dir) where !c.hasPrefix(".") {
        let p = join(join(dir, c), "SKILL.md")
        guard isFile(p) else { continue }
        let fmx = frontmatter(readText(p).0)
        let desc = (fmx["name"] ?? c) + ": " + (fmx["description"] ?? "")
        var r = fileRecord(p, scope: scope, level: level, kind: "skill", load: nested ? .onDemand : .description,
                           applies: applies, note: nested ? "Skill in a subfolder: discovered when Claude works there." : "Only the name and description are in every chat; the full skill loads when it's used.",
                           perChatText: desc)
        r["name"] = fmx["name"] ?? c
        r["description"] = fmx["description"] ?? ""
        out.append(r)
    }
    return out
}

func agentRecords(_ dir: String, scope: String, level: String, applies: String) -> [[String: Any]] {
    mdFiles(in: dir, recursive: true).map { p in
        let fmx = frontmatter(readText(p).0)
        let name = fmx["name"] ?? (baseName(p) as NSString).deletingPathExtension
        var r = fileRecord(p, scope: scope, level: level, kind: "agent", load: .description, applies: applies,
                           note: "Subagent: its name and description are listed in every chat; its body is the subagent's own prompt, used only when it runs.",
                           perChatText: name + ": " + (fmx["description"] ?? ""))
        r["name"] = name
        r["description"] = fmx["description"] ?? ""
        return r
    }
}

func memoryRecords(_ memDir: String, scope: String, folder: String) -> [[String: Any]] {
    guard isDir(memDir) else { return [] }
    var out: [[String: Any]] = []
    let idx = join(memDir, "MEMORY.md")
    if isFile(idx) {
        let full = readText(idx).0
        var lines = Array(full.components(separatedBy: "\n").prefix(MEMORY_MAX_LINES)).joined(separator: "\n")
        if lines.utf8.count > MEMORY_MAX_BYTES { lines = String(decoding: Array(lines.utf8.prefix(MEMORY_MAX_BYTES)), as: UTF8.self) }
        out.append(fileRecord(idx, scope: scope, level: "memory", kind: "memory-index", load: .everyChat,
                              applies: "Sessions in \(tilde(folder)) (auto memory)",
                              note: "Auto memory index: the first \(MEMORY_MAX_LINES) lines or 25 KB load at the start of every session in this project.",
                              perChatText: lines))
    }
    for p in mdFiles(in: memDir, recursive: true) where p != idx {
        out.append(fileRecord(p, scope: scope, level: "memory", kind: "memory", load: .onDemand,
                              applies: "Sessions in \(tilde(folder)) (read when relevant)",
                              note: "Auto memory topic file: Claude reads it on demand."))
    }
    return out
}

// MARK: - Config (scan folders)

func defaultRoots() -> [String] {
    ["Developer", "code", "Code", "Projects", "projects", "src", "dev", "repos", "git", "workspace", "AndroidStudioProjects", "StudioProjects"]
        .map { join(HOME, $0) }.filter { isDir($0) }
}

func loadRoots() -> [String] {
    if let r = env["CCM_ROOTS"] { return r.split(separator: ":").map(String.init) }
    guard let d = fm.contents(atPath: CONFIG_FILE),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let roots = o["roots"] as? [String] else { return defaultRoots() }
    return roots
}

func saveRoots(_ roots: [String]) {
    try? fm.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
    if let d = try? JSONSerialization.data(withJSONObject: ["roots": roots], options: [.prettyPrinted]) {
        fm.createFile(atPath: CONFIG_FILE, contents: d)
    }
}

// MARK: - Scan

func hasClaudeFiles(_ p: String) -> Bool {
    if p == HOME { return isFile(join(p, "CLAUDE.md")) || isFile(join(p, "CLAUDE.local.md")) }
    return isFile(join(p, "CLAUDE.md")) || isFile(join(p, "CLAUDE.local.md")) || isDir(join(p, ".claude"))
}

/// Files that mark a folder as a code project even without git.
let PROJECT_MARKERS = ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts", "package.json",
                       "Package.swift", "pyproject.toml", "Cargo.toml", "go.mod", "pom.xml", "Gemfile", "pubspec.yaml"]

func looksLikeProject(_ p: String) -> Bool {
    fm.fileExists(atPath: join(p, ".git")) || hasClaudeFiles(p) || PROJECT_MARKERS.contains { isFile(join(p, $0)) }
        || children(p).contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
}

/// True when a folder holds projects (e.g. ~/Developer/AndroidStudioProjects) rather than being one.
func containsRepo(_ p: String, depth: Int) -> Bool {
    if depth == 0 { return false }
    for c in children(p) where !c.hasPrefix(".") && !SKIP_DIRS.contains(c) {
        let q = join(p, c)
        guard isDir(q), !isSymlink(q) else { continue }
        if looksLikeProject(q) { return true }
        if containsRepo(q, depth: depth - 1) { return true }
    }
    return false
}

func skipDir(_ name: String) -> Bool {
    name.hasPrefix(".") || SKIP_DIRS.contains(name) || SKIP_EXT.contains((name as NSString).pathExtension.lowercased())
}

final class Scanner {
    var scopes: [[String: Any]] = []
    var files: [[String: Any]] = []
    var scopeByPath: [String: String] = [:]

    func addScope(_ id: String, level: String, label: String, path: String?, parent: String?, applies: String, extra: [String: Any] = [:]) {
        var s: [String: Any] = ["id": id, "level": level, "label": label, "appliesTo": applies]
        if let p = path { s["path"] = p; s["display"] = tilde(p); scopeByPath[p] = id }
        if let par = parent { s["parent"] = par }
        for (k, v) in extra { s[k] = v }
        scopes.append(s)
    }

    /// Instruction files that live directly in a folder (project, subfolder or ancestor folder).
    func folderFiles(_ dir: String, scope: String, level: String, onDemand: Bool) {
        let applies = onDemand
            ? "When Claude reads or edits files inside \(tilde(dir)) (or a session starts there)"
            : "Sessions started in \(tilde(dir)) or any folder inside it"
        let load: Load = onDemand ? .onDemand : .everyChat
        var seen = Set<String>()
        for name in ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"] {
            if name.hasPrefix(".claude") && dir == HOME { continue }
            let p = join(dir, name)
            if isFile(p) {
                files += withImports(p, scope: scope, level: level, kind: name == "CLAUDE.local.md" ? "claude-local" : "claude-md",
                                     load: load, applies: applies,
                                     note: name == "CLAUDE.local.md" ? "Personal project notes (usually git-ignored), appended after CLAUDE.md." : nil,
                                     seen: &seen)
            }
        }
        if dir == HOME { return } // ~/.claude belongs to the user level
        let cd = join(dir, ".claude")
        files += rulesRecords(join(cd, "rules"), scope: scope, level: level, applies: applies, forceOnDemand: onDemand)
        for (n, label) in [("settings.json", "Shared project settings (committed to git)"), ("settings.local.json", "Personal project settings (not committed); override settings.json")] {
            let p = join(cd, n)
            if isFile(p) {
                files.append(fileRecord(p, scope: scope, level: level, kind: "settings", load: .notInContext,
                                        applies: "Sessions in \(tilde(dir))",
                                        note: label + ". Settings configure Claude Code (permissions, model, hooks…); they aren't sent to the model."))
            }
        }
        files += skillRecords(join(cd, "skills"), scope: scope, level: level, applies: applies, nested: onDemand)
        files += agentRecords(join(cd, "agents"), scope: scope, level: level, applies: applies)
    }

    func scanAccount() {
        let cat = join(CLAUDE_DIR, "catalog.md")
        var items: [[String: Any]] = []
        if isFile(cat) {
            let text = readText(cat).0
            var inSection = false
            var headers: [String] = []
            for l in text.components(separatedBy: "\n") {
                if l.hasPrefix("## ") {
                    inSection = l.range(of: "Account", options: .caseInsensitive) != nil && l.contains("1")
                    headers = []
                    continue
                }
                guard inSection, l.trimmingCharacters(in: .whitespaces).hasPrefix("|") else { continue }
                let cells = l.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                if headers.isEmpty { headers = cells; continue }
                var md = ""
                for (i, c) in cells.enumerated() { md += "**\(i < headers.count ? headers[i] : "")**: \(c)\n\n" }
                var title = cells.first ?? "Item"
                if let a = title.range(of: "**"), let b = title.range(of: "**", range: a.upperBound..<title.endIndex) {
                    title = String(title[a.upperBound..<b.lowerBound])
                }
                items.append(["id": "account:\(items.count)", "path": cat, "display": tilde(cat) + " → 1 · Account", "name": title,
                              "scope": "account", "level": "account", "kind": "account-item", "load": "account",
                              "appliesTo": "Every Claude app and device signed in to your account",
                              "content": md, "format": "md", "perChat": 0, "tokens": tokenEstimate(md), "words": wordCount(md),
                              "note": "Account items live on claude.ai, not on this Mac. This entry comes from the \"1 · Account\" section of ~/.claude/catalog.md.",
                              "modified": modified(cat) ?? ""])
            }
        }
        addScope("account", level: "account", label: "Account (claude.ai)", path: nil, parent: nil,
                 applies: "Every Claude app and device signed in to your account",
                 extra: ["note": isFile(cat)
                         ? "Skills, connectors and plugins managed on claude.ai. They aren't on disk; listed from the \"1 · Account\" section of ~/.claude/catalog.md."
                         : "Skills, connectors and plugins managed on claude.ai → Settings. They aren't on disk. (Optional: a ~/.claude/catalog.md with a \"1 · Account\" section shows them here.)"])
        files += items
    }

    func scanOrg() {
        addScope("org", level: "org", label: "Organization policy", path: MANAGED_DIR, parent: "account",
                 applies: "Every user and session on this Mac; can't be overridden")
        var seen = Set<String>()
        let p = join(MANAGED_DIR, "CLAUDE.md")
        if isFile(p) {
            files += withImports(p, scope: "org", level: "org", kind: "claude-md", load: .everyChat,
                                 applies: "Every session for every user on this Mac", note: "Managed policy, set by IT/admins. Loads first.", seen: &seen)
        }
        let ms = join(MANAGED_DIR, "managed-settings.json")
        if isFile(ms) {
            files.append(fileRecord(ms, scope: "org", level: "org", kind: "settings", load: .notInContext,
                                    applies: "Every session for every user on this Mac",
                                    note: "Managed settings have the highest priority and can't be overridden."))
        }
        for f in children(join(MANAGED_DIR, "managed-settings.d")) where f.hasSuffix(".json") {
            files.append(fileRecord(join(join(MANAGED_DIR, "managed-settings.d"), f), scope: "org", level: "org", kind: "settings",
                                    load: .notInContext, applies: "Every session for every user on this Mac", note: "Managed settings fragment (merged alphabetically)."))
        }
    }

    func scanMac() {
        addScope("mac", level: "mac", label: "This Mac (\(tilde(CLAUDE_DIR)))", path: CLAUDE_DIR, parent: "org",
                 applies: "Every Claude Code session on this Mac, in any folder")
        let applies = "Every Claude Code session on this Mac, in any folder"
        var seen = Set<String>()
        let cm = join(CLAUDE_DIR, "CLAUDE.md")
        if isFile(cm) {
            files += withImports(cm, scope: "mac", level: "mac", kind: "claude-md", load: .everyChat, applies: applies,
                                 note: "Your personal instructions for all projects.", seen: &seen)
        }
        files += rulesRecords(join(CLAUDE_DIR, "rules"), scope: "mac", level: "mac", applies: applies)
        let st = join(CLAUDE_DIR, "settings.json")
        if isFile(st) {
            files.append(fileRecord(st, scope: "mac", level: "mac", kind: "settings", load: .notInContext, applies: applies,
                                    note: "User settings: lowest priority; project and managed settings override them. Not sent to the model."))
        }
        files += skillRecords(join(CLAUDE_DIR, "skills"), scope: "mac", level: "mac", applies: applies)
        files += agentRecords(join(CLAUDE_DIR, "agents"), scope: "mac", level: "mac", applies: applies)
        for (n, note) in [("catalog.md", "Your list of customizations. Not loaded into chats; Claude reads it only when asked or when a rule says so."),
                          ("change-log.md", "Your log of changes. Not loaded into chats; Claude reads it only when asked or when a rule says so.")] {
            let p = join(CLAUDE_DIR, n)
            if isFile(p) {
                files.append(fileRecord(p, scope: "mac", level: "mac", kind: "notes", load: .notLoaded, applies: "Reference only", note: note))
            }
        }
    }

    func addProject(_ p: String, parent: String, root: String) -> String {
        let id = "p:" + p
        if scopeByPath[p] != nil { return scopeByPath[p]! }
        addScope(id, level: "project", label: baseName(p), path: p, parent: parent,
                 applies: "Sessions started in \(tilde(p)) or any folder inside it",
                 extra: ["root": root, "git": fm.fileExists(atPath: join(p, ".git"))])
        folderFiles(p, scope: id, level: "project", onDemand: false)
        return id
    }

    /// `group` is true for a scan folder and for grouping folders inside it: their direct
    /// subfolders count as projects even without git or Claude files.
    func walk(_ dir: String, depth: Int, root: String, parent: String, inProject: Bool, group: Bool = false) {
        for name in children(dir) where !skipDir(name) {
            let p = join(dir, name)
            guard isDir(p), !isSymlink(p) else { continue }
            let git = fm.fileExists(atPath: join(p, ".git"))
            let claude = hasClaudeFiles(p)
            var nextParent = parent
            var nowInProject = inProject
            var nextGroup = false
            if !inProject {
                let isGroup = !git && !claude && !looksLikeProject(p) && containsRepo(p, depth: 2)
                if git || claude || looksLikeProject(p) || (group && !isGroup) {
                    nextParent = addProject(p, parent: parent, root: root)
                    nowInProject = true
                } else if isGroup { nextGroup = true }
            } else if claude {
                let id = "s:" + p
                addScope(id, level: "subfolder", label: baseName(p), path: p, parent: parent,
                         applies: "When Claude works with files in \(tilde(p))", extra: ["root": root])
                folderFiles(p, scope: id, level: "subfolder", onDemand: true)
                nextParent = id
            }
            if depth < MAX_DEPTH { walk(p, depth: depth + 1, root: root, parent: nextParent, inProject: nowInProject, group: nextGroup) }
        }
    }

    func scanRoots(_ roots: [String]) {
        for root in roots {
            let r = (root as NSString).standardizingPath
            guard isDir(r) else { continue }
            // Folders above (and including) the root whose CLAUDE.md applies to everything below.
            var parent = "mac"
            let anc = ancestors(r)
            for a in anc where a != r || !(fm.fileExists(atPath: join(r, ".git"))) {
                if a == "/" && !hasClaudeFiles(a) { continue }
                guard hasClaudeFiles(a) else { continue }
                if let existing = scopeByPath[a] { parent = existing; continue }
                let id = "f:" + a
                addScope(id, level: "project", label: tilde(a) + "/", path: a, parent: parent,
                         applies: "Every session in \(tilde(a)) or any folder inside it", extra: ["folder": true, "root": r])
                folderFiles(a, scope: id, level: "project", onDemand: false)
                parent = id
            }
            if fm.fileExists(atPath: join(r, ".git")) {
                let id = addProject(r, parent: parent, root: r)
                walk(r, depth: 1, root: r, parent: id, inProject: true)
            } else {
                walk(r, depth: 1, root: r, parent: parent, inProject: false, group: true)
            }
        }
    }

    func scanMemory() {
        let projDir = join(CLAUDE_DIR, "projects")
        for name in children(projDir) {
            let mem = join(join(projDir, name), "memory")
            guard isDir(mem) else { continue }
            var scopeId: String? = nil
            var folder = ""
            for (p, id) in scopeByPath where encodeProjectPath(p) == name { scopeId = id; folder = p; break }
            if scopeId == nil {
                let real = decodeProjectName(name)
                folder = real ?? name
                let id = "m:" + name
                addScope(id, level: "project", label: real.map { baseName($0) } ?? "(folder no longer exists)",
                         path: real, parent: "mac",
                         applies: real.map { "Sessions started in \(tilde($0))" } ?? "A folder that no longer exists (\(name))",
                         extra: ["outside": true, "encoded": name, "missing": real == nil])
                scopeId = id
            }
            files += memoryRecords(mem, scope: scopeId!, folder: folder)
        }
    }

    func run(roots: [String]) -> [String: Any] {
        scanAccount(); scanOrg(); scanMac(); scanRoots(roots); scanMemory()
        return ["home": HOME, "claudeDir": CLAUDE_DIR, "managedDir": MANAGED_DIR, "roots": roots,
                "rootsDisplay": roots.map(tilde), "scannedAt": isoFormatter.string(from: Date()),
                "scopes": scopes, "files": files]
    }
}

// MARK: - "What applies here?" stack

func stackFor(_ folderIn: String) -> [String: Any] {
    let folder = (folderIn as NSString).standardizingPath
    let groot = gitRoot(folder)
    let projectRoot = groot ?? folder
    var every: [[String: Any]] = []
    var onDemand: [[String: Any]] = []
    var settings: [[String: Any]] = []
    var seen = Set<String>()
    func tag(_ recs: [[String: Any]], _ why: String) -> [[String: Any]] {
        recs.map { var r = $0; r["why"] = why; return r }
    }
    // 1. Managed policy
    let mc = join(MANAGED_DIR, "CLAUDE.md")
    if isFile(mc) { every += tag(withImports(mc, scope: "org", level: "org", kind: "claude-md", load: .everyChat, applies: "Everyone on this Mac", seen: &seen), "Organization policy (loads first)") }
    // 2. User
    let uc = join(CLAUDE_DIR, "CLAUDE.md")
    if isFile(uc) { every += tag(withImports(uc, scope: "mac", level: "mac", kind: "claude-md", load: .everyChat, applies: "All sessions on this Mac", seen: &seen), "Your instructions for every project") }
    for r in rulesRecords(join(CLAUDE_DIR, "rules"), scope: "mac", level: "mac", applies: "All sessions on this Mac") {
        if r["load"] as? String == Load.everyChat.rawValue { every.append(r.merging(["why": "Your rules (~/.claude/rules)"]) { $1 }) } else { onDemand.append(r) }
    }
    // 3. Every folder from / down to here
    for a in ancestors(folder) {
        let lvl = a == folder ? "project" : (a.count < projectRoot.count ? "folder" : "project")
        for name in ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"] {
            if name.hasPrefix(".claude") && a == HOME { continue }
            let p = join(a, name)
            if isFile(p) {
                every += tag(withImports(p, scope: a, level: lvl, kind: name == "CLAUDE.local.md" ? "claude-local" : "claude-md",
                                         load: .everyChat, applies: "Sessions in \(tilde(a)) and below", seen: &seen),
                             a == folder ? "This folder" : "Parent folder \(tilde(a))")
            }
        }
        if a != HOME && a.count >= projectRoot.count {
            for r in rulesRecords(join(a, ".claude/rules"), scope: a, level: lvl, applies: "Sessions in \(tilde(a))") {
                if r["load"] as? String == Load.everyChat.rawValue { every.append(r.merging(["why": "Project rules (\(tilde(a))/.claude/rules)"]) { $1 }) } else { onDemand.append(r) }
            }
        }
    }
    // 4. Auto memory
    let memDir = join(join(join(CLAUDE_DIR, "projects"), encodeProjectPath(projectRoot)), "memory")
    for r in memoryRecords(memDir, scope: "memory", folder: projectRoot) {
        if r["load"] as? String == Load.everyChat.rawValue { every.append(r.merging(["why": "Auto memory for \(tilde(projectRoot))"]) { $1 }) } else { onDemand.append(r) }
    }
    // 5. Skill and subagent descriptions
    var skillDirs = [(join(CLAUDE_DIR, "skills"), "mac", "Your skills")]
    var agentDirs = [(join(CLAUDE_DIR, "agents"), "mac", "Your subagents")]
    for a in ancestors(folder) where a.count >= projectRoot.count && a != HOME {
        skillDirs.append((join(a, ".claude/skills"), "project", "Project skills (\(tilde(a)))"))
        agentDirs.append((join(a, ".claude/agents"), "project", "Project subagents (\(tilde(a)))"))
    }
    for (d, lvl, why) in skillDirs { every += tag(skillRecords(d, scope: lvl, level: lvl, applies: "Here"), why) }
    for (d, lvl, why) in agentDirs { every += tag(agentRecords(d, scope: lvl, level: lvl, applies: "Here"), why) }
    // 6. On demand: CLAUDE.md files in subfolders
    func nested(_ dir: String, _ depth: Int) {
        guard depth <= 5 else { return }
        for c in children(dir) where !skipDir(c) {
            let p = join(dir, c)
            guard isDir(p), !isSymlink(p) else { continue }
            for name in ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"] where isFile(join(p, name)) {
                var r = fileRecord(join(p, name), scope: p, level: "subfolder", kind: "claude-md", load: .onDemand,
                                   applies: "When Claude works in \(tilde(p))")
                r["why"] = "Subfolder \(tilde(p)): loads when Claude reads or edits files there"
                onDemand.append(r)
            }
            for r in skillRecords(join(p, ".claude/skills"), scope: p, level: "subfolder", applies: "When Claude works in \(tilde(p))", nested: true) {
                onDemand.append(r)
            }
            nested(p, depth + 1)
        }
    }
    nested(folder, 1)
    // 7. Settings, lowest to highest priority
    func addSetting(_ p: String, _ lvl: String, _ why: String) {
        if isFile(p) { var r = fileRecord(p, scope: lvl, level: lvl, kind: "settings", load: .notInContext, applies: "Here"); r["why"] = why; settings.append(r) }
    }
    addSetting(join(CLAUDE_DIR, "settings.json"), "mac", "User settings (lowest priority)")
    if projectRoot != HOME {
        addSetting(join(projectRoot, ".claude/settings.json"), "project", "Shared project settings")
        addSetting(join(projectRoot, ".claude/settings.local.json"), "project", "Personal project settings")
        if folder != projectRoot && folder != HOME {
            addSetting(join(folder, ".claude/settings.json"), "project", "Shared settings in this folder")
            addSetting(join(folder, ".claude/settings.local.json"), "project", "Personal settings in this folder")
        }
    }
    addSetting(join(MANAGED_DIR, "managed-settings.json"), "org", "Managed settings (highest priority, can't be overridden)")
    let total = every.reduce(0) { $0 + (($1["perChat"] as? Int) ?? 0) }
    return ["folder": folder, "display": tilde(folder), "gitRoot": groot.map { $0 as Any } ?? NSNull(), "projectRoot": projectRoot,
            "everyChat": every, "onDemand": onDemand, "settings": settings, "totalPerChat": total]
}

// MARK: - Command line modes (for testing and generating README screenshots)

func printJSON(_ o: Any) {
    let d = try! JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(d)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

let args = CommandLine.arguments
func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
if args.contains("--dump-scan") { printJSON(Scanner().run(roots: loadRoots())); exit(0) }
if let p = argValue("--dump-stack") { printJSON(stackFor(p)); exit(0) }

// MARK: - App

var demoData: [String: Any]? = nil
if let p = argValue("--demo"), let d = fm.contents(atPath: p) { demoData = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
let snapshotPath = argValue("--snapshot")
let snapshotSetup = argValue("--setup") ?? "{}"

final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var web: WKWebView?

    func reply(_ id: Int, _ obj: Any) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]) else { return }
        web?.evaluateJavaScript("window.__reply(\(id), \(String(decoding: d, as: UTF8.self)))", completionHandler: nil)
    }

    func pickFolder(_ prompt: String, _ done: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.directoryURL = URL(fileURLWithPath: HOME)
        if let w = web?.window {
            panel.beginSheetModal(for: w) { r in done(r == .OK ? panel.url?.path : nil) }
        } else {
            done(panel.runModal() == .OK ? panel.url?.path : nil)
        }
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let b = message.body as? [String: Any], let id = (b["id"] as? NSNumber)?.intValue, let cmd = b["cmd"] as? String else { return }
        if let demo = demoData {
            switch cmd {
            case "scan": reply(id, demo["scan"] ?? [:])
            case "stack":
                let stacks = demo["stacks"] as? [String: Any] ?? [:]
                reply(id, stacks[b["path"] as? String ?? ""] ?? stacks.values.first ?? [:])
            default: reply(id, NSNull())
            }
            return
        }
        switch cmd {
        case "scan":
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Scanner().run(roots: loadRoots())
                DispatchQueue.main.async { self.reply(id, r) }
            }
        case "stack":
            let p = b["path"] as? String ?? HOME
            DispatchQueue.global(qos: .userInitiated).async {
                let r = stackFor(p)
                DispatchQueue.main.async { self.reply(id, r) }
            }
        case "addRoot":
            pickFolder("Add scan folder") { p in
                var roots = loadRoots()
                if let p = p, !roots.contains(p) { roots.append(p); saveRoots(roots) }
                self.reply(id, p != nil)
            }
        case "removeRoot":
            if let p = b["path"] as? String { saveRoots(loadRoots().filter { $0 != p }) }
            reply(id, true)
        case "pickFolder":
            pickFolder("Show what applies here") { p in self.reply(id, p ?? NSNull()) }
        case "reveal":
            if let p = b["path"] as? String, fm.fileExists(atPath: p) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            }
            reply(id, true)
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(b["text"] as? String ?? "", forType: .string)
            reply(id, true)
        default:
            reply(id, NSNull())
        }
    }

    // Open web links in the default browser; never navigate the app window away.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            if ["http", "https", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let out = snapshotPath else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            webView.evaluateJavaScript("window.__setup && window.__setup(\(snapshotSetup))") { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let cfg = WKSnapshotConfiguration()
                    webView.takeSnapshot(with: cfg) { img, err in
                        if let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: out))
                            print("wrote \(out)")
                        } else { print("snapshot failed: \(String(describing: err))") }
                        exit(0)
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let bridge = Bridge()

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(bridge, name: "bridge")
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = bridge
        bridge.web = web
        let w = Double(argValue("--width") ?? "") ?? 1440
        let h = Double(argValue("--height") ?? "") ?? 900
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Claude Config Map"
        window.contentView = web
        window.minSize = NSSize(width: 900, height: 600)
        if snapshotPath == nil { window.setFrameAutosaveName("MainWindow") }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let res = Bundle.main.resourceURL, fm.fileExists(atPath: res.appendingPathComponent("web/index.html").path) {
            let dir = res.appendingPathComponent("web")
            web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        } else {
            // Running the bare binary during development: look for ../Resources/web next to the sources.
            let dir = URL(fileURLWithPath: argValue("--web") ?? "Resources/web")
            web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Claude Config Map", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Claude Config Map", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Claude Config Map", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Find…", action: #selector(AppDelegate.find), keyEquivalent: "f")
        editItem.submenu = edit
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Refresh", action: #selector(AppDelegate.refresh), keyEquivalent: "r")
        viewItem.submenu = view
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.mainMenu = main
    }

    @objc func refresh() { bridge.web?.evaluateJavaScript("window.__refresh && window.__refresh()", completionHandler: nil) }
    @objc func find() { bridge.web?.evaluateJavaScript("window.__focusSearch && window.__focusSearch()", completionHandler: nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
