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
    private var previousFrameBuffer: [UInt8]?
    private let sampleWidth = 32
    private let sampleHeight = 32
    private let differenceThreshold: Float = 3.5
    
    /// Captures the screen area directly beneath the NSPanel using ScreenCaptureKit
    func captureAndProcess(for panel: NSPanel) {
        // 1. Prevent race conditions / timer queue backlogs
        guard !isProcessing else { return }

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

        guard let mainScreen = NSScreen.main else {
            isProcessing = false
            return
        }

        let screenHeight = mainScreen.frame.height

        // Convert AppKit coordinates (bottom-left) to Screen coordinates (top-left)
        let cropRect = CGRect(
            x: frame.origin.x,
            y: screenHeight - frame.origin.y - frame.size.height,
            width: frame.size.width,
            height: frame.size.height
        )

        // Fetch shareable display content
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self else { return }

            guard error == nil, let content = content, let display = content.displays.first else {
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
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { cgImage, error in
                defer { self.isProcessing = false }

                guard let cgImage = cgImage, error == nil else { return }

                // STEP 1: Downsampled Difference Check
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
        guard let prevBuffer = previousFrameBuffer else { return true }
        
        var totalDifference: Float = 0
        for i in 0..<(sampleWidth * sampleHeight) {
            let diff = abs(Int32(currentBuffer[i]) - Int32(prevBuffer[i]))
            totalDifference += Float(diff)
        }
        
        let averageDiff = totalDifference / Float(sampleWidth * sampleHeight)
        return averageDiff > differenceThreshold
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
        
        // 3. Set recognition level to .accurate for higher precision with complex Kanji
        request.recognitionLevel = .accurate
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
                
                let pixelRect = CGRect(
                    x: boundingBox.origin.x * imgWidth,
                    y: boundingBox.origin.y * imgHeight,
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
                
                let translatedText = TranslationManager.shared.checkLocalDatabase(for: rawText) ?? rawText

                blocks.append(RecognizedTextBlock(
                    text: translatedText,
                    originalText: rawText,
                    frame: normalizedBox,
                    backgroundColor: Color(nsColor: bgColor),
                    textColor: textColor
                ))
                }

                // Dispatch translation queries for uncached lines.
                // Looping over `blocks` (not `observations`) means each Task already
                // knows exactly which block.id to patch once translation resolves.
            for block in blocks {
                Task {
                    let result = await TranslationManager.shared.translate(japaneseText: block.originalText)
                    await MainActor.run {
                        PanelData.shared.updateBlockText(id: block.id, newText: result.text)
                    }
                }
            }

            DispatchQueue.main.async {
                PanelData.shared.textBlocks = blocks   // fires almost immediately
            }
            
            DispatchQueue.main.async {
                PanelData.shared.textBlocks = blocks
                PanelData.shared.statusText = "OCR: Active (\(blocks.count) blocks)"
            }
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
