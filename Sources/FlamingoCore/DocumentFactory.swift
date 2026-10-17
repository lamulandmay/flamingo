import Foundation
import Darwin
import UniformTypeIdentifiers

/// Creates real documents, never empty files wearing a binary format's extension.
public enum DocumentFactory {
    public struct Format: Equatable, Sendable {
        /// How a blank one comes to exist.
        public enum Source: Equatable, Sendable {
            /// Flamingo writes these bytes: the smallest valid file of the format.
            case text(String)
            /// A blank saved by the format's own app, shipped as `Templates/Blank.<ext>`.
            case template
            /// Only the app (a bundle identifier, or its prefix for versioned ones) can start
            /// one, in its own window. Flamingo opens the app.
            case app(String)
        }
        public let ext: String
        public let title: String
        public let source: Source
        /// Opens in Flamingo's editor; everything else opens in its own app.
        public let isText: Bool
        /// What people type for it besides the extension and the title.
        public let keywords: [String]

        public init(_ ext: String, _ title: String, isText: Bool = false) {
            self.init(ext, title, isText ? .text("") : .template, isText: isText)
        }

        public init(_ ext: String, _ title: String, _ source: Source, isText: Bool = false, _ keywords: String = "") {
            self.ext = ext; self.title = title; self.source = source; self.isText = isText
            self.keywords = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        /// False when only the app itself can make one.
        public var isFile: Bool { if case .app = source { false } else { true } }
    }

    /// Most used first: the order of an empty search, and the tiebreak of any other.
    public static let formats: [Format] = [
        Format("md", "Markdown note", .text(""), isText: true, "note, notes, markdown, text, writing, journal"),
        Format("docx", "Word document", .template, "word, doc, document, writing, letter, report, essay, paper"),
        Format("pptx", "PowerPoint presentation", .template, "ppt, powerpoint, slides, slide, deck, presentation, talk, pitch"),
        Format("xlsx", "Excel workbook", .template, "excel, xls, sheet, spreadsheet, table, workbook, budget, data"),
        Format("key", "Keynote presentation", .template, "keynote, ppt, powerpoint, slides, slide, deck, presentation, talk, pitch"),
        Format("pages", "Pages document", .template, "pages, word, doc, document, writing, letter, report, essay, paper"),
        Format("numbers", "Numbers spreadsheet", .template, "numbers, excel, xls, sheet, spreadsheet, table, budget, data"),
        Format("txt", "Plain text", .text(""), isText: true, "text, plain, note"),
        Format("csv", "CSV table", .text(""), isText: true, "table, data, sheet, spreadsheet, excel, comma"),
        Format("shapr", "Shapr3D design", .app("com.shapr3d.shapr"), "3d, cad, model, design, part, sketch, shapr3d, print"),
        Format("blend", "Blender scene", .app("org.blenderfoundation.blender"), "3d, model, mesh, scene, render, animation, blender"),
        Format("stl", "STL mesh", .text("solid untitled\nendsolid untitled\n"), "3d, mesh, model, print, printing, cad"),
        Format("obj", "Wavefront OBJ model", .text("# Wavefront OBJ\n"), "3d, mesh, model, wavefront"),
        Format("ply", "PLY mesh", .text("ply\nformat ascii 1.0\nelement vertex 0\nproperty float x\nproperty float y\nproperty float z\nelement face 0\nproperty list uchar int vertex_indices\nend_header\n"),
               "3d, mesh, model, point cloud, scan"),
        Format("gltf", "glTF scene", .text("{\n  \"asset\": { \"version\": \"2.0\" },\n  \"scene\": 0,\n  \"scenes\": [{ \"nodes\": [] }]\n}\n"), "3d, model, scene, web"),
        Format("usda", "USD scene", .text("#usda 1.0\n"), "3d, model, scene, usd, ar, reality"),
        Format("svg", "SVG drawing", .text("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"600\" viewBox=\"0 0 800 600\">\n</svg>\n"),
               "vector, drawing, graphic, image, icon, illustration, design"),
        Format("psd", "Photoshop image", .app("com.adobe.Photoshop"), "photoshop, image, photo, design, graphic"),
        Format("ai", "Illustrator artwork", .app("com.adobe.illustrator"), "illustrator, vector, drawing, graphic, design, logo"),
        Format("sketch", "Sketch design", .app("com.bohemiancoding.sketch3"), "sketch, design, ui, mockup"),
        Format("indd", "InDesign document", .app("com.adobe.InDesign"), "indesign, layout, print, magazine, poster, brochure, design"),
        Format("xmind", "Xmind mind map", .app("net.xmind.vana.app"), "mind map, mindmap, brainstorm, map, outline, xmind"),
        Format("band", "GarageBand project", .app("com.apple.garageband10"), "music, song, audio, beat, record, garageband"),
        Format("logicx", "Logic Pro project", .app("com.apple.logic10"), "music, song, audio, beat, record, logic"),
        Format("sesx", "Audition session", .app("com.adobe.Audition"), "audio, podcast, sound, mix, record, audition"),
        Format("prproj", "Premiere Pro project", .app("com.adobe.PremierePro"), "video, film, movie, edit, premiere"),
        Format("dna", "SnapGene DNA file", .app("com.gslbiotech.snapgene"), "dna, plasmid, sequence, cloning, gene, primer, snapgene"),
        Format("rtf", "Rich text", .text("{\\rtf1\\ansi\n}\n"), "text, rich, textedit, document"),
        Format("html", "HTML page", .text("<!doctype html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title></title>\n</head>\n<body>\n\n</body>\n</html>\n"), isText: true,
               "web, page, website, html"),
        Format("tex", "LaTeX document", .text("\\documentclass{article}\n\\begin{document}\n\n\\end{document}\n"), isText: true, "latex, paper, math"),
        Format("ipynb", "Jupyter notebook", .text("{\n \"cells\": [],\n \"metadata\": {},\n \"nbformat\": 4,\n \"nbformat_minor\": 5\n}\n"),
               "notebook, jupyter, python, data"),
        Format("py", "Python script", .text(""), isText: true, "python, script, code"),
        Format("swift", "Swift source", .text(""), isText: true, "swift, code"),
        Format("js", "JavaScript", .text(""), isText: true, "javascript, script, code, web"),
        Format("ts", "TypeScript", .text(""), isText: true, "typescript, code, web"),
        Format("css", "Stylesheet", .text(""), isText: true, "css, style, web"),
        Format("json", "JSON", .text("{}\n"), isText: true, "data, config"),
        Format("yaml", "YAML", .text(""), isText: true, "yml, data, config"),
        Format("sh", "Shell script", .text("#!/bin/sh\n"), isText: true, "shell, bash, zsh, script"),
        Format("ino", "Arduino sketch", .text("void setup() {\n}\n\nvoid loop() {\n}\n"), "arduino, microcontroller, code"),
    ]

