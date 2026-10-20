import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func drawIcon(size: Int, mac: Bool) throws -> String {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let inset: CGFloat = mac ? 68 : 0
    let square = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let mask = NSBezierPath(roundedRect: square, xRadius: mac ? 195 : 0, yRadius: mac ? 195 : 0)
    mask.addClip()
    NSGraphicsContext.current?.imageInterpolation = .high
    let masterURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("design/icon-concepts/layer-stack.png")
    guard let master = NSImage(contentsOf: masterURL) else { fatalError("Missing selected icon artwork") }
    master.draw(in: square, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let filename = "icon-\(mac ? "mac" : "ios")-\(size).png"
    var output = bitmap
    if !mac {
        // App Store iOS icons must have no alpha channel, including an opaque one.
        let rgb = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<size {
            for x in 0..<size {
                for channel in 0..<3 {
                    rgb.bitmapData![y * rgb.bytesPerRow + x * 3 + channel] = bitmap.bitmapData![y * bitmap.bytesPerRow + x * 4 + channel]
                }
            }
        }
        output = rgb
    }
    try output.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(filename))
    return filename
}

var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = try drawIcon(size: points * scale, mac: true)
        entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}
var iosSizes: [Int: String] = [:]
func iosFile(_ size: Int) throws -> String {
    if let file = iosSizes[size] { return file }
    let file = try drawIcon(size: size, mac: false); iosSizes[size] = file; return file
}
for (idiom, points, scales) in [("iphone", 20.0, [2, 3]), ("iphone", 29.0, [2, 3]),
                                ("iphone", 40.0, [2, 3]), ("iphone", 60.0, [2, 3]),
                                ("ipad", 20.0, [1, 2]), ("ipad", 29.0, [1, 2]),
                                ("ipad", 40.0, [1, 2]), ("ipad", 76.0, [1, 2]), ("ipad", 83.5, [2])] {
    let label = points == floor(points) ? String(Int(points)) : String(points)
    for scale in scales {
        entries.append(["idiom": idiom, "size": "\(label)x\(label)", "scale": "\(scale)x",
                        "filename": try iosFile(Int(points * Double(scale)))])
    }
}
entries.append(["idiom": "ios-marketing", "size": "1024x1024", "scale": "1x", "filename": try iosFile(1024)])
let json: [String: Any] = ["images": entries, "info": ["author": "Daniel", "version": 1]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: root.appendingPathComponent("Contents.json"))
print("Generated Mac and iOS app icons.")
