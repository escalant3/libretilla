import Foundation
import Testing

@testable import LibretillaDocx

enum Corpus {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let generated = root.appendingPathComponent("Fixtures/generated")

    static var all: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: generated, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "docx" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: generated.appendingPathComponent(name))
    }
}

/// Minimal OPC sanity checks: the things that most often make Word show a "repair" prompt.
enum PackageChecker {
    static func problems(_ data: Data) throws -> [String] {
        let package = try OPCPackage(data: data)
        var problems: [String] = []
        for part in package.parts where part.name.hasSuffix(".xml") || part.name.hasSuffix(".rels") {
            do { _ = try RawXML.Document(data: part.data, part: part.name) } catch {
                problems.append("\(part.name): \(error)")
            }
        }
        guard let ct = package["[Content_Types].xml"] else { return problems + ["no [Content_Types].xml"] }
        let types = try RawXML.Document(data: ct).root
        let defaults = Set(types.childElements(named: "Default").compactMap { $0.attribute("Extension")?.lowercased() })
        let overrides = Set(types.childElements(named: "Override").compactMap { $0.attribute("PartName") })
        for name in package.partNames where name != "[Content_Types].xml" {
            let ext = name.split(separator: "/").last?.split(separator: ".").last.map { $0.lowercased() } ?? ""
            if !overrides.contains("/" + name) && !defaults.contains(ext) {
                problems.append("no content type: \(name)")
            }
        }
        for o in overrides where package[String(o.dropFirst())] == nil { problems.append("override for missing \(o)") }
        for rels in package.partNames where rels.hasSuffix(".rels") {
            let owner =
                rels == "_rels/.rels"
                ? ""
                : rels.replacingOccurrences(of: "_rels/", with: "")
                    .replacingOccurrences(of: ".rels", with: "")
            for rel in try package.relationships(of: owner) where !rel.isExternal {
                if let target = rel.resolvedPartName, package[target] == nil {
                    problems.append("\(rels): dangling \(rel.id) → \(rel.target)")
                }
            }
        }
        return problems
    }
}