    private static func normalized(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    public static func resolve(_ input: String) -> Format? {
        let raw = normalized(input)
        let aliases: [String: String] = ["powerpoint": "pptx", "ppt": "pptx", "presentation": "pptx",
            "slides": "pptx", "word": "docx", "doc": "docx", "document": "docx", "excel": "xlsx",
            "xls": "xlsx", "spreadsheet": "xlsx", "workbook": "xlsx", "markdown": "md",
            "note": "md", "text": "txt", "plain text": "txt", "python": "py", "latex": "tex", "yml": "yaml"]
        let ext = aliases[raw] ?? raw
        if let format = formats.first(where: { $0.ext == ext }) { return format }
        let textTypes: Set<String> = ["tsx", "jsx", "scss", "toml", "xml", "c", "h", "cpp", "rs", "go", "rb", "sql", "r", "tsv"]
        return textTypes.contains(ext) ? Format(ext, ext.uppercased() + " source", .text(""), isText: true) : nil
    }

    /// The kinds a query names, best first. The extension itself wins, then a word for it
    /// ("3d", "ppt", "excel"), then any word that starts with it. When nothing is named
    /// outright, a plain extension still gets an empty file of its own.
    public static func search(_ query: String) -> [Format] {
        let q = normalized(query)
        guard !q.isEmpty else { return formats }
        let ranked = formats.enumerated().compactMap { i, f in rank(f, q).map { ($0, i, f) } }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        var found = ranked.map { $0.2 }
        if !ranked.contains(where: { $0.0 <= 1 }), let typed = resolve(q) ?? blank(ext: q) {
            found.removeAll { $0.ext == typed.ext }
            found.insert(typed, at: 0)
        }
        return found
    }

    private static func rank(_ f: Format, _ q: String) -> Int? {
        if f.ext == q { return 0 }
        if f.keywords.contains(q) { return 1 }
        if f.ext.hasPrefix(q) { return 2 }
        let words = f.title.lowercased().split(separator: " ").map(String.init) + f.keywords
        if words.contains(where: { $0.hasPrefix(q) }) { return 3 }
        let tokens = q.split(separator: " ")
        if tokens.count > 1, tokens.allSatisfy({ t in words.contains { $0.hasPrefix(t) } }) { return 3 }
        return nil
    }

    /// An extension Flamingo has no entry for, when an empty file is still a valid one:
    /// text formats, and ones no app on this Mac has declared.
    public static func blank(ext: String) -> Format? {
        let ext = normalized(ext)
        guard (1...16).contains(ext.utf8.count), ext.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
              ext.utf8.contains(where: { (97...122).contains($0) }) else { return nil }
        if let type = UTType(filenameExtension: ext), !type.isDynamic, !type.conforms(to: .text) { return nil }
        return Format(ext, "Empty file", .text(""), isText: true)
    }

    public static func filename(_ name: String, format: Format) throws -> String {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !format.ext.isEmpty, format.ext.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
              !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), !name.hasPrefix("~$"),
              !name.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" }),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DocumentError.invalidName
        }
        if (name as NSString).pathExtension.lowercased() == format.ext {
            name = (name as NSString).deletingPathExtension
        }
        let filename = name + "." + format.ext
        guard !name.isEmpty, filename.utf8.count <= 255 else { throw DocumentError.invalidName }
        return filename
    }

