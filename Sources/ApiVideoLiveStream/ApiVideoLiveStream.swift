//
//  ApiVideoLiveStream.swift
//

import AVFoundation
import Foundation
import HaishinKit
#if !os(macOS)
import UIKit
#endif
import VideoToolbox

public class ApiVideoLiveStream {
    private let rtmpStream: RTMPStream
    private let rtmpConnection = RTMPConnection()

    private var streamKey: String = ""
    private var url: String = ""

    private var isAudioConfigured = false
    private var isVideoConfigured = false

    // MultiCam integration
    #if os(iOS)
    @available(iOS 13.0, *)
    private var multiCamController: MultiCameraController?
    private var useMultiCam = false
    private var orientationUpdatesEnabled = true
    #endif

    // Local recording
    private var localRecorder: LocalRecorder?

    #if os(iOS)
    private func currentVideoOrientation() -> AVCaptureVideoOrientation? {
        // ALWAYS use device physical orientation sensors, never UI interface orientation
        // This ensures correct video rotation even when UI is locked portrait
        let deviceOrientation = UIDevice.current.orientation

        if deviceOrientation != .unknown,
           deviceOrientation != .faceUp,
           deviceOrientation != .faceDown,
           let orientation = DeviceUtil.videoOrientation(by: deviceOrientation) {
            return orientation
        }

        // Fallback to portrait only if device orientation is unavailable
        // DO NOT check interfaceOrientation - it reflects UI lock, not physical device rotation
        return DeviceUtil.videoOrientation(by: UIDeviceOrientation.portrait)
    }

    private func applyVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        self.rtmpStream.lockQueue.async {
            self.rtmpStream.videoOrientation = orientation

            if let captureUnit = self.rtmpStream.videoCapture(for: 0) {
                captureUnit.videoOrientation = orientation
            }

            let currentVideoSize = self.rtmpStream.videoSettings.videoSize
            let isLandscape = orientation.isLandscape
            let targetWidth = isLandscape
                ? max(currentVideoSize.width, currentVideoSize.height)
                : min(currentVideoSize.width, currentVideoSize.height)
            let targetHeight = isLandscape
                ? min(currentVideoSize.width, currentVideoSize.height)
                : max(currentVideoSize.width, currentVideoSize.height)

            self.rtmpStream.videoSettings.videoSize = CGSize(width: targetWidth, height: targetHeight)
        }

