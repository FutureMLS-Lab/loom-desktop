import Foundation

/// Reads a bundled asset — the web pages the app hosts, and the scripts,
/// stylesheet and fonts they load.
///
/// Three places to look, because the app runs two ways. Installed, the files
/// sit in the `.app`'s Resources. Run as a bare binary out of a checkout there
/// is no bundle at all, so the last candidate walks back to the package's own
/// `Resources/` — which is what keeps `swift run` working without an install
/// step. `Package.swift` declares no resources, so nothing here is generated.
enum LoomResource {
    static func text(_ name: String, _ ext: String) -> String? {
        for case let url? in candidates(name, ext) {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// The same lookup as bytes, for a file handed to a page as it is.
    static func data(_ name: String, _ ext: String) -> Data? {
        for case let url? in candidates(name, ext) {
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    /// What the markdown page may fetch as `loom-asset://bundle/<path>`, with
    /// its type: the diagram renderer, and KaTeX with its fonts, each loaded
    /// only once a document needs it. Any other path is refused, so a
    /// document cannot read the rest of the bundle through the scheme.
    static func pageAsset(_ path: String) -> (data: Data, type: String)? {
        guard let type = pageAssetType(path) else { return nil }
        let file = path as NSString
        return data(file.deletingPathExtension, file.pathExtension).map { ($0, type) }
    }

    static func pageAssetResponse(_ url: URL, _ asset: (data: Data, type: String)) -> URLResponse {
        URLResponse(
            url: url, mimeType: asset.type, expectedContentLength: asset.data.count,
            textEncodingName: asset.type.hasPrefix("text/") ? "utf-8" : nil
        )
    }

    private static func pageAssetType(_ path: String) -> String? {
        switch path {
        case "mermaid.min.js", "katex/katex.min.js", "katex/copy-tex.min.js":
            return "text/javascript"
        case "katex/katex.min.css":
            return "text/css"
        default:
            let prefix = "katex/fonts/KaTeX_", suffix = ".woff2"
            guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
            let name = path.dropFirst(prefix.count).dropLast(suffix.count)
            let plain = !name.isEmpty
                && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            return plain ? "font/woff2" : nil
        }
    }

    private static func candidates(_ name: String, _ ext: String) -> [URL?] {
        [
            Bundle.main.url(forResource: name, withExtension: ext),
            Bundle.main.resourceURL?.appendingPathComponent("\(name).\(ext)"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // Sources/LoomDesktop
                .deletingLastPathComponent()   // Sources
                .deletingLastPathComponent()   // package root
                .appendingPathComponent("Resources/\(name).\(ext)"),
        ]
    }
}
