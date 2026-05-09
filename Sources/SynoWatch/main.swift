import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Top-level code in main.swift always runs on the main thread.
// MainActor.assumeIsolated communicates this to the Swift 6 concurrency system.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
