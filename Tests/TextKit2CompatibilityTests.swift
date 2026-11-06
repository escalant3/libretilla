import AppKit
import PDFKit
import XCTest

@testable import Libretilla

/// Tracks TextKit 2 behaviour Libretilla depends on (ADR 0001) and the known gaps listed in
/// `docs/TEXTKIT2_GAPS.md`. Tests named `testGap…` pin a *current limitation*. When one fails,
/// TextKit 2 has improved: update the gap register and remove the workaround.
@MainActor
final class TextKit2CompatibilityTests: XCTestCase {
    // MARK: - Fixtures

    static let pageSize = NSSize(width: 612, height: 792)
    static let margin: CGFloat = 72

    /// ~65k words in 1 000 paragraphs with periodic headings: close to Fixtures/generated/09-large.docx.
    static func largeText() -> NSAttributedString {
        let words = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore"
            .split(separator: " ")
        let body = NSMutableAttributedString()
        let font = NSFont(name: "Helvetica", size: 11)!
        let heading = NSFont(name: "Helvetica-Bold", size: 16)!
        for i in 0..<1000 {
            if i % 25 == 0 {
                body.append(NSAttributedString(string: "Chapter \(i / 25 + 1)\n", attributes: [.font: heading]))
            }
            let para = (0..<65).map { words[($0 * 7 + i * 13) % words.count] }.joined(separator: " ")
            body.append(NSAttributedString(string: para + ".\n", attributes: [.font: font]))
        }
        return body
    }

    static func tableText() -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = 2
        let out = NSMutableAttributedString(string: "Before the table.\n")
        for row in 0..<2 {
            for col in 0..<2 {
                let block = NSTextTableBlock(
                    table: table, startingRow: row, rowSpan: 1, startingColumn: col, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(.black)
                block.setWidth(4, type: .absoluteValueType, for: .padding)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                out.append(NSAttributedString(string: "r\(row)c\(col)\n", attributes: [.paragraphStyle: style]))
            }
        }
        out.append(NSAttributedString(string: "After the table.\n"))
        return out
    }

    static func listText() -> NSAttributedString {
        let list = NSTextList(markerFormat: .disc, options: 0)
        let style = NSMutableParagraphStyle()
        style.textLists = [list]
        return NSAttributedString(string: "\t•\tOne\n\t•\tTwo\n", attributes: [.paragraphStyle: style])
    }

    func makeTextView() -> NSTextView {
        let tv = NSTextView(usingTextLayoutManager: true)
        tv.frame = NSRect(origin: .zero, size: Self.pageSize)
        tv.isVerticallyResizable = true
        tv.textContainerInset = NSSize(width: Self.margin, height: Self.margin)
        return tv
    }

    func report(_ line: String) { print("TEXTKIT2: \(line)") }

