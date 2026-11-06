import Foundation
import Testing
import ZIPFoundation

/// Confirms the dependency is wired up and reads our corpus. Real codec tests arrive in M1.
@Suite struct ZIPFoundationSmokeTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/generated/01-plain.docx")

    @Test func readsAFixturePackage() throws {
        let archive = try Archive(url: Self.fixture, accessMode: .read)
        let names = Set(archive.map(\.path))
        #expect(names.contains("[Content_Types].xml"))
        #expect(names.contains("word/document.xml"))
        let entry = try #require(archive["word/document.xml"])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        #expect(String(decoding: data, as: UTF8.self).contains("plain paragraph"))
    }
}
