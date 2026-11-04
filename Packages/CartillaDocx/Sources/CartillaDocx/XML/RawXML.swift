import Foundation

/// A small, lossless XML reader for OOXML parts.
///
/// Unlike `XMLParser`, every node records the **byte range** it came from, so unedited content
/// can be re-emitted verbatim (ADR 0002). It handles the XML that Office files use: elements,
/// attributes, character data, entity and character references, CDATA, comments and processing
/// instructions. DTDs are rejected (no entity expansion: OOXML never needs it).
public enum RawXML {
    public struct Document: Sendable {
        public let bytes: Data
        public let root: Element

        public init(data: Data, part: String = "?") throws {
            self.bytes = data
            var parser = Parser(bytes: [UInt8](data), part: part)
            self.root = try parser.parseDocument()
        }

        public func slice(_ range: Range<Int>) -> Data {
            bytes.subdata(in: (bytes.startIndex + range.lowerBound)..<(bytes.startIndex + range.upperBound))
        }
    }

    public struct Attribute: Sendable, Equatable {
        public var name: String
        public var value: String
    }

    public struct Element: Sendable {
        public var name: String
        public var attributes: [Attribute]
        public var children: [Node]
        /// Byte range of the whole element, from `<` of the start tag to `>` of the end tag.
        public var range: Range<Int>
        /// Byte range of the start tag (equal to `range` when self-closing).
        public var startTagRange: Range<Int>
        /// Byte range of the end tag; empty at `range.upperBound` when self-closing.
        public var endTagRange: Range<Int>

        public func attribute(_ name: String) -> String? {
            attributes.first { $0.name == name }?.value
        }

        public var childElements: [Element] {
            children.compactMap { if case .element(let e) = $0 { e } else { nil } }
        }

        public func childElements(named name: String) -> [Element] {
            childElements.filter { $0.name == name }
        }

        public func firstChild(named name: String) -> Element? {
            for case .element(let e) in children where e.name == name { return e }
            return nil
        }

        /// Depth-first search, including `self`.
        public func descendants(named name: String) -> [Element] {
            var out: [Element] = []
            func walk(_ e: Element) {
                if e.name == name { out.append(e) }
                for c in e.childElements { walk(c) }
            }
            walk(self)
            return out
        }

        /// Concatenated character data of this element's direct text children.
        public var text: String {
            children.compactMap { if case .text(let t) = $0 { t.value } else { nil } }.joined()
        }
    }