    /// Loads `text` through the TK2 content storage without touching TextKit 1 accessors,
    /// lays it out, and reports whether the view fell back to TextKit 1.
    func load(_ text: NSAttributedString, into tv: NSTextView) -> Bool {
        var switched = false
        let token = NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: tv, queue: nil
        ) { _ in MainActor.assumeIsolated { switched = true } }
        defer { NotificationCenter.default.removeObserver(token) }
        tv.textContentStorage?.textStorage?.setAttributedString(text)
        if let tlm = tv.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        tv.layoutSubtreeIfNeeded()
        tv.display()
        return switched || tv.textLayoutManager == nil
    }

    // MARK: - Engine

    func testEditorUsesTextKit2() {
        let editor = EditorViewController()
        editor.loadView()
        XCTAssertNotNil(editor.textView.textLayoutManager)
    }

    func testPlainTextStaysOnTextKit2() {
        XCTAssertFalse(load(NSAttributedString(string: "Plain.\nAnother.\n"), into: makeTextView()))
    }

    func testListsStayOnTextKit2() {
        XCTAssertFalse(load(Self.listText(), into: makeTextView()))
    }

    /// Any access to `.layoutManager` permanently drops a view to TextKit 1. Libretilla code must
    /// never touch it; the editor logs a fault if a fallback ever happens (see `EditorViewController`).
    func testTextKit1AccessorForcesFallback() {
        let tv = makeTextView()
        _ = tv.layoutManager
        XCTAssertNil(tv.textLayoutManager)
    }

    // MARK: - Gap G1: tables

    /// G1: TK2 accepts NSTextTable content without falling back, but ignores the text blocks and
    /// stacks cells as plain paragraphs.
    func testGapTablesAreNotLaidOut() throws {
        let tv = makeTextView()
        XCTAssertFalse(load(Self.tableText(), into: tv), "no fallback")
        let tlm = try XCTUnwrap(tv.textLayoutManager)
        var frames: [String: CGRect] = [:]
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { frag in
            if let p = frag.textElement as? NSTextParagraph {
                frames[p.attributedString.string.trimmingCharacters(in: .newlines)] = frag.layoutFragmentFrame
            }
            return true
        }
        let c00 = try XCTUnwrap(frames["r0c0"])
        let c01 = try XCTUnwrap(frames["r0c1"])
        let sideBySide = abs(c00.minY - c01.minY) < 1 && c01.minX > c00.minX
        report("G1 table cells side by side=\(sideBySide) r0c0=\(c00.integral) r0c1=\(c01.integral)")
        XCTAssertFalse(sideBySide, "TextKit 2 now lays out NSTextTable: close G1 in docs/TEXTKIT2_GAPS.md")
    }

    /// Control for G1: the same content *is* a valid table (TextKit 1 lays it out).
    func testGapTablesControlTextKit1LaysOutTheSameContent() throws {
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.frame = NSRect(origin: .zero, size: Self.pageSize)
        tv.textStorage?.setAttributedString(Self.tableText())
        let lm = try XCTUnwrap(tv.layoutManager)
        let tc = try XCTUnwrap(tv.textContainer)
        lm.ensureLayout(for: tc)
        func rect(_ s: String) -> CGRect {
            let r = (tv.string as NSString).range(of: s)
            return lm.boundingRect(
                forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
        }
        let c00 = rect("r0c0")
        let c01 = rect("r0c1")
        XCTAssertTrue(abs(c00.minY - c01.minY) < 1 && c01.minX > c00.maxX)
    }

    // MARK: - Gap G2: one text container per layout manager

    /// G2: an NSTextLayoutManager has a single `textContainer`. With a container one page tall,
    /// layout fills that page and stops; the rest of the text is never placed, and TextKit 2 has no
    /// TextKit 1-style "continue in the next container". The v1.1 paginated view must build that itself.
    func testGapNoFlowIntoNextPageContainer() throws {
        let storage = NSTextContentStorage()
        let tlm = NSTextLayoutManager()
        storage.addTextLayoutManager(tlm)
        let page = NSSize(width: Self.pageSize.width - 2 * Self.margin, height: Self.pageSize.height - 2 * Self.margin)
        tlm.textContainer = NSTextContainer(size: page)
        storage.textStorage?.setAttributedString(Self.largeText())
        tlm.ensureLayout(for: tlm.documentRange)
        var maxY: CGFloat = 0
        var lastLaidOut = tlm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) {
            maxY = max(maxY, $0.layoutFragmentFrame.maxY)
            lastLaidOut = $0.rangeInElement.endLocation
            return true
        }
        let placed = storage.offset(from: tlm.documentRange.location, to: lastLaidOut)
        let total = storage.offset(from: tlm.documentRange.location, to: tlm.documentRange.endLocation)
        report(
            "G2 one page-sized container: height used=\(Int(maxY))/\(Int(page.height)) chars placed=\(placed)/\(total)")
        XCTAssertLessThanOrEqual(maxY, page.height)
        XCTAssertLessThan(placed, total / 10, "layout now continues past one container: revisit G2")
    }

    // MARK: - Printing / PDF

    func testPrintPaginatesLargeDocument() throws {
        let tv = makeTextView()
        _ = load(Self.largeText(), into: tv)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tk2-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let info = NSPrintInfo()
        info.paperSize = Self.pageSize
        (info.topMargin, info.bottomMargin, info.leftMargin, info.rightMargin) =
            (Self.margin, Self.margin, Self.margin, Self.margin)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        tv.textContainerInset = .zero
        tv.frame.size.width = Self.pageSize.width - 2 * Self.margin
        tv.sizeToFit()
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        XCTAssertTrue(op.run())
        let pages = try XCTUnwrap(PDFDocument(url: url)).pageCount
        report("PDF pages=\(pages)")
        XCTAssertGreaterThan(pages, 100)
        XCTAssertNotNil(tv.textLayoutManager, "printing must not force TextKit 1")
    }

    // MARK: - Typing cost on a large document

    func testEditCostOnLargeDocument() {
        let tv = makeTextView()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        scroll.documentView = tv
        _ = load(Self.largeText(), into: tv)
        let mid = (tv.string as NSString).length / 2
        let start = Date()
        for i in 0..<50 {
            tv.textStorage?.replaceCharacters(in: NSRange(location: mid + i, length: 0), with: "x")
            tv.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        let perKey = Date().timeIntervalSince(start) / 50 * 1000
        report("edit+relayout ms/keystroke=\(String(format: "%.3f", perKey))")
        XCTAssertLessThan(perKey, 16)
        XCTAssertNotNil(tv.textLayoutManager)
    }
}
