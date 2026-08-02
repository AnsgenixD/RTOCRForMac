//
//  PanelData.swift
//  Overlay--->Pythonfile
//

import Foundation
import SwiftUI
import Combine

struct RecognizedTextBlock: Identifiable {
    // Stable, content-derived id instead of a fresh UUID() per frame.
    // Every capture cycle (every ~50ms) used to generate brand-new random
    // UUIDs for every block, so when an async translation resolved and
    // called updateBlockText(id:), the array had already been replaced by
    // a newer frame's blocks with different UUIDs — the patch silently
    // matched nothing. Deriving id from the OCR'd text means the same
    // line of dialogue keeps the same id across frames, so the patch lands.
    let id: String
    var text: String            // mutable so translation can update it in place
    let originalText: String    // raw OCR/Japanese text, used for improveTranslation()
    let frame: CGRect
    let backgroundColor: Color
    let textColor: Color

    init(text: String, originalText: String, frame: CGRect, backgroundColor: Color, textColor: Color) {
        // Bucket position to ~2% of panel size (0.02 in normalized 0-1 space).
        // Coarse enough that minor per-frame OCR jitter in a box's exact
        // coordinates doesn't break id stability, fine enough that two
        // separate on-screen instances of identical text (e.g. two
        // "Screenshot" labels) land in different buckets and don't collide.
        let bucket: (CGFloat) -> Int = { Int(($0 * 50).rounded()) }
        let positionKey = "\(bucket(frame.origin.x)):\(bucket(frame.origin.y))"
        self.id = originalText.trimmingCharacters(in: .whitespacesAndNewlines) + "@" + positionKey
        self.text = text
        self.originalText = originalText
        self.frame = frame
        self.backgroundColor = backgroundColor
        self.textColor = textColor
    }
}

class PanelData: ObservableObject {
    @Published var textBlocks: [RecognizedTextBlock] = []
    @Published var statusText: String = "Status: Idle"
    @Published var isVerticalScanning: Bool = false {
        didSet { updatePanelOrientationBounds() }
    }

    // Toggles HUD Mode (hides glass panel container completely)
    @Published var isHudOnlyMode: Bool = false {
        didSet { updatePanelGlassVisibility() }
    }

    // Click-through: when true, all mouse events pass through the panel to
    // whatever's underneath (e.g. a manga reader's page-turn button).
    // Defaults to true so the overlay never gets in the way; toggle off
    // (Cmd+Option+X) briefly to move/resize the panel, then back on.
    @Published var isClickThrough: Bool = true

    // Reference to GlassPanel
    weak var glassPanel: GlassPanel?

    static let shared = PanelData()

    /// Updates a single block's displayed text in place (used when an async
    /// translation — Apple MT or a manual DeepL "improve" — resolves after
    /// the block was already rendered with raw/placeholder text).
    func updateBlockText(id: String, newText: String) {
        guard let index = textBlocks.firstIndex(where: { $0.id == id }) else { return }
        textBlocks[index].text = newText
    }

    private func updatePanelGlassVisibility() {
        guard let panel = glassPanel else { return }

        DispatchQueue.main.async {
            // Tell the GlassPanel instance to hide its blur/background views!
            panel.setHudMode(self.isHudOnlyMode)
        }
    }

    private func updatePanelOrientationBounds() {
        guard let panel = glassPanel else { return }
        if isVerticalScanning {
            panel.minSize = NSSize(width: 160, height: 350)
            panel.maxSize = NSSize(width: 450, height: 900)
        } else {
            panel.minSize = NSSize(width: 350, height: 160)
            panel.maxSize = NSSize(width: 900, height: 450)
        }
    }
}