        if #available(iOS 13.0, *), useMultiCam, let multiCamController = multiCamController {
            DispatchQueue.main.async {
                multiCamController.setOrientation(orientation)
            }
        }
    }

    public func setOrientationUpdatesEnabled(_ enabled: Bool) {
        orientationUpdatesEnabled = enabled
        if !enabled, let orientation = currentVideoOrientation() {
            applyVideoOrientation(orientation)
        }
    }
    #endif

    /// The delegate of the ApiVideoLiveStream
    public weak var delegate: ApiVideoLiveStreamDelegate?

    ///  Getter and Setter for an AudioConfig
    public var audioConfig: AudioConfig {
        get {
            AudioConfig(bitrate: self.rtmpStream.audioSettings.bitRate)
        }
        set {
            self.prepareAudio(audioConfig: newValue)
        }
    }

    /// Getter and Setter for a VideoConfig
    public var videoConfig: VideoConfig {
        get {
            VideoConfig(
                bitrate: Int(self.rtmpStream.videoSettings.bitRate),
                resolution: CGSize(
                    width: Int(self.rtmpStream.videoSettings.videoSize.width),
                    height: Int(self.rtmpStream.videoSettings.videoSize.height)
                ),
                fps: self.rtmpStream.frameRate,
                gopDuration: TimeInterval(self.rtmpStream.videoSettings.maxKeyFrameIntervalDuration)
            )
        }
        set {
            self.prepareVideo(videoConfig: newValue)
        }
    }

    /// Getter and Setter for the Bitrate number for the video
    public var videoBitrate: Int {
        get {
            self.rtmpStream.videoSettings.bitRate
        }
        set(newValue) {
            self.rtmpStream.videoSettings.bitRate = newValue
        }
    }

    private var lastCamera: AVCaptureDevice?

    /// Camera position
    public var cameraPosition: AVCaptureDevice.Position {
        get {
            #if os(iOS)
            if #available(iOS 13.0, *), useMultiCam, let multiCam = multiCamController {
                return multiCam.activeCamera == .front ? .front : .back
            }
            #endif
            guard let position = rtmpStream.videoCapture(for: 0)?.device?.position else {
                return AVCaptureDevice.Position.unspecified
            }
            return position
        }
        set(newValue) {
            #if os(iOS)
            if #available(iOS 13.0, *), useMultiCam, let multiCam = multiCamController {
                do {
                    try multiCam.switchCamera()
                } catch {
                    print("[ApiVideo] MultiCam switch failed: \(error)")
                }
                return
            }
            #endif
            self.attachCamera(newValue)
        }
    }

    /// Camera device
    public var camera: AVCaptureDevice? {
        get {
            self.rtmpStream.videoCapture(for: 0)?.device
        }
        set(newValue) {
            self.attachCamera(newValue)
        }
    }

    /// Mutes or unmutes audio capture.
    public var isMuted: Bool {
        get {
            !self.rtmpStream.hasAudio
        }
        set(newValue) {
            self.rtmpStream.hasAudio = !newValue
        }
    }

    #if os(iOS)
    /// Zoom on the video capture
    public var zoomRatio: CGFloat {
        get {
            guard let device = rtmpStream.videoCapture(for: 0)?.device else {
                return 1.0
            }
            return device.videoZoomFactor
        }
        set(newValue) {
            guard let device = rtmpStream.videoCapture(for: 0)?.device, newValue >= 1,
                  newValue < device.activeFormat.videoMaxZoomFactor else
            {
                return
            }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = newValue
                device.unlockForConfiguration()
            } catch let error as NSError {
                print("Error while locking device for zoom ramp: \(error)")
            }
        }
    }
    #endif

    /// Creates a new ApiVideoLiveStream object without a preview
    /// - Parameters:
    ///   - initialAudioConfig: The ApiVideoLiveStream's initial AudioConfig
    ///   - initialVideoConfig: The ApiVideoLiveStream's initial VideoConfig
    ///   - initialCamera: The ApiVideoLiveStream's initial camera device
    public init(
        initialAudioConfig: AudioConfig? = AudioConfig(),
        initialVideoConfig: VideoConfig? = VideoConfig(),
        initialCamera: AVCaptureDevice? = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        )
    ) throws {
        #if os(iOS)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        let session = AVAudioSession.sharedInstance()

        // https://stackoverflow.com/questions/51010390/avaudiosession-setcategory-swift-4-2-ios-12-play-sound-on-silent
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #endif

        self.rtmpStream = RTMPStream(connection: self.rtmpConnection)

        // Force default resolution because HK default resolution is not supported (480x272)
        self.rtmpStream.videoSettings = VideoCodecSettings(videoSize: .init(width: 1_280, height: 720))

        #if os(iOS)
        if let orientation = currentVideoOrientation() {
            applyVideoOrientation(orientation)
        }
        #endif

        // Initialize camera with MultiCam support
        if let initialCamera = initialCamera {
            #if os(iOS)
            if #available(iOS 13.0, *) {
                NSLog("[ApiVideo] iOS 13+ detected, checking MultiCam support...")
                NSLog("[ApiVideo] MultiCam.isSupported = \(MultiCameraController.isSupported)")
                if MultiCameraController.isSupported {
                    NSLog("[ApiVideo] ✅ MultiCam supported! Using position-based init")
                    self.attachCamera(initialCamera.position)
                } else {
                    NSLog("[ApiVideo] ❌ MultiCam NOT supported, using legacy init")
                    self.attachCamera(initialCamera)
                }
            } else {
                NSLog("[ApiVideo] iOS < 13, using legacy init")
                self.attachCamera(initialCamera)
            }
            #else
            self.attachCamera(initialCamera)
            #endif
        }
        if let initialVideoConfig = initialVideoConfig {
            self.prepareVideo(videoConfig: initialVideoConfig)
        }

        // ALWAYS configure audio settings (sets bitrate, marks isAudioConfigured = true)
        // This is required for stream validation and RTMP encoder configuration
        if let initialAudioConfig = initialAudioConfig {
            self.prepareAudio(audioConfig: initialAudioConfig)
        }

        // ONLY attach legacy audio capture if MultiCam is NOT active
        // MultiCam provides its own audio via delegate (prevents dual audio sources)
        if !useMultiCam {
            self.attachAudio()
        } else {
            NSLog("[ApiVideo] ✅ MultiCam active - using MultiCam audio capture (legacy attachAudio skipped)")
        }

        #if !os(macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.didEnterBackground(_:)),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        #endif

        self.rtmpConnection.addEventListener(.rtmpStatus, selector: #selector(self.rtmpStatusHandler), observer: self)
        self.rtmpConnection.addEventListener(.ioError, selector: #selector(self.rtmpErrorHandler), observer: self)

        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.orientationDidChange(_:)),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        #endif
    }

    #if !os(macOS)
    /// Creates a new ApiVideoLiveStream object with a UIView as preview
    /// - Parameters:
    ///   - preview: The UIView where to display the preview of camera
    ///   - initialAudioConfig: The ApiVideoLiveStream's new AudioConfig
    ///   - initialVideoConfig: The ApiVideoLiveStream's new VideoConfig
    ///   - initialCamera: The ApiVideoLiveStream's initial camera device
    public convenience init(
        preview: UIView,
        initialAudioConfig: AudioConfig? = AudioConfig(),
        initialVideoConfig: VideoConfig? = VideoConfig(),
        initialCamera: AVCaptureDevice? = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        )
    ) throws {
        try self.init(
            initialAudioConfig: initialAudioConfig,
            initialVideoConfig: initialVideoConfig,
            initialCamera: initialCamera
        )

        let mthkView = MTHKView(frame: preview.bounds)
        mthkView.translatesAutoresizingMaskIntoConstraints = false
        mthkView.videoGravity = AVLayerVideoGravity.resizeAspectFill
        mthkView.attachStream(self.rtmpStream)

        preview.addSubview(mthkView)

        let maxWidth = mthkView.widthAnchor.constraint(lessThanOrEqualTo: preview.widthAnchor)
        let maxHeight = mthkView.heightAnchor.constraint(lessThanOrEqualTo: preview.heightAnchor)
        let width = mthkView.widthAnchor.constraint(equalTo: preview.widthAnchor)
        let height = mthkView.heightAnchor.constraint(equalTo: preview.heightAnchor)
        let centerX = mthkView.centerXAnchor.constraint(equalTo: preview.centerXAnchor)
        let centerY = mthkView.centerYAnchor.constraint(equalTo: preview.centerYAnchor)

        width.priority = .defaultHigh
        height.priority = .defaultHigh

        NSLayoutConstraint.activate([
            maxWidth, maxHeight, width, height, centerX, centerY
        ])
    }
    #endif

    /// Creates a new ApiVideoLiveStream object with a NetStreamDrawable
    /// - Parameters:
    ///   - preview: The NetStreamDrawable where to display the preview of camera
    ///   - initialAudioConfig: The ApiVideoLiveStream's new AudioConfig
    ///   - initialVideoConfig: The ApiVideoLiveStream's new VideoConfig
    ///   - initialCamera: The ApiVideoLiveStream's initial camera device
    public convenience init(
        preview: IOStreamDrawable,
        initialAudioConfig: AudioConfig? = AudioConfig(),
        initialVideoConfig: VideoConfig? = VideoConfig(),
        initialCamera: AVCaptureDevice? = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        )
    ) throws {
        try self.init(
            initialAudioConfig: initialAudioConfig,
            initialVideoConfig: initialVideoConfig,
            initialCamera: initialCamera
        )
        preview.attachStream(self.rtmpStream)
    }

    deinit {
        #if os(iOS)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        #endif
        #if !os(macOS)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        #endif
        rtmpConnection.removeEventListener(.rtmpStatus, selector: #selector(rtmpStatusHandler), observer: self)
        rtmpConnection.removeEventListener(.ioError, selector: #selector(rtmpErrorHandler), observer: self)
    }

    private func attachCamera(_ cameraPosition: AVCaptureDevice.Position) {
        #if os(iOS)
        if #available(iOS 13.0, *), MultiCameraController.isSupported {
            setupMultiCam(initialPosition: cameraPosition)
            return
        }
        #endif

        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition)
        self.attachCamera(camera)
    }

    private func attachCamera(_ camera: AVCaptureDevice?) {
        self.lastCamera = camera

        // HaishinKit 1.7.3: attachCamera has channel parameter with configuration callback
        self.rtmpStream.attachCamera(camera, channel: 0) { videoCaptureUnit, error in
            if let err = error {
                print("======== Camera error ==========")
                print(err)
                // error is IOVideoUnitError, extract underlying Error if available
                switch err {
                case .failedToAttach(let underlyingError):
                    if let underlyingError {
                        self.delegate?.videoError(underlyingError)
                    } else {
                        self.delegate?.videoError(err)  // Pass IOVideoUnitError itself
                    }
                default:
                    self.delegate?.videoError(err)
                }
                return
            }

            if let camera {
                videoCaptureUnit?.isVideoMirrored = camera.position == .front
            }
            if let orientation = self.currentVideoOrientation() {
                videoCaptureUnit?.videoOrientation = orientation
            }
            #if os(iOS)
            // videoCaptureUnit.preferredVideoStabilizationMode = AVCaptureVideoStabilizationMode
            //   .auto // Add latency to video
            #endif

            guard let device = videoCaptureUnit?.device else {
                return
            }
            self.rtmpStream.lockQueue.async {
                do {
                    try device.lockForConfiguration()
                    if device.isExposureModeSupported(AVCaptureDevice.ExposureMode.continuousAutoExposure) {
                        device.exposureMode = AVCaptureDevice.ExposureMode.continuousAutoExposure
                    }
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    device.unlockForConfiguration()
                } catch {
                    print("Could not lock device for exposure and focus: \(error)")
                }
            }
        }
    }

    #if os(iOS)
    @available(iOS 13.0, *)
    private func setupMultiCam(initialPosition: AVCaptureDevice.Position) {
        NSLog("[ApiVideo] 🎬 setupMultiCam called with position: \(initialPosition)")
        let controller = MultiCameraController()
        controller.delegate = self

        let cameraPos: CameraPosition = initialPosition == .front ? .front : .back
        NSLog("[ApiVideo] Attempting MultiCam setup...")
        do {
            try controller.setup(initialCamera: cameraPos)
            NSLog("[ApiVideo] MultiCam setup() succeeded, starting...")
            controller.start()
            multiCamController = controller
            useMultiCam = true
            if let orientation = self.currentVideoOrientation() {
                controller.setOrientation(orientation)
            }
            // Disable HaishinKit’s internal microphone graph to prevent duplicate audio
            self.rtmpStream.attachAudio(nil)
            self.rtmpStream.hasAudio = true  // keep encoder active
            NSLog("[ApiVideo] 🧩 Detached default HaishinKit audio input (MultiCam handles audio)")

            NSLog("[ApiVideo] ✅ ✅ ✅ MULTICAM MODE ACTIVE - INSTANT SWITCHING ENABLED ✅ ✅ ✅")
        } catch {
            NSLog("[ApiVideo] ❌ MultiCam setup failed: \(error), falling back to legacy")
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: initialPosition)
            attachCamera(camera)
        }
    }
    #endif

    private func prepareVideo(videoConfig: VideoConfig) {
        self.rtmpStream.frameRate = videoConfig.fps
        self.rtmpStream.sessionPreset = AVCaptureSession.Preset.high

        let resolution = videoConfig.resolution
        let width = self.rtmpStream.videoOrientation
            .isLandscape ? max(resolution.width, resolution.height) : min(resolution.width, resolution.height)
        let height = self.rtmpStream.videoOrientation
            .isLandscape ? min(resolution.width, resolution.height) : max(resolution.width, resolution.height)

        self.rtmpStream.videoSettings = VideoCodecSettings(
            videoSize: CGSize(width: width, height: height),
            bitRate: videoConfig.bitrate,
            profileLevel: kVTProfileLevel_H264_Baseline_5_2 as String,
            maxKeyFrameIntervalDuration: Int32(videoConfig.gopDuration)
        )

        self.isVideoConfigured = true
    }

    private func attachAudio() {
        self.rtmpStream.attachAudio(AVCaptureDevice.default(for: AVMediaType.audio)) { error in
            print("======== Audio error ==========")
            print(error)
            self.delegate?.audioError(error)
        }
    }

    private func prepareAudio(audioConfig: AudioConfig) {
        // HaishinKit 1.7.3 uses AudioCodecSettings.default with bitRate property
        var audioSettings = AudioCodecSettings()
        audioSettings.bitRate = audioConfig.bitrate
        self.rtmpStream.audioSettings = audioSettings

        self.isAudioConfigured = true
    }

    /// Start your livestream
    /// - Parameters:
    ///   - streamKey: The key of your live
    ///   - url: The url of your rtmp server, by default it's rtmp://broadcast.api.video/s
    /// - Returns: Void
    public func startStreaming(streamKey: String, url: String = "rtmp://broadcast.api.video/s") throws {
        if streamKey.isEmpty {
            throw LiveStreamError.IllegalArgumentError("Stream key must not be empty")
        }
        if url.isEmpty {
            throw LiveStreamError.IllegalArgumentError("URL must not be empty")
        }
        if !self.isAudioConfigured || !self.isVideoConfigured {
            throw LiveStreamError.IllegalOperationError("Missing audio and/or video configuration")
        }

        self.streamKey = streamKey
        self.url = url

        self.rtmpConnection.connect(url)
    }

    /// Stop your livestream
    /// - Returns: Void
    public func stopStreaming() {
        let isConnected = self.rtmpConnection.connected
        self.rtmpConnection.close()
        if isConnected {
            self.delegate?.disconnection()
        }
    }

    // MARK: - Local Recording
    /// Start recording stream to local file
    /// - Throws: Error if recording cannot be started
    public func startLocalRecording() throws {
        NSLog("[ApiVideoLiveStream] startLocalRecording() called")
        if localRecorder == nil {
            NSLog("[ApiVideoLiveStream] Creating new LocalRecorder instance")
            localRecorder = LocalRecorder()
        } else {
            NSLog("[ApiVideoLiveStream] Reusing existing LocalRecorder instance")
        }
        NSLog("[ApiVideoLiveStream] Calling localRecorder.startRecording()")
        try localRecorder?.startRecording()
        NSLog("[ApiVideoLiveStream] startLocalRecording() completed successfully")
    }

    /// Stop recording and return local file URL
    /// - Parameter completion: Callback with file URL (nil if recording failed)
    public func stopLocalRecording(completion: @escaping (URL?) -> Void) {
        NSLog("[ApiVideoLiveStream] stopLocalRecording() called")
        if localRecorder == nil {
            NSLog("[ApiVideoLiveStream] ❌ localRecorder is nil - cannot stop recording")
            completion(nil)
            return
        }
        NSLog("[ApiVideoLiveStream] Calling localRecorder.stopRecording()")
        localRecorder?.stopRecording(completion: completion)
    }

    public func startPreview() {
        guard let lastCamera = lastCamera else {
            print("No camera has been set")
            return
        }
        self.attachCamera(lastCamera)

        // Audio attachment removed - already handled in init()
        // - MultiCam mode: Uses delegate audio (didOutputAudioSampleBuffer)
        // - Legacy mode: Already attached in init() at line 214
        // DO NOT attach audio here - causes duplicate audio sources (3-channel chaos)
    }

    public func stopPreview() {
        // HaishinKit 1.7.3 doesn't have channel parameter
        self.rtmpStream.attachCamera(nil)
        self.rtmpStream.attachAudio(nil)
    }

    @objc
    private func rtmpStatusHandler(_ notification: Notification) {
        let e = Event.from(notification)
        guard let data: ASObject = e.data as? ASObject,
              let code: String = data["code"] as? String,
              let level: String = data["level"] as? String else
        {
            print("rtmpStatusHandler: failed to parse event: \(e)")
            return
        }
        switch code {
        case RTMPConnection.Code.connectSuccess.rawValue:
            self.rtmpStream.publish(self.streamKey)

        case RTMPStream.Code.publishStart.rawValue:
            self.delegate?.connectionSuccess()

        case RTMPConnection.Code.connectClosed.rawValue:
            self.delegate?.disconnection()

        default:
            if level == "error" {
                self.delegate?.connectionFailed(code)
            }
        }
    }

    @objc
    private func rtmpErrorHandler(_ notification: Notification) {
        let e = Event.from(notification)
        print("rtmpErrorHandler: \(e)")
        DispatchQueue.main.async {
            self.rtmpConnection.connect(self.url)
        }
    }

    #if os(iOS)
    @objc
    private func orientationDidChange(_: Notification) {
        guard orientationUpdatesEnabled else {
            return
        }
        guard let orientation = currentVideoOrientation() else {
            return
        }
        applyVideoOrientation(orientation)
    }
    #endif

    #if !os(macOS)
    @objc
    private func didEnterBackground(_: Notification) {
        self.stopStreaming()
    }
    #endif
}

