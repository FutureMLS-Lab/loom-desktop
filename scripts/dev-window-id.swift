#!/usr/bin/env swift
// Print the CGWindowID of the dev copy's largest on-screen window, for
// `screencapture -l`. The offscreen snapshot (LOOM_DESKTOP_SNAPSHOT_DIR)
// renders the content view only — no title bar, no toolbar — and paints web
// views over anything SwiftUI drew above them, so a check of the toolbar or
// of a bar floating over the plan needs the real screen.
//
// Matched by owner name, exactly: a prefix match once picked up the installed
// app's window and photographed someone's live tasks.
//
//   swift scripts/dev-window-id.swift            # the dev bundle
//   swift scripts/dev-window-id.swift "Loom Desktop"   # another owner name
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Loom Desktop Dev"
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
var best: (id: Int, area: Double)?
for info in list {
    guard (info[kCGWindowOwnerName as String] as? String) == owner,
          let id = info[kCGWindowNumber as String] as? Int,
          let bounds = info[kCGWindowBounds as String] as? [String: Double]
    else { continue }
    let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    if best == nil || area > best!.area { best = (id, area) }
}
if let best { print(best.id) } else { exit(2) }
