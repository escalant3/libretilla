import Foundation

/// `numbering.xml`: list definitions. Kept as its source bytes. Libretilla only appends to it, when
/// the user starts a new list, so existing definitions are never rewritten.
public struct Numbering: Sendable {
    public struct Level: Sendable, Equatable {
        public var start = 1
        /// `decimal`, `bullet`, `lowerLetter`, `upperRoman`, … (`ST_NumberFormat`).
        public var format = "decimal"
        /// e.g. `%1.` or `%1.%2.`; for bullets, the bullet character.
        public var text = "%1."
        public var indentLeft: Double?
        /// Negative for hanging.
        public var firstLine: Double?
        /// Bullet font (`Symbol`, `Wingdings`, …), used to map private-use bullet characters.
        public var font: String?
        /// Which higher level restarts this one (1-based, as in `w:lvlRestart`); nil means "the previous".
        public var restartAfter: Int?
    }

    public struct AbstractNum: Sendable {
        public var levels: [Int: Level] = [:]
    }

    public struct Num: Sendable {
        public var abstractId: Int
        public var startOverrides: [Int: Int] = [:]
        public var levelOverrides: [Int: Level] = [:]
    }

    public private(set) var xml: Data?
    public private(set) var abstractNums: [Int: AbstractNum] = [:]
    public private(set) var nums: [Int: Num] = [:]

    public init() {}

    public init(xml: Data?) throws {
        self.xml = xml
        guard let xml else { return }
        let root = try RawXML.Document(data: xml, part: "numbering").root
        for a in root.childElements(named: "w:abstractNum") {
            guard let id = a.attribute("w:abstractNumId").flatMap({ Int($0) }) else { continue }
            var abstract = AbstractNum()
            for l in a.childElements(named: "w:lvl") {
                guard let i = l.attribute("w:ilvl").flatMap({ Int($0) }) else { continue }
                abstract.levels[i] = Self.parseLevel(l)
            }
            abstractNums[id] = abstract
        }
        for n in root.childElements(named: "w:num") {
            guard let id = n.attribute("w:numId").flatMap({ Int($0) }),
                let abstractId = n.firstChild(named: "w:abstractNumId")?.attribute("w:val").flatMap({ Int($0) })
            else { continue }
            var num = Num(abstractId: abstractId)
            for o in n.childElements(named: "w:lvlOverride") {
                guard let i = o.attribute("w:ilvl").flatMap({ Int($0) }) else { continue }
                if let s = o.firstChild(named: "w:startOverride")?.attribute("w:val").flatMap({ Int($0) }) {
                    num.startOverrides[i] = s
                }
                if let l = o.firstChild(named: "w:lvl") { num.levelOverrides[i] = Self.parseLevel(l) }
            }
            nums[id] = num
        }
    }

    static func parseLevel(_ l: RawXML.Element) -> Level {
        var level = Level()
        if let s = l.firstChild(named: "w:start")?.attribute("w:val").flatMap({ Int($0) }) { level.start = s }
        if let f = l.firstChild(named: "w:numFmt")?.attribute("w:val") { level.format = f }
        if let t = l.firstChild(named: "w:lvlText")?.attribute("w:val") { level.text = t }
        if let r = l.firstChild(named: "w:lvlRestart")?.attribute("w:val").flatMap({ Int($0) }) {
            level.restartAfter = r
        }
        let p = ParagraphProperties(l.firstChild(named: "w:pPr"))
        level.indentLeft = p.indentLeft
        level.firstLine = p.firstLine
        level.font = RunProperties(l.firstChild(named: "w:rPr")).font
        return level
    }

    public func level(numId: Int, ilvl: Int) -> Level? {
        guard let num = nums[numId] else { return nil }
        if let o = num.levelOverrides[ilvl] { return o }
        return abstractNums[num.abstractId]?.levels[ilvl]
    }

    public func isBullet(numId: Int) -> Bool {
        level(numId: numId, ilvl: 0)?.format == "bullet"
    }

    // MARK: - Counting

    /// Word's list counters, fed one paragraph at a time in document order.
    public struct Counter: Sendable {
        let numbering: Numbering
        /// Counters are shared by every `w:num` of one abstract definition (that's how Word continues
        /// numbering across instances); a `w:startOverride` restarts them when its instance first appears.
        var values: [Int: [Int: Int]] = [:]
        var seenNums = Set<Int>()

        public init(_ numbering: Numbering) { self.numbering = numbering }

        /// The marker for the next list item, or nil if `numId`/`ilvl` don't name a list.
        public mutating func next(numId: Int, ilvl: Int) -> String? {
            guard numId != 0, let num = numbering.nums[numId], let level = numbering.level(numId: numId, ilvl: ilvl)
            else { return nil }
            let key = num.abstractId
            var counts = values[key] ?? [:]
            if seenNums.insert(numId).inserted {
                for (i, s) in num.startOverrides { counts[i] = s - 1 }
            }
            counts[ilvl] = (counts[ilvl] ?? (level.start - 1)) + 1
            // Deeper levels restart (unless their w:lvlRestart says otherwise).
            for (deeper, _) in counts where deeper > ilvl {
                let restart = numbering.level(numId: numId, ilvl: deeper)?.restartAfter
                if restart == nil || restart! > ilvl { counts[deeper] = nil }
            }
            values[key] = counts
            if level.format == "bullet" { return Numbering.bulletText(level) }
            var text = level.text
            for i in 0...8 where text.contains("%\(i + 1)") {
                let l = numbering.level(numId: numId, ilvl: i) ?? Level()
                let n = counts[i] ?? l.start
                text = text.replacingOccurrences(of: "%\(i + 1)", with: Numbering.format(n, l.format))
            }
            return text
        }
    }

