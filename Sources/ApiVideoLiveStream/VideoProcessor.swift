/**
 * PROBLEM: Overlay widgets rendered inside Flutter never reached the RTMP encoder, leaving viewers with camera-only video.
 * ROOT CAUSE: The legacy Metal pipeline relied on an unfinished texture coordinator, so no overlay pixels were ever blended.
 * SOLUTION: Replace the pipeline with a CIContext compositor that blends captured overlay snapshots (plus a debug test square) directly into each frame.
 * IMPACT: Viewer-side streams now include real overlay imagery, and the orange debug tile verifies the compositor path while we validate the feed.
 */

import Foundation
import CoreVideo
import CoreImage
import Metal
import CoreMedia

#if os(iOS)
import UIKit
#else
import AppKit
#endif

final class VideoProcessor {
    enum OverlayKind: String, CaseIterable {
        case chat
        case subGoal
        case followerGoal
    }

    private struct OverlayState {
        var rect: CGRect = .zero
        var opacity: CGFloat = 1.0
        var image: CIImage?
        var visible: Bool = false
    }

    private let ciContext: CIContext
    private let overlayQueue = DispatchQueue(label: "com.plusreps.overlay-state", attributes: .concurrent)
    private var overlays: [OverlayKind: OverlayState] = [:]

