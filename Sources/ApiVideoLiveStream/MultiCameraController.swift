//
//  MultiCameraController.swift
//  ApiVideoLiveStream
//
//  Created for instant camera switching using AVCaptureMultiCamSession
//  Solves 9-second delay by keeping both cameras running simultaneously
//

#if os(iOS)
import AVFoundation
import Foundation
import HaishinKit
import UIKit

/// Position of camera device
public enum CameraPosition {
    case front
    case back
}

/// Controller for managing multiple cameras simultaneously
/// Enables instant camera switching (<100ms) by keeping both cameras running
@available(iOS 13.0, *)
public class MultiCameraController: NSObject {

    // MARK: - Properties

    private var multiCamSession: AVCaptureMultiCamSession?
    private var frontCameraInput: AVCaptureDeviceInput?
    private var backCameraInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?

    private(set) var activeCamera: CameraPosition = .front
    private var isConfigured = false
    private var currentOrientation: AVCaptureVideoOrientation = .portrait

    /// Delegate for receiving video/audio samples
    public weak var delegate: MultiCameraControllerDelegate?

    // Video settings
    private let videoQueue = DispatchQueue(label: "com.apivideo.multicam.video")
    private let audioQueue = DispatchQueue(label: "com.apivideo.multicam.audio")
    private var videoMuted = false

    // MARK: - Public API

    /// Check if device supports MultiCam (iPhone XS+, iOS 13+)
    public static var isSupported: Bool {
        return AVCaptureMultiCamSession.isMultiCamSupported
    }

    /// Setup both cameras and start session
    /// - Parameter initialCamera: Which camera to use initially
    /// - Throws: If cameras cannot be configured
    public func setup(initialCamera: CameraPosition = .front) throws {
        guard Self.isSupported else {
            throw MultiCamError.notSupported
        }

        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()

        // Configure cameras
        try configureCameras(session: session)

        // Configure audio
        try configureAudio(session: session)

        // Configure outputs
        try configureOutputs(session: session)

        // Connect active camera to outputs
        activeCamera = initialCamera
        currentOrientation = resolveOrientation()
        connectCamera(activeCamera, to: session)

        session.commitConfiguration()

        multiCamSession = session
        isConfigured = true

        setOrientation(currentOrientation)

        print("[MultiCam] ✅ Setup complete - both cameras ready")
    }

