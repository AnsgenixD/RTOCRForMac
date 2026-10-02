//
//  TranslationManager.swift
//  Overlay
//
//  Created by Ansgenix on 02/08/26.
//

import Foundation
import Translation // Apple's Native Translation Framework (macOS 15+)
import SQLite3     // Native macOS C-library for SQLite

class TranslationManager {
    static let shared = TranslationManager()

    private var db: OpaquePointer?
    
    /// Dedicated serial queue for all SQLite operations to guarantee strict thread safety
    /// and prevent "illegal multi-threaded access to database connection" crashes.
    private let dbQueue = DispatchQueue(label: "com.rtocr.databaseQueue", qos: .userInitiated)

    /// Fast L1 thread-safe in-memory cache to eliminate repetitive disk queries during game playback.
    private var memoryCache: [String: String] = [:]
    private let memoryCacheLock = NSLock()

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

    /// In-flight translation deduplication: if multiple concurrent OCR frames
    /// or subtitle blocks request translation for the exact same text, they join
    /// the same in-flight Task instead of spawning redundant API calls or returning dummy placeholders.
    private var inFlightTasks: [String: Task<(text: String, source: String), Never>] = [:]
    private let inFlightLock = NSLock()

    init() {
        setupLocalSQLiteDB()
    }

    // Make function accessible (not private) so OCRManager can call it directly!
    func checkLocalDatabase(for text: String) -> String? {
        // 1. Check ultra-fast L1 memory cache first (< 0.001 ms, zero disk I/O)
        memoryCacheLock.lock()
        if let memoryHit = memoryCache[text] {
            memoryCacheLock.unlock()
            return memoryHit
        }
        memoryCacheLock.unlock()

        // 2. Check hardcoded sample dictionary
        let sampleDB: [String: String] = [
            "こんにちは世界": "Hello World",
            "設定メニューを開く": "Open Settings Menu",
            "魔王城の封印が解除された": "The seal on the Demon Lord's Castle has been broken!"
        ]
        if let sampleHit = sampleDB[text] {
            return sampleHit
        }

        // 3. Fallback: Query persistent SQLite on dedicated serial queue
        let diskHit = dbQueue.sync { [weak self] () -> String? in
            guard let self = self else { return nil }
            return self.querySQLite(japaneseText: text)
        }

        if let diskHit = diskHit {
            // Populate memory cache so future frames hit L1 immediately
            memoryCacheLock.lock()
            memoryCache[text] = diskHit
            memoryCacheLock.unlock()
            return diskHit
        }

        return nil
    }

