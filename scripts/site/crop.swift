// Keeps the top <height> pixels of a window shot and scales it to <width> pixels wide.
// Usage: swift scripts/site/crop.swift <in.png> <out.png> <height> <width>
import AppKit

let args = CommandLine.arguments
guard args.count == 5, let keep = Int(args[3]), let outWidth = Int(args[4]),
    let image = NSImage(contentsOfFile: args[1]),
    let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
    let top = source.cropping(to: CGRect(x: 0, y: 0, width: source.width, height: min(keep, source.height)))
else {
    FileHandle.standardError.write("usage: crop.swift <in.png> <out.png> <height> <width>\n".data(using: .utf8)!)
    exit(1)
}
let outHeight = Int((Double(top.height) * Double(outWidth) / Double(top.width)).rounded())
let context = CGContext(
    data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.interpolationQuality = .high
context.draw(top, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
try png.write(to: URL(filePath: args[2]))
print("\(args[2]): \(outWidth)x\(outHeight)")