    @discardableResult
    public static func create(type: String, name: String, in directory: URL) throws -> URL {
        guard let format = resolve(type) else { throw DocumentError.unsupportedType(type) }
        return try create(format, name: name, in: directory)
    }

    @discardableResult
    public static func create(_ format: Format, name: String, in directory: URL) throws -> URL {
        let destination = directory.appendingPathComponent(try filename(name, format: format))
        let data: Data
        switch format.source {
        case .text(let text):
            data = Data(text.utf8)
        case .template:
            guard let template = templateURL(for: format.ext) else {
                throw DocumentError.missingTemplate(format.ext)
            }
            data = try Data(contentsOf: template)
        case .app:
            throw DocumentError.unsupportedType(format.ext)
        }
        // Stage completely before publishing, with an exclusive rename. Competing creators
        // and existing symlinks can never be overwritten, and a crash cannot leave a partial document.
        let parent = try DocumentFileIO.openDirectory(directory)
        defer { close(parent) }
        let temporary = try DocumentFileIO.temporary(in: parent, path: destination.path, mode: 0o666)
        defer { close(temporary.fd); unlinkat(parent, temporary.name, 0) }
        try DocumentFileIO.write(data, to: temporary.fd, path: destination.path)
        guard fsync(temporary.fd) == 0 else { throw DocumentFileIO.error(path: destination.path) }
        guard renameatx_np(parent, temporary.name, parent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw DocumentFileIO.error(path: destination.path)
        }
        _ = fsync(parent)
        return destination
    }

    /// Mirrors SwiftPM's supported bundle locations without its fatalError when an installation
    /// is missing the resource bundle. The caller can surface a recoverable missing-template error.
    static func templateURL(for ext: String, roots: [URL]? = nil) -> URL? {
        var candidates = roots ?? [Bundle.main.resourceURL, Bundle(for: ResourceMarker.self).resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        #if DEBUG
        if roots == nil, let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            candidates.insert(URL(fileURLWithPath: override), at: 0)
        }
        #endif
        for root in candidates {
            guard let bundle = Bundle(url: root.appendingPathComponent("Flamingo_FlamingoCore.bundle")),
                  let template = bundle.url(forResource: "Blank", withExtension: ext, subdirectory: "Templates") else { continue }
            return template
        }
        return nil
    }

    private final class ResourceMarker: NSObject {}
}

public enum DocumentError: LocalizedError {
    case invalidName, exists(String), unsupportedType(String), missingTemplate(String), changedOnDisk, unsupportedText, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Choose a name without slashes, colons, control characters, or an Office ~$ prefix."
        case .exists(let name): "“\(name)” is already in this folder."
        case .unsupportedType(let type): "No document template for ‘\(type)’. Choose a supported format below."
        case .missingTemplate(let ext): "The \(ext) template is missing from this installation."
        case .changedOnDisk: "This file changed in another app. Your draft is safe. Save a copy or reload the disk version."
        case .unsupportedText: "This file is not editable UTF-8 text. Open it in its native editor."
        case .tooLarge: "This file is too large for the built-in editor. Open it in its native editor."
        }
    }
}
