import SwiftUI
import UniformTypeIdentifiers // Fixes the '.json' missing import error!

@main
struct Overlay: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var panelData = PanelData.shared

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandMenu("Scan Mode") {
                // Vertical Japanese (Tategaki) scanning removed for now —
                // OCR orientation support existed but there was no
                // corresponding redraw/layout logic for vertical text,
                // so the toggle did nothing useful. Revisit if vertical
                // manga support becomes a real goal again.

                // Note: this toggle has NO .keyboardShortcut() here on
                // purpose. Cmd+Option+H is handled by AppDelegate's global
                // + local NSEvent monitors instead, so it works even when
                // another app (a game, a browser) is frontmost — SwiftUI's
                // Commands shortcuts only fire while THIS app is focused.
                // Adding both would double-toggle when the app is active.
                Toggle("Invisible Glass Panel (HUD Mode) — ⌥⌘H", isOn: $panelData.isHudOnlyMode)

                Divider()

                // Same reasoning — handled by AppDelegate's global/local
                // monitors, not a SwiftUI keyboardShortcut, so it works
                // while reading manga in another app without needing to
                // switch focus to Overlay first.
                Toggle("Click-Through (let clicks pass to app below) — ⌥⌘X", isOn: $panelData.isClickThrough)

                Divider()

                Text("Click-Through is ON by default so the panel never blocks clicks (e.g. a manga reader's next-page button). Turn it off briefly to drag or resize the panel, then back on.")
                    .font(.caption)
            }

            CommandMenu("Dictionary") {
                Button("Import JSON Dictionary...") {
                    importDictionaryFile()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button("Export Database...") {
                    exportDatabaseFile()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])

                Divider()

                Text("Import/export a JSON dictionary of {\"Japanese\": \"English\"} pairs, stored in the local SQLite cache. Exported translations are re-used instantly next time the same line is detected.")
                    .font(.caption)
            }
        }
    }

    private func importDictionaryFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            TranslationManager.shared.importDictionary(from: url)
        }
    }

    private func exportDatabaseFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MyTranslations.json"
        if panel.runModal() == .OK, let url = panel.url {
            TranslationManager.shared.exportCache(to: url)
        }
    }
}
