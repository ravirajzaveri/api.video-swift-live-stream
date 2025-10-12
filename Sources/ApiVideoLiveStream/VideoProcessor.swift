
/**
 * PROBLEM: WebView overlays cause performance degradation in Flutter
 * ISSUE: Each WebView (chat, sub goals, follower goals) consumes significant CPU/GPU
 * ROOT CAUSE: WebView rendering pipeline conflicts with camera preview rendering
 * SOLUTION: Metal-based native overlay compositor with zero-copy buffer management
 * IMPACT: Estimated 40-60% CPU reduction, 3-5ms render time per frame on A14+
 *
 * Phase 1: Core Pipeline - YUV/BGRA → Composited BGRA output
 * Phase 2: Overlay Ingestion - Native CALayer rendering for overlays
 * Phase 3: HaishinKit Integration - Direct encoder feed
 */

import Foundation
import CoreVideo
import Metal
import MetalKit
import Dispatch

#if !os(macOS)
class VideoProcessor {
    // Metal resources
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache!

    // Overlay texture heap for efficient memory management
    private var overlayTextureHeap: MTLHeap?
    private var subGoalTexture: MTLTexture?
    private var followerGoalTexture: MTLTexture?
    private var chatTexture: MTLTexture?

    // Overlay renderer (native CALayer rendering - DEPRECATED, use WebView capture instead)
    private var overlayRenderer: OverlayRenderer?

    // WebView capture manager (captures Flutter WebViews as Metal textures)
    private var webViewCaptureManager: OverlayCaptureManager?

    // Render pipeline states
    private var yuvRenderPipelineState: MTLRenderPipelineState!
    private var bgraRenderPipelineState: MTLRenderPipelineState!

    // Buffer pool for output pixel buffers (pre-warmed to 8)
    private var outputPixelBufferPool: CVPixelBufferPool?

    // Backpressure management (max 3 in-flight buffers)
    private let frameSemaphore = DispatchSemaphore(value: 3)

    // Dedicated serial queue for all Metal operations
    private let metalQueue = DispatchQueue(label: "com.plusreps.metal", qos: .userInteractive)

    // Overlay state (controlled via Flutter API)
    struct OverlayState {
        var chatVisible: Bool = false
        var subGoalVisible: Bool = false
        var followerGoalVisible: Bool = false
        var chatRect: CGRect = .zero
        var subGoalRect: CGRect = .zero
        var followerGoalRect: CGRect = .zero
        var chatOpacity: Float = 1.0
        var subGoalOpacity: Float = 1.0
        var followerGoalOpacity: Float = 1.0
    }
    var overlayState = OverlayState()

