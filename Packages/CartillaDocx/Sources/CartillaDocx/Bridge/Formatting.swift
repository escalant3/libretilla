import AppKit

// Formatting edits on the editor's text (M2).
//
// The custom attributes (`RunFormat`, `ParagraphFormat`) are the truth that gets saved. Display
// attributes (font, colour, paragraph style) are derived from them. Two paths keep them in step:
//
// - Cartilla's own commands change the semantics, then `restyle` redraws the display.
// - AppKit's own tools (Font panel, ruler, paste) change the display directly; `reconcile` then
//   works out which Word properties changed and updates the semantics to match.
//
// Either way, only the `w:rPr` / `w:pPr` children for the changed fields are rewritten.

public enum RunChange: Sendable, Equatable {
    case bold(Bool), italic(Bool), underline(Bool), strike(Bool)
    case size(Double)
    case font(String)
    /// Hex `RRGGBB`, or nil for automatic.
    case color(String?)
    /// Word highlight name, or nil for none.
    case highlight(String?)
    /// `superscript`, `subscript`, or nil for baseline.
    case verticalAlignment(String?)
    /// Removes all direct character formatting Cartilla models (Clear Formatting).
    case clear
    /// Sets (an id) or removes (nil) the run's character style (`w:rStyle`), e.g. "Hyperlink".
    case characterStyle(String?)
}

public enum ParagraphChange: Sendable, Equatable {
    /// A paragraph style id; nil for the default (Normal).
    case style(String?)
    /// `left`, `center`, `right`, `both`.
    case alignment(String)
    /// A multiple of single spacing.
    case lineSpacing(Double)
    case spaceBefore(Double)
    case spaceAfter(Double)
    /// Adds to the left indent (points; negative to decrease), never below zero.
    case indent(by: Double)
    /// Makes the paragraph an item of list `numId` at `level` (nil keeps its current level, or 0),
    /// or (`numId` nil) not a list item.
    case list(numId: Int?, level: Int?)
    /// Moves a list item `by` levels (0…8).
    case listLevel(by: Int)
    /// Removes direct alignment, spacing, indents and tabs.
    case clear
}

/// What the format bar shows for a selection. Nil means "mixed".
public struct SelectionFormat: Equatable {
    public var styleId: String?
    public var fontFamily: String?
    public var fontSize: Double?
    public var bold = false
    public var italic = false
    public var underline = false
    public var strike = false
    public var color: NSColor?
    public var alignment: String?
    public var list: Numbering.ListKind?
    public var lineSpacing: Double?
    /// Of the first selected paragraph.
    public var spaceBefore: Double = 0
    public var spaceAfter: Double = 0
    public var isListItem: Bool { list != nil }

    public init() {}
}

extension AttributedStringBridge {
    // MARK: - Paragraph ranges

    /// Full paragraph ranges (with terminators) that `range` touches.
    public static func paragraphRanges(in text: NSAttributedString, touching range: NSRange) -> [NSRange] {
        let ns = text.string as NSString
        guard ns.length > 0 else { return [] }
        var out: [NSRange] = []
        var location = min(range.location, ns.length - 1)
        let end = max(NSMaxRange(range), range.location)
        repeat {
            let r = ns.paragraphRange(for: NSRange(location: location, length: 0))
            out.append(r)
            location = NSMaxRange(r)
        } while location < end && location < ns.length
        return out
    }

    /// A placeholder line for a table or other opaque block: it has no paragraph properties of its own.
    static func isBlock(_ text: NSAttributedString, _ paragraph: NSRange) -> Bool {
        paragraph.length > 0 && text.attribute(.cartillaBlock, at: paragraph.location, effectiveRange: nil) != nil
    }

    /// The paragraph's format (nil for pasted text not reconciled yet, or a block placeholder).
    public static func paragraphFormatOf(_ text: NSAttributedString, _ paragraph: NSRange) -> ParagraphFormat? {
        paragraphFormat(text, paragraph)
    }

