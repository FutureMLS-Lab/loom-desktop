import Foundation

/// Reads a bundled text asset — the web pages the app hosts, and the
/// JavaScript they load.
///
/// Three places to look, because the app runs two ways. Installed, the files
/// sit in the `.app`'s Resources. Run as a bare binary out of a checkout there
/// is no bundle at all, so the last candidate walks back to the package's own
/// `Resources/` — which is what keeps `swift run` working without an install
/// step. `Package.swift` declares no resources, so nothing here is generated.
enum LoomResource {
    static func text(_ name: String, _ ext: String) -> String? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: ext),
            Bundle.main.resourceURL?.appendingPathComponent("\(name).\(ext)"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // Sources/LoomDesktop
                .deletingLastPathComponent()   // Sources
                .deletingLastPathComponent()   // package root
                .appendingPathComponent("Resources/\(name).\(ext)"),
        ]
        for case let url? in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
