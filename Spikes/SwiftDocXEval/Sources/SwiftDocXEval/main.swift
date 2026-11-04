// SwiftDocX evaluation harness (Milestone 0, ADR 0002).
//
//   swift run SwiftDocXEval [--fixtures <dir>] [--out <dir>] [--results <file.md>] [--pages]
//
// For every fixture it:
//   1. probes the source package (ground truth, DocxProbe);
//   2. reads it with SwiftDocX and records what the model captured;
//   3. writes it back with SwiftDocX two ways:
//        naive   – `Document(contentsOf:)` then `write(to:)`, exactly what an app would do;
//        rebuilt – same, but first copies `paragraphs` into `elements` (a workaround,
//                  because the reader fills only `paragraphs` while the writer emits `elements`);
//   4. probes each output, diffs parts against the source, and re-reads it with SwiftDocX;
//   5. optionally opens each output in Pages (smoke test for "opens without repair").
// Then it authors a document with SwiftDocX's own API and checks that path as well.
// The results go to RESULTS.md.

import DocxProbe
import Foundation
import SwiftDocX

// MARK: - Arguments

let spikeDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let repoRoot = spikeDir.deletingLastPathComponent().deletingLastPathComponent()

var fixturesDir = repoRoot.appendingPathComponent("Fixtures/generated")
var outDir = spikeDir.appendingPathComponent("out")
var resultsFile = spikeDir.appendingPathComponent("RESULTS.md")
var usePages = false
do {
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--fixtures": fixturesDir = URL(fileURLWithPath: args.next()!)
        case "--out": outDir = URL(fileURLWithPath: args.next()!)
        case "--results": resultsFile = URL(fileURLWithPath: args.next()!)
        case "--pages": usePages = true
        default: FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8)); exit(2)
        }
    }
}

let fm = FileManager.default
try? fm.removeItem(at: outDir)
for sub in ["naive", "rebuilt", "authored"] {
    try fm.createDirectory(at: outDir.appendingPathComponent(sub), withIntermediateDirectories: true)
}

// MARK: - Model summary

struct ModelSummary {
    var paragraphs = 0, elements = 0, runs = 0
    var tables = 0, headings = 0, listItems = 0, hyperlinks = 0, images = 0
    var bold = 0, italic = 0, underline = 0, strike = 0, color = 0, highlight = 0, fontSize = 0, font = 0,
        vertAlign = 0
    var alignment = 0, spacing = 0, indentation = 0, pageBreaks = 0
    var hasHeader = false, hasFooter = false
    var text = ""
    var words: Int { DocxProbe.wordCount(text) }

    init(_ doc: Document) {
        paragraphs = doc.paragraphs.count
        elements = doc.elements.count
        tables = doc.tables.count
        hasHeader = doc.header != nil
        hasFooter = doc.footer != nil
        text = doc.paragraphs.map(\.text).joined(separator: "\n")
        for p in doc.paragraphs {
            if p.headingLevel != nil { headings += 1 }
            if p.listType != nil { listItems += 1 }
            if p.alignment != nil { alignment += 1 }
            if p.spacing != ParagraphSpacing() { spacing += 1 }
            if p.indentation != ParagraphIndentation() { indentation += 1 }
            if p.pageBreakBefore { pageBreaks += 1 }
            for r in p.runs {
                runs += 1
                let f = r.formatting
                if f.bold { bold += 1 }
                if f.italic { italic += 1 }
                if f.underline != nil { underline += 1 }
                if f.strikethrough { strike += 1 }
                if f.color != nil { color += 1 }
                if f.highlight != nil { highlight += 1 }
                if f.fontSize != nil { fontSize += 1 }
                if f.font != nil { font += 1 }
                if f.superscript || f.subscriptText { vertAlign += 1 }
                if r.hyperlink != nil { hyperlinks += 1 }
                if r.image != nil { images += 1 }
            }
        }
    }
}

// MARK: - Pages smoke test