    public struct Text: Sendable {
        public var value: String
        public var range: Range<Int>
        public var isWhitespace: Bool { value.allSatisfy { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" } }
    }

    public enum Node: Sendable {
        case element(Element)
        case text(Text)
        /// Comments and processing instructions.
        case other(Range<Int>)

        public var range: Range<Int> {
            switch self {
            case .element(let e): e.range
            case .text(let t): t.range
            case .other(let r): r
            }
        }
    }

    // MARK: - Escaping

    public static func escapeText(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    public static func escapeAttribute(_ s: String) -> String {
        escapeText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Parser

    struct Parser {
        let b: [UInt8]
        let part: String
        var i = 0

        init(bytes: [UInt8], part: String) {
            self.b = bytes
            self.part = part
        }

        func fail(_ reason: String) -> DocxCodecError {
            .malformedXML(part: part, reason: "\(reason) at byte \(i)")
        }

        func hasPrefix(_ s: StaticString) -> Bool {
            let n = s.utf8CodeUnitCount
            guard i + n <= b.count else { return false }
            return s.withUTF8Buffer { buf in
                for k in 0..<n where b[i + k] != buf[k] { return false }
                return true
            }
        }

        mutating func skip(past terminator: StaticString) throws {
            while i < b.count {
                if hasPrefix(terminator) {
                    i += terminator.utf8CodeUnitCount
                    return
                }
                i += 1
            }
            throw fail("unterminated construct")
        }

        static func isNameByte(_ c: UInt8) -> Bool {
            !(c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x2F || c == 0x3E || c == 0x3D
                || c == 0x3C || c == 0x22 || c == 0x27)
        }

        static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

        mutating func skipSpace() { while i < b.count, Self.isSpace(b[i]) { i += 1 } }

        mutating func name() throws -> String {
            let start = i
            while i < b.count, Self.isNameByte(b[i]) { i += 1 }
            guard i > start else { throw fail("expected a name") }
            return String(decoding: b[start..<i], as: UTF8.self)
        }

        func decode(_ range: Range<Int>) throws -> String {
            let raw = b[range]
            guard raw.contains(0x26) else { return String(decoding: raw, as: UTF8.self) }  // no '&'
            var out = [UInt8]()
            out.reserveCapacity(raw.count)
            var k = range.lowerBound
            while k < range.upperBound {
                let c = b[k]
                guard c == 0x26 else {
                    out.append(c)
                    k += 1
                    continue
                }
                guard let semi = b[k..<range.upperBound].firstIndex(of: 0x3B) else {
                    throw DocxCodecError.malformedXML(part: part, reason: "bad entity at byte \(k)")
                }
                let entity = String(decoding: b[(k + 1)..<semi], as: UTF8.self)
                let scalar: Unicode.Scalar?
                switch entity {
                case "lt": scalar = "<"
                case "gt": scalar = ">"
                case "amp": scalar = "&"
                case "quot": scalar = "\""
                case "apos": scalar = "'"
                default:
                    if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                        scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
                    } else if entity.hasPrefix("#") {
                        scalar = UInt32(entity.dropFirst(1)).flatMap(Unicode.Scalar.init)
                    } else {
                        scalar = nil
                    }
                }
                guard let scalar else {
                    throw DocxCodecError.malformedXML(part: part, reason: "unknown entity &\(entity);")
                }
                out.append(contentsOf: Array(String(scalar).utf8))
                k = semi + 1
            }
            return String(decoding: out, as: UTF8.self)
        }

        mutating func attributes() throws -> [Attribute] {
            var attrs: [Attribute] = []
            while true {
                skipSpace()
                guard i < b.count else { throw fail("unterminated tag") }
                if b[i] == 0x2F || b[i] == 0x3E { return attrs }  // '/' or '>'
                let n = try name()
                skipSpace()
                guard i < b.count, b[i] == 0x3D else { throw fail("expected '='") }
                i += 1
                skipSpace()
                guard i < b.count, b[i] == 0x22 || b[i] == 0x27 else { throw fail("expected a quote") }
                let quote = b[i]
                i += 1
                let start = i
                while i < b.count, b[i] != quote { i += 1 }
                guard i < b.count else { throw fail("unterminated attribute") }
                attrs.append(Attribute(name: n, value: try decode(start..<i)))
                i += 1
            }
        }

        private struct Open {
            var name: String
            var attributes: [Attribute]
            var children: [Node]
            var start: Int
            var startTagEnd: Int
        }

        mutating func parseDocument() throws -> Element {
            var stack: [Open] = []
            var root: Element?
            while i < b.count {
                let start = i
                if b[i] != 0x3C {  // character data
                    while i < b.count, b[i] != 0x3C { i += 1 }
                    if !stack.isEmpty {
                        stack[stack.count - 1].children.append(
                            .text(Text(value: try decode(start..<i), range: start..<i)))
                    } else if !b[start..<i].allSatisfy(Self.isSpace) {
                        throw fail("text outside the root element")
                    }
                    continue
                }
                if hasPrefix("<?") {
                    try skip(past: "?>")
                    if !stack.isEmpty { stack[stack.count - 1].children.append(.other(start..<i)) }
                } else if hasPrefix("<!--") {
                    try skip(past: "-->")
                    if !stack.isEmpty { stack[stack.count - 1].children.append(.other(start..<i)) }
                } else if hasPrefix("<![CDATA[") {
                    let contentStart = i + 9
                    try skip(past: "]]>")
                    guard !stack.isEmpty else { throw fail("CDATA outside the root element") }
                    let value = String(decoding: b[contentStart..<(i - 3)], as: UTF8.self)
                    stack[stack.count - 1].children.append(.text(Text(value: value, range: start..<i)))
                } else if hasPrefix("<!") {
                    throw DocxCodecError.unsupported("XML with a DTD (\(part))")
                } else if hasPrefix("</") {
                    i += 2
                    let n = try name()
                    skipSpace()
                    guard i < b.count, b[i] == 0x3E else { throw fail("expected '>'") }
                    i += 1
                    guard let open = stack.popLast(), open.name == n else { throw fail("mismatched </\(n)>") }
                    let element = Element(
                        name: open.name, attributes: open.attributes, children: open.children,
                        range: open.start..<i, startTagRange: open.start..<open.startTagEnd,
                        endTagRange: start..<i)
                    if stack.isEmpty {
                        root = element
                    } else {
                        stack[stack.count - 1].children.append(.element(element))
                    }
                } else {
                    i += 1
                    let n = try name()
                    let attrs = try attributes()
                    if b[i] == 0x2F {  // '/>'
                        guard i + 1 < b.count, b[i + 1] == 0x3E else { throw fail("expected '/>'") }
                        i += 2
                        let element = Element(
                            name: n, attributes: attrs, children: [], range: start..<i, startTagRange: start..<i,
                            endTagRange: i..<i)
                        if stack.isEmpty {
                            root = element
                        } else {
                            stack[stack.count - 1].children.append(.element(element))
                        }
                    } else {
                        i += 1
                        stack.append(Open(name: n, attributes: attrs, children: [], start: start, startTagEnd: i))
                    }
                }
                if root != nil && stack.isEmpty {
                    // Allow trailing comments/PIs/whitespace after the root element.
                    skipSpace()
                    while i < b.count {
                        if hasPrefix("<?") {
                            try skip(past: "?>")
                        } else if hasPrefix("<!--") {
                            try skip(past: "-->")
                        } else {
                            throw fail("content after the root element")
                        }
                        skipSpace()
                    }
                }
            }
            guard stack.isEmpty else { throw fail("unclosed <\(stack.last!.name)>") }
            guard let root else { throw fail("no root element") }
            return root
        }
    }
}