    // Performance diagnostics
    private var frameCount: Int = 0
    private var droppedFrames: Int = 0
    private var lastLogTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("❌ VideoProcessor: Metal not supported on this device")
            return nil
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            print("❌ VideoProcessor: Could not create Metal command queue")
            return nil
        }
        self.commandQueue = commandQueue

        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) != kCVReturnSuccess {
            print("❌ VideoProcessor: Could not create texture cache")
            return nil
        }

        // Initialize overlay renderer (DEPRECATED - fallback only)
        self.overlayRenderer = OverlayRenderer(device: device)

        // Initialize WebView capture manager (primary overlay source)
        self.webViewCaptureManager = OverlayCaptureManager(device: device)

        if webViewCaptureManager != nil {
            print("✅ VideoProcessor: Initialized with WebView capture support")
        } else {
            print("⚠️  VideoProcessor: WebView capture unavailable, falling back to OverlayRenderer")
        }
    }

    // MARK: - Overlay State Updates (called from ApiVideoLiveStream)

    // Legacy API: Update overlay state (for OverlayRenderer fallback)
    func updateSubGoal(current: Int, target: Int, visible: Bool) {
        overlayRenderer?.updateSubGoalState(current: current, target: target, visible: visible)
        overlayState.subGoalVisible = visible
    }

    func updateFollowerGoal(current: Int, target: Int, visible: Bool) {
        overlayRenderer?.updateFollowerGoalState(current: current, target: target, visible: visible)
        overlayState.followerGoalVisible = visible
    }

    // NEW API: Update WebView textures (called from Flutter via method channel)
    func updateWebViewTexture(kind: String, texture: MTLTexture, rect: CGRect, opacity: Float) {
        switch kind {
        case "chat":
            chatTexture = texture
            overlayState.chatRect = rect
            overlayState.chatOpacity = opacity
            overlayState.chatVisible = true
            print("✅ VideoProcessor: Updated chat WebView texture (\(Int(rect.width))x\(Int(rect.height)))")

        case "subGoal":
            subGoalTexture = texture
            overlayState.subGoalRect = rect
            overlayState.subGoalOpacity = opacity
            overlayState.subGoalVisible = true
            print("✅ VideoProcessor: Updated subGoal WebView texture (\(Int(rect.width))x\(Int(rect.height)))")

        case "followerGoal":
            followerGoalTexture = texture
            overlayState.followerGoalRect = rect
            overlayState.followerGoalOpacity = opacity
            overlayState.followerGoalVisible = true
            print("✅ VideoProcessor: Updated followerGoal WebView texture (\(Int(rect.width))x\(Int(rect.height)))")

        default:
            print("⚠️  VideoProcessor: Unknown overlay kind: \(kind)")
        }
    }

    // Clear specific overlay texture (called when overlay disabled)
    func clearWebViewTexture(kind: String) {
        switch kind {
        case "chat":
            chatTexture = nil
            overlayState.chatVisible = false
            webViewCaptureManager?.clearCache(for: kind)
        case "subGoal":
            subGoalTexture = nil
            overlayState.subGoalVisible = false
            webViewCaptureManager?.clearCache(for: kind)
        case "followerGoal":
            followerGoalTexture = nil
            overlayState.followerGoalVisible = false
            webViewCaptureManager?.clearCache(for: kind)
        default:
            break
        }
        print("🗑️  VideoProcessor: Cleared \(kind) WebView texture")
    }

    // MARK: - Buffer Pool Setup (Pre-warmed to prevent stalls)
    private func setupPixelBufferPool(width: Int, height: Int) {
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 8
        ]

        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, bufferAttributes as CFDictionary, &outputPixelBufferPool)

        // Pre-warm the pool to prevent allocation stalls during streaming
        let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary
        var pixelBuffers: [CVPixelBuffer] = []
        for _ in 0..<8 {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, outputPixelBufferPool!, auxAttributes, &pixelBuffer)
            if let pixelBuffer = pixelBuffer {
                pixelBuffers.append(pixelBuffer)
            }
        }
        print("✅ VideoProcessor: Pre-warmed \(pixelBuffers.count) buffers at \(width)x\(height)")
    }

    // MARK: - Pipeline Setup (Dual paths: YUV and BGRA)
    private func setupPipelines() {
        guard let library = device.makeDefaultLibrary() else {
            fatalError("❌ VideoProcessor: Could not create Metal library")
        }

        let vertexFunction = library.makeFunction(name: "vertexShader")

        // YUV pipeline (full-range BT.709 conversion)
        let yuvFragmentFunction = library.makeFunction(name: "compositeFrag")
        let yuvPipelineDescriptor = MTLRenderPipelineDescriptor()
        yuvPipelineDescriptor.vertexFunction = vertexFunction
        yuvPipelineDescriptor.fragmentFunction = yuvFragmentFunction
        yuvPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        yuvRenderPipelineState = try! device.makeRenderPipelineState(descriptor: yuvPipelineDescriptor)

        // BGRA pipeline (passthrough with overlay compositing)
        let bgraFragmentFunction = library.makeFunction(name: "compositeFragBGRA")
        let bgraPipelineDescriptor = MTLRenderPipelineDescriptor()
        bgraPipelineDescriptor.vertexFunction = vertexFunction
        bgraPipelineDescriptor.fragmentFunction = bgraFragmentFunction
        bgraPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        bgraRenderPipelineState = try! device.makeRenderPipelineState(descriptor: bgraPipelineDescriptor)

        print("✅ VideoProcessor: Pipeline states created (YUV + BGRA)")
    }


    // MARK: - Main Processing (with backpressure & diagnostics)
    func process(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        // Backpressure: Drop frame if 3 buffers already in-flight
        let result = frameSemaphore.wait(timeout: .now())
        if result == .timedOut {
            droppedFrames += 1
            return nil  // Drop frame silently, never stall camera
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if outputPixelBufferPool == nil {
            setupPixelBufferPool(width: width, height: height)
            setupPipelines()
        }

        // WebView textures are provided via updateWebViewTexture() from Flutter
        // No need to render overlays here - textures already captured by OverlayCaptureManager
        // Fallback to OverlayRenderer only if WebView capture is unavailable
        if webViewCaptureManager == nil, let renderer = overlayRenderer {
            // Fallback: Use legacy CALayer rendering
            if overlayState.subGoalVisible {
                subGoalTexture = renderer.renderSubGoalTexture(width: 320, height: 80)
            }
            if overlayState.followerGoalVisible {
                followerGoalTexture = renderer.renderFollowerGoalTexture(width: 320, height: 80)
            }
        }

        var outputPixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool!, &outputPixelBuffer)
        guard let outputPixelBuffer = outputPixelBuffer else {
            print("❌ VideoProcessor: Could not create output pixel buffer")
            frameSemaphore.signal()
            return nil
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("❌ VideoProcessor: Could not create command buffer")
            frameSemaphore.signal()
            return nil
        }

        commandBuffer.addCompletedHandler { _ in
            self.frameSemaphore.signal()
        }

        let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        var inputTextures: [MTLTexture] = []

        if isPlanar && pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            // YUV processing path (full-range BT.709)
            guard let yTexture = createTexture(from: pixelBuffer, pixelFormat: .r8Unorm, planeIndex: 0),
                  let cbcrTexture = createTexture(from: pixelBuffer, pixelFormat: .rg8Unorm, planeIndex: 1) else {
                print("❌ VideoProcessor: Could not create YUV textures")
                frameSemaphore.signal()
                return nil
            }
            inputTextures.append(yTexture)
            inputTextures.append(cbcrTexture)
        } else if !isPlanar && pixelFormat == kCVPixelFormatType_32BGRA {
            // BGRA processing path (passthrough)
            guard let bgraTexture = createTexture(from: pixelBuffer, pixelFormat: .bgra8Unorm, planeIndex: 0) else {
                print("❌ VideoProcessor: Could not create BGRA texture")
                frameSemaphore.signal()
                return nil
            }
            inputTextures.append(bgraTexture)
        } else {
            print("❌ VideoProcessor: Unsupported pixel format: \(pixelFormat)")
            frameSemaphore.signal()
            return nil
        }

        guard let outputTexture = createTexture(from: outputPixelBuffer, pixelFormat: .bgra8Unorm, planeIndex: 0) else {
            print("❌ VideoProcessor: Could not create output texture")
            frameSemaphore.signal()
            return nil
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = outputTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            print("❌ VideoProcessor: Could not create render command encoder")
            frameSemaphore.signal()
            return nil
        }

        if isPlanar {
            renderCommandEncoder.setRenderPipelineState(yuvRenderPipelineState)
            renderCommandEncoder.setFragmentTexture(inputTextures[0], index: 0)
            renderCommandEncoder.setFragmentTexture(inputTextures[1], index: 1)
            // Overlay textures for YUV path
            if overlayState.subGoalVisible, let subTex = subGoalTexture {
                renderCommandEncoder.setFragmentTexture(subTex, index: 2)
            }
            if overlayState.followerGoalVisible, let folTex = followerGoalTexture {
                renderCommandEncoder.setFragmentTexture(folTex, index: 3)
            }
        } else {
            renderCommandEncoder.setRenderPipelineState(bgraRenderPipelineState)
            renderCommandEncoder.setFragmentTexture(inputTextures[0], index: 0)
            // Overlay textures for BGRA path
            if overlayState.subGoalVisible, let subTex = subGoalTexture {
                renderCommandEncoder.setFragmentTexture(subTex, index: 1)
            }
            if overlayState.followerGoalVisible, let folTex = followerGoalTexture {
                renderCommandEncoder.setFragmentTexture(folTex, index: 2)
            }
        }

        // TODO: Set uniform buffer with overlay params

        renderCommandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderCommandEncoder.endEncoding()

        commandBuffer.commit()

        // Performance diagnostics (log every 1 second)
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLogTime >= 1.0 {
            let fps = Double(frameCount) / (now - lastLogTime)
            print("📊 VideoProcessor: \(String(format: "%.1f", fps)) FPS | Dropped: \(droppedFrames)")
            frameCount = 0
            droppedFrames = 0
            lastLogTime = now
        }

        return outputPixelBuffer
    }

    private func createTexture(from pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat, planeIndex: Int) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)

        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, pixelFormat, width, height, planeIndex, &texture)

        if status == kCVReturnSuccess,
           let metalTexture = CVMetalTextureGetTexture(texture!) {
            return metalTexture
        } else {
            return nil
        }
    }
}
#endif // !os(macOS)
