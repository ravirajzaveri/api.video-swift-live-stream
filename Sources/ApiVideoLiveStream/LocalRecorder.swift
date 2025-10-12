import Foundation
import AVFoundation

/**
 * LOCAL RECORDING IMPLEMENTATION
 *
 * PROBLEM: Users want to save stream recordings locally without uploading to api.video
 * ISSUE: api.video SDK only supports cloud streaming, no local file saving
 * ROOT CAUSE: No AVAssetWriter implementation for capturing camera+audio to local file
 * SOLUTION: Custom AVAssetWriter-based recorder that saves to temp directory
 * IMPACT: Users can record streams locally, save to gallery only if desired
 *
 * Captures video+audio from AVCaptureSession and writes to MP4 file in temp directory
 */
class LocalRecorder: NSObject {

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var isRecording = false
    private var sessionStartTime: CMTime?
    private var videoSettingsConfigured = false // Track if video settings are set from first frame

    override init() {
        super.init()
    }

    /// Start recording to a temporary MP4 file
    func startRecording() throws {
        guard !isRecording else {
            print("[LocalRecorder] Already recording")
            return
        }

        // Create temp file URL
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "plusreps_recording_\(Date().timeIntervalSince1970).mp4"
        let fileURL = tempDir.appendingPathComponent(filename)

        print("[LocalRecorder] 📁 Temp directory: \(tempDir.path)")
        print("[LocalRecorder] 📄 Recording filename: \(filename)")

        // Remove existing file if any
        try? FileManager.default.removeItem(at: fileURL)

        // Create asset writer
        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)

        // Video settings: Will be configured from first frame to match actual orientation
        // Use nil settings initially - we'll configure from first CMSampleBuffer dimensions
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        videoInput.expectsMediaDataInRealTime = true

        // Audio settings: AAC 128kbps
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        // Add inputs to writer
        if writer.canAdd(videoInput) {
            writer.add(videoInput)
            print("[LocalRecorder] ✅ Video input added")
        } else {
            print("[LocalRecorder] ❌ Cannot add video input")
            throw NSError(domain: "LocalRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
        }

        if writer.canAdd(audioInput) {
            writer.add(audioInput)
            print("[LocalRecorder] ✅ Audio input added")
        } else {
            print("[LocalRecorder] ❌ Cannot add audio input")
            throw NSError(domain: "LocalRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input"])
        }

