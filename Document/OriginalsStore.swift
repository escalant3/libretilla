import CryptoKit
import Foundation
import os

/// Private copies of documents as they were before Libretilla first saved over them (ADR 0004).
/// Lives in the app's sandbox container; copies older than 30 days are pruned at launch.
struct OriginalsStore: Sendable {
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    static let shared = OriginalsStore()
    private static let log = Logger(subsystem: "app.libretilla.Libretilla", category: "Originals")

    struct Entry: Codable, Sendable, Equatable {
        var originalPath: String
        var sha256: String
        var file: String
        var date: Date
    }

    let directory: URL

    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Libretilla/Originals", isDirectory: true)
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func write(_ entries: [Entry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: indexURL, options: .atomic)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stores `data` as the original of `fileURL`, unless an identical copy is already kept.
    @discardableResult
    func keepOriginal(_ data: Data, of fileURL: URL, now: Date = Date()) throws -> Entry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var all = entries()
        let hash = Self.sha256(data)
        if let existing = all.first(where: { $0.sha256 == hash && $0.originalPath == fileURL.path }) {
            return existing
        }
        let file = "\(hash.prefix(16))-\(fileURL.lastPathComponent)"
        try data.write(to: directory.appendingPathComponent(file), options: .atomic)
        let entry = Entry(originalPath: fileURL.path, sha256: hash, file: file, date: now)
        all.append(entry)
        try write(all)
        Self.log.info("Kept original of \(fileURL.lastPathComponent, privacy: .private)")
        return entry
    }

    /// The most recent original kept for `fileURL`.
    func latestOriginal(of fileURL: URL) -> (Entry, URL)? {
        entries().filter { $0.originalPath == fileURL.path }.max { $0.date < $1.date }
            .map { ($0, directory.appendingPathComponent($0.file)) }
    }

    /// Deletes copies older than the retention period.
    func prune(now: Date = Date()) {
        let all = entries()
        let keep = all.filter { now.timeIntervalSince($0.date) < Self.retention }
        guard keep.count != all.count else { return }
        for old in all where !keep.contains(old) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.file))
        }
        try? write(keep)
    }
}
