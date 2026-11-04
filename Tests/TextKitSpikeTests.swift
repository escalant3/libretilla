import AppKit
import PDFKit
import XCTest

/// Milestone 0 TextKit spike (ADR 0001). Each test checks one fact the decision
/// depends on and prints a `TEXTKIT-SPIKE` line with the measurement.
@MainActor
final class TextKitSpikeTests: XCTestCase {
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

    func makeTextView(textKit2: Bool) -> NSTextView {
        let frame = NSRect(origin: .zero, size: NSSize(width: Self.pageSize.width, height: Self.pageSize.height))
        let tv = textKit2 ? NSTextView(frame: frame) : NSTextView(usingTextLayoutManager: false)
        if !textKit2 { tv.frame = frame }
        tv.isVerticallyResizable = true
        tv.textContainerInset = NSSize(width: Self.margin, height: Self.margin)
        return tv
    }

    func report(_ line: String) { print("TEXTKIT-SPIKE: \(line)") }

    // MARK: - 1. Default engine and compatibility fallback

    func testDefaultTextViewUsesTextKit2() {
        let tv = NSTextView(frame: .zero)
        report("default NSTextView textLayoutManager=\(tv.textLayoutManager != nil)")
        XCTAssertNotNil(tv.textLayoutManager, "macOS 26 NSTextView defaults to TextKit 2")
    }

