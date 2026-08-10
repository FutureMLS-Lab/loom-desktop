#!/usr/bin/env swift
// Summon the running Loom Desktop to the current screen (panel + main
// window), without going through LaunchServices. Safe to run anytime:
//   swift scripts/summon.swift            → panel + main window
//   swift scripts/summon.swift panel      → just the panel
import Foundation

let name = CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "panel"
    ? "com.loom.desktop.show-panel"
    : "com.loom.desktop.summon"
DistributedNotificationCenter.default().postNotificationName(
    .init(name), object: nil, userInfo: nil, deliverImmediately: true
)
print("sent \(name)")