    /// Start the capture session
    public func start() {
        guard let session = multiCamSession else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
            print("[MultiCam] 📹 Session started")
        }
    }

    /// Stop the capture session
    public func stop() {
        guard let session = multiCamSession else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
            print("[MultiCam] ⏹️ Session stopped")
        }
    }

    /// Switch camera instantly (<100ms)
    /// - Throws: If session not configured
    public func switchCamera() throws {
        guard let session = multiCamSession, isConfigured else {
            throw MultiCamError.notConfigured
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        session.beginConfiguration()

        // Remove all video connections
        for connection in session.connections {
            if connection.output == videoDataOutput {
                session.removeConnection(connection)
            }
        }

        // Toggle active camera
        activeCamera = activeCamera == .front ? .back : .front

        // Connect new camera
        connectCamera(activeCamera, to: session)

        session.commitConfiguration()

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("[MultiCam] ⚡ Camera switched in \(Int(elapsed))ms")

        delegate?.multiCameraController(self, didSwitchTo: activeCamera)

        setOrientation(currentOrientation)
    }

    /// Cleanup and release resources
    public func cleanup() {
        stop()
        multiCamSession = nil
        frontCameraInput = nil
        backCameraInput = nil
        audioInput = nil
        videoDataOutput = nil
        audioDataOutput = nil
        isConfigured = false

        print("[MultiCam] 🧹 Cleaned up")
    }

    // MARK: - Private Configuration

    private func configureCameras(session: AVCaptureMultiCamSession) throws {
        // Get front camera
        guard let frontDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) else {
            throw MultiCamError.cameraNotFound(.front)
        }

        // Get back camera
        guard let backDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw MultiCamError.cameraNotFound(.back)
        }

        // Configure camera settings
        try configureCameraDevice(frontDevice)
        try configureCameraDevice(backDevice)

        // Create inputs
        let frontInput = try AVCaptureDeviceInput(device: frontDevice)
        let backInput = try AVCaptureDeviceInput(device: backDevice)

        // Add both inputs WITHOUT automatic connections
        session.addInputWithNoConnections(frontInput)
        session.addInputWithNoConnections(backInput)

        frontCameraInput = frontInput
        backCameraInput = backInput

        print("[MultiCam] 📷 Front camera configured")
        print("[MultiCam] 📷 Back camera configured")
    }

    private func configureCameraDevice(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()

        // Set video quality
        if device.supportsSessionPreset(.hd1280x720) {
            // 720p for streaming
        }

        // Enable auto focus if supported
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }

        // Enable auto exposure if supported
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        // Enable auto white balance if supported
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }

        device.unlockForConfiguration()
    }

    private func configureAudio(session: AVCaptureMultiCamSession) throws {
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            print("[MultiCam] ⚠️ No audio device found")
            return
        }

        let audioInput = try AVCaptureDeviceInput(device: audioDevice)

        if session.canAddInput(audioInput) {
            session.addInput(audioInput)
            self.audioInput = audioInput
            print("[MultiCam] 🎤 Audio configured")
        }
    }

    private func configureOutputs(session: AVCaptureMultiCamSession) throws {
        // Video output
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true

        session.addOutputWithNoConnections(videoOutput)
        self.videoDataOutput = videoOutput

        print("[MultiCam] 🎬 Video output configured")

        // Audio output
        if audioInput != nil {
            let audioOutput = AVCaptureAudioDataOutput()
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)

            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                self.audioDataOutput = audioOutput
                print("[MultiCam] 🔊 Audio output configured")
            }
        }
    }

    private func connectCamera(_ position: CameraPosition, to session: AVCaptureMultiCamSession) {
        let input = position == .front ? frontCameraInput : backCameraInput
        guard let deviceInput = input, let output = videoDataOutput else {
            print("[MultiCam] ❌ Cannot connect \(position) camera - missing input/output")
            return
        }

        // Find video port
        guard let videoPort = deviceInput.ports.first(where: { $0.mediaType == .video }) else {
            print("[MultiCam] ❌ No video port found for \(position) camera")
            return
        }

        // Create connection
        let connection = AVCaptureConnection(inputPorts: [videoPort], output: output)

        // Configure connection
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = currentOrientation
        }

        // Mirror front camera
        if position == .front, connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }

        // Add connection
        if session.canAddConnection(connection) {
            session.addConnection(connection)
            print("[MultiCam] ✅ Connected \(position) camera to output")
        } else {
            print("[MultiCam] ❌ Cannot add connection for \(position) camera")
        }
    }

    private func resolveOrientation() -> AVCaptureVideoOrientation {
        let deviceOrientation = UIDevice.current.orientation
        if let orientation = DeviceUtil.videoOrientation(by: deviceOrientation) {
            return orientation
        }
        return .portrait
    }

    public func setOrientation(_ orientation: AVCaptureVideoOrientation) {
        currentOrientation = orientation
        guard let videoOutput = videoDataOutput else { return }

        for connection in videoOutput.connections where connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }
    }

    /**
     * PROBLEM: Screensaver toggle required keeping MultiCam session alive but hiding camera frames.
     * ROOT CAUSE: MultiCam kept forwarding frames to the delegate even when the UI asked for the screensaver.
     * SOLUTION: Allow ApiVideoLiveStream to mute video delivery without tearing down the whole session.
     */
    public func setVideoMuted(_ muted: Bool) {
        videoMuted = muted
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension MultiCameraController: AVCaptureVideoDataOutputSampleBufferDelegate,
                                  AVCaptureAudioDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Forward to delegate
        if output == videoDataOutput {
            if !videoMuted {
                delegate?.multiCameraController(self, didOutputVideoSampleBuffer: sampleBuffer)
            }
        } else if output == audioDataOutput {
            delegate?.multiCameraController(self, didOutputAudioSampleBuffer: sampleBuffer)
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Optionally handle dropped frames
        print("[MultiCam] ⚠️ Dropped frame")
    }
}

// MARK: - Delegate Protocol

public protocol MultiCameraControllerDelegate: AnyObject {
    func multiCameraController(_ controller: MultiCameraController,
                              didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer)

    func multiCameraController(_ controller: MultiCameraController,
                              didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer)

    func multiCameraController(_ controller: MultiCameraController,
                              didSwitchTo camera: CameraPosition)
}

// MARK: - Error Types

public enum MultiCamError: Error, LocalizedError {
    case notSupported
    case notConfigured
    case cameraNotFound(CameraPosition)

    public var errorDescription: String? {
        switch self {
        case .notSupported:
            return "Multi-camera capture not supported on this device (requires iPhone XS or newer)"
        case .notConfigured:
            return "Multi-camera controller not configured. Call setup() first."
        case .cameraNotFound(let position):
            return "Camera not found: \(position)"
        }
    }
}
#endif