    func format(of text: NSAttributedString, paragraph: NSRange) -> ParagraphFormat {
        Self.paragraphFormat(text, paragraph) ?? ParagraphFormat(properties: ParagraphProperties(), xml: nil)
    }

    // MARK: - Character formatting

    /// Applies `change` to the runs in `range`. Links, fields and objects keep their formatting.
    public func apply(_ change: RunChange, to text: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        var replaced: [ObjectIdentifier: RunFormat] = [:]
        for paragraph in Self.paragraphRanges(in: text, touching: range) {
            let styleId = format(of: text, paragraph: paragraph).properties.styleId
            let r = NSIntersectionRange(paragraph, range)
            guard r.length > 0 else { continue }
            text.enumerateAttributes(in: r, options: []) { attrs, span, _ in
                guard attrs[.cartillaOpaque] == nil, attrs[.cartillaBlock] == nil else { return }
                // The paragraph terminator carries no run.
                if span.length == 1, (text.string as NSString).character(at: span.location) == 0x0A { return }
                let old = runFormat(attrs, paragraphStyle: styleId)
                let key = ObjectIdentifier(old)
                let new = replaced[key] ?? applying(change, to: old, paragraphStyle: styleId)
                replaced[key] = new
                Self.setDisplay(displayAttributes(for: new, paragraphStyle: styleId), on: text, range: span)
                text.addAttribute(.cartillaRun, value: new, range: span)
            }
        }
    }

    /// Typing attributes after `change` (a formatting command with an empty selection).
    public func typingAttributes(
        _ attrs: [NSAttributedString.Key: Any], applying change: RunChange, paragraphStyle styleId: String?
    ) -> [NSAttributedString.Key: Any] {
        var out = attrs
        let new = applying(change, to: runFormat(attrs, paragraphStyle: styleId), paragraphStyle: styleId)
        let display = displayAttributes(for: new, paragraphStyle: styleId)
        for k in Self.optionalDisplayKeys { out[k] = nil }
        for (k, v) in display { out[k] = v }
        out[.cartillaRun] = new
        return out
    }

    /// The run's format, or one derived from its display for text that has none (pasted text).
    func runFormat(_ attrs: [NSAttributedString.Key: Any], paragraphStyle styleId: String?) -> RunFormat {
        if let f = attrs[.cartillaRun] as? RunFormat { return f }
        let empty = RunFormat(properties: RunProperties(), xml: nil)
        return reconciled(empty, attrs: attrs, paragraphStyle: styleId, text: nil) ?? empty
    }

    /// Display attributes that are present only when on (absent means off).
    static let optionalDisplayKeys: [NSAttributedString.Key] = [
        .underlineStyle, .strikethroughStyle, .superscript, .backgroundColor,
    ]

    /// Replaces a span's display attributes, removing decorations the new display doesn't have.
    static func setDisplay(
        _ display: [NSAttributedString.Key: Any], on text: NSMutableAttributedString, range: NSRange
    ) {
        for key in optionalDisplayKeys where display[key] == nil { text.removeAttribute(key, range: range) }
        text.addAttributes(display, range: range)
    }

    /// The value each field has when the run sets nothing itself (paragraph style and character style).
    func inheritedRun(_ direct: RunProperties, paragraphStyle styleId: String?) -> RunProperties {
        var styleOnly = RunProperties()
        styleOnly.styleId = direct.styleId
        return styles.resolveRun(paragraphStyle: styleId, direct: styleOnly)
    }