@MainActor func pagesOpens(_ url: URL) -> String {
    guard usePages else { return "–" }
    let script = repoRoot.appendingPathComponent("scripts/fixtures/pages_roundtrip.applescript")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = [script.path, url.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return "error" }
    p.waitUntilExit()
    let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if p.terminationStatus != 0 { return "❌ \(s.split(separator: ":").last.map(String.init) ?? s)" }
    // "words=185 pages=1" → "✅ 185 w"
    let words = s.split(separator: " ").first?.replacingOccurrences(of: "words=", with: "") ?? "?"
    return "✅ \(words) w"
}

// MARK: - Evaluation

struct OutputResult {
    var probe: DocxProbe
    var diff: PackageDiff
    var rereadWords: Int
    var pages: String
}

struct FixtureResult {
    var name: String
    var source: DocxProbe
    var readError: String?
    var readMillis: Double = 0
    var model: ModelSummary?
    var naive: OutputResult?
    var rebuilt: OutputResult?
    var writeError: String?
}

@MainActor func evaluateOutput(_ url: URL, source: DocxProbe) throws -> OutputResult {
    let probe = try DocxProbe(url: url)
    let reread = (try? Document(contentsOf: url)).map { ModelSummary($0).words } ?? -1
    return OutputResult(
        probe: probe, diff: PackageDiff(from: source, to: probe), rereadWords: reread, pages: pagesOpens(url))
}

let fixtures = try fm.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "docx" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

var results: [FixtureResult] = []
let clock = ContinuousClock()
for url in fixtures {
    let name = url.lastPathComponent
    print("• \(name)")
    var r = FixtureResult(name: name, source: try DocxProbe(url: url))
    do {
        var doc: Document!
        let elapsed = try clock.measure { doc = try Document(contentsOf: url) }
        r.readMillis = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        r.model = ModelSummary(doc)

        let naiveURL = outDir.appendingPathComponent("naive/\(name)")
        try doc.write(to: naiveURL)
        r.naive = try evaluateOutput(naiveURL, source: r.source)

        doc.elements = doc.paragraphs.map { .paragraph($0) }
        let rebuiltURL = outDir.appendingPathComponent("rebuilt/\(name)")
        try doc.write(to: rebuiltURL)
        r.rebuilt = try evaluateOutput(rebuiltURL, source: r.source)
    } catch {
        if r.model == nil { r.readError = "\(error)" } else { r.writeError = "\(error)" }
    }
    results.append(r)
}

// MARK: - Authoring through SwiftDocX's own API

print("• authoring")
let authored = Document()
authored.properties = DocumentProperties(title: "SwiftDocX authoring probe", language: "es-ES")
authored.addHeading1("Título con eñe")
authored.addParagraph("Texto ").runs.append(Run(text: "negrita", formatting: TextFormatting(bold: true)))
authored.addHeading("Heading 4", level: .heading4)
authored.addBulletItem("Bullet level 0")
authored.addBulletItem("Bullet level 1", level: 1)
authored.addNumberedItem("Numbered 1")
authored.addNumberedItem("Numbered 1.a", level: 1)
let table = authored.addTable(from: [["Name", "Qty"], ["Apples", "3"]], hasHeader: true)
table.rows[1].cells[0].backgroundColor = .yellow
authored.addHyperlink(url: "https://example.com/?a=1&b=2", text: "example")
let png = try Data(contentsOf: repoRoot.appendingPathComponent("scripts/fixtures/assets/photo.jpg"))
authored.addImage(DocImage(data: png, fileExtension: "jpeg", width: 120, height: 80))
authored.addPageBreak()
authored.addParagraph("After page break")
authored.setHeader("Header text", alignment: .right)
authored.setFooterWithPageNumbersAndTotal()
let authoredURL = outDir.appendingPathComponent("authored/authored.docx")
try authored.write(to: authoredURL)
let authoredProbe = try DocxProbe(url: authoredURL)
let authoredBack = ModelSummary(try Document(contentsOf: authoredURL))
let authoredPages = pagesOpens(authoredURL)
let authoredSelf = ModelSummary(authored)

// MARK: - Report

func n(_ p: DocxProbe, _ f: Feature) -> Int { p.features[f] ?? 0 }
func cell(_ src: Int, _ got: Int) -> String {
    if src == 0 && got == 0 { return "·" }
    if got >= src { return "\(got)/\(src) ✅" }
    if got == 0 { return "0/\(src) ❌" }
    return "\(got)/\(src) ⚠️"
}

