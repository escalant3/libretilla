// Renders Resources/Icon/AppIcon.svg into every size the AppIcon set needs.
// Usage: swift scripts/render-icon.swift
import AppKit
import WebKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let svgURL = root.appendingPathComponent("Resources/Icon/AppIcon.svg")
let outDir = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
let svg = try String(contentsOf: svgURL, encoding: .utf8)

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    var done: (NSImage) -> Void = { _ in }
    func start(_ html: String) {
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.loadHTMLString(html, baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = 1024
        webView.takeSnapshot(with: cfg) { img, err in
            guard let img else { fatalError("snapshot failed: \(String(describing: err))") }
            self.done(img)
        }
    }
}

func png(_ image: NSImage, size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let app = NSApplication.shared
let r = Renderer()
r.done = { img in
    var images: [String] = []
    for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! png(img, size: pt * scale).write(to: outDir.appendingPathComponent(name))
        images.append(#"    { "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(pt)x\#(pt)", "filename" : "\#(name)" }"#)
    }
    let json = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
    try! json.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("wrote \(images.count) icons to \(outDir.path)")
    exit(0)
}
r.start("<html><body style='margin:0;background:transparent'>\(svg)</body></html>")
app.run()
