// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: swift scripts/render-app-icon.swift OUTPUT.png\n".utf8))
    exit(2)
}

func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let intermediate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
defer { try? FileManager.default.removeItem(at: intermediate) }
try run(["rsvg-convert", "-w", "1536", "-h", "1536", "-o", intermediate.path,
         root.appendingPathComponent("Assets/AppIcon.svg").path])
try run(["magick", intermediate.path, "-filter", "Lanczos", "-resize", "1024x1024",
         "-depth", "8", "PNG32:" + CommandLine.arguments[1]])
