// Purpose: WorkspaceFileKind, what the workspace editor makes of a file: text (with the
//          highlight.js language to colour it in), an image or a PDF shown inline, or nothing
//          (the file keeps Quick Look and its default app).
// Dependencies: Foundation, UniformTypeIdentifiers, ImageIO (image check)
// Used by: Sources/App/Supporting/WorkspaceEditorStore.swift (open, read),
//          Sources/App/Views/WorkspaceEditorPane.swift (content per kind),
//          Tests/WorkspaceFileKindTests.swift
// Notes: Detection order (decided 2026-10-13, modelled on VS Code, which opens anything that is
//        text): 1. known file names (Dockerfile, Makefile, .gitignore, .env, ...), 2. known
//        extensions with a language, 3. plain-text extensions without one (txt, log, csv, ...),
//        4. PDF and images by type, 5. formats that are text but read better outside (rtf) and
//        binary families by type (audio, video, archives, fonts, executables) are refused,
//        6. anything else is sniffed: the first 8 KB must hold no NUL byte and decode as UTF-8.
//        A sniffed file with a shebang gets its interpreter's language. Language names are
//        highlight.js names from Highlightr's bundle (TOML maps to "ini", .env to "properties",
//        HTML, plist and SVG to "xml"); nil means plain text without colours. SVG opens as XML
//        text, like VS Code, not as an image. UTF-16 files contain NUL bytes and are refused.
//        Folders and packages never open. Size limits live in WorkspaceEditorStore.

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum WorkspaceFileKind: Equatable, Sendable {
    /// Text, coloured with the highlight.js language when there is one.
    case text(language: String?)
    case image
    case pdf

    var isText: Bool { if case .text = self { true } else { false } }

    var language: String? { if case .text(let language) = self { language } else { nil } }

    /// What the editor makes of the file, or nil when it stays with Quick Look and the default
    /// app. Reads the first 8 KB of files it cannot place by name or extension.
    static func detect(_ url: URL) -> WorkspaceFileKind? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        if let kind = detectByName(url) { return kind }
        let ext = url.pathExtension.lowercased()
        if refusedExtensions.contains(ext) { return nil }
        if let type = UTType(filenameExtension: ext), !ext.isEmpty {
            if type.conforms(to: .image) { return isReadableImage(url) ? .image : nil }
            if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) { return .text(language: nil) }
            if binaryFamilies.contains(where: { type.conforms(to: $0) }) { return nil }
        }
        return sniff(url)
    }

    /// The kind from the file's name and extension alone, without touching the disk; nil when
    /// that is not enough to decide.
    static func detectByName(_ url: URL) -> WorkspaceFileKind? {
        let name = url.lastPathComponent.lowercased()
        if let language = languageByFileName[name] { return .text(language: language) }
        if plainTextFileNames.contains(name) { return .text(language: nil) }
        if name.hasPrefix(".env.") { return .text(language: "properties") }
        if name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") { return .text(language: "dockerfile") }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if let language = languageByExtension[ext] { return .text(language: language) }
        if plainTextExtensions.contains(ext) { return .text(language: nil) }
        if ext == "pdf" { return .pdf }
        return nil
    }

    // MARK: - Tables

    /// highlight.js language per extension (lowercased).
    static let languageByExtension: [String: String] = {
        var map: [String: String] = [:]
        func add(_ language: String, _ extensions: String...) { extensions.forEach { map[$0] = language } }
        add("swift", "swift")
        add("python", "py", "pyw", "pyi")
        add("javascript", "js", "mjs", "cjs", "jsx")
        add("typescript", "ts", "tsx", "mts", "cts")
        add("json", "json", "jsonc", "json5", "geojson", "webmanifest", "ipynb", "resolved", "jsonl", "ndjson")
        add("yaml", "yaml", "yml")
        add("ini", "toml", "ini", "cfg", "conf", "cnf", "editorconfig", "gitconfig")
        add("properties", "properties", "env")
        add("xml", "xml", "plist", "xsd", "xsl", "xslt", "svg", "xib", "storyboard", "entitlements",
            "csproj", "rss", "atom", "xcscheme", "html", "htm", "xhtml", "vue", "kml", "gpx")
        add("css", "css")
        add("scss", "scss")
        add("less", "less")
        add("bash", "sh", "bash", "zsh", "ksh", "fish", "command")
        add("powershell", "ps1", "psm1", "psd1")
        add("dos", "bat", "cmd")
        add("sql", "sql")
        add("pgsql", "pgsql", "psql")
        add("markdown", "md", "markdown", "mdown", "mkd", "mdx")
        add("c", "c", "h")
        add("cpp", "cpp", "cc", "cxx", "hpp", "hh", "hxx", "ino", "metal")
        add("objectivec", "m", "mm")
        add("csharp", "cs")
        add("java", "java")
        add("kotlin", "kt", "kts")
        add("go", "go")
        add("rust", "rs")
        add("ruby", "rb", "rake", "gemspec", "podspec")
        add("php", "php")
        add("perl", "pl", "pm")
        add("lua", "lua")
        add("r", "r")
        add("dart", "dart")
        add("scala", "scala", "sc")
        add("groovy", "groovy")
        add("gradle", "gradle")
        add("haskell", "hs")
        add("elixir", "ex", "exs")
        add("erlang", "erl", "hrl")
        add("clojure", "clj", "cljs", "cljc", "edn")
        add("latex", "tex", "sty", "cls")
        add("diff", "diff", "patch")
        add("graphql", "graphql", "gql")
        add("protobuf", "proto")
        add("cmake", "cmake")
        add("makefile", "mk", "mak")
        add("dockerfile", "dockerfile")
        add("vim", "vim")
        add("http", "http")
        add("nix", "nix")
        add("julia", "jl")
        add("vbnet", "vb")
        add("fsharp", "fs", "fsx")
        add("ocaml", "ml", "mli")
        add("lisp", "lisp", "el")
        add("scheme", "scm", "ss")
        add("tcl", "tcl")
        add("verilog", "v", "sv")
        add("vhdl", "vhd", "vhdl")
        add("awk", "awk")
        add("crystal", "cr")
        add("elm", "elm")
        add("coffeescript", "coffee")
        add("handlebars", "hbs", "handlebars")
        add("twig", "twig")
        add("erb", "erb")
        add("haml", "haml")
        add("asciidoc", "adoc", "asciidoc")
        add("glsl", "glsl", "vert", "frag")
        add("applescript", "applescript")
        add("nginx", "nginxconf")
        return map
    }()

    /// Text without a highlight.js language: shown plain.
    static let plainTextExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "out", "err", "srt", "vtt", "ics", "vcf", "rst", "org",
        "lock", "gitignore", "gitattributes", "dockerignore", "npmignore", "keep", "gitkeep",
        "sass", "tf", "hcl", "zig", "eml", "nfo", "pem", "crt", "pub", "license",
    ]

    /// highlight.js language for well-known file names (lowercased, the whole name).
    static let languageByFileName: [String: String] = [
        "dockerfile": "dockerfile", "containerfile": "dockerfile",
        "makefile": "makefile", "gnumakefile": "makefile",
        "cmakelists.txt": "cmake",
        ".env": "properties",
        ".bashrc": "bash", ".bash_profile": "bash", ".zshrc": "bash", ".zprofile": "bash",
        ".zshenv": "bash", ".profile": "bash",
        ".gitconfig": "ini", ".gitmodules": "ini", ".editorconfig": "ini", ".npmrc": "ini",
        ".prettierrc": "json", ".eslintrc": "json", ".babelrc": "json",
        "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby", "fastfile": "ruby",
        "brewfile": "ruby", "vagrantfile": "ruby", "appfile": "ruby",
        "jenkinsfile": "groovy",
        "package.resolved": "json",
        "nginx.conf": "nginx",
    ]

    /// Well-known names that are plain text.
    static let plainTextFileNames: Set<String> = [
        ".gitignore", ".gitattributes", ".dockerignore", ".npmignore", ".gitkeep", ".keep",
        "license", "licence", "readme", "changelog", "authors", "contributors", "codeowners",
        "notice", "procfile", "todo",
    ]

    /// Text formats that read far better in Quick Look or their app than as source.
    static let refusedExtensions: Set<String> = ["rtf", "rtfd", "webarchive", "scpt", "scptd"]

    /// Type families that are never text, so they skip the sniff.
    private static let binaryFamilies: [UTType] = [
        .audiovisualContent, .archive, .executable, .font, .diskImage, .database,
        .spreadsheet, .presentation, .package, .bundle,
    ]

    // MARK: - Disk checks

    /// The image is one ImageIO can decode (NSImage uses the same decoders).
    private static func isReadableImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    static let sniffBytes = 8192

    /// Text when the first 8 KB hold no NUL byte and decode as UTF-8 (a character cut at the
    /// 8 KB boundary is forgiven). A shebang names the language.
    static func sniff(_ url: URL) -> WorkspaceFileKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: sniffBytes) else { return nil }
        guard !data.isEmpty else { return .text(language: nil) }
        guard !data.contains(0) else { return nil }
        var head: String?
        for cut in 0...3 where data.count > cut {
            head = String(data: data.dropLast(cut), encoding: .utf8)
            if head != nil || data.count < sniffBytes { break }
        }
        guard let head else { return nil }
        return .text(language: shebangLanguage(head))
    }

    /// The language a "#!" first line names, e.g. "#!/usr/bin/env python3".
    static func shebangLanguage(_ text: String) -> String? {
        guard text.hasPrefix("#!") else { return nil }
        let line = text.prefix { $0 != "\n" }.lowercased()
        let interpreters: [(String, String)] = [
            ("python", "python"), ("node", "javascript"), ("deno", "typescript"), ("ruby", "ruby"),
            ("perl", "perl"), ("php", "php"), ("swift", "swift"), ("pwsh", "powershell"),
            ("osascript", "applescript"), ("zsh", "bash"), ("bash", "bash"), ("/sh", "bash"),
            (" sh", "bash"),
        ]
        return interpreters.first { line.contains($0.0) }?.1
    }
}