public protocol ApiVideoLiveStreamDelegate: AnyObject {
    /// Called when the connection to the rtmp server is successful
    func connectionSuccess()

    /// Called when the connection to the rtmp server failed
    func connectionFailed(_ code: String)

    /// Called when the connection to the rtmp server is closed
    func disconnection()

    /// Called if an error happened during the audio configuration
    func audioError(_ error: Error)

    /// Called if an error happened during the video configuration
    func videoError(_ error: Error)
}

extension AVCaptureVideoOrientation {
    var isLandscape: Bool {
        self == .landscapeLeft || self == .landscapeRight
    }
}

public enum LiveStreamError: Error {
    case IllegalArgumentError(String)
    case IllegalOperationError(String)
}


    // MARK: - VideoProcessor Integration
    private var videoProcessor: VideoProcessor?

    public func enableOverlayCompositing() {
        guard let processor = VideoProcessor() else {
            print("❌ ApiVideoLiveStream: Could not initialize VideoProcessor")
            return
        }
        videoProcessor = processor
        print("✅ ApiVideoLiveStream: Overlay compositing enabled")
    }

    public func disableOverlayCompositing() {
        videoProcessor = nil
        print("✅ ApiVideoLiveStream: Overlay compositing disabled")
    }

    public func updateSubGoal(current: Int, target: Int, visible: Bool) {
        // TODO: Pass to VideoProcessor's OverlayRenderer
        print("📊 ApiVideoLiveStream: SubGoal updated - \(current)/\(target) visible: \(visible)")
    }

    public func updateFollowerGoal(current: Int, target: Int, visible: Bool) {
        // TODO: Pass to VideoProcessor's OverlayRenderer
        print("📊 ApiVideoLiveStream: FollowerGoal updated - \(current)/\(target) visible: \(visible)")
    }