    /// Main entry point used by OCRManager. Returns immediately with a cached hit
    /// if one exists; otherwise hands off to the user-selected TranslationProvider
    /// (Apple MT by default, DeepL if configured — see Settings) and caches the
    /// result. In-flight task coalescing ensures that concurrent frames seamlessly
    /// share the same async request.
    func translate(japaneseText: String) async -> (text: String, source: String) {
        if let localTranslation = checkLocalDatabase(for: japaneseText) {
            return (localTranslation, "Local DB")
        }

        // Check or register in-flight Task
        inFlightLock.lock()
        let task: Task<(text: String, source: String), Never>
        let isInitiator: Bool

        if let existingTask = inFlightTasks[japaneseText] {
            task = existingTask
            isInitiator = false
        } else {
            let activeProvider = self.provider
            let newTask = Task { () -> (text: String, source: String) in
                return await activeProvider.translate(japaneseText)
            }
            inFlightTasks[japaneseText] = newTask
            task = newTask
            isInitiator = true
        }
        inFlightLock.unlock()

        // Await translation result
        let result = await task.value

        // Only the initiating Task is responsible for cleanup & caching
        if isInitiator {
            inFlightLock.lock()
            inFlightTasks.removeValue(forKey: japaneseText)
            inFlightLock.unlock()

            // Cache successful provider output
            if !result.source.hasPrefix("Raw OCR") && result.text != japaneseText {
                insertOrUpdateSQLite(japanese: japaneseText, english: result.text)
            }
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

    // --- Thread-Safe Native SQLite Implementation ---

    private func setupLocalSQLiteDB() {
        dbQueue.sync { [weak self] in
            guard let self = self else { return }

            guard let docURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first else {
                print("❌ Could not access Documents directory")
                return
            }
            let fileURL = docURL.appendingPathComponent("MORT_Translations.sqlite")

            // Open with SQLITE_OPEN_FULLMUTEX to enforce serialized thread safety inside SQLite
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            if sqlite3_open_v2(fileURL.path, &self.db, flags, nil) == SQLITE_OK {
                // Enable WAL mode and NORMAL synchronous mode for high-throughput, non-blocking reads
                sqlite3_exec(self.db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
                sqlite3_exec(self.db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)

                let createTableQuery = "CREATE TABLE IF NOT EXISTS translations (id INTEGER PRIMARY KEY AUTOINCREMENT, japanese TEXT UNIQUE, english TEXT);"
                sqlite3_exec(self.db, createTableQuery, nil, nil, nil)

                // Warm up in-memory cache with existing saved translations
                let queryStatementString = "SELECT japanese, english FROM translations;"
                var queryStatement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
                    self.memoryCacheLock.lock()
                    while sqlite3_step(queryStatement) == SQLITE_ROW {
                        if let jp = sqlite3_column_text(queryStatement, 0),
                           let en = sqlite3_column_text(queryStatement, 1) {
                            self.memoryCache[String(cString: jp)] = String(cString: en)
                        }
                    }
                    self.memoryCacheLock.unlock()
                }
                sqlite3_finalize(queryStatement)
            } else {
                print("❌ Failed to open SQLite database at \(fileURL.path)")
            }
        }
    }

    /// Internal query method. Must always be executed within dbQueue!
    private func querySQLite(japaneseText: String) -> String? {
        guard let db = self.db else { return nil }
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

    deinit {
        dbQueue.sync { [weak self] in
            if let db = self?.db {
                sqlite3_close(db)
                self?.db = nil
            }
        }
    }
}

extension TranslationManager {

    /// Thread-safe insert or update: updates in-memory cache synchronously,
    /// then asynchronously commits to SQLite on the serial dbQueue without stalling calling threads.
    func insertOrUpdateSQLite(japanese: String, english: String) {
        // 1. Immediately update L1 memory cache
        memoryCacheLock.lock()
        memoryCache[japanese] = english
        memoryCacheLock.unlock()

        // 2. Offload disk write to serial dbQueue asynchronously
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

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

    /// Imports a JSON dictionary file (Format: {"Jap": "Eng"}) into SQLite using an atomic transaction.
    func importDictionary(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            print("❌ Failed to parse imported dictionary file")
            return
        }

        // Update memory cache
        memoryCacheLock.lock()
        for (jp, en) in dict {
            memoryCache[jp] = en
        }
        memoryCacheLock.unlock()

        // Batch insert in a single SQLite transaction on dbQueue
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            let insertStatementString = "INSERT OR REPLACE INTO translations (japanese, english) VALUES (?, ?);"
            var insertStatement: OpaquePointer?

            if sqlite3_prepare_v2(db, insertStatementString, -1, &insertStatement, nil) == SQLITE_OK {
                for (jp, en) in dict {
                    sqlite3_bind_text(insertStatement, 1, (jp as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(insertStatement, 2, (en as NSString).utf8String, -1, nil)
                    sqlite3_step(insertStatement)
                    sqlite3_reset(insertStatement)
                }
            }
            sqlite3_finalize(insertStatement)
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            print("✅ Successfully imported and committed \(dict.count) translation pairs!")
        }
    }

    /// Exports the local SQLite cache to a shareable JSON file safely on dbQueue
    func exportCache(to url: URL) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

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
    }

    /// Empties the SQLite translation cache ("Reset Translation Cache" menu item).
    func clearCache() {
        memoryCacheLock.lock()
        memoryCache.removeAll()
        memoryCacheLock.unlock()

        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let deleteStatementString = "DELETE FROM translations;"
            if sqlite3_exec(db, deleteStatementString, nil, nil, nil) == SQLITE_OK {
                print("🗑️ Translation cache cleared")
            } else {
                print("❌ Failed to clear translation cache")
            }
        }
    }
}