    /// Word's private-use bullets (Symbol/Wingdings) shown as Unicode.
    static func bulletText(_ level: Level) -> String {
        let t = level.text
        guard let scalar = t.unicodeScalars.first else { return "" }
        switch (level.font, scalar.value) {
        case (_, 0xF0B7), ("Symbol", 0xB7): return "•"
        case (_, 0xF0A7), ("Wingdings", 0xA7): return "▪"
        case (_, 0xF0D8), ("Wingdings", 0xD8): return "➢"
        case (_, 0xF0FC), ("Wingdings", 0xFC): return "✓"
        case (_, 0xF076), ("Wingdings", 0x76): return "❖"
        case ("Courier New", 0x6F): return "◦"
        default: return scalar.value >= 0xF000 && scalar.value <= 0xF0FF ? "•" : t
        }
    }

    public static func format(_ n: Int, _ format: String) -> String {
        switch format {
        case "lowerLetter": letters(n, upper: false)
        case "upperLetter": letters(n, upper: true)
        case "lowerRoman": roman(n).lowercased()
        case "upperRoman": roman(n)
        case "decimalZero": n < 10 ? "0\(n)" : "\(n)"
        case "none": ""
        default: "\(n)"
        }
    }

    /// Word's letter numbering: a…z, then aa…zz, aaa….
    static func letters(_ n: Int, upper: Bool) -> String {
        guard n > 0 else { return "" }
        let base = Character(upper ? "A" : "a").asciiValue!
        let letter = Character(UnicodeScalar(base + UInt8((n - 1) % 26)))
        return String(repeating: letter, count: (n - 1) / 26 + 1)
    }

    static func roman(_ n: Int) -> String {
        guard n > 0, n < 4000 else { return "\(n)" }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var n = n
        var out = ""
        for (v, s) in table {
            while n >= v {
                out += s
                n -= v
            }
        }
        return out
    }

    // MARK: - Adding lists

    public enum ListKind: Sendable { case bullet, numbered }

    /// A new list instance (`w:num`) for `kind`, appended to the part. Bulleted lists share one
    /// Libretilla definition; each numbered list restarts at 1.
    public mutating func addList(_ kind: ListKind) -> Int {
        let abstractId = libretillaAbstract(kind) ?? addAbstract(kind)
        let numId = (nums.keys.max() ?? 0) + 1
        var num = "<w:num w:numId=\"\(numId)\"><w:abstractNumId w:val=\"\(abstractId)\"/>"
        if kind == .numbered { num += "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride>" }
        num += "</w:num>"
        insert(num, before: ["w:numIdMacAtCleanup"])
        return numId
    }

    /// Marks Libretilla's own definitions so later lists reuse them.
    static func nsid(_ kind: ListKind) -> String { kind == .bullet ? "CA471B01" : "CA471D01" }

    func libretillaAbstract(_ kind: ListKind) -> Int? {
        guard let xml, let root = try? RawXML.Document(data: xml).root else { return nil }
        return root.childElements(named: "w:abstractNum").first {
            $0.firstChild(named: "w:nsid")?.attribute("w:val") == Self.nsid(kind)
        }?.attribute("w:abstractNumId").flatMap { Int($0) }
    }

    mutating func addAbstract(_ kind: ListKind) -> Int {
        let id = (abstractNums.keys.max() ?? -1) + 1
        var xml =
            "<w:abstractNum w:abstractNumId=\"\(id)\"><w:nsid w:val=\"\(Self.nsid(kind))\"/>"
            + "<w:multiLevelType w:val=\"hybridMultilevel\"/>"
        let bullets = ["•", "◦", "▪"]
        let formats = ["decimal", "lowerLetter", "lowerRoman"]
        for i in 0..<9 {
            let left = 720 * (i + 1)
            let (fmt, text) = kind == .bullet ? ("bullet", bullets[i % 3]) : (formats[i % 3], "%\(i + 1).")
            xml +=
                "<w:lvl w:ilvl=\"\(i)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(fmt)\"/>"
                + "<w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/>"
                + "<w:pPr><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }
        xml += "</w:abstractNum>"
        // Every w:abstractNum must come before the first w:num.
        insert(xml, before: ["w:num", "w:numIdMacAtCleanup"])
        return id
    }

    /// Inserts `element` before the first root child named in `before`, else at the end.
    mutating func insert(_ element: String, before: [String]) {
        var bytes = Data([UInt8](xml ?? Self.emptyPart))
        guard let root = try? RawXML.Document(data: bytes).root else { return }
        var at = root.endTagRange.lowerBound
        if let first = root.childElements.first(where: { before.contains($0.name) }) { at = first.range.lowerBound }
        if root.endTagRange.isEmpty {
            // `<w:numbering …/>`: rebuild with an explicit end tag.
            bytes = Self.emptyPart
            self = (try? Numbering(xml: bytes)) ?? self
            insert(element, before: before)
            return
        }
        bytes.insert(contentsOf: Data(element.utf8), at: at)
        if let reparsed = try? Numbering(xml: bytes) { self = reparsed }
    }

    static let emptyPart = Data(
        ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n"
            + "<w:numbering xmlns:w=\"\(wordprocessingMLNamespace)\"></w:numbering>").utf8)
}
