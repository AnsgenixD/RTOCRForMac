//
//  TranslationManager.swift
//  Overlay
//
//  Created by Ansgenix  on 02/08/26.
//

import Foundation
import Translation // Apple's Native Translation Framework (macOS 15+)
import SQLite3     // Native macOS C-library for SQLite

class TranslationManager {
    static let shared = TranslationManager()

    private var db: OpaquePointer?

    // The actual translation backend. Selected in Settings (persisted in
    // UserDefaults) and re-read before each request so a Settings change
    // takes effect immediately without restarting the app.
    private var provider: TranslationProvider {
        switch TranslationBackend.current {
        case .appleMT:
            return AppleTranslationProvider()
        case .deepl:
            // Guard against a persisted DeepL choice with no key configured
            // (e.g. Secrets.swift placeholder) — silently fall back to Apple MT.
            guard DeepLTranslationProvider.keyIsConfigured else { return AppleTranslationProvider() }
            return DeepLTranslationProvider()
        }
    }

    // Tracks lines currently being translated so a line still visible across
    // several 50ms capture cycles doesn't spawn a new Apple MT request every
    // single frame while the first one is still in flight.
    private var inFlight = Set<String>()
    private let inFlightQueue = DispatchQueue(label: "TranslationManager.inFlight")

    init() {
        setupLocalSQLiteDB()
    }

    // Make function accessible (not private) so OCRManager can call it directly!
    func checkLocalDatabase(for text: String) -> String? {
        // 1. Try exact SQLite Query
        if let queryResult = querySQLite(japaneseText: text) {
            return queryResult
        }

        // 2. Fallback sample hardcoded dictionary
        let sampleDB: [String: String] = [
            "こんにちは世界": "Hello World",
            "設定メニューを開く": "Open Settings Menu",
            "魔王城の封印が解除された": "The seal on the Demon Lord's Castle has been broken!"
        ]

        return sampleDB[text]
    }

    /// Main entry point used by OCRManager. Returns immediately with a cached hit
    /// if one exists; otherwise hands off to the user-selected TranslationProvider
    /// (Apple MT by default, DeepL if configured — see Settings) and caches the
    /// result. Cache lookup + in-flight dedup live here so every provider gets
    /// them for free.
    func translate(japaneseText: String) async -> (text: String, source: String) {
        print("🔤 translate() called for: \"\(japaneseText)\"")

        if let localTranslation = checkLocalDatabase(for: japaneseText) {
            print("🔤 → Local DB hit: \"\(localTranslation)\"")
            return (localTranslation, "Local DB")
        }

        let alreadyInFlight: Bool = inFlightQueue.sync {
            if inFlight.contains(japaneseText) { return true }
            inFlight.insert(japaneseText)
            return false
        }
        if alreadyInFlight {
            print("🔤 → already in flight, skipping duplicate request")
            return (japaneseText, "Raw OCR — translation pending")
        }
        defer {
            inFlightQueue.sync { inFlight.remove(japaneseText) }
        }

        let result = await provider.translate(japaneseText)

        // Cache successful provider output (source label starting with "Raw OCR"
        // means the provider fell back to the original text — nothing to cache).
        if !result.source.hasPrefix("Raw OCR") && result.text != japaneseText {
            insertOrUpdateSQLite(japanese: japaneseText, english: result.text)
        }
        return result
    }

    /// Manual "improve this translation" trigger — call this when the user
    /// explicitly requests a better translation for one specific block
    /// (e.g. a double-tap/right-click gesture in ContentView). Uses DeepL,
    /// which is generally stronger than Apple MT on short, context-free
    /// OCR lines. Updates the block in place via PanelData once it resolves,
    /// and overwrites the SQLite cache entry so future detections of the
    /// same line get the improved version for free.
    func improveTranslation(for blockId: String, originalText: String) {
        guard DeepLTranslationProvider.keyIsConfigured else {
            print("⚠️ Set your DeepL API key in Secrets.swift before using improveTranslation()")
            DispatchQueue.main.async {
                PanelData.shared.statusText = "DeepL not configured — add your API key in Secrets.swift"
            }
            return
        }

        Task {
            do {
                let improved = try await DeepLTranslationProvider.callDeepL(text: originalText)
                insertOrUpdateSQLite(japanese: originalText, english: improved)

                await MainActor.run {
                    PanelData.shared.updateBlockText(id: blockId, newText: improved, source: "DeepL (improved)")
                    PanelData.shared.statusText = "Source: DeepL (improved)"
                }
            } catch {
                print("⚠️ DeepL improve failed: \(error)")
            }
        }
    }