    func applying(_ change: RunChange, to format: RunFormat, paragraphStyle styleId: String?) -> RunFormat {
        let inherited = inheritedRun(format.properties, paragraphStyle: styleId)
        var new = format.properties
        let field: RunProperties.Field
        switch change {
        case .bold(let v):
            field = .bold
            new.bold = v == (inherited.bold ?? false) ? nil : v
        case .italic(let v):
            field = .italic
            new.italic = v == (inherited.italic ?? false) ? nil : v
        case .underline(let v):
            field = .underline
            new.underline = v == (inherited.underline ?? false) ? nil : v
        case .strike(let v):
            field = .strike
            new.strike = v == (inherited.strike ?? false) ? nil : v
        case .size(let v):
            field = .size
            new.size = v == (inherited.size ?? Double(Self.defaultFontSize)) ? nil : v
        case .font(let family):
            field = .font
            let same = styles.fontFamily(for: inherited)?.caseInsensitiveCompare(family) == .orderedSame
            new.font = same ? nil : family
            new.themeFont = nil
        case .color(let hex):
            field = .color
            let inheritedColor = inherited.color == "auto" ? nil : inherited.color
            new.color = hex?.uppercased() == inheritedColor?.uppercased() ? nil : (hex ?? "auto")
            if new.color == "auto" && inherited.color == nil { new.color = nil }
        case .highlight(let name):
            field = .highlight
            new.highlight = name == inherited.highlight ? nil : (name ?? "none")
            if new.highlight == "none" && inherited.highlight == nil { new.highlight = nil }
        case .verticalAlignment(let v):
            field = .verticalAlignment
            let inheritedValue = inherited.verticalAlignment == "baseline" ? nil : inherited.verticalAlignment
            new.verticalAlignment = v == inheritedValue ? nil : (v ?? "baseline")
        case .characterStyle(let id):
            field = .style
            new.styleId = id
        case .clear:
            // Character styles go too, as with Word's Clear Formatting. (Links are opaque and untouched.)
            return format.setting(Set(RunProperties.Field.allCases), from: RunProperties())
        }
        return format.setting([field], from: new)
    }

    /// Display attributes for a run (font, colour, decorations).
    func displayAttributes(for format: RunFormat, paragraphStyle styleId: String?) -> [NSAttributedString.Key: Any] {
        characterAttributes(styles.resolveRun(paragraphStyle: styleId, direct: format.properties))
    }

    // MARK: - Paragraph formatting

    /// Applies `change` to every paragraph `range` touches and redraws them.
    public func apply(_ change: ParagraphChange, to text: NSMutableAttributedString, range: NSRange) {
        for paragraph in Self.paragraphRanges(in: text, touching: range) where !Self.isBlock(text, paragraph) {
            let old = format(of: text, paragraph: paragraph)
            let new = applying(change, to: old)
            guard new !== old || Self.paragraphFormat(text, paragraph) == nil else { continue }
            text.addAttribute(.cartillaParagraphFormat, value: new, range: paragraph)
            restyle(text, paragraph: paragraph)
        }
    }

