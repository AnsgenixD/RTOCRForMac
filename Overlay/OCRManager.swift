//
//  OCRManager.swift
//  Overlay
//
//  Created by Ansgenix  on 02/08/26.


//

//  OCRManager.swift
//  Overlay-->Pythonfile

import Foundation
import Vision
import AppKit
import ScreenCaptureKit
import SwiftUI

class OCRManager {
    static let shared = OCRManager()
    
    private var isProcessing = false
    private var needsReprocess = false
    
    // Baseline downsampled buffer from the frame where OCR was last executed
    private var lastProcessedBuffer: [UInt8]?
    // Buffer from the immediately preceding frame for motion / stabilization tracking
    private var previousFrameBuffer: [UInt8]?
    // Timestamp when OCR was last executed
    private var lastOCRCompletionTime: CFAbsoluteTime = 0
    
    // 96x32 preserves the ~3:1 aspect ratio typical of game subtitle and dialogue boxes
    private let sampleWidth = 96
    private let sampleHeight = 32

    /// UserDefaults key shared with SettingsView's @AppStorage toggle.
    /// Fast mode trades some Kanji accuracy for lower OCR latency — the
    /// project's stated priority is speed for game text.
    static let usesFastOCRKey = "usesFastOCR"
    private var usesFastOCR: Bool { UserDefaults.standard.bool(forKey: Self.usesFastOCRKey) }
    
    /// Captures the screen area directly beneath the NSPanel using ScreenCaptureKit
    func captureAndProcess(for panel: NSPanel) {
        // If an OCR pass is already active, flag that a newer frame has arrived so we catch up immediately
        if isProcessing {
            needsReprocess = true
            return
        }

        // 2. Preflight macOS Screen Capture Permissions
        guard CGPreflightScreenCaptureAccess() else {
            DispatchQueue.main.async {
                if PanelData.shared.statusText != "Permission Required" {
                    PanelData.shared.statusText = "Permission Required (Enable in Settings)"
                }
            }
            return
        }

        isProcessing = true

        let frame = panel.frame
        // Read this NSWindow property on the main thread NOW — it must never be
        // touched from inside the SCShareableContent completion closure below,
        // which runs on a background XPC queue (this was the Main Thread
        // Checker violation: -[NSWindow windowNumber] called off-main).
        let ownWindowID = CGWindowID(panel.windowNumber)

        guard let screen = panel.screen ?? NSScreen.main else {
            isProcessing = false
            return
        }

        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

        // Convert AppKit coordinates (bottom-left) to Screen coordinates (top-left relative to this screen)
        let cropRect = CGRect(
            x: frame.origin.x - screen.frame.origin.x,
            y: screen.frame.height - (frame.origin.y - screen.frame.origin.y) - frame.size.height,
            width: frame.size.width,
            height: frame.size.height
        )

        // Fetch shareable display content
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self else { return }

            guard error == nil, let content = content else {
                self.isProcessing = false
                return
            }

            let display = (screenNumber != nil ? content.displays.first { $0.displayID == screenNumber } : nil)
                ?? content.displays.first
            guard let display = display else {
                self.isProcessing = false
                return
            }

            // Exclude our own GlassPanel window so it doesn't capture itself.
            // Uses the plain Int captured above instead of touching `panel` here.
            let excludedWindows = content.windows.filter { $0.windowID == ownWindowID }

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let config = SCStreamConfiguration()

            config.sourceRect = cropRect
            config.width = Int(cropRect.width * 2) // Retina 2x scale
            config.height = Int(cropRect.height * 2)
            config.showsCursor = false

            // Take screenshot via ScreenCaptureKit
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self, weak panel] cgImage, error in
                guard let self = self else { return }
                defer {
                    self.isProcessing = false
                    if self.needsReprocess {
                        self.needsReprocess = false
                        DispatchQueue.main.async { [weak panel] in
                            guard let panel = panel else { return }
                            self.captureAndProcess(for: panel)
                        }
                    }
                }

                guard let cgImage = cgImage, error == nil else { return }

