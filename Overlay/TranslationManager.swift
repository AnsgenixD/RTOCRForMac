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

    /*Put your DeepL API key here (get one at https://www.deepl.com/pro-api).
     Free tier keys end in ":fx" and must hit api-free.deepl.com, not api.deepl.com.
     DeepL key lives in Secrets.swift (gitignored — see README) so a real key never gets committed to the public repo. Secrets.swift just
     needs to define: let deepLAPIKeyValue = "your-real-key-here" */
    
    private let deepLAPIKey = "deepLAPIKeyValue"
    private var deepLIsFreeTier = true

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
    /// if one exists; otherwise runs Apple's on-device translation and returns
    /// the result. This is the function that was previously never being called —
    /// OCRManager was calling checkLocalDatabase() directly and using its `nil`
    /// fallback (raw Japanese text) whenever nothing was cached.
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

        if #available(macOS 15.0, *) {
            let sourceLang = Locale.Language(identifier: "ja")
            let targetLang = Locale.Language(identifier: "en")

            let availability = LanguageAvailability()
            let status = await availability.status(from: sourceLang, to: targetLang)
            print("🔤 → LanguageAvailability status: \(status)")

            switch status {
            case .installed:
                do {
                    let session = TranslationSession(installedSource: sourceLang, target: targetLang)
                    let response = try await session.translate(japaneseText)
                    print("🔤 → Apple MT SUCCESS: \"\(response.targetText)\"")
                    insertOrUpdateSQLite(japanese: japaneseText, english: response.targetText)
                    return (response.targetText, "Apple MT")
                } catch {
                    print("⚠️ Apple Translation failed even though marked installed: \(error)")
                    return (japaneseText, "Raw OCR")
                }

            case .supported:
                print("🔤 → status is .supported, NOT .installed — pack shows in Settings but system doesn't consider it ready")
                await MainActor.run {
                    PanelData.shared.statusText = "Japanese language pack not installed — download it in System Settings → General → Language & Region → Translation Languages"
                }
                return (japaneseText, "Raw OCR — JA pack missing")

            case .unsupported:
                print("🔤 → status is .unsupported")
                return (japaneseText, "Raw OCR — unsupported pair")

            @unknown default:
                print("🔤 → status is unknown case")
                return (japaneseText, "Raw OCR")
            }
        } else {
            print("🔤 → macOS < 15, Translation framework unavailable")
            return (japaneseText, "Raw OCR")
        }
    }

    /// Manual "improve this translation" trigger — call this when the user
    /// explicitly requests a better translation for one specific block
    /// (e.g. a double-tap/right-click gesture in ContentView). Uses DeepL,
    /// which is generally stronger than Apple MT on short, context-free
    /// OCR lines. Updates the block in place via PanelData once it resolves,
    /// and overwrites the SQLite cache entry so future detections of the
    /// same line get the improved version for free.
    func improveTranslation(for blockId: String, originalText: String) {
        guard deepLAPIKey != "YOUR_DEEPL_API_KEY_HERE" else {
            print("⚠️ Set your DeepL API key in TranslationManager before using improveTranslation()")
            return
        }

        Task {
            do {
                let improved = try await callDeepL(text: originalText)
                insertOrUpdateSQLite(japanese: originalText, english: improved)

                await MainActor.run {
                    PanelData.shared.updateBlockText(id: blockId, newText: improved)
                    PanelData.shared.statusText = "Source: DeepL (improved)"
                }
            } catch {
                print("⚠️ DeepL improve failed: \(error)")
            }
        }
    }

    private func callDeepL(text: String) async throws -> String {
        let host = deepLIsFreeTier ? "api-free.deepl.com" : "api.deepl.com"
        guard let url = URL(string: "https://\(host)/v2/translate") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(deepLAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "text": text,
            "source_lang": "JA",
            "target_lang": "EN-US"
        ]
        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        struct DeepLResponse: Decodable {
            struct Translation: Decodable { let text: String }
            let translations: [Translation]
        }

        let decoded = try JSONDecoder().decode(DeepLResponse.self, from: data)
        guard let translated = decoded.translations.first?.text else {
            throw URLError(.cannotParseResponse)
        }
        return translated
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

}