    func applying(_ change: ParagraphChange, to format: ParagraphFormat) -> ParagraphFormat {
        let direct = format.properties
        var new = direct
        let inherited = effectiveParagraph(Self.styleOnly(direct))
        let effective = effectiveParagraph(direct)
        switch change {
        case .style(let id):
            new.styleId = id
            return format.setting([.style], from: new)
        case .alignment(let a):
            let normalized = a == "start" ? "left" : a
            new.alignment = normalized == Self.alignmentName(inherited.alignment) ? nil : normalized
            return format.setting([.alignment], from: new)
        case .lineSpacing(let m):
            let same = (inherited.lineRule ?? "auto") == "auto" && abs((inherited.line ?? 1) - m) < 0.001
            new.line = same ? nil : m
            new.lineRule = same ? nil : "auto"
            return format.setting([.lineSpacing], from: new)
        case .spaceBefore(let v):
            new.spaceBefore = abs((inherited.spaceBefore ?? 0) - v) < 0.01 ? nil : v
            return format.setting([.spaceBefore], from: new)
        case .spaceAfter(let v):
            new.spaceAfter = abs((inherited.spaceAfter ?? 0) - v) < 0.01 ? nil : v
            return format.setting([.spaceAfter], from: new)
        case .indent(let delta):
            let left = max(0, (effective.indentLeft ?? 0) + delta)
            new.indentLeft = left
            new.indentRight = effective.indentRight
            new.firstLine = effective.firstLine
            if left == (inherited.indentLeft ?? 0), effective.firstLine == inherited.firstLine,
                effective.indentRight == inherited.indentRight
            {
                new.indentLeft = nil
                new.indentRight = nil
                new.firstLine = nil
            }
            return format.setting([.indentation], from: new)
        case .list(let numId, let level):
            var fields: Set<ParagraphProperties.Field> = [.numbering]
            let styleNumbering = effectiveParagraph(Self.styleOnly(ParagraphProperties(styleId: direct.styleId)))
            if let numId {
                new.numId = numId
                new.ilvl = level ?? (effective.hasNumbering ? effective.ilvl ?? 0 : 0)
                // Word puts list items in "List Paragraph" when they'd otherwise be Normal.
                if direct.styleId == nil || direct.styleId == styles.defaultParagraphStyleId,
                    let list = styles.styleId(named: "List Paragraph")
                {
                    new.styleId = list
                    fields.insert(.style)
                }
            } else {
                // Off: say "no list" explicitly only if the style itself numbers paragraphs.
                new.numId = styleNumbering.hasNumbering ? 0 : nil
                new.ilvl = nil
                if let list = styles.styleId(named: "List Paragraph"), direct.styleId == list {
                    new.styleId = nil
                    fields.insert(.style)
                }
            }
            // A list's indents come from its level: drop direct indents that would fight them.
            new.indentLeft = nil
            new.firstLine = nil
            fields.insert(.indentation)
            new.indentRight = direct.indentRight
            return format.setting(fields, from: new)
        case .listLevel(let delta):
            guard effective.hasNumbering else { return format }
            new.numId = effective.numId
            new.ilvl = min(8, max(0, (effective.ilvl ?? 0) + delta))
            return format.setting([.numbering], from: new)
        case .clear:
            new = ParagraphProperties()
            return format.setting(
                [.alignment, .spaceBefore, .spaceAfter, .lineSpacing, .indentation, .tabs], from: new)
        }
    }

    static func styleOnly(_ p: ParagraphProperties) -> ParagraphProperties {
        var s = ParagraphProperties()
        s.styleId = p.styleId
        return s
    }

    static func alignmentName(_ a: String?) -> String {
        switch a {
        case "center": "center"
        case "right", "end": "right"
        case "both", "distribute": "both"
        default: "left"
        }
    }

    // MARK: - Redrawing