                // STEP 1: Responsive Localized Difference Check
                if self.hasFrameChanged(cgImage) {
                    // STEP 2: Vision OCR Pass
                    self.processFrameWithBoundingBoxes(cgImage)
                }
            }
        }
    }

    private func hasFrameChanged(_ image: CGImage) -> Bool {
        guard let currentBuffer = extractDownsampledBuffer(from: image) else { return true }
        
        defer { previousFrameBuffer = currentBuffer }
        
        guard let lastBuffer = lastProcessedBuffer else {
            // First capture: always run OCR and establish the baseline buffer!
            lastProcessedBuffer = currentBuffer
            return true
        }
        
        let count = sampleWidth * sampleHeight
        var totalDiffAgainstProcessed: Float = 0
        var maxDiffAgainstProcessed: Int32 = 0
        var significantPixelsAgainstProcessed = 0
        
        for i in 0..<count {
            let diff = abs(Int32(currentBuffer[i]) - Int32(lastBuffer[i]))
            totalDiffAgainstProcessed += Float(diff)
            if diff > maxDiffAgainstProcessed { maxDiffAgainstProcessed = diff }
            if diff > 14 {
                significantPixelsAgainstProcessed += 1
            }
        }
        
        let avgDiffAgainstProcessed = totalDiffAgainstProcessed / Float(count)
        
        // 1. Localized text appearance / mutation:
        // Even a single character appearing changes 4+ downsampled pixels by > 14 with maxDiff > 28.
        let hasTextChanged = significantPixelsAgainstProcessed >= 4 && maxDiffAgainstProcessed > 28
        
        // 2. Global scene / dialogue box transition:
        let hasSceneChanged = avgDiffAgainstProcessed > 1.2
        
        // 3. Stale guard: if text blocks are currently displayed on screen, but no OCR has executed
        // for over 1.2 seconds, and there is ANY slight divergence (e.g. subtitle cleared or faded), re-verify!
        let now = CFAbsoluteTimeGetCurrent()
        let hasStaleDivergence = !PanelData.shared.textBlocks.isEmpty && (now - lastOCRCompletionTime > 1.2) && (avgDiffAgainstProcessed > 0.25 || maxDiffAgainstProcessed > 18)
        
        if hasTextChanged || hasSceneChanged || hasStaleDivergence {
            lastProcessedBuffer = currentBuffer
            return true
        }
        
        return false
    }
    
    private func extractDownsampledBuffer(from image: CGImage) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &buffer,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        return buffer
    }
    
    // MARK: - Overlapping observation suppression
    
    private func suppressOverlappingObservations(
        _ observations: [VNRecognizedTextObservation],
        iouThreshold: CGFloat = 0.3
    ) -> [VNRecognizedTextObservation] {
        // Sort by confidence, highest first
        let sorted = observations.sorted {
            ($0.topCandidates(1).first?.confidence ?? 0) > ($1.topCandidates(1).first?.confidence ?? 0)
        }
        
        var kept: [VNRecognizedTextObservation] = []
        
        for candidate in sorted {
            let candidateBox = candidate.boundingBox
            let overlapsExisting = kept.contains { existing in
                iou(candidateBox, existing.boundingBox) > iouThreshold
            }
            if !overlapsExisting {
                kept.append(candidate)
            }
        }
        
        return kept
    }
    
    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = (a.width * a.height) + (b.width * b.height) - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
    
    private func processFrameWithBoundingBoxes(_ image: CGImage) {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["ja-JP", "en-US"]
        
        // 2. Disable automatic language fallback (forces it to search for Japanese Kanji/Kana)
        request.automaticallyDetectsLanguage = false
        
        // 3. Recognition level: user-tunable in Settings.
        // NOTE: Apple Vision framework only supports Japanese (ja-JP) in .accurate mode.
        // In .fast mode, Vision drops ja-JP and falls back to Latin-only.
        let hasCJK = request.recognitionLanguages.contains { $0.hasPrefix("ja") || $0.hasPrefix("zh") || $0.hasPrefix("ko") }
        request.recognitionLevel = (usesFastOCR && !hasCJK) ? .fast : .accurate
        request.usesLanguageCorrection = true
        
        let isVertical = PanelData.shared.isVerticalScanning
        let orientation: CGImagePropertyOrientation = isVertical ? .right : .up
        
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        
        do {
            try handler.perform([request])
            guard let observations = request.results, !observations.isEmpty else {
                DispatchQueue.main.async {
                    PanelData.shared.textBlocks = []
                    PanelData.shared.statusText = "OCR: Active (No text detected)"
                }
                self.lastOCRCompletionTime = CFAbsoluteTimeGetCurrent()
                return
            }
            
            let imgWidth = CGFloat(image.width)
            let imgHeight = CGFloat(image.height)
            var blocks: [RecognizedTextBlock] = []
            
            // NEW: filter overlapping observations
            let filteredObservations = suppressOverlappingObservations(observations)
            for observation in filteredObservations {
                guard let topCandidate = observation.topCandidates(1).first else { continue }
                
                let rawText = topCandidate.string
                let boundingBox = observation.boundingBox // Normalized rect (0.0 to 1.0)
                
                // CGImage pixel coordinates (origin top-left):
                // In Vision boundingBox, y=0 is at the bottom, so top-left y is (1.0 - origin.y - height)
                let pixelRect = CGRect(
                    x: boundingBox.origin.x * imgWidth,
                    y: (1.0 - boundingBox.origin.y - boundingBox.size.height) * imgHeight,
                    width: boundingBox.size.width * imgWidth,
                    height: boundingBox.size.height * imgHeight
                )
                
                // Sample local background color
                let bgColor = self.sampleColorAroundRect(pixelRect, in: image)
                
                // Calculate text contrast
                let components = bgColor.cgColor.components ?? [1, 1, 1]
                let luminance = (0.299 * components[0]) + (0.587 * components[1]) + (0.114 * components[2])
                let textColor: Color = luminance > 0.5 ? .black : .white
                
                // Convert Vision coordinates (origin bottom-left) to SwiftUI space (origin top-left)
                let normalizedBox = CGRect(
                    x: boundingBox.origin.x,
                    y: 1.0 - boundingBox.origin.y - boundingBox.size.height,
                    width: boundingBox.size.width,
                    height: boundingBox.size.height
                )
                
                let cached = TranslationManager.shared.checkLocalDatabase(for: rawText)
                let translatedText = cached ?? rawText
                let initialSource = cached != nil ? "Local DB" : "OCR (translating…)"

                blocks.append(RecognizedTextBlock(
                    text: translatedText,
                    source: initialSource,
                    originalText: rawText,
                    frame: normalizedBox,
                    backgroundColor: Color(nsColor: bgColor),
                    textColor: textColor
                ))
            }

            // Dispatch translation queries for uncached lines.
            // Looping over `blocks` (not `observations`) means each Task already
            // knows exactly which block.id to patch once translation resolves.
            for block in blocks where block.source != "Local DB" {
                Task {
                    let result = await TranslationManager.shared.translate(japaneseText: block.originalText)
                    await MainActor.run {
                        PanelData.shared.updateBlockText(id: block.id, newText: result.text, source: result.source)
                    }
                }
            }

            DispatchQueue.main.async {
                PanelData.shared.textBlocks = blocks
                PanelData.shared.statusText = "OCR: Active (\(blocks.count) blocks)"
            }
            self.lastOCRCompletionTime = CFAbsoluteTimeGetCurrent()
        } catch {
            print("❌ Vision OCR Error: \(error)")
        }
    }
    
    /// Samples pixels OUTSIDE the bounding box perimeter to catch the true background color
    private func sampleColorAroundRect(_ rect: CGRect, in image: CGImage) -> NSColor {
        guard let pixelData = image.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else { return .white }
        
        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        
        let offsetPadding: CGFloat = 8.0 // Step 8 pixels OUTSIDE the text box perimeter
        
        // Sample 4 points slightly expanded outside the text box perimeter
        let samplePoints = [
            CGPoint(x: rect.minX - offsetPadding, y: rect.minY - offsetPadding),
            CGPoint(x: rect.maxX + offsetPadding, y: rect.minY - offsetPadding),
            CGPoint(x: rect.minX - offsetPadding, y: rect.maxY + offsetPadding),
            CGPoint(x: rect.maxX + offsetPadding, y: rect.maxY + offsetPadding)
        ]
        
        var rSum: CGFloat = 0, gSum: CGFloat = 0, bSum: CGFloat = 0, count: CGFloat = 0
        
        for pt in samplePoints {
            let x = min(max(0, Int(pt.x)), image.width - 1)
            let y = min(max(0, Int(pt.y)), image.height - 1)
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)
            
            rSum += CGFloat(data[offset]) / 255.0
            gSum += CGFloat(data[offset + 1]) / 255.0
            bSum += CGFloat(data[offset + 2]) / 255.0
            count += 1
        }
        
        return NSColor(red: rSum / count, green: gSum / count, blue: bSum / count, alpha: 1.0)
    }
}

// End of file
