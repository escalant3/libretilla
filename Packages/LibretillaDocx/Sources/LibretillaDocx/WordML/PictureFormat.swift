import Foundation

/// What Format ▸ Picture… edits about a picture, as DrawingML says it:
///
/// - `size`: `wp:extent` and the picture's `a:xfrm/a:ext` (EMU).
/// - `rotation`: `a:xfrm@rot` (60,000ths of a degree, clockwise). The extra room a rotated picture takes
///   is `wp:effectExtent`, as Word writes it.
/// - `brightness`, `contrast`: `a:blip/a:lum@bright` and `@contrast` (1,000ths of a percent).
/// - `opacity`: `a:blip/a:alphaModFix@amt` (1,000ths of a percent).
public struct PictureFormat: Sendable, Equatable {
    /// Unrotated size in points.
    public var size: CGSize
    /// Degrees clockwise, in 0..<360.
    public var rotation: CGFloat
    /// -1…1; 0 leaves the picture as it is.
    public var brightness: CGFloat
    /// -1…1; 0 leaves the picture as it is.
    public var contrast: CGFloat
    /// 0…1; 1 is opaque.
    public var opacity: CGFloat

    public init(
        size: CGSize, rotation: CGFloat = 0, brightness: CGFloat = 0, contrast: CGFloat = 0, opacity: CGFloat = 1
    ) {
        self.size = size
        self.rotation = rotation
        self.brightness = brightness
        self.contrast = contrast
        self.opacity = opacity
    }