    private let frameSemaphore = DispatchSemaphore(value: 3)
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int)?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private let debugSquareEnabled = false
    private let debugSquareRect = CGRect(x: 0.05, y: 0.05, width: 0.22, height: 0.18)

    init?() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [
                CIContextOption.priorityRequestLow: false
            ])
        } else {
            ciContext = CIContext(options: [
                CIContextOption.useSoftwareRenderer: false,
                CIContextOption.priorityRequestLow: false
            ])
        }
    }


    func updateSubGoal(current: Int, target: Int, visible: Bool) {
        updateVisibility(for: .subGoal, visible: visible)
    }

    func updateFollowerGoal(current: Int, target: Int, visible: Bool) {
        updateVisibility(for: .followerGoal, visible: visible)
    }

    func configureOverlay(
        kind: String,
        urlString: String?,
        rect: CGRect,
        opacity: Float
    ) {
        updateOverlayLayout(kind: kind, rect: rect, opacity: CGFloat(opacity))
    }

    func updateOverlayLayout(kind: String, rect: CGRect, opacity: CGFloat) {
        guard let overlayKind = OverlayKind(rawValue: kind) else {
            print("⚠️ VideoProcessor: Unknown overlay kind \(kind)")
            return
        }

        let clampedRect = clamp(rect: rect)
        let clampedOpacity = max(0.0, min(opacity, 1.0))

        overlayQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            var state = self.overlays[overlayKind] ?? OverlayState()
            state.rect = clampedRect
            state.opacity = clampedOpacity
            state.visible = clampedOpacity > 0.01
            self.overlays[overlayKind] = state
        }

    }

    #if os(iOS)
    func updateOverlayImage(kind: String, image: UIImage) {
        guard let overlayKind = OverlayKind(rawValue: kind) else { return }
        guard let ciImage = CIImage(image: image)?.oriented(.up) else {
            print("⚠️ VideoProcessor: Failed to convert overlay snapshot for \(kind)")
            return
        }

        overlayQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            var state = self.overlays[overlayKind] ?? OverlayState()
            state.image = ciImage
            state.visible = state.opacity > 0.01 && !state.rect.isEmpty
            self.overlays[overlayKind] = state
        }
    }
    #endif

    func clearOverlayTexture(kind: String) {
        guard let overlayKind = OverlayKind(rawValue: kind) else { return }
        overlayQueue.async(flags: .barrier) { [weak self] in
            self?.overlays[overlayKind] = OverlayState()
        }
    }

    func clearAllOverlays() {
        overlayQueue.async(flags: .barrier) { [weak self] in
            self?.overlays.removeAll()
        }
    }

    /// Drain in-flight frames and reset state
    /// Call before disabling screen saver or stopping stream
    func drainAndReset() {
        // Clear the overlay state completely
        overlayQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.overlays.removeAll()
        }

        // Reset buffer pool
        pixelBufferPool = nil
        poolSize = nil
    }

    // MARK: - Compositing

    func process(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let overlaysSnapshot = overlayQueue.sync { overlays }
        let hasRenderableOverlay = overlaysSnapshot.contains { $0.value.visible }

        if !hasRenderableOverlay && !debugSquareEnabled {
            return nil
        }

        guard frameSemaphore.wait(timeout: .now()) == .success else {
            return nil
        }
        defer { frameSemaphore.signal() }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        if pixelBufferPoolRequiresRefresh(width: width, height: height) {
            guard rebuildPixelBufferPool(width: width, height: height) else {
                return nil
            }
        }

        var outputPixelBufferOptional: CVPixelBuffer?
        guard let pool = pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBufferOptional) == kCVReturnSuccess,
              let outputPixelBuffer = outputPixelBufferOptional else {
            return nil
        }

        let frameRect = CGRect(x: 0, y: 0, width: width, height: height)
        var composedImage = CIImage(cvPixelBuffer: pixelBuffer)

        for (kind, state) in overlaysSnapshot where state.visible {
            guard let overlayImage = makeOverlayImage(kind: kind,
                                                      state: state,
                                                      frameWidth: CGFloat(width),
                                                      frameHeight: CGFloat(height)) else {
                continue
            }
            composedImage = overlayImage.composited(over: composedImage)
        }

        if debugSquareEnabled,
           let debugOverlay = makeDebugOverlay(frameWidth: CGFloat(width), frameHeight: CGFloat(height)) {
            composedImage = debugOverlay.composited(over: composedImage)
        }

        ciContext.render(composedImage,
                         to: outputPixelBuffer,
                         bounds: frameRect,
                         colorSpace: colorSpace)

        return outputPixelBuffer
    }

    func process(sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let processedPixelBuffer = process(pixelBuffer: imageBuffer) else {
            return nil
        }

        var timingInfo = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                          imageBuffer: processedPixelBuffer,
                                                          formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else {
            return nil
        }

        var compositedSampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: processedPixelBuffer,
                                                       formatDescription: formatDescription,
                                                       sampleTiming: &timingInfo,
                                                       sampleBufferOut: &compositedSampleBuffer) == noErr,
              let compositedSampleBuffer else {
            return nil
        }

        return compositedSampleBuffer
    }

    // MARK: - Helpers

    private func updateVisibility(for kind: OverlayKind, visible: Bool) {
        overlayQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            var state = self.overlays[kind] ?? OverlayState()
            /**
             * PROBLEM: Disabling an overlay cleared the cached snapshot, so re-enabling left nothing to composite.
             * ROOT CAUSE: We nulled `state.image` whenever `visible` became false, and Flutter only flips visibility flags.
             * SOLUTION: Preserve the last CIImage so a simple toggle can restore the overlay without waiting for a new capture.
             */
            state.visible = visible
            self.overlays[kind] = state
        }
    }

    private func clamp(rect: CGRect) -> CGRect {
        var left = max(0.0, min(rect.origin.x, 1.0))
        var top = max(0.0, min(rect.origin.y, 1.0))
        var width = max(0.0, min(rect.width, 1.0))
        var height = max(0.0, min(rect.height, 1.0))

        if left + width > 1.0 {
            width = max(0.0, 1.0 - left)
        }
        if top + height > 1.0 {
            height = max(0.0, 1.0 - top)
        }

        return CGRect(x: left, y: top, width: width, height: height)
    }

    private func pixelBufferPoolRequiresRefresh(width: Int, height: Int) -> Bool {
        guard let poolSize else { return true }
        return poolSize.width != width || poolSize.height != height
    }

    private func rebuildPixelBufferPool(width: Int, height: Int) -> Bool {
        pixelBufferPool = nil
        poolSize = nil

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 6
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             poolAttributes as CFDictionary,
                                             bufferAttributes as CFDictionary,
                                             &pool)
        guard status == kCVReturnSuccess, let createdPool = pool else {
            print("❌ VideoProcessor: Unable to create pixel buffer pool (\(status))")
            return false
        }

        pixelBufferPool = createdPool
        poolSize = (width, height)
        return true
    }

    private func makeOverlayImage(kind: OverlayKind,
                                  state: OverlayState,
                                  frameWidth: CGFloat,
                                  frameHeight: CGFloat) -> CIImage? {
        guard state.visible,
              state.opacity > 0.01,
              state.rect.width > 0.0,
              state.rect.height > 0.0 else {
            return nil
        }

        let widthPx = max(1.0, state.rect.width * frameWidth)
        let heightPx = max(1.0, state.rect.height * frameHeight)
        let leftPx = state.rect.origin.x * frameWidth
        let topPx = state.rect.origin.y * frameHeight
        let bottomPx = max(0.0, min(frameHeight - (topPx + heightPx), frameHeight))

        guard let storedImage = state.image else {
            return nil
        }

        var overlayImage = storedImage
        let extent = overlayImage.extent
        if extent.width > 0 && extent.height > 0 {
            let scaleX = widthPx / extent.width
            let scaleY = heightPx / extent.height
            overlayImage = overlayImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        if state.opacity < 0.99 {
            overlayImage = overlayImage.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: state.opacity),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
        }

        return overlayImage.transformed(by: CGAffineTransform(translationX: leftPx, y: bottomPx))
    }

    private func makeDebugOverlay(frameWidth: CGFloat, frameHeight: CGFloat) -> CIImage? {
        let rect = debugSquareRect
        let widthPx = rect.width * frameWidth
        let heightPx = rect.height * frameHeight
        guard widthPx >= 1.0, heightPx >= 1.0 else { return nil }

        let leftPx = rect.origin.x * frameWidth
        let topPx = rect.origin.y * frameHeight
        let bottomPx = max(0.0, min(frameHeight - (topPx + heightPx), frameHeight))

        let color = CIColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 0.85)
        let base = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
        return base.transformed(by: CGAffineTransform(translationX: leftPx, y: bottomPx))
    }
}
