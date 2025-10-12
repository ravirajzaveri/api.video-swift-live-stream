/**
 * PROBLEM: Metal compositor (OverlayRenderer) recreates overlays but doesn't match Flutter appearance
 * ISSUE: Position, size, styling don't match what streamer sees (WebView chat, goal bars)
 * ROOT CAUSE: CALayer recreation != WebView pixel-perfect rendering
 * SOLUTION: Capture WebView snapshots directly as Metal textures
 * ALTERNATIVES: Screen recording API (too slow), UIView snapshots (same issue)
 * IMPACT: Stream viewers see exactly what streamer sees (position, size, scale, live updates)
 */

import Foundation
import Metal
import CoreVideo

#if !os(macOS)
import UIKit
import WebKit

class OverlayCaptureManager {
    // MARK: - Properties
    private let metalDevice: MTLDevice
    private var cachedTextures: [String: MTLTexture] = [:]
    private var lastCaptureTime: [String: Date] = [:]

    private let debounceInterval: TimeInterval = 0.033 // 30fps max (match video frame rate)

    // Texture cache for efficient CVPixelBuffer → MTLTexture conversion
    private var textureCache: CVMetalTextureCache?

    // MARK: - Initialization
    init?(device: MTLDevice) {
        self.metalDevice = device

        // Create texture cache for CVPixelBuffer → MTLTexture conversion
        let result = CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        guard result == kCVReturnSuccess, textureCache != nil else {
            print("❌ OverlayCaptureManager: Failed to create CVMetalTextureCache")
            return nil
        }

        print("✅ OverlayCaptureManager: Initialized with Metal device")
    }

    // MARK: - Public API

    /**
     * Capture WebView as UIImage → CVPixelBuffer → MTLTexture
     * Debounced to 30fps to prevent excessive captures
     *
     * - Parameters:
     *   - kind: Overlay identifier ('chat', 'subGoal', 'followerGoal')
     *   - webView: WKWebView instance to capture
     *   - frame: Capture region (CGRect) - usually webView.bounds
     *   - completion: Callback with MTLTexture (nil if capture fails)
     */
    func captureOverlay(
        kind: String,
        webView: WKWebView,
        frame: CGRect,
        completion: @escaping (MTLTexture?) -> Void
    ) {
        // Debounce: Skip if captured less than 33ms ago (prevent capture spam)
        if let lastTime = lastCaptureTime[kind],
           Date().timeIntervalSince(lastTime) < debounceInterval {
            // Reuse cached texture from previous capture
            completion(cachedTextures[kind])
            return
        }

        // WKWebView takeSnapshot API (async, returns UIImage)
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: frame.size)

        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self = self else {
                completion(nil)
                return
            }

            guard let image = image else {
                print("⚠️  OverlayCaptureManager: Failed to capture \(kind): \(error?.localizedDescription ?? "unknown")")
                completion(nil)
                return
            }

            // Convert UIImage → MTLTexture
            if let texture = self.createMetalTexture(from: image, kind: kind) {
                self.cachedTextures[kind] = texture
                self.lastCaptureTime[kind] = Date()
                completion(texture)
            } else {
                completion(nil)
            }
        }
    }

    /// Clear cached texture for specific overlay (called when overlay disabled)
    func clearCache(for kind: String) {
        cachedTextures.removeValue(forKey: kind)
        lastCaptureTime.removeValue(forKey: kind)
        print("🗑️  OverlayCaptureManager: Cleared cache for \(kind)")
    }

    /// Clear all cached textures (called when overlays disabled globally)
    func clearAllCaches() {
        cachedTextures.removeAll()
        lastCaptureTime.removeAll()
        print("🗑️  OverlayCaptureManager: Cleared all texture caches")
    }

    // MARK: - Private Methods

    /**
     * Convert UIImage → MTLTexture via CVPixelBuffer intermediate
     * Path: UIImage → CGImage → CVPixelBuffer (BGRA) → MTLTexture
     *
     * IMPORTANT: Using kCVPixelFormatType_32BGRA for compatibility with Metal shaders
     * (matches VideoProcessor's expected format)
     */
    private func createMetalTexture(from image: UIImage, kind: String) -> MTLTexture? {
        guard let cgImage = image.cgImage else {
            print("❌ OverlayCaptureManager: No CGImage for \(kind)")
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height

        // Create CVPixelBuffer with Metal-compatible format
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA, // BGRA8 format (matches Metal shader expectations)
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer = pixelBuffer else {
            print("❌ OverlayCaptureManager: Failed to create CVPixelBuffer for \(kind)")
            return nil
        }

        // Render CGImage → CVPixelBuffer
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue // Premultiplied alpha for Metal blending
        )

        guard let context = context else {
            print("❌ OverlayCaptureManager: Failed to create CGContext for \(kind)")
            return nil
        }

        // Draw image into pixel buffer (flipped coordinate system)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // CVPixelBuffer → MTLTexture using texture cache
        guard let cache = textureCache else {
            print("❌ OverlayCaptureManager: No texture cache for \(kind)")
            return nil
        }

        var cvTexture: CVMetalTexture?
        let texStatus = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            .bgra8Unorm, // Metal pixel format
            width, height, 0,
            &cvTexture
        )

        guard texStatus == kCVReturnSuccess, let cvTexture = cvTexture else {
            print("❌ OverlayCaptureManager: Failed to create Metal texture for \(kind)")
            return nil
        }

        guard let texture = CVMetalTextureGetTexture(cvTexture) else {
            print("❌ OverlayCaptureManager: Failed to get MTLTexture from CVMetalTexture for \(kind)")
            return nil
        }

        print("✅ OverlayCaptureManager: Captured \(kind) overlay: \(width)x\(height)")
        return texture
    }
}
#endif // !os(macOS)