    /// `degrees` brought into 0..<360.
    public static func normalized(_ degrees: CGFloat) -> CGFloat {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Brightness, contrast or opacity differ from the picture's own.
    public var isAdjusted: Bool { brightness != 0 || contrast != 0 || opacity < 1 }

    /// The room the picture takes on the line: its size turned by `rotation`.
    public var boundingSize: CGSize {
        let a = rotation * .pi / 180
        let c = abs(cos(a))
        let s = abs(sin(a))
        // Rounding noise (cos 90° isn't exactly 0) would add a sliver of a point.
        func clean(_ v: CGFloat) -> CGFloat { (v * 1000).rounded() / 1000 }
        return CGSize(
            width: clean(size.width * c + size.height * s), height: clean(size.width * s + size.height * c))
    }

    /// Reads the format of a drawing frame (`wp:inline` or `wp:anchor`).
    init(frame: RawXML.Element, size: CGSize) {
        self.init(size: size)
        if let xfrm = Self.pictureShapeProperties(in: frame)?.firstChild(named: "a:xfrm"),
            let rot = xfrm.attribute("rot").flatMap(Double.init)
        {
            rotation = Self.normalized(CGFloat(rot) / 60000)
        }
        if let blip = frame.descendants(named: "a:blip").first {
            if let lum = blip.firstChild(named: "a:lum") {
                brightness = Self.fraction(lum.attribute("bright"), range: -1...1) ?? 0
                contrast = Self.fraction(lum.attribute("contrast"), range: -1...1) ?? 0
            }
            if let alpha = blip.firstChild(named: "a:alphaModFix") {
                opacity = Self.fraction(alpha.attribute("amt"), range: 0...1) ?? 1
            }
        }
    }

    /// A DrawingML percentage (`ST_Percentage`: 1,000ths of a percent, or "50%") as a fraction.
    static func fraction(_ value: String?, range: ClosedRange<CGFloat>) -> CGFloat? {
        guard let value else { return nil }
        let v: Double?
        if value.hasSuffix("%") {
            v = Double(value.dropLast()).map { $0 / 100 }
        } else {
            v = Double(value).map { $0 / 100000 }
        }
        return v.map { min(max(CGFloat($0), range.lowerBound), range.upperBound) }
    }

    static func percentage(_ fraction: CGFloat) -> String { String(Int((fraction * 100000).rounded())) }

    /// The `pic:spPr` of the picture in a drawing frame.
    static func pictureShapeProperties(in frame: RawXML.Element) -> RawXML.Element? {
        frame.descendants(named: "pic:pic").first?.firstChild(named: "pic:spPr")
    }
}

extension ImageReference {
    static func emu(_ points: CGFloat) -> String { String(Int((points * emuPerPoint).rounded())) }
}

extension OpaqueInline {
    /// This picture with `format`, or nil if it isn't a picture Libretilla can format. Only the elements
    /// and attributes `PictureFormat` names are rewritten; everything else keeps its bytes.
    public func formattingPicture(_ format: PictureFormat) -> OpaqueInline? {
        guard image != nil, let doc = try? RawXML.Document(data: xml, part: "picture"),
            let frame = doc.root.descendants(named: "w:drawing").first?.childElements.first,
            let extent = frame.firstChild(named: "wp:extent"),
            let spPr = PictureFormat.pictureShapeProperties(in: frame),
            let blip = frame.descendants(named: "a:blip").first
        else { return nil }
        let old = PictureFormat(frame: frame, size: image!.size)
        let cx = ImageReference.emu(format.size.width)
        let cy = ImageReference.emu(format.size.height)
        var edits: [(Range<Int>, Data)] = []

        func setting(_ e: RawXML.Element, _ changes: [(String, String?)]) -> String {
            var attrs = e.attributes.map { ($0.name, $0.value) }
            for (key, value) in changes {
                if let i = attrs.firstIndex(where: { $0.0 == key }) {
                    if let value { attrs[i].1 = value } else { attrs.remove(at: i) }
                } else if let value {
                    attrs.append((key, value))
                }
            }
            return ElementPatch.startTag(e.name, attrs, selfClosing: e.endTagRange.isEmpty)
        }

        // wp:extent, and wp:effectExtent when the rotation changes (Word puts a rotated picture's extra
        // room there; anything else it held, like a shadow's, is lost only then).
        edits.append((extent.startTagRange, Data(setting(extent, [("cx", cx), ("cy", cy)]).utf8)))
        if format.rotation != old.rotation || (format.rotation != 0 && format.size != old.size) {
            let bound = format.boundingSize
            let dx = ImageReference.emu(max(0, (bound.width - format.size.width) / 2))
            let dy = ImageReference.emu(max(0, (bound.height - format.size.height) / 2))
            let values: [(String, String?)] = [("l", dx), ("t", dy), ("r", dx), ("b", dy)]
            if let effect = frame.firstChild(named: "wp:effectExtent") {
                edits.append((effect.startTagRange, Data(setting(effect, values).utf8)))
            } else {
                let tag = "<wp:effectExtent l=\"\(dx)\" t=\"\(dy)\" r=\"\(dx)\" b=\"\(dy)\"/>"
                edits.append((extent.range.upperBound..<extent.range.upperBound, Data(tag.utf8)))
            }
        }

        // pic:spPr › a:xfrm (rotation) › a:ext (size).
        let rot: String? = format.rotation == 0 ? nil : String(Int((format.rotation * 60000).rounded()))
        if let xfrm = spPr.firstChild(named: "a:xfrm"), !xfrm.endTagRange.isEmpty,
            let ext = xfrm.firstChild(named: "a:ext")
        {
            edits.append((xfrm.startTagRange, Data(setting(xfrm, [("rot", rot)]).utf8)))
            edits.append((ext.startTagRange, Data(setting(ext, [("cx", cx), ("cy", cy)]).utf8)))
        } else {
            let rotAttr = rot.map { " rot=\"\($0)\"" } ?? ""
            let xfrm =
                "<a:xfrm\(rotAttr)><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
            guard
                let patched = ElementPatch.apply(
                    [.replace("a:xfrm", xml: xfrm)], to: doc.slice(spPr.range), wrapper: "pic:spPr",
                    order: ["a:xfrm"])
            else { return nil }
            edits.append((spPr.range, patched))
        }

        // a:blip › a:lum, a:alphaModFix.
        var blipEdits: [ElementPatch.Edit] = []
        if format.brightness != old.brightness || format.contrast != old.contrast {
            blipEdits.append(
                .attributes(
                    "a:lum",
                    [
                        ("bright", format.brightness == 0 ? nil : PictureFormat.percentage(format.brightness)),
                        ("contrast", format.contrast == 0 ? nil : PictureFormat.percentage(format.contrast)),
                    ]))
        }
        if format.opacity != old.opacity {
            blipEdits.append(
                .attributes(
                    "a:alphaModFix", [("amt", format.opacity >= 1 ? nil : PictureFormat.percentage(format.opacity))]))
        }
        if !blipEdits.isEmpty {
            guard
                let patched = ElementPatch.apply(
                    blipEdits, to: doc.slice(blip.range), wrapper: "a:blip", order: Self.blipOrder)
            else { return nil }
            edits.append((blip.range, patched))
        }

        var bytes = Data([UInt8](xml))
        for (range, data) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            bytes.replaceSubrange(range, with: data)
        }
        guard let reparsed = try? RawXML.Document(data: bytes, part: "picture") else { return nil }
        var out = OpaqueInline(parsing: reparsed.root, in: reparsed)
        out.newMedia = newMedia
        out.pageField = pageField
        return out
    }

    /// Children of `a:blip` (CT_Blip): its effects, then `a:extLst`.
    static let blipOrder = [
        "a:alphaBiLevel", "a:alphaCeiling", "a:alphaFloor", "a:alphaInv", "a:alphaMod", "a:alphaModFix",
        "a:alphaRepl", "a:biLevel", "a:blur", "a:clrChange", "a:clrRepl", "a:duotone", "a:fillOverlay", "a:grayscl",
        "a:hsl", "a:lum", "a:tint", "a:extLst",
    ]
}
