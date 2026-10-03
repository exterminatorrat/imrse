import Foundation

guard CommandLine.arguments.count == 2 else {
    throw NSError(domain: "imrse.icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Supply an iconset output directory"])
}

let fileManager = FileManager.default
let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let sourceDirectory = scriptDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconNames = [
    "icon_16x16.png",
    "icon_16x16@2x.png",
    "icon_32x32.png",
    "icon_32x32@2x.png",
    "icon_128x128.png",
    "icon_128x128@2x.png",
    "icon_256x256.png",
    "icon_256x256@2x.png",
    "icon_512x512.png",
    "icon_512x512@2x.png"
]

for name in iconNames {
    guard fileManager.fileExists(atPath: sourceDirectory.appendingPathComponent(name).path) else {
        throw NSError(domain: "imrse.icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing supplied icon export: \(name)"])
    }
}

if fileManager.fileExists(atPath: outputDirectory.path) {
    try fileManager.removeItem(at: outputDirectory)
}
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for name in iconNames {
    try fileManager.copyItem(
        at: sourceDirectory.appendingPathComponent(name),
        to: outputDirectory.appendingPathComponent(name)
    )
}
