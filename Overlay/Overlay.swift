import SwiftUI
import UniformTypeIdentifiers // Fixes the '.json' missing import error!
import ApplicationServices    // AXIsProcessTrusted (accessibility check)

@main
struct Overlay: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var panelData = PanelData.shared

    var body: some Scene {
        Settings {
            SettingsView()
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

                // Same reasoning — handled by AppDelegate's global/local
                // monitors, not a SwiftUI keyboardShortcut, so it works
                // while reading manga in another app without needing to
                // switch focus to Overlay first.
                Toggle("Click-Through (let clicks pass to app below) — ⌥⌘X", isOn: $panelData.isClickThrough)

                Divider()

                // Read-only mirror of the two states above (the toggles
                // already render as checkmarks; this spells out the
                // combined state for at-a-glance checking).
                Text("Current state: HUD \(panelData.isHudOnlyMode ? "ON (glass hidden)" : "OFF (glass visible)") · Click-through \(panelData.isClickThrough ? "ON" : "OFF")")
                    .font(.caption)

                Divider()

                Text("Click-Through is ON by default so the panel never blocks clicks (e.g. a manga reader's next-page button). Turn it off briefly to drag or resize the panel, then back on.")
                    .font(.caption)
            }

            CommandMenu("Overlay") {
                Button("Reset Translation Cache…") {
                    confirmResetCache()
                }

                Button("Check Accessibility Permission…") {
                    checkAccessibility()
                }

                Button("Prepare Translation Pack…") {
                    // Re-triggers ContentView's .translationTask(id:) via the
                    // token, which re-shows the system ja→en pack download
                    // prompt — for users who dismissed the first-run one.
                    panelData.translationPrepToken += 1
                }

                Divider()

                Text("Reset clears every cached translation in the local SQLite database (irreversible). Check Accessibility shows whether the global-hotkey permission is granted and offers to open System Settings. Prepare Translation Pack re-runs the one-time Japanese→English language download prompt.")
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

            CommandMenu("Help") {
                Button("Show Help & Hotkeys") {
                    AuxiliaryWindowController.shared.showHelp()
                }
                .keyboardShortcut("?", modifiers: [.command])

                Button("Show Onboarding…") {
                    AuxiliaryWindowController.shared.showOnboarding()
                }
            }
        }
    }

    /// Destructive cache reset — always confirm first.
    private func confirmResetCache() {
        let alert = NSAlert()
        alert.messageText = "Reset Translation Cache?"
        alert.informativeText = "This deletes every translation stored in the local SQLite database. Lines already on screen will be re-translated from scratch. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset Cache")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            TranslationManager.shared.clearCache()
        }
    }

    private func checkAccessibility() {
        let trusted = AXIsProcessTrusted() // non-prompting check
        let alert = NSAlert()
        alert.messageText = trusted
            ? "Accessibility permission: granted ✓"
            : "Accessibility permission: NOT granted"
        alert.informativeText = trusted
            ? "Global hotkeys (⌥⌘H, ⌥⌘X) work while any app is frontmost."
            : "Global hotkeys won't work until MACmort is enabled in System Settings → Privacy & Security → Accessibility."
        alert.alertStyle = trusted ? .informational : .warning
        if !trusted {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn {
                PermissionStatus.openAccessibilitySettings()
            }
            return
        }
        alert.runModal()
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