    /// Loads `text` into a TextKit 2 view through the TK2 content storage, without touching
    /// any TextKit 1 accessor (`layoutManager` itself triggers the fallback), and lays it out.
    func loadsWithoutFallback(_ text: NSAttributedString) -> (switched: Bool, stillTK2: Bool) {
        let tv = makeTextView(textKit2: true)
        var switched = false
        let token = NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: tv, queue: nil
        ) { _ in MainActor.assumeIsolated { switched = true } }
        defer { NotificationCenter.default.removeObserver(token) }
        tv.textContentStorage?.textStorage?.setAttributedString(text)
        if let tlm = tv.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        tv.layoutSubtreeIfNeeded()
        tv.display()
        return (switched, tv.textLayoutManager != nil)
    }

    func testPlainTextStaysOnTextKit2() {
        let r = loadsWithoutFallback(NSAttributedString(string: "Plain paragraph.\nAnother.\n"))
        report("plain text in TK2 view (control): switchNotification=\(r.switched) stillTK2=\(r.stillTK2)")
        XCTAssertTrue(r.stillTK2)
    }

    func testTablesForceFallbackToTextKit1() {
        let r = loadsWithoutFallback(Self.tableText())
        report("NSTextTable in TK2 view: switchNotification=\(r.switched) stillTK2=\(r.stillTK2)")
        // Recorded rather than asserted: on macOS 26.5 this stays on TextKit 2 (see ADR 0001).
    }

    /// Does TextKit 2 actually *lay out* the table (cells side by side), or merely tolerate it?
    func testTextKit2TableGeometryAndEditing() throws {
        let tv = makeTextView(textKit2: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = tv
        tv.textContentStorage?.textStorage?.setAttributedString(Self.tableText())
        let tlm = try XCTUnwrap(tv.textLayoutManager)
        tlm.ensureLayout(for: tlm.documentRange)
        var frames: [String: CGRect] = [:]
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { frag in
            if let p = frag.textElement as? NSTextParagraph {
                let key = p.attributedString.string.trimmingCharacters(in: .newlines)
                frames[key] = frag.layoutFragmentFrame
            }
            return true
        }
        let c00 = try XCTUnwrap(frames["r0c0"]), c01 = try XCTUnwrap(frames["r0c1"]),
            c10 = try XCTUnwrap(frames["r1c0"])
        let sideBySide = abs(c00.minY - c01.minY) < 1 && c01.minX > c00.minX
        report(
            "TK2 table geometry: r0c0=\(c00.integral) r0c1=\(c01.integral) r1c0=\(c10.integral) sideBySide=\(sideBySide)"
        )

        // Type into the first cell, as a user would.
        let cellStart = (tv.string as NSString).range(of: "r0c0").location
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: cellStart + 4, length: 0))
        tv.insertText(" typed", replacementRange: tv.selectedRange())
        tv.insertNewline(nil)
        tv.layoutSubtreeIfNeeded()
        report("TK2 table after typing + newline in a cell: stillTK2=\(tv.textLayoutManager != nil)")
        // Pinned finding (macOS 26.5): TK2 accepts NSTextTable without falling back but
        // ignores the blocks and stacks cells as plain paragraphs. If this starts failing,
        // TextKit 2 gained table layout: revisit ADR 0001.
        XCTAssertFalse(sideBySide, "TextKit 2 now lays out NSTextTable; revisit ADR 0001")
    }

    func testTextKit1TableGeometry() throws {
        let tv = makeTextView(textKit2: false)
        tv.textStorage?.setAttributedString(Self.tableText())
        let lm = try XCTUnwrap(tv.layoutManager), tc = try XCTUnwrap(tv.textContainer)
        lm.ensureLayout(for: tc)
        func rect(_ s: String) -> CGRect {
            let r = (tv.string as NSString).range(of: s)
            return lm.boundingRect(
                forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
        }
        let c00 = rect("r0c0"), c01 = rect("r0c1"), c10 = rect("r1c0")
        let sideBySide = abs(c00.minY - c01.minY) < 1 && c01.minX > c00.maxX
        report(
            "TK1 table geometry: r0c0=\(c00.integral) r0c1=\(c01.integral) r1c0=\(c10.integral) sideBySide=\(sideBySide)"
        )
        XCTAssertTrue(sideBySide)
        XCTAssertGreaterThan(c10.minY, c00.maxY)
    }

    func testTextKit1AccessorForcesFallback() {
        let tv = makeTextView(textKit2: true)
        _ = tv.layoutManager
        report("touching .layoutManager on TK2 view: stillTK2=\(tv.textLayoutManager != nil)")
        XCTAssertNil(tv.textLayoutManager)
    }

    func testListsStayOnTextKit2() {
        let r = loadsWithoutFallback(Self.listText())
        report("NSTextList in TK2 view: switchNotification=\(r.switched) stillTK2=\(r.stillTK2)")
        XCTAssertTrue(r.stillTK2)
    }

    // MARK: - 2. Pagination for print / PDF export

    func pdfPageCount(for tv: NSTextView, label: String) throws -> Int {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spike-\(label)-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let info = NSPrintInfo()
        info.paperSize = Self.pageSize
        info.topMargin = Self.margin
        info.bottomMargin = Self.margin
        info.leftMargin = Self.margin
        info.rightMargin = Self.margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        tv.textContainerInset = .zero
        tv.frame.size.width = Self.pageSize.width - 2 * Self.margin
        tv.sizeToFit()
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        let start = Date()
        XCTAssertTrue(op.run())
        let pages = try XCTUnwrap(PDFDocument(url: url)).pageCount
        report("PDF \(label): pages=\(pages) seconds=\(String(format: "%.2f", Date().timeIntervalSince(start)))")
        return pages
    }

    func testPrintPaginationTextKit1() throws {
        let tv = makeTextView(textKit2: false)
        tv.textStorage?.setAttributedString(Self.largeText())
        XCTAssertGreaterThan(try pdfPageCount(for: tv, label: "TK1 large"), 100)
    }

    func testPrintPaginationTextKit2() throws {
        let tv = makeTextView(textKit2: true)
        tv.textStorage?.setAttributedString(Self.largeText())
        let pages = try pdfPageCount(for: tv, label: "TK2 large")
        report("TK2 view still TK2 after print=\(tv.textLayoutManager != nil)")
        XCTAssertGreaterThan(pages, 100)
    }

    func testPrintTableTextKit1() throws {
        let tv = makeTextView(textKit2: false)
        tv.textStorage?.setAttributedString(Self.tableText())
        XCTAssertEqual(try pdfPageCount(for: tv, label: "TK1 table"), 1)
    }

    // MARK: - 3. Multi-container page layout (needed for the v1.1 paginated view)

    func testTextKit1FlowsAcrossPageContainers() {
        let storage = NSTextStorage(attributedString: Self.largeText())
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let body = NSSize(width: Self.pageSize.width - 2 * Self.margin, height: Self.pageSize.height - 2 * Self.margin)
        let start = Date()
        var containers = 0
        repeat {
            lm.addTextContainer(NSTextContainer(size: body))
            containers += 1
            lm.ensureLayout(for: lm.textContainers.last!)
        } while NSMaxRange(lm.glyphRange(for: lm.textContainers.last!)) < lm.numberOfGlyphs && containers < 1000
        report(
            "TK1 multi-container pages=\(containers) seconds=\(String(format: "%.2f", Date().timeIntervalSince(start)))"
        )
        XCTAssertGreaterThan(containers, 100)
        XCTAssertLessThan(containers, 1000)
    }

    func testTextKit2HasSingleContainer() {
        // API fact: NSTextLayoutManager exposes exactly one `textContainer`; paginated layout
        // requires one layout manager per page or custom viewport/fragment placement.
        let tlm = NSTextLayoutManager()
        tlm.textContainer = NSTextContainer(size: Self.pageSize)
        XCTAssertNotNil(tlm.textContainer)
        report("TK2 NSTextLayoutManager containers=1 (API)")
    }

    // MARK: - 4. Edit + relayout cost on a large document (typing-latency proxy)

    func editCost(textKit2: Bool) -> Double {
        let tv = makeTextView(textKit2: textKit2)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        scroll.documentView = tv
        tv.textStorage?.setAttributedString(Self.largeText())
        if !textKit2 { tv.layoutManager?.allowsNonContiguousLayout = true }
        tv.layoutSubtreeIfNeeded()
        let mid = (tv.string as NSString).length / 2
        let start = Date()
        for i in 0..<50 {
            tv.textStorage?.replaceCharacters(in: NSRange(location: mid + i, length: 0), with: "x")
            if textKit2, let tlm = tv.textLayoutManager {
                tlm.textViewportLayoutController.layoutViewport()
            } else {
                tv.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: mid, length: 200))
            }
        }
        let perKey = Date().timeIntervalSince(start) / 50 * 1000
        report(
            "edit+relayout \(textKit2 ? "TK2" : "TK1") ms/keystroke=\(String(format: "%.3f", perKey)) tk2=\(tv.textLayoutManager != nil)"
        )
        return perKey
    }

    func testEditCostTextKit1() { XCTAssertLessThan(editCost(textKit2: false), 16) }
    func testEditCostTextKit2() { XCTAssertLessThan(editCost(textKit2: true), 16) }
}
