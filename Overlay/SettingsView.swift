//
//  SettingsView.swift
//  Overlay
//
//  Replaces the previous `Settings { EmptyView() }` stub with a real macOS
//  Settings window: translation backend selection + OCR speed/accuracy
//  tuning. Both settings persist in UserDefaults (@AppStorage) and are read
//  live by TranslationManager / OCRManager, so changes take effect
//  immediately — no restart needed.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(TranslationBackend.storageKey) private var translationBackend: String = TranslationBackend.appleMT.rawValue
    @AppStorage(OCRManager.usesFastOCRKey) private var usesFastOCR: Bool = false

    var body: some View {
        Form {
            Section("Translation") {
                Picker("Backend", selection: $translationBackend) {
                    Text("Apple Translation (on-device)").tag(TranslationBackend.appleMT.rawValue)
                    Text("DeepL").tag(TranslationBackend.deepl.rawValue)
                }

                if !DeepLTranslationProvider.keyIsConfigured {
                    Text("DeepL requires an API key in Secrets.swift (see README). Until a key is configured, DeepL requests fall back to Apple Translation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("The local SQLite cache is always checked first, whatever the backend.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("OCR") {
                Toggle("Fast recognition (speed over accuracy)", isOn: $usesFastOCR)

                Text("Fast mode lowers Vision's recognition level for lower latency on game text. Leave it off for maximum Kanji accuracy.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped) // macOS counterpart of iOS's .form style
        .frame(width: 480)
        .padding()
    }
}