        // Start writing
        guard writer.startWriting() else {
            let error = writer.error ?? NSError(domain: "LocalRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"])
            print("[LocalRecorder] ❌ Failed to start writing: \(error.localizedDescription)")
            throw error
        }

        self.assetWriter = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.outputURL = fileURL
        self.isRecording = true
        self.sessionStartTime = nil
        self.videoSettingsConfigured = false

        print("[LocalRecorder] ✅ Recording started to: \(fileURL.path)")
        print("[LocalRecorder] ⏳ Video dimensions will be set from first frame")
    }

    /// Append video sample buffer
    func appendVideo(sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              let videoInput = videoInput,
              let writer = assetWriter else {
            return
        }

        guard writer.status == .writing else {
            if writer.status == .failed {
                print("[LocalRecorder] ❌ Writer in failed state, error: \(writer.error?.localizedDescription ?? "unknown")")
            }
            return
        }

        // Configure video settings from first frame to match actual dimensions
        if !videoSettingsConfigured {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                print("[LocalRecorder] ⚠️ No format description on first frame")
                return
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            let width = Int(dimensions.width)
            let height = Int(dimensions.height)

            print("[LocalRecorder] 📐 Detected video dimensions from first frame: \(width)x\(height)")

            // Create new video input with actual dimensions
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2500000, // 2.5 Mbps
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]

            let newVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            newVideoInput.expectsMediaDataInRealTime = true

            // Replace the nil-settings input with properly configured one
            writer.remove(videoInput)
            if writer.canAdd(newVideoInput) {
                writer.add(newVideoInput)
                self.videoInput = newVideoInput
                videoSettingsConfigured = true
                print("[LocalRecorder] ✅ Video input reconfigured with \(width)x\(height)")
            } else {
                print("[LocalRecorder] ❌ Cannot add reconfigured video input")
                return
            }
        }

        // Start session on first video frame
        if sessionStartTime == nil {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: timestamp)
            sessionStartTime = timestamp
            print("[LocalRecorder] 🎬 Session started at timestamp: \(timestamp.seconds)s")
        }

        // Write video frame
        if videoInput.isReadyForMoreMediaData {
            if videoInput.append(sampleBuffer) {
                // Success - only log first few frames to avoid spam
                if let startTime = sessionStartTime {
                    let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let elapsed = CMTimeSubtract(currentTime, startTime).seconds
                    if elapsed < 1.0 { // Log first second
                        print("[LocalRecorder] 📹 Video frame written at \(elapsed)s")
                    }
                }
            } else {
                print("[LocalRecorder] ⚠️ Failed to append video frame")
            }
        }
    }

    /// Append audio sample buffer
    func appendAudio(sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              let audioInput = audioInput,
              let writer = assetWriter else {
            return
        }

        guard writer.status == .writing else {
            return
        }

        guard sessionStartTime != nil else {
            // Only write audio after video session started
            return
        }

        // Write audio frame
        if audioInput.isReadyForMoreMediaData {
            if audioInput.append(sampleBuffer) {
                // Success - only log first few frames
                if let startTime = sessionStartTime {
                    let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let elapsed = CMTimeSubtract(currentTime, startTime).seconds
                    if elapsed < 1.0 { // Log first second
                        print("[LocalRecorder] 🎤 Audio frame written at \(elapsed)s")
                    }
                }
            }
        }
    }

    /// Stop recording and return file path
    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard isRecording else {
            print("[LocalRecorder] ❌ Not currently recording")
            completion(nil)
            return
        }

        isRecording = false

        guard let writer = assetWriter,
              let outputURL = outputURL else {
            print("[LocalRecorder] ❌ No active writer or output URL")
            completion(nil)
            return
        }

        print("[LocalRecorder] 🛑 Stopping recording...")
        print("[LocalRecorder] 📊 Writer status before finish: \(writer.status.rawValue)")
        print("[LocalRecorder] 📊 Session start time: \(sessionStartTime?.seconds ?? -1)s")

        // Mark inputs as finished
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        print("[LocalRecorder] ✅ Inputs marked as finished")

        // Finalize the file
        writer.finishWriting { [weak self] in
            guard let self = self else {
                print("[LocalRecorder] ❌ Self deallocated during finish")
                completion(nil)
                return
            }

            print("[LocalRecorder] 📊 Writer status after finish: \(writer.status.rawValue)")

            if writer.status == .completed {
                // Check file exists and size
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                    let fileSize = attributes[.size] as? Int64 ?? 0
                    print("[LocalRecorder] ✅ Recording saved to: \(outputURL.path)")
                    print("[LocalRecorder] 📦 File size: \(fileSize) bytes (\(fileSize / 1024 / 1024)MB)")
                    completion(outputURL)
                } catch {
                    print("[LocalRecorder] ❌ File exists but cannot read attributes: \(error.localizedDescription)")
                    completion(outputURL) // Still return URL even if we can't read attributes
                }
            } else if let error = writer.error {
                print("[LocalRecorder] ❌ Recording failed with error: \(error.localizedDescription)")
                print("[LocalRecorder] ❌ Error domain: \((error as NSError).domain), code: \((error as NSError).code)")
                completion(nil)
            } else {
                print("[LocalRecorder] ❌ Recording failed with unknown error (status: \(writer.status.rawValue))")
                completion(nil)
            }

            // Cleanup
            self.assetWriter = nil
            self.videoInput = nil
            self.audioInput = nil
            self.outputURL = nil
            self.sessionStartTime = nil
            self.videoSettingsConfigured = false
        }
    }

    /// Cancel recording and delete temp file
    func cancelRecording() {
        guard isRecording else { return }

        isRecording = false

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        assetWriter?.cancelWriting()

        // Delete temp file
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
            print("[LocalRecorder] Recording cancelled and file deleted")
        }

        assetWriter = nil
        videoInput = nil
        audioInput = nil
        outputURL = nil
        sessionStartTime = nil
        videoSettingsConfigured = false
    }
}
