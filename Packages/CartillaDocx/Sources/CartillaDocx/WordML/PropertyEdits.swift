import Foundation

// Writing properties back. A formatting change rewrites only the `w:rPr` / `w:pPr` children
// that hold the changed fields; every other child keeps its bytes (ADR 0002).

extension RunProperties {
    public enum Field: Sendable, Hashable, CaseIterable {
        case style, font, bold, italic, underline, strike, color, size, highlight, verticalAlignment
    }

    /// `xml` (a `<w:rPr>` or nil) changed so that `fields` say what `self` says. Nil when empty.
    public func patching(_ xml: Data?, fields: Set<Field>) -> Data? {
        let edits = Field.allCases.filter(fields.contains).flatMap(edits(for:))
        return ElementPatch.apply(edits, to: xml, wrapper: "w:rPr", order: ElementPatch.runPropertiesOrder)
    }

    func edits(for field: Field) -> [ElementPatch.Edit] {
        func val(_ v: String) -> String { "w:val=\"\(RawXML.escapeAttribute(v))\"" }
        func toggle(_ name: String, _ v: Bool?) -> ElementPatch.Edit {
            v.map { .replace(name, xml: $0 ? "<\(name)/>" : "<\(name) w:val=\"0\"/>") } ?? .remove(name)
        }
        switch field {
        case .style:
            return [styleId.map { .replace("w:rStyle", xml: "<w:rStyle \(val($0))/>") } ?? .remove("w:rStyle")]
        case .font:
            if let font {
                return [
                    .attributes(
                        "w:rFonts",
                        [
                            ("w:ascii", font), ("w:hAnsi", font), ("w:cs", font), ("w:asciiTheme", nil),
                            ("w:hAnsiTheme", nil), ("w:cstheme", nil),
                        ])
                ]
            }
            if let themeFont {
                return [
                    .attributes(
                        "w:rFonts",
                        [("w:asciiTheme", themeFont), ("w:hAnsiTheme", themeFont), ("w:ascii", nil), ("w:hAnsi", nil)])
                ]
            }
            return [
                .attributes(
                    "w:rFonts",
                    [
                        ("w:ascii", nil), ("w:hAnsi", nil), ("w:cs", nil), ("w:asciiTheme", nil),
                        ("w:hAnsiTheme", nil), ("w:cstheme", nil),
                    ])
            ]
        case .bold: return [toggle("w:b", bold)]
        case .italic: return [toggle("w:i", italic)]
        case .strike: return [toggle("w:strike", strike)]
        case .underline:
            return [underline.map { .replace("w:u", xml: "<w:u \(val($0 ? "single" : "none"))/>") } ?? .remove("w:u")]
        case .color:
            return [color.map { .replace("w:color", xml: "<w:color \(val($0))/>") } ?? .remove("w:color")]
        case .size:
            guard let size else { return [.remove("w:sz"), .remove("w:szCs")] }
            let half = String(Int((size * 2).rounded()))
            return [.replace("w:sz", xml: "<w:sz \(val(half))/>"), .replace("w:szCs", xml: "<w:szCs \(val(half))/>")]
        case .highlight:
            return [
                highlight.map { .replace("w:highlight", xml: "<w:highlight \(val($0))/>") } ?? .remove("w:highlight")
            ]
        case .verticalAlignment:
            return [
                verticalAlignment.map { .replace("w:vertAlign", xml: "<w:vertAlign \(val($0))/>") }
                    ?? .remove("w:vertAlign")
            ]
        }
    }

    /// Copies `fields` from `other`.
    public mutating func take(_ fields: Set<Field>, from other: RunProperties) {
        for f in fields {
            switch f {
            case .style: styleId = other.styleId
            case .font:
                font = other.font
                themeFont = other.themeFont
            case .bold: bold = other.bold
            case .italic: italic = other.italic
            case .underline: underline = other.underline
            case .strike: strike = other.strike
            case .color: color = other.color
            case .size: size = other.size
            case .highlight: highlight = other.highlight
            case .verticalAlignment: verticalAlignment = other.verticalAlignment
            }
        }
    }
}

extension ParagraphProperties {
    public enum Field: Sendable, Hashable, CaseIterable {
        case style, numbering, tabs, spaceBefore, spaceAfter, lineSpacing, indentation, alignment
    }