var md = """
    # SwiftDocX evaluation: results

    _Generated by `swift run SwiftDocXEval\(usePages ? " --pages" : "")` against SwiftDocX **1.0.2** and \
    `Fixtures/generated/`. Don't edit by hand; ADR 0002 interprets these results._

    Legend: `got/source` counts. ✅ fully kept, ⚠️ partially kept, ❌ lost, · not present in the fixture.

    ## 1. Read: what the SwiftDocX model captures

    The "source" counts come from `DocxProbe`, an independent scan of `word/document.xml`.

    | Fixture | Read | ms | Words | Paragraphs | Headings | List items | Tables | Hyperlinks | Images | Page breaks | Header/footer |
    |---|---|---:|---|---|---|---|---|---|---|---|---|

    """
for r in results {
    let s = r.source
    guard let m = r.model else {
        md += "| \(r.name) | ❌ \(r.readError ?? "") | | | | | | | | | | |\n"
        continue
    }
    let hf =
        (n(s, .headerReference) + n(s, .footerReference)) == 0
        ? "·" : ((m.hasHeader || m.hasFooter) ? "✅" : "0/\(n(s, .headerReference) + n(s, .footerReference)) ❌")
    md +=
        "| \(r.name) | ✅ | \(String(format: "%.1f", r.readMillis)) | \(cell(s.words, m.words)) "
        + "| \(cell(n(s, .paragraph), m.paragraphs)) | \(cell(n(s, .headingParagraph), m.headings)) "
        + "| \(cell(n(s, .listParagraph), m.listItems)) | \(cell(n(s, .table), m.tables)) "
        + "| \(cell(n(s, .hyperlink), m.hyperlinks)) | \(cell(n(s, .imageBlip), m.images)) "
        + "| \(cell(n(s, .pageBreak), m.pageBreaks)) | \(hf) |\n"
}

md += """

    Character and paragraph formatting captured (runs and paragraphs that carry the property):

    | Fixture | Bold | Italic | Underline | Strike | Colour | Highlight | Size | Font | Super/sub | Align | Spacing | Indent |
    |---|---|---|---|---|---|---|---|---|---|---|---|---|

    """
for r in results {
    guard let m = r.model else { continue }
    let s = r.source
    md +=
        "| \(r.name) | \(cell(n(s, .bold), m.bold)) | \(cell(n(s, .italic), m.italic)) "
        + "| \(cell(n(s, .underline), m.underline)) | \(cell(n(s, .strike), m.strike)) "
        + "| \(cell(n(s, .color), m.color)) | \(cell(n(s, .highlight), m.highlight)) "
        + "| \(cell(n(s, .fontSize), m.fontSize)) | \(cell(n(s, .fonts), m.font)) "
        + "| \(cell(n(s, .vertAlign), m.vertAlign)) | \(cell(n(s, .alignment), m.alignment)) "
        + "| \(cell(n(s, .spacing), m.spacing)) | \(cell(n(s, .indentation), m.indentation)) |\n"
}

@MainActor func roundTripTable(_ title: String, _ pick: (FixtureResult) -> OutputResult?) -> String {
    var s = """

        ## \(title)

        | Fixture | Words out | Parts kept byte-identical | Parts changed | Parts dropped | Parts added | Re-read words | Package problems | Pages |
        |---|---|---|---|---|---|---|---|---|

        """
    for r in results {
        guard let o = pick(r) else {
            s += "| \(r.name) | ❌ \(r.writeError ?? r.readError ?? "") | | | | | | | |\n"
            continue
        }
        let problems = o.probe.packageProblems.count + o.probe.malformedParts.count
        s +=
            "| \(r.name) | \(cell(r.source.words, o.probe.words)) | \(o.diff.identical.count)/\(r.source.parts.count) "
            + "| \(o.diff.changed.count) | \(o.diff.dropped.count) | \(o.diff.added.count) "
            + "| \(o.rereadWords) | \(problems == 0 ? "none" : "\(problems) ❌") | \(o.pages) |\n"
    }
    return s
}

