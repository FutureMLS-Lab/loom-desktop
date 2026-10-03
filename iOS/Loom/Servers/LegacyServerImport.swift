import CryptoKit
import Foundation

/// Brings over the servers the React Native app kept.
///
/// This app ships under the same bundle identifier, so installing it over
/// the old one keeps the app's container — and with it AsyncStorage's files:
/// `Application Support/<bundle id>/RCTAsyncLocalStorage_V1/manifest.json`,
/// holding values up to 1 KB inline and larger ones in a file named after the
/// MD5 of their key. Read once, on the first launch with no list of our own.
enum LegacyServerImport {
    private static let doneKey = "loom.ios.legacyImportDone"
    private static let serversKey = "loom-app:servers"
    private static let activeKey = "loom-app:active-server"
    private static let gatewayKey = "loom-app:gateway-url"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard defaults.data(forKey: LoomSettings.serversKey) == nil,
              let storage = storageDirectory(),
              let manifestData = try? Data(contentsOf: storage.appendingPathComponent("manifest.json")),
              let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any]
        else { return }

        func value(_ key: String) -> String? {
            if let inline = manifest[key] as? String { return inline }
            guard manifest.keys.contains(key) else { return nil }
            let file = storage.appendingPathComponent(md5(key))
            return try? String(contentsOf: file, encoding: .utf8)
        }

        var servers: [LoomServer] = []
        if let raw = value(serversKey),
           let list = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]] {
            for entry in list {
                let url = normalized((entry["url"] as? String) ?? "")
                guard url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
                servers.append(LoomServer(
                    id: (entry["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
                    name: (entry["name"] as? String) ?? "",
                    baseURL: url,
                    token: (entry["token"] as? String) ?? ""
                ))
            }
        }
        if servers.isEmpty, let legacy = value(gatewayKey).map(normalized),
           legacy.hasPrefix("http://") || legacy.hasPrefix("https://") {
            servers = [LoomServer(name: "", baseURL: legacy, token: "")]
        }
        guard !servers.isEmpty else { return }

        LoomSettings.servers = servers
        let active = value(activeKey)
        LoomSettings.activeServerID = servers.contains { $0.id == active } ? active! : servers[0].id
    }

    private static func storageDirectory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let bundle = Bundle.main.bundleIdentifier
        else { return nil }
        let directory = support
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("RCTAsyncLocalStorage_V1", isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    private static func normalized(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func md5(_ key: String) -> String {
        Insecure.MD5.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
