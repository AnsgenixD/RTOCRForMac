//
//  ContentView.swift
//  Overlay--->Pythonfile
//

import SwiftUI
import Translation

struct ContentView: View {
    @ObservedObject var dataManager = PanelData.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear

                if dataManager.textBlocks.isEmpty {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(dataManager.statusText)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.black.opacity(0.5)))
                            Spacer()
                        }
                        Spacer()
                    }
                }

                ForEach(dataManager.textBlocks) { block in
                    let rect = CGRect(
                        x: block.frame.origin.x * geometry.size.width,
                        y: block.frame.origin.y * geometry.size.height,
                        width: block.frame.size.width * geometry.size.width,
                        height: block.frame.size.height * geometry.size.height
                    )

                    ZStack {
                        // 1. Text Eraser Patch (Blends with the local speech bubble background)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(block.backgroundColor)
                            .padding(-3) // Slight negative padding covers character edges completely

                        // 2. Outlined English Text (Halo effect guarantees high readability)
                        Text(block.text)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(block.textColor)
                            // Stroke Halo Shadow
                            .shadow(color: block.textColor == .black ? .white : .black, radius: 1)
                            .shadow(color: block.textColor == .black ? .white : .black, radius: 1)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.4)
                    }
                    .frame(width: max(rect.width, 24), height: max(rect.height, 14))
                    .position(x: rect.midX, y: rect.midY)
                    // Double-tap a block to request a DeepL "improve this translation" pass.
                    // Requires a valid deepLAPIKey set in TranslationManager.
                    .onTapGesture(count: 2) {
                        TranslationManager.shared.improveTranslation(
                            for: block.id,
                            originalText: block.originalText
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        // One-time trigger to move ja→en from LanguageAvailability's
        // .supported state to .installed for THIS app. Downloading the
        // pack via System Settings only registers it for system features
        // (Siri, Safari, keyboard translate) — a third-party app must
        // separately request it through .translationTask, which shows
        // the user a proper system download prompt the first time. A
        // headless background Task can't trigger this; it needs a live
        // view, which is why this lives here instead of in TranslationManager.
        .translationTask(
            source: .init(identifier: "ja"),
            target: .init(identifier: "en")
        ) { session in
            do {
                try await session.prepareTranslation()
                print("✅ ja→en translation pack prepared/installed for this app")
            } catch {
                print("⚠️ prepareTranslation failed: \(error)")
            }
        }
    }
}
