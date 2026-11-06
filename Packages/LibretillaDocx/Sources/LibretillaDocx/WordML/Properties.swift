import Foundation

/// The run (character) properties Libretilla understands, parsed from `w:rPr`.
/// `nil` means "not set here, inherit". The raw `w:rPr` bytes are kept separately for lossless writing.
public struct RunProperties: Sendable, Equatable {
    public var styleId: String?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strike: Bool?
    /// Points.
    public var size: Double?
    /// Hex `RRGGBB`; `"auto"` is the automatic colour.
    public var color: String?
    public var font: String?
    /// e.g. `minorHAnsi`, resolved through the theme.
    public var themeFont: String?
    /// `superscript` / `subscript` / `baseline`.
    public var verticalAlignment: String?
    /// Word highlight name, e.g. `yellow`.
    public var highlight: String?

    public init() {}

    public init(_ rPr: RawXML.Element?) {
        guard let rPr else { return }
        for e in rPr.childElements {
            switch e.name {
            case "w:rStyle": styleId = e.attribute("w:val")
            case "w:b": bold = Self.toggle(e)
            case "w:i": italic = Self.toggle(e)
            case "w:strike": strike = Self.toggle(e)
            case "w:u": underline = (e.attribute("w:val") ?? "single") != "none"
            case "w:sz": size = e.attribute("w:val").flatMap(Double.init).map { $0 / 2 }
            case "w:color": color = e.attribute("w:val")
            case "w:rFonts":
                font = e.attribute("w:ascii") ?? e.attribute("w:hAnsi")
                themeFont = e.attribute("w:asciiTheme") ?? e.attribute("w:hAnsiTheme")
            case "w:vertAlign": verticalAlignment = e.attribute("w:val")
            case "w:highlight": highlight = e.attribute("w:val")
            default: break
            }
        }
    }

    static func toggle(_ e: RawXML.Element) -> Bool {
        switch e.attribute("w:val") {
        case "0", "false", "off": false
        default: true
        }
    }

    /// `self` wins; unset values come from `base`.
    public func over(_ base: RunProperties) -> RunProperties {
        var r = base
        if let styleId { r.styleId = styleId }
        if let bold { r.bold = bold }
        if let italic { r.italic = italic }
        if let underline { r.underline = underline }
        if let strike { r.strike = strike }
        if let size { r.size = size }
        if let color { r.color = color }
        if font != nil || themeFont != nil {
            r.font = font
            r.themeFont = themeFont
        }
        if let verticalAlignment { r.verticalAlignment = verticalAlignment }
        if let highlight { r.highlight = highlight }
        return r
    }
}

/// The paragraph properties Libretilla understands, parsed from `w:pPr`. Lengths are in points.
public struct ParagraphProperties: Sendable, Equatable {
    public var styleId: String?
    /// `left`/`start`, `center`, `right`/`end`, `both`, `distribute`.
    public var alignment: String?
    public var spaceBefore: Double?
    public var spaceAfter: Double?
    /// Line spacing: a multiple of single spacing when `lineRule` is `auto`, else points.
    public var line: Double?
    public var lineRule: String?
    public var indentLeft: Double?
    public var indentRight: Double?
    /// Positive for a first-line indent, negative for a hanging indent.
    public var firstLine: Double?
    /// `w:numPr`: the list (`numId`, 0 means "no list") and level. Either may come from the style.
    public var numId: Int?
    public var ilvl: Int?
    /// Custom tab stops (`w:tabs`), in points; nil means inherit.
    public var tabs: [TabStop]?
    public var hasSectionBreak = false

    /// The paragraph is a list item.
    public var hasNumbering: Bool { (numId ?? 0) != 0 }

    public init() {}

    public init(_ pPr: RawXML.Element?) {
        guard let pPr else { return }
        func pt(_ v: String?) -> Double? { v.flatMap(Double.init).map { $0 / 20 } }
        for e in pPr.childElements {
            switch e.name {
            case "w:pStyle": styleId = e.attribute("w:val")
            case "w:jc": alignment = e.attribute("w:val")
            case "w:spacing":
                spaceBefore = pt(e.attribute("w:before"))
                spaceAfter = pt(e.attribute("w:after"))
                lineRule = e.attribute("w:lineRule")
                if let raw = e.attribute("w:line").flatMap(Double.init) {
                    line = (lineRule ?? "auto") == "auto" ? raw / 240 : raw / 20
                }
            case "w:ind":
                indentLeft = pt(e.attribute("w:left") ?? e.attribute("w:start"))
                indentRight = pt(e.attribute("w:right") ?? e.attribute("w:end"))
                if let h = pt(e.attribute("w:hanging")) {
                    firstLine = -h
                } else if let f = pt(e.attribute("w:firstLine")) {
                    firstLine = f
                }
            case "w:numPr":
                numId = e.firstChild(named: "w:numId")?.attribute("w:val").flatMap { Int($0) }
                ilvl = e.firstChild(named: "w:ilvl")?.attribute("w:val").flatMap { Int($0) }
            case "w:tabs":
                tabs = e.childElements(named: "w:tab").compactMap(TabStop.init)
            case "w:sectPr": hasSectionBreak = true
            default: break
            }
        }
    }

    /// `self` wins; unset values come from `base`. Style id and the section flag stay `self`'s.
    public func over(_ base: ParagraphProperties) -> ParagraphProperties {
        var p = self
        p.alignment = alignment ?? base.alignment
        p.spaceBefore = spaceBefore ?? base.spaceBefore
        p.spaceAfter = spaceAfter ?? base.spaceAfter
        if line == nil {
            p.line = base.line
            p.lineRule = base.lineRule
        }
        p.indentLeft = indentLeft ?? base.indentLeft
        p.indentRight = indentRight ?? base.indentRight
        p.firstLine = firstLine ?? base.firstLine
        p.numId = numId ?? base.numId
        p.ilvl = ilvl ?? base.ilvl
        p.tabs = tabs ?? base.tabs
        return p
    }
}

/// A custom tab stop. `alignment` is `left`, `center`, `right` or `decimal` (`start`/`end` map to left/right).
public struct TabStop: Sendable, Equatable {
    public var position: Double
    public var alignment: String
    public var leader: String?

    public init(position: Double, alignment: String = "left", leader: String? = nil) {
        self.position = position
        self.alignment = alignment
        self.leader = leader
    }

    init?(_ e: RawXML.Element) {
        guard let val = e.attribute("w:val"), val != "clear", val != "bar",
            let pos = e.attribute("w:pos").flatMap(Double.init)
        else { return nil }
        position = pos / 20
        switch val {
        case "start": alignment = "left"
        case "end": alignment = "right"
        default: alignment = val
        }
        leader = e.attribute("w:leader").flatMap { $0 == "none" ? nil : $0 }
    }
}