    // --- Native SQLite Implementation ---

    private func setupLocalSQLiteDB() {
        // Creates a local SQLite database file in the app's Document Directory
        guard let docURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not access Documents directory")
            return
        }
        let fileURL = docURL.appendingPathComponent("MORT_Translations.sqlite")

        if sqlite3_open(fileURL.path, &db) == SQLITE_OK {
            let createTableQuery = "CREATE TABLE IF NOT EXISTS translations (id INTEGER PRIMARY KEY AUTOINCREMENT, japanese TEXT UNIQUE, english TEXT);"
            sqlite3_exec(db, createTableQuery, nil, nil, nil)
        }
    }

    private func querySQLite(japaneseText: String) -> String? {
        let queryStatementString = "SELECT english FROM translations WHERE japanese = ? LIMIT 1;"
        var queryStatement: OpaquePointer?
        var result: String? = nil

        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(queryStatement, 1, (japaneseText as NSString).utf8String, -1, nil)

            if sqlite3_step(queryStatement) == SQLITE_ROW {
                if let queryResultCol = sqlite3_column_text(queryStatement, 0) {
                    result = String(cString: queryResultCol)
                }
            }
        }
        sqlite3_finalize(queryStatement)
        return result
    }

    private func updateUI(original: String, translated: String, source: String) {
        DispatchQueue.main.async {
            PanelData.shared.statusText = "Source: \(source)"
        }
    }
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
}

extension TranslationManager {

    /// Imports a JSON dictionary file (Format: {"Jap": "Eng"}) into SQLite
    func importDictionary(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            print("❌ Failed to parse imported dictionary file")
            return
        }

        // Insert parsed entries into SQLite
        for (jp, en) in dict {
            insertOrUpdateSQLite(japanese: jp, english: en)
        }

        print("✅ Successfully imported \(dict.count) translation pairs!")
    }

    /// Exports the local SQLite cache to a shareable JSON file
    func exportCache(to url: URL) {
        let queryStatementString = "SELECT japanese, english FROM translations;"
        var queryStatement: OpaquePointer?
        var exportDict: [String: String] = [:]

        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                if let jp = sqlite3_column_text(queryStatement, 0),
                   let en = sqlite3_column_text(queryStatement, 1) {
                    exportDict[String(cString: jp)] = String(cString: en)
                }
            }
        }
        sqlite3_finalize(queryStatement)

        if let jsonData = try? JSONSerialization.data(withJSONObject: exportDict, options: .prettyPrinted) {
            try? jsonData.write(to: url)
            print("✅ Exported database to \(url.path)")
        }
    }

    func insertOrUpdateSQLite(japanese: String, english: String) {
        let insertStatementString = "INSERT OR REPLACE INTO translations (japanese, english) VALUES (?, ?);"
        var insertStatement: OpaquePointer?

        if sqlite3_prepare_v2(db, insertStatementString, -1, &insertStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(insertStatement, 1, (japanese as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 2, (english as NSString).utf8String, -1, nil)
            sqlite3_step(insertStatement)
        }
        sqlite3_finalize(insertStatement)
    }

    /// Empties the SQLite translation cache ("Reset Translation Cache" menu
    /// item). The caller (Overlay menu) is responsible for the confirmation
    /// alert — this is destructive and unrecoverable.
    func clearCache() {
        let deleteStatementString = "DELETE FROM translations;"
        if sqlite3_exec(db, deleteStatementString, nil, nil, nil) == SQLITE_OK {
            print("🗑️ Translation cache cleared")
        } else {
            print("❌ Failed to clear translation cache")
        }
    }

}
