//
//  ResizableGlassView.swift
//  Overlay
//
//  Created by Ansgenix on 02/08/26.
//

import Cocoa
import SwiftUI

// 1. The Custom Glass View Handling Cursors
class ResizableGlassView: NSVisualEffectView {
    private let inset: CGFloat = 8.0

    override func resetCursorRects() {
        super.resetCursorRects()
        let b = bounds

        let top = NSRect(x: inset, y: b.height - inset, width: b.width - (inset * 2), height: inset)
        let bottom = NSRect(x: inset, y: 0, width: b.width - (inset * 2), height: inset)
        let left = NSRect(x: 0, y: inset, width: inset, height: b.height - (inset * 2))
        let right = NSRect(x: b.width - inset, y: inset, width: inset, height: b.height - (inset * 2))

        addCursorRect(top, cursor: .resizeUpDown)
        addCursorRect(bottom, cursor: .resizeUpDown)
        addCursorRect(left, cursor: .resizeLeftRight)
        addCursorRect(right, cursor: .resizeLeftRight)
    }
}

// 2. The Custom Panel Setup
class GlassPanel: NSPanel {
    private var glassView: ResizableGlassView?
    private var containerView: NSView?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        self.minSize = NSSize(width: 250, height: 180)
        self.maxSize = NSSize(width: 800, height: 600)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Force a dark vibrant appearance so .hudWindow material renders
        // its intended tint/blur rather than falling back to a flat fill.
        self.appearance = NSAppearance(named: .vibrantDark)

        // --- Build glass FIRST, fully configured, before it touches the window ---
        let glass = ResizableGlassView(frame: NSRect(origin: .zero, size: contentRect.size))
        glass.autoresizingMask = [.width, .height]
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.isEmphasized = true
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 20.0
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1.0
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor

        // Plain container as the actual contentView — always transparent, never hidden.
        // NOT layer-backed itself, so it doesn't force glass's blur layer to
        // flatten/rasterize against a parent CALayer.
        let container = NSView(frame: contentRect)
        container.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        self.glassView = glass
        self.containerView = container
        self.contentView = container

        // Glass must exist in the window hierarchy before ordering front
        // for .behindWindow blending to start sampling correctly.
        self.displayIfNeeded()
    }

    func setHudMode(_ isHud: Bool) {
        glassView?.alphaValue = isHud ? 0.0 : 1.0
        self.hasShadow = !isHud
        if !isHud {
            glassView?.state = .active
            glassView?.isEmphasized = true
            glassView?.material = .hudWindow
            glassView?.layer?.borderWidth = 1.0
            glassView?.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        }
        self.contentView?.needsLayout = true
        self.contentView?.needsDisplay = true
        self.displayIfNeeded()
        self.invalidateShadow()
    }

    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}
