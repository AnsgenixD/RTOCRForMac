//
//  TranslationProviders.swift
//  Overlay
//
//  Roadmap: "define a TranslationProvider protocol now so adding backends
//  later doesn't require touching call sites." TranslationManager owns the
//  cache + in-flight dedup and delegates the actual translation to whichever
//  provider the user picked in Settings (persisted in UserDefaults).
//

import Foundation
import Translation

// MARK: - Backend selection (persisted in UserDefaults)

enum TranslationBackend: String, CaseIterable, Identifiable {
    case appleMT   // default — on-device, offline, free
    case deepl     // requires an API key in Secrets.swift

    var id: String { rawValue }

    /// UserDefaults key shared by SettingsView (@AppStorage) and TranslationManager.
    static let storageKey = "translationBackend"

    var displayName: String {
        switch self {
        case .appleMT: return "Apple Translation (on-device)"
        case .deepl: return "DeepL (requires API key)"
        }
    }

    /// The user's persisted choice, falling back to Apple MT.
    static var current: TranslationBackend {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? appleMT.rawValue
        return TranslationBackend(rawValue: raw) ?? .appleMT
    }
}

// MARK: - Provider protocol

protocol TranslationProvider {
    var name: String { get }
    /// Translates `text` (Japanese) to English. Returns the translated string
    /// and a short source label for display (e.g. "Apple MT", "DeepL").
    func translate(_ text: String) async -> (text: String, source: String)
}

// MARK: - Apple Translation (default)

final class AppleTranslationProvider: TranslationProvider {
    let name = "Apple MT"

    func translate(_ text: String) async -> (text: String, source: String) {
        guard #available(macOS 15.0, *) else {
            print("🔤 → macOS < 15, Translation framework unavailable")
            return (text, "Raw OCR")
        }

        let sourceLang = Locale.Language(identifier: "ja")
        let targetLang = Locale.Language(identifier: "en")

        let availability = LanguageAvailability()
        let status = await availability.status(from: sourceLang, to: targetLang)
        print("🔤 → LanguageAvailability status: \(status)")

        switch status {
        case .installed:
            do {
                let session = TranslationSession(installedSource: sourceLang, target: targetLang)
                let response = try await session.translate(text)
                print("🔤 → Apple MT SUCCESS: \"\(response.targetText)\"")
                return (response.targetText, "Apple MT")
            } catch {
                print("⚠️ Apple Translation failed even though marked installed: \(error)")
                return (text, "Raw OCR")
            }

        case .supported:
            print("🔤 → status is .supported, NOT .installed — pack shows in Settings but system doesn't consider it ready")
            await MainActor.run {
                PanelData.shared.statusText = "Japanese language pack not installed — download it in System Settings → General → Language & Region → Translation Languages"
            }
            return (text, "Raw OCR — JA pack missing")

        case .unsupported:
            print("🔤 → status is .unsupported")
            return (text, "Raw OCR — unsupported pair")

        @unknown default:
            print("🔤 → status is unknown case")
            return (text, "Raw OCR")
        }
    }
}

// MARK: - DeepL

final class DeepLTranslationProvider: TranslationProvider {
    let name = "DeepL"

    /// DeepL API key resolution.
    /// Condition: if key not present then don't import / use it (returns nil).
    static var apiKey: String? {
        // 1. Check Secrets.swift value
        let key = deepLAPIKeyValue
        if !key.isEmpty && key != "YOUR_DEEPL_API_KEY_HERE" {
            return key
        }
        // 2. Check environment variable (e.g. DEEPL_API_KEY)
        if let envKey = ProcessInfo.processInfo.environment["DEEPL_API_KEY"],
           !envKey.isEmpty, envKey != "YOUR_DEEPL_API_KEY_HERE" {
            return envKey
        }
        // 3. Check UserDefaults (e.g. configured via defaults write or settings)
        if let defaultsKey = UserDefaults.standard.string(forKey: "deepLAPIKey"),
           !defaultsKey.isEmpty, defaultsKey != "YOUR_DEEPL_API_KEY_HERE" {
            return defaultsKey
        }
        // 4. Check Info.plist
        if let infoKey = Bundle.main.infoDictionary?["DeepLAPIKey"] as? String,
           !infoKey.isEmpty, infoKey != "YOUR_DEEPL_API_KEY_HERE" {
            return infoKey
        }
        // Condition: if key not present then don't import it
        return nil
    }

    /// True when a real API key is configured.
    /// Condition: if key not present, don't import / enable DeepL.
    /// Used to enable/disable the DeepL option in Settings.
    static var keyIsConfigured: Bool {
        guard let key = apiKey, !key.isEmpty, key != "YOUR_DEEPL_API_KEY_HERE" else {
            return false
        }
        return true
    }

    func translate(_ text: String) async -> (text: String, source: String) {
        // Condition: if key not present then don't import / use DeepL
        guard Self.keyIsConfigured else {
            print("⚠️ DeepL key not present — skipping DeepL translation")
            return (text, "Raw OCR — DeepL not configured")
        }

        do {
            let translated = try await Self.callDeepL(text: text)
            return (translated, "DeepL")
        } catch {
            print("⚠️ DeepL translation failed: \(error)")
            return (text, "Raw OCR — DeepL error")
        }
    }

    /// Calls DeepL translation API.
    /// Condition: if key not present then don't import / call it.
    static func callDeepL(text: String) async throws -> String {
        // Condition: if key not present then don't import it
        guard let key = apiKey, keyIsConfigured else {
            throw URLError(.userAuthenticationRequired)
        }

        let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        guard let url = URL(string: "https://\(host)/v2/translate") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
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
}
