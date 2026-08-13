//
//  HelpView.swift
//  Overlay
//
//  In-app Help (roadmap item 2): hotkey cheatsheet, permission requirements
//  with live status, the OCR/translation source of every currently active
//  block, and a link to the README. The app has no standard windows (its
//  only Scene is Settings), so Help/Onboarding open in plain NSWindows
//  hosting SwiftUI via NSHostingView, managed by AuxiliaryWindowController.
//

import SwiftUI
import ApplicationServices
import Translation

// MARK: - Permission status helpers

enum PermissionStatus {
    /// Screen Recording (ScreenCaptureKit) — preflight check, doesn't prompt.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Accessibility (global hotkeys) — non-prompting trust check.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Whether the ja→en pack is installed *for this app* (Translation
    /// framework language packs are per-app, not just system-wide).
    static func translationPackInstalled() async -> Bool {
        guard #available(macOS 15.0, *) else { return false }
        let status = await LanguageAvailability()
            .status(from: .init(identifier: "ja"), to: .init(identifier: "en"))
        if case .installed = status { return true }
        return false
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens System Settings → Privacy & Security → Screen Recording.
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Shared permission checklist row (used by Help + Onboarding)

struct PermissionChecklistView: View {
    @State private var screenRecordingOK = PermissionStatus.screenRecording
    @State private var accessibilityOK = PermissionStatus.accessibility
    @State private var translationPackOK = false
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PermissionRow(
                title: "Screen Recording",
                subtitle: "Required to capture the screen area under the panel",
                granted: screenRecordingOK,
                fixAction: PermissionStatus.openScreenRecordingSettings
            )
            PermissionRow(
                title: "Accessibility",
                subtitle: "Required for global hotkeys (⌥⌘H / ⌥⌘X) while another app is frontmost",
                granted: accessibilityOK,
                fixAction: PermissionStatus.openAccessibilitySettings
            )
            PermissionRow(
                title: "Japanese→English Translation Pack",
                subtitle: "Required for on-device Apple translation (use Overlay → Prepare Translation Pack)",
                granted: translationPackOK,
                fixAction: nil
            )
        }
        .task { await refresh() }
        .onAppear {
            // Re-check periodically so granting a permission in System
            // Settings is reflected here without reopening the window.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in await refresh() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func refresh() async {
        screenRecordingOK = PermissionStatus.screenRecording
        accessibilityOK = PermissionStatus.accessibility
        translationPackOK = await PermissionStatus.translationPackInstalled()
    }
}

private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let granted: Bool
    let fixAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(granted ? .green : .orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.headline)
                    if !granted, let fixAction = fixAction {
                        Button("Open Settings", action: fixAction)
                            .controlSize(.small)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Hotkey cheatsheet (shared by Help + Onboarding)

struct HotkeyCheatsheetView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            hotkeyRow("⌥⌘H", "Toggle HUD mode — hide the glass backdrop, leave only the text patches")
            hotkeyRow("⌥⌘X", "Toggle click-through — ON by default; turn OFF briefly to drag/resize the panel")
            hotkeyRow("⌥⌘I", "Import a JSON {\"Japanese\": \"English\"} dictionary into the local cache")
            hotkeyRow("⌥⌘E", "Export the local translation cache to JSON")
            hotkeyRow("Double-tap", "Request a DeepL \"improve translation\" pass on one block (needs a DeepL key)")
        }
    }

    private func hotkeyRow(_ key: String, _ description: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 90, alignment: .leading)
            Text(description)
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Help window content

struct HelpView: View {
    @ObservedObject private var dataManager = PanelData.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("MACmort Help")
                    .font(.title.bold())

                GroupBox("Permissions") {
                    PermissionChecklistView()
                        .padding(6)
                }

                GroupBox("Keyboard shortcuts") {
                    HotkeyCheatsheetView()
                        .padding(6)
                }

                GroupBox("Currently detected text — source per block") {
                    if dataManager.textBlocks.isEmpty {
                        Text("No text detected right now. Place the overlay panel over Japanese text and it will appear here.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(dataManager.textBlocks) { block in
                                HStack(alignment: .top) {
                                    Text(block.source)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(width: 170, alignment: .leading)
                                        .foregroundColor(.secondary)
                                    VStack(alignment: .leading) {
                                        Text(block.originalText).font(.caption).foregroundColor(.secondary)
                                        Text(block.text).font(.callout)
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }
                }

                GroupBox("About") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OCR: Apple Vision (\(UserDefaults.standard.bool(forKey: OCRManager.usesFastOCRKey) ? "fast" : "accurate") mode) · Translation backend: \(TranslationBackend.current.displayName)")
                            .font(.callout)
                        Button("View README on GitHub") {
                            NSWorkspace.shared.open(URL(string: "https://github.com/AnsgenixD/RTOCRForMac")!)
                        }
                    }
                    .padding(6)
                }
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }
}

// MARK: - Window management

/// Owns the auxiliary NSWindows (Help, Onboarding). The app's only SwiftUI
/// Scene is Settings, so these are plain AppKit windows hosting SwiftUI.
final class AuxiliaryWindowController {
    static let shared = AuxiliaryWindowController()

    private var helpWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    /// UserDefaults flag gating the first-launch onboarding sheet.
    static let onboardingCompletedKey = "hasCompletedOnboarding"

    var onboardingRequired: Bool {
        !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
    }

    func showHelp() {
        if let window = helpWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow(title: "MACmort Help", size: NSSize(width: 660, height: 560), rootView: HelpView())
        helpWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow(title: "Welcome to MACmort", size: NSSize(width: 560, height: 520), rootView: OnboardingView())
        onboardingWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(title: String, size: NSSize, rootView: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: rootView)
        return window
    }
}
