import Foundation

/// Started with `-LoomServerURL <address>`, the app points its current server
/// at that address and keeps the server's token; `-LoomServerName <name>`
/// renames it as well. For a gateway that moved, set from the Mac:
///
///   xcrun devicectl device process launch --device <phone> --terminate-existing \
///     engineering.loom.ios -- -LoomServerURL https://… -LoomServerName …
///
/// Written through the app's own settings, which is the only way the change
/// holds: the preferences file swapped from outside is read past, since the
/// system keeps serving the copy it already has. Only Xcode or a paired Mac
/// can pass launch arguments, so a link cannot send the token elsewhere.
enum LaunchServerAddress {
    static func applyIfGiven() {
        let arguments = ProcessInfo.processInfo.arguments
        guard var address = value(after: "-LoomServerURL", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            address.hasPrefix("https://") || address.hasPrefix("http://")
        else { return }
        while address.hasSuffix("/") { address.removeLast() }
        var servers = LoomSettings.servers
        guard let index = servers.firstIndex(where: { $0.id == LoomSettings.activeServerID })
            ?? servers.indices.first
        else { return }
        servers[index].baseURL = address
        if let name = value(after: "-LoomServerName", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            servers[index].name = name
        }
        LoomSettings.servers = servers
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