md += roundTripTable("2. Naive open → save (`Document(contentsOf:)` → `write(to:)`)") { $0.naive }
md += roundTripTable("3. Workaround open → save (`elements` rebuilt from `paragraphs`)") { $0.rebuilt }

md += """

    ### Body features lost on the workaround save

    A feature is listed when the source has it and the saved file has fewer instances (`saved/source`).

    | Fixture | Lost or reduced |
    |---|---|

    """
for r in results {
    guard let o = r.rebuilt else { continue }
    let losses = Feature.allCases.compactMap { f -> String? in
        let a = n(r.source, f), b = n(o.probe, f)
        return a > 0 && b < a ? "`\(f.rawValue)` \(b)/\(a)" : nil
    }
    md += "| \(r.name) | \(losses.isEmpty ? "none" : losses.joined(separator: ", ")) |\n"
}

md += """

    ### Parts dropped on save (union over the corpus)

    Every part below exists in at least one source fixture and is missing from SwiftDocX's output.

    """
var droppedUnion: [String: [String]] = [:]
for r in results { for p in r.rebuilt?.diff.dropped ?? [] { droppedUnion[p, default: []].append(r.name) } }
for (part, files) in droppedUnion.sorted(by: { $0.key < $1.key }) {
    md += "- `\(part)`: \(files.count) fixture\(files.count == 1 ? "" : "s")\n"
}
let changedAlways = Set(results.compactMap { $0.rebuilt?.diff.changed }.joined())
md +=
    "\nParts always rewritten from scratch (never byte-identical): "
    + changedAlways.sorted().map { "`\($0)`" }.joined(separator: ", ") + ".\n"

md += """

    ## 4. Authoring with SwiftDocX's API (write side only)

    A document built with `addHeading…`, `addBulletItem`, `addNumberedItem`, `addTable`, `addHyperlink`, `addImage`,
    `addPageBreak`, `setHeader` and `setFooterWithPageNumbersAndTotal`, then probed, opened in Pages, and read back.

    | Feature | In written file (probe) | Read back by SwiftDocX |
    |---|---|---|
    | Words | \(authoredProbe.words) | \(authoredBack.words) / \(authoredSelf.words) |
    | Heading paragraphs (`w:pStyle` Heading*) | \(n(authoredProbe, .headingParagraph)) | \(authoredBack.headings) |
    | List paragraphs (`w:numPr`) | \(n(authoredProbe, .listParagraph)) | \(authoredBack.listItems) |
    | Tables | \(n(authoredProbe, .table)) | \(authoredBack.tables) |
    | Cell shading | \(n(authoredProbe, .cellShading)) | – |
    | Hyperlinks | \(n(authoredProbe, .hyperlink)) | \(authoredBack.hyperlinks) |
    | Images (`a:blip`) | \(n(authoredProbe, .imageBlip)) | \(authoredBack.images) |
    | Header / footer references | \(n(authoredProbe, .headerReference)) / \(n(authoredProbe, .footerReference)) | \(authoredBack.hasHeader) / \(authoredBack.hasFooter) |
    | Fields in footer (PAGE, NUMPAGES) | \(authoredProbe.features(inPart: "word/footer1.xml")[.complexField] ?? 0) | – |
    | Package problems | \(authoredProbe.packageProblems.isEmpty && authoredProbe.malformedParts.isEmpty ? "none" : (authoredProbe.packageProblems + authoredProbe.malformedParts.map { "\($0.key): \($0.value)" }).joined(separator: "; ")) | |
    | Opens in Pages | \(authoredPages) | |

    Parts written: \(authoredProbe.partNames.map { "`\($0)`" }.joined(separator: ", ")).

    """

let problemsAll = results.flatMap { r in (r.rebuilt?.probe.packageProblems ?? []).map { "\(r.name): \($0)" } }
if !problemsAll.isEmpty {
    md += "\n## 5. Package problems found in outputs\n\n" + problemsAll.map { "- \($0)" }.joined(separator: "\n") + "\n"
}

try md.write(to: resultsFile, atomically: true, encoding: .utf8)
print("Wrote \(resultsFile.path)")
