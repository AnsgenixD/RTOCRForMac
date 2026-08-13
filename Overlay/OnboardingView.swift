//
//  OnboardingView.swift
//  Overlay
//
//  First-launch onboarding (roadmap item 2): permissions checklist with live
//  status + hotkey cheatsheet, so users don't need to read the GitHub README
//  to get going. Gated by the "hasCompletedOnboarding" UserDefaults flag in
//  AuxiliaryWindowController; reopenable via Help → Show Onboarding.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to MACmort")
                    .font(.title.bold())
                Text("A transparent overlay that detects Japanese text on screen and translates it in place. Get set up in three steps:")
                    .foregroundColor(.secondary)
            }

            GroupBox("1 · Grant permissions") {
                PermissionChecklistView()
                    .padding(6)
            }

            GroupBox("2 · Learn the shortcuts") {
                HotkeyCheatsheetView()
                    .padding(6)
            }

            GroupBox("3 · Place the overlay") {
                Text("Drag the panel over the Japanese text you want translated (turn click-through OFF with ⌥⌘X to move it, then back ON). Detected lines are covered with a color-matched patch and the English translation on top.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(6)
            }

            Spacer()

            HStack {
                Button("View README on GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/AnsgenixD/RTOCRForMac")!)
                }
                Spacer()
                Button("Get Started") {
                    UserDefaults.standard.set(true, forKey: AuxiliaryWindowController.onboardingCompletedKey)
                    NSApp.keyWindow?.orderOut(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 520)
    }
}
