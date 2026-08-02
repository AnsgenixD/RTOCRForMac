//
//  AppDelegate.swift
//  Overlay
//
//  Created by Ansgenix  on 02/08/26.
//

import Cocoa
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var glassPanel: GlassPanel?
    var ocrTimer: Timer?
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkAccessibilityPermission()

        let panelFrame = NSRect(x: 400, y: 300, width: 380, height: 260)
        let panel = GlassPanel(contentRect: panelFrame)

        panel.delegate = self

        let hostingView = NSHostingView(rootView: ContentView())
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        panel.contentView?.addSubview(hostingView)
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        self.glassPanel = panel
        PanelData.shared.glassPanel = panel

        // Bridge PanelData's HUD toggle to the actual AppKit panel state.
        PanelData.shared.$isHudOnlyMode
            .removeDuplicates()
            .sink { [weak self] isHud in
                self?.glassPanel?.setHudMode(isHud)
            }
            .store(in: &cancellables)

        // Bridge click-through toggle to the panel. Default is click-through
        // ON so the overlay never blocks interaction with whatever's under
        // it (e.g. a manga reader's "next page" button) — the user only
        // needs to disable it briefly to move/resize the panel itself.
        PanelData.shared.$isClickThrough
            .removeDuplicates()
            .sink { [weak self] isClickThrough in
                self?.glassPanel?.ignoresMouseEvents = isClickThrough
            }
            .store(in: &cancellables)

        setupGlobalHotkeys()
        setupLocalHotkeys()

        // Start the native Swift capture & OCR loop (checks every 50ms)
        startOCRLoop()
    }

    /// NSEvent.addGlobalMonitorForEvents silently receives nothing without
    /// this permission — no error, no crash, it just never fires while
    /// another app is frontmost. This is why hotkeys previously only
    /// appeared to work while the app itself was focused (that was actually
    /// the menu bar Commands shortcuts firing, not the global monitor).
    private func checkAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options: [String: Bool] = [promptKey as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)

        if !trusted {
            print("⚠️ Accessibility permission not granted — global hotkeys won't work until enabled in System Settings → Privacy & Security → Accessibility")
        }
    }

    func startOCRLoop() {
        ocrTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let panel = self?.glassPanel else { return }
            OCRManager.shared.captureAndProcess(for: panel)
        }
    }

    /// Fires while another app (Firefox, a game, etc.) is frontmost.
    /// Requires Accessibility permission — see checkAccessibilityPermission().
    private func setupGlobalHotkeys() {
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            Self.handleHotkey(event)
        }
    }

    /// Global monitors never fire for the app's OWN window by design —
    /// this local monitor covers the case where the panel itself (or this
    /// app generally) is frontmost/key. Returning the event keeps it
    /// propagating normally afterward.
    private func setupLocalHotkeys() {
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleHotkey(event)
            return event
        }
    }

    private static func handleHotkey(_ event: NSEvent) {
        guard event.modifierFlags.contains([.command, .option]) else { return }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "h":
            PanelData.shared.isHudOnlyMode.toggle()
        case "x":
            // Toggle click-through: hold this off briefly to move/resize
            // the panel, then flip back on so it stops blocking clicks.
            PanelData.shared.isClickThrough.toggle()
        default:
            break
        }
    }

    deinit {
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