    /// Recomputes the display attributes of one paragraph from its formats. The list marker is kept
    /// until `renumber` runs.
    public func restyle(_ text: NSMutableAttributedString, paragraph: NSRange) {
        guard paragraph.length > 0, !Self.isBlock(text, paragraph) else { return }
        let format = format(of: text, paragraph: paragraph)
        let styleId = format.properties.styleId
        let effective = effectiveParagraph(format.properties)
        let oldStyle = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
        let marker = effective.hasNumbering ? (Self.listMarker(oldStyle)?.marker ?? "") : nil
        let paragraphStyle = Self.paragraphStyle(effective, marker: marker)
        let ns = text.string as NSString
        text.enumerateAttributes(in: paragraph, options: []) { attrs, span, _ in
            if attrs[.cartillaBlock] != nil { return }
            var display: [NSAttributedString.Key: Any]
            if let box = attrs[.cartillaOpaque] as? OpaqueInlineBox {
                display = characterAttributes(
                    styles.resolveRun(paragraphStyle: styleId, direct: box.inline.displayProperties))
                if box.inline.isHyperlink {
                    display[.foregroundColor] = NSColor.linkColor
                    display[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            } else if let run = attrs[.cartillaRun] as? RunFormat {
                display = displayAttributes(for: run, paragraphStyle: styleId)
            } else if span.length == 1, ns.character(at: span.location) == 0x0A {
                display = characterAttributes(styles.resolveRun(paragraphStyle: styleId, direct: RunProperties()))
            } else {
                display = displayAttributes(for: runFormat(attrs, paragraphStyle: styleId), paragraphStyle: styleId)
            }
            if attrs[.attachment] != nil { display[.font] = nil }
            Self.setDisplay(display, on: text, range: span)
        }
        text.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraph)
    }

    /// Recomputes every list marker (numbers depend on all earlier items). Returns the ranges changed.
    @discardableResult
    public func renumber(_ text: NSMutableAttributedString) -> [NSRange] {
        var counter = Numbering.Counter(numbering)
        var changed: [NSRange] = []
        for paragraph in Self.paragraphRanges(in: text, touching: NSRange(location: 0, length: text.length)) {
            guard let format = Self.paragraphFormat(text, paragraph) else { continue }
            let effective = effectiveParagraph(format.properties)
            let marker = effective.hasNumbering ? counter.next(numId: effective.numId!, ilvl: effective.ilvl ?? 0) : nil
            let current =
                text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            let lists = marker.map { Self.textLists(marker: $0, indent: effective.indentLeft) } ?? []
            let shown = Self.listMarker(current)
            guard shown?.marker != marker || (shown?.depth ?? 0) != lists.count else { continue }
            let style = (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.textLists = lists
            text.addAttribute(.paragraphStyle, value: style, range: paragraph)
            changed.append(paragraph)
        }
        return changed
    }

    // MARK: - Reconciling display changes made by AppKit

    /// Updates the formats in `range` (widened to whole paragraphs) to match display attributes that
    /// AppKit changed directly. Returns true if any format changed.
    @discardableResult
    public func reconcile(_ text: NSMutableAttributedString, range: NSRange) -> Bool {
        var changed = false
        let ns = text.string as NSString
        for paragraph in Self.paragraphRanges(in: text, touching: range) where !Self.isBlock(text, paragraph) {
            // Paragraph: one format for the whole paragraph, matching its (first character's) style.
            let current = Self.paragraphFormat(text, paragraph)
            var format = current ?? ParagraphFormat(properties: ParagraphProperties(), xml: nil)
            if let shown = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                as? NSParagraphStyle, let derived = reconciled(format, shown: shown)
            {
                format = derived
            }
            var uniform = current != nil
            if uniform {
                text.enumerateAttribute(.cartillaParagraphFormat, in: paragraph) { v, _, stop in
                    if (v as AnyObject?) !== format {
                        uniform = false
                        stop.pointee = true
                    }
                }
            }
            if !uniform || format !== current {
                text.addAttribute(.cartillaParagraphFormat, value: format, range: paragraph)
                changed = true
            }

            // Runs.
            let styleId = format.properties.styleId
            let runs = NSIntersectionRange(paragraph, range)
            guard runs.length > 0 else { continue }
            text.enumerateAttributes(in: runs, options: []) { attrs, span, _ in
                guard attrs[.cartillaOpaque] == nil, attrs[.cartillaBlock] == nil else { return }
                if span.length == 1, ns.character(at: span.location) == 0x0A { return }
                let old = attrs[.cartillaRun] as? RunFormat
                let base = old ?? RunFormat(properties: RunProperties(), xml: nil)
                let substring = ns.substring(with: span)
                if let new = reconciled(base, attrs: attrs, paragraphStyle: styleId, text: substring) {
                    text.addAttribute(.cartillaRun, value: new, range: span)
                    changed = true
                } else if old == nil {
                    text.addAttribute(.cartillaRun, value: base, range: span)
                    changed = true
                }
            }
        }
        return changed
    }

    /// The run format that explains `attrs`, or nil if `format` already does.
    func reconciled(
        _ format: RunFormat, attrs: [NSAttributedString.Key: Any], paragraphStyle styleId: String?, text: String?
    ) -> RunFormat? {
        let expected = displayAttributes(for: format, paragraphStyle: styleId)
        var changes: [RunChange] = []

        if let shown = attrs[.font] as? NSFont, let want = expected[.font] as? NSFont, shown != want {
            let manager = NSFontManager.shared
            let shownFamily = shown.familyName ?? shown.fontName
            let wantFamily = want.familyName ?? want.fontName
            // A font swapped in by AppKit for characters the run's font lacks (emoji, CJK) isn't a choice.
            let substituted =
                text.map { !want.coveredCharacterSet.isSuperset(of: CharacterSet(charactersIn: $0)) } ?? false
            if shownFamily != wantFamily, !substituted { changes.append(.font(shownFamily)) }
            if abs(shown.pointSize - want.pointSize) > 0.01 { changes.append(.size(Double(shown.pointSize))) }
            let shownTraits = manager.traits(of: shown)
            let wantTraits = manager.traits(of: want)
            if shownTraits.contains(.boldFontMask) != wantTraits.contains(.boldFontMask) {
                changes.append(.bold(shownTraits.contains(.boldFontMask)))
            }
            if shownTraits.contains(.italicFontMask) != wantTraits.contains(.italicFontMask) {
                changes.append(.italic(shownTraits.contains(.italicFontMask)))
            }
        }
        func int(_ key: NSAttributedString.Key, _ a: [NSAttributedString.Key: Any]) -> Int {
            (a[key] as? Int) ?? (a[key] as? NSNumber)?.intValue ?? 0
        }
        if (int(.underlineStyle, attrs) != 0) != (int(.underlineStyle, expected) != 0) {
            changes.append(.underline(int(.underlineStyle, attrs) != 0))
        }
        if (int(.strikethroughStyle, attrs) != 0) != (int(.strikethroughStyle, expected) != 0) {
            changes.append(.strike(int(.strikethroughStyle, attrs) != 0))
        }
        let shownScript = int(.superscript, attrs).signum()
        if shownScript != int(.superscript, expected).signum() {
            changes.append(.verticalAlignment(shownScript > 0 ? "superscript" : shownScript < 0 ? "subscript" : nil))
        }
        let shownColor = attrs[.foregroundColor] as? NSColor
        let wantColor = expected[.foregroundColor] as? NSColor
        if !Self.sameColor(shownColor ?? .textColor, wantColor ?? .textColor) {
            changes.append(.color(shownColor.flatMap(Self.hex)))
        }
        let shownBackground = attrs[.backgroundColor] as? NSColor
        let wantBackground = expected[.backgroundColor] as? NSColor
        if !Self.sameColor(shownBackground, wantBackground) {
            changes.append(.highlight(shownBackground.map(Self.nearestHighlight)))
        }
        guard !changes.isEmpty else { return nil }
        var f = format
        for c in changes { f = applying(c, to: f, paragraphStyle: styleId) }
        return f === format ? nil : f
    }

    /// The paragraph format that explains `shown`, or nil if `format` already does.
    func reconciled(_ format: ParagraphFormat, shown: NSParagraphStyle) -> ParagraphFormat? {
        let effective = effectiveParagraph(format.properties)
        let want = Self.paragraphStyle(effective)
        var changes: [ParagraphChange] = []
        func differ(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > 0.01 }
        let shownAlignment = shown.alignment == .natural ? NSTextAlignment.left : shown.alignment
        let wantAlignment = want.alignment == .natural ? NSTextAlignment.left : want.alignment
        if shownAlignment != wantAlignment {
            let name =
                switch shownAlignment {
                case .center: "center"
                case .right: "right"
                case .justified: "both"
                default: "left"
                }
            changes.append(.alignment(name))
        }
        if differ(shown.paragraphSpacingBefore, want.paragraphSpacingBefore) {
            changes.append(.spaceBefore(Double(shown.paragraphSpacingBefore)))
        }
        if differ(shown.paragraphSpacing, want.paragraphSpacing) {
            changes.append(.spaceAfter(Double(shown.paragraphSpacing)))
        }
        var f = format
        for c in changes { f = applying(c, to: f) }

        // Indents, line height and tabs: set as found.
        var new = f.properties
        var fields: Set<ParagraphProperties.Field> = []
        if differ(shown.headIndent, want.headIndent) || differ(shown.firstLineHeadIndent, want.firstLineHeadIndent)
            || (shown.tailIndent <= 0 && differ(shown.tailIndent, want.tailIndent))
        {
            new.indentLeft = Double(shown.headIndent)
            new.firstLine = Double(shown.firstLineHeadIndent - shown.headIndent)
            if shown.tailIndent <= 0 { new.indentRight = Double(-shown.tailIndent) }
            fields.insert(.indentation)
        }
        if differ(shown.lineHeightMultiple, want.lineHeightMultiple)
            || differ(shown.minimumLineHeight, want.minimumLineHeight)
            || differ(shown.maximumLineHeight, want.maximumLineHeight)
        {
            if shown.minimumLineHeight > 0, shown.minimumLineHeight == shown.maximumLineHeight {
                new.line = Double(shown.minimumLineHeight)
                new.lineRule = "exact"
            } else if shown.minimumLineHeight > 0 {
                new.line = Double(shown.minimumLineHeight)
                new.lineRule = "atLeast"
            } else {
                new.line = shown.lineHeightMultiple > 0 ? Double(shown.lineHeightMultiple) : 1
                new.lineRule = "auto"
            }
            fields.insert(.lineSpacing)
        }
        func tabKey(_ t: NSTextTab) -> String { "\(Int((t.location * 20).rounded()))/\(t.alignment.rawValue)" }
        if shown.tabStops.map(tabKey) != want.tabStops.map(tabKey) {
            new.tabs = shown.tabStops.map { t in
                let decimal = t.options[.columnTerminators] != nil
                let alignment =
                    switch t.alignment {
                    case .center: "center"
                    case .right: decimal ? "decimal" : "right"
                    default: "left"
                    }
                return TabStop(position: Double(t.location), alignment: alignment)
            }
            fields.insert(.tabs)
        }
        if !fields.isEmpty { f = f.setting(fields, from: new) }
        return f === format ? nil : f
    }

    static func sameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let a?, let b?):
            if a == b { return true }
            guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
            return abs(x.redComponent - y.redComponent) < 0.004 && abs(x.greenComponent - y.greenComponent) < 0.004
                && abs(x.blueComponent - y.blueComponent) < 0.004 && abs(x.alphaComponent - y.alphaComponent) < 0.004
        }
    }

    /// `RRGGBB` for a chosen colour; nil for the automatic text colour.
    public static func hex(_ color: NSColor) -> String? {
        if color == .textColor || color == .labelColor || color == .controlTextColor { return nil }
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    /// The Word highlight closest to `color`.
    static func nearestHighlight(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "yellow" }
        var best = ("yellow", CGFloat.infinity)
        for (name, h) in highlightColors {
            guard let x = h.usingColorSpace(.sRGB) else { continue }
            let d =
                pow(x.redComponent - c.redComponent, 2) + pow(x.greenComponent - c.greenComponent, 2)
                + pow(x.blueComponent - c.blueComponent, 2)
            if d < best.1 { best = (name, d) }
        }
        return best.0
    }

    // MARK: - Selection state

    public func selectionFormat(
        _ text: NSAttributedString, range: NSRange, typingAttributes: [NSAttributedString.Key: Any]
    ) -> SelectionFormat {
        var out = SelectionFormat()
        let paragraphs = Self.paragraphRanges(in: text, touching: range)
        let formats = paragraphs.map { format(of: text, paragraph: $0) }
        let styleIds = Set(formats.map { $0.properties.styleId ?? styles.defaultParagraphStyleId ?? "" })
        out.styleId = styleIds.count == 1 ? styleIds.first.flatMap { $0.isEmpty ? nil : $0 } : nil
        let effective = formats.map { effectiveParagraph($0.properties) }
        let alignments = Set(effective.map { Self.alignmentName($0.alignment) })
        out.alignment = alignments.count == 1 ? alignments.first : nil
        let lists = Set(
            effective.map { p -> String in p.hasNumbering ? (numbering.isBullet(numId: p.numId!) ? "b" : "n") : "-" })
        if lists.count == 1 {
            out.list = lists.first == "b" ? .bullet : lists.first == "n" ? .numbered : nil
        }
        out.spaceBefore = effective.first?.spaceBefore ?? 0
        out.spaceAfter = effective.first?.spaceAfter ?? 0
        let lines = Set(effective.map { ($0.lineRule ?? "auto") == "auto" ? ($0.line ?? 1) : -1 })
        out.lineSpacing = lines.count == 1 && lines.first! > 0 ? lines.first : nil

        // Spans of the selection, each with its paragraph's style (the typing attributes for a caret).
        var attrsList: [[NSAttributedString.Key: Any]] = []
        var semanticFamilies: [String] = []
        var semanticSizes: [Double] = []
        func collect(_ attrs: [NSAttributedString.Key: Any], styleId: String?) {
            attrsList.append(attrs)
            if attrs[.cartillaOpaque] == nil, let run = attrs[.cartillaRun] as? RunFormat {
                let resolved = styles.resolveRun(paragraphStyle: styleId, direct: run.properties)
                if let family = styles.fontFamily(for: resolved) { semanticFamilies.append(family) }
                semanticSizes.append(resolved.size ?? Double(Self.defaultFontSize))
            } else if let font = attrs[.font] as? NSFont {
                semanticFamilies.append(font.familyName ?? font.fontName)
                semanticSizes.append(Double(font.pointSize))
            }
        }
        let ns = text.string as NSString
        if range.length == 0 || text.length == 0 {
            collect(typingAttributes, styleId: formats.first?.properties.styleId)
        } else {
            for (paragraph, format) in zip(paragraphs, formats) {
                let r = NSIntersectionRange(paragraph, range)
                guard r.length > 0 else { continue }
                text.enumerateAttributes(in: r, options: []) { attrs, span, _ in
                    if span.length == 1, ns.character(at: span.location) == 0x0A { return }
                    collect(attrs, styleId: format.properties.styleId)
                }
            }
            if attrsList.isEmpty { collect(typingAttributes, styleId: formats.first?.properties.styleId) }
        }
        let fonts = attrsList.compactMap { $0[.font] as? NSFont }
        let families = Set(semanticFamilies)
        out.fontFamily = families.count == 1 ? families.first : nil
        let sizes = Set(semanticSizes)
        out.fontSize = sizes.count == 1 ? sizes.first : nil
        let manager = NSFontManager.shared
        out.bold = !fonts.isEmpty && fonts.allSatisfy { manager.traits(of: $0).contains(.boldFontMask) }
        out.italic = !fonts.isEmpty && fonts.allSatisfy { manager.traits(of: $0).contains(.italicFontMask) }
        func on(_ key: NSAttributedString.Key) -> Bool {
            attrsList.allSatisfy { (($0[key] as? Int) ?? 0) != 0 }
        }
        out.underline = on(.underlineStyle)
        out.strike = on(.strikethroughStyle)
        out.color = attrsList.first?[.foregroundColor] as? NSColor
        return out
    }
}

extension ParagraphProperties {
    public init(styleId: String?) {
        self.init()
        self.styleId = styleId
    }
}