// MARK: - MultiCameraControllerDelegate
#if os(iOS)
@available(iOS 13.0, *)
extension ApiVideoLiveStream: MultiCameraControllerDelegate {
    public func multiCameraController(_ controller: MultiCameraController,
                                      didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer) {
        var finalSampleBuffer = sampleBuffer

        // Apply overlay compositing if enabled
        if let processor = videoProcessor,
           let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
           let processedBuffer = processor.process(pixelBuffer: imageBuffer) {
            // Create new CMSampleBuffer with processed pixel buffer
            // Reuse original timing info for A/V sync
            var newSampleBuffer: CMSampleBuffer?
            var timingInfo = CMSampleTimingInfo()
            CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)

            var formatDescription: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: processedBuffer,
                formatDescriptionOut: &formatDescription
            )

            if let formatDescription = formatDescription {
                CMSampleBufferCreateReadyWithImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: processedBuffer,
                    formatDescription: formatDescription,
                    sampleTiming: &timingInfo,
                    sampleBufferOut: &newSampleBuffer
                )

                if let newSampleBuffer = newSampleBuffer {
                    finalSampleBuffer = newSampleBuffer
                }
            }
        }

        // HaishinKit 1.7.3: IOStream.append() auto-detects media type
        rtmpStream.append(finalSampleBuffer)
        // Feed video to local recorder
        localRecorder?.appendVideo(sampleBuffer: finalSampleBuffer)
    }

    public func multiCameraController(_ controller: MultiCameraController,
                                      didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        // MultiCam audio source (only active when useMultiCam == true)
        // Legacy attachAudio() is disabled when MultiCam is active to prevent dual audio sources
        rtmpStream.append(sampleBuffer)
        // Feed audio to local recorder
        localRecorder?.appendAudio(sampleBuffer: sampleBuffer)
    }

    public func multiCameraController(_ controller: MultiCameraController,
                                      didSwitchTo camera: CameraPosition) {
        print("[ApiVideo] ✅ Switched to \(camera) camera")
    }
}
#endif
