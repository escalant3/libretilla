import Foundation
import Testing

@testable import CartillaDocx

@Suite struct RawXMLTests {
    @Test func keepsByteRangesAndDecodesEntities() throws {
        let xml = Data(#"<?xml version="1.0"?><a x="1 &amp; 2"><b>T&lt;&#233;&#x1F600;</b><c/><!-- n --></a>"#.utf8)
        let doc = try RawXML.Document(data: xml)
        #expect(doc.root.name == "a")
        #expect(doc.root.attribute("x") == "1 & 2")
        let b = try #require(doc.root.firstChild(named: "b"))
        #expect(b.text == "T<é😀")
        #expect(String(decoding: doc.slice(b.range), as: UTF8.self) == "<b>T&lt;&#233;&#x1F600;</b>")
        let c = try #require(doc.root.firstChild(named: "c"))
        #expect(String(decoding: doc.slice(c.range), as: UTF8.self) == "<c/>")
        #expect(c.endTagRange.isEmpty)
    }

    @Test func cdataBecomesText() throws {
        let doc = try RawXML.Document(data: Data("<a><![CDATA[x < y]]></a>".utf8))
        #expect(doc.root.text == "x < y")
    }

    @Test func rejectsMalformedAndDTD() {
        #expect(throws: DocxCodecError.self) { try RawXML.Document(data: Data("<a><b></a>".utf8)) }
        #expect(throws: DocxCodecError.self) { try RawXML.Document(data: Data("<a>".utf8)) }
        #expect(throws: DocxCodecError.self) { try RawXML.Document(data: Data("<!DOCTYPE a []><a/>".utf8)) }
        #expect(throws: DocxCodecError.self) { try RawXML.Document(data: Data("<a>&bogus;</a>".utf8)) }
    }

    @Test func escaping() {
        #expect(RawXML.escapeText("a<b>&c") == "a&lt;b&gt;&amp;c")
        #expect(RawXML.escapeAttribute("\"q\"") == "&quot;q&quot;")
    }
}