    /// `xml` (a `<w:pPr>` or nil) changed so that `fields` say what `self` says. Nil when empty.
    public func patching(_ xml: Data?, fields: Set<Field>) -> Data? {
        let edits = Field.allCases.filter(fields.contains).flatMap(edits(for:))
        return ElementPatch.apply(edits, to: xml, wrapper: "w:pPr", order: ElementPatch.paragraphPropertiesOrder)
    }

    static func twips(_ pt: Double?) -> String? { pt.map { String(Int(($0 * 20).rounded())) } }

    func edits(for field: Field) -> [ElementPatch.Edit] {
        func val(_ v: String) -> String { "w:val=\"\(RawXML.escapeAttribute(v))\"" }
        switch field {
        case .style:
            return [styleId.map { .replace("w:pStyle", xml: "<w:pStyle \(val($0))/>") } ?? .remove("w:pStyle")]
        case .alignment:
            return [alignment.map { .replace("w:jc", xml: "<w:jc \(val($0))/>") } ?? .remove("w:jc")]
        case .numbering:
            guard numId != nil || ilvl != nil else { return [.remove("w:numPr")] }
            var inner = ""
            if let ilvl { inner += "<w:ilvl \(val(String(ilvl)))/>" }
            if let numId { inner += "<w:numId \(val(String(numId)))/>" }
            return [.replace("w:numPr", xml: "<w:numPr>\(inner)</w:numPr>")]
        case .tabs:
            guard let tabs, !tabs.isEmpty else { return [.remove("w:tabs")] }
            let items = tabs.map { t in
                "<w:tab \(val(t.alignment))" + (t.leader.map { " w:leader=\"\($0)\"" } ?? "")
                    + " w:pos=\"\(Self.twips(t.position) ?? "0")\"/>"
            }
            return [.replace("w:tabs", xml: "<w:tabs>\(items.joined())</w:tabs>")]
        case .spaceBefore:
            return [
                .attributes(
                    "w:spacing",
                    [("w:before", Self.twips(spaceBefore)), ("w:beforeLines", nil), ("w:beforeAutospacing", nil)])
            ]
        case .spaceAfter:
            return [
                .attributes(
                    "w:spacing",
                    [("w:after", Self.twips(spaceAfter)), ("w:afterLines", nil), ("w:afterAutospacing", nil)])
            ]
        case .lineSpacing:
            guard let line else { return [.attributes("w:spacing", [("w:line", nil), ("w:lineRule", nil)])] }
            let rule = lineRule ?? "auto"
            let raw = rule == "auto" ? Int((line * 240).rounded()) : Int((line * 20).rounded())
            return [.attributes("w:spacing", [("w:line", String(raw)), ("w:lineRule", rule)])]
        case .indentation:
            var hanging: String?
            var first: String?
            if let firstLine {
                if firstLine < 0 { hanging = Self.twips(-firstLine) } else { first = Self.twips(firstLine) }
            }
            return [
                .attributes(
                    "w:ind",
                    [
                        ("w:left", Self.twips(indentLeft)), ("w:start", nil), ("w:right", Self.twips(indentRight)),
                        ("w:end", nil), ("w:firstLine", first), ("w:hanging", hanging), ("w:leftChars", nil),
                        ("w:startChars", nil), ("w:rightChars", nil), ("w:endChars", nil),
                        ("w:firstLineChars", nil), ("w:hangingChars", nil),
                    ])
            ]
        }
    }

    /// Copies `fields` from `other`.
    public mutating func take(_ fields: Set<Field>, from other: ParagraphProperties) {
        for f in fields {
            switch f {
            case .style: styleId = other.styleId
            case .alignment: alignment = other.alignment
            case .numbering:
                numId = other.numId
                ilvl = other.ilvl
            case .tabs: tabs = other.tabs
            case .spaceBefore: spaceBefore = other.spaceBefore
            case .spaceAfter: spaceAfter = other.spaceAfter
            case .lineSpacing:
                line = other.line
                lineRule = other.lineRule
            case .indentation:
                indentLeft = other.indentLeft
                indentRight = other.indentRight
                firstLine = other.firstLine
            }
        }
    }
}
