import AVFoundation
import ScreenCaptureKit

/// SCStream → AVAssetWriter (H.264-MP4). Läuft komplett auf einer eigenen Queue.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noFrames, writer(String)
        var errorDescription: String? {
            switch self {
            case .noFrames: "Es wurde kein einziges Bild aufgenommen."
            case .writer(let s): "Video konnte nicht geschrieben werden: \(s)"
            }
        }
    }

    struct Options {
        var display: SCDisplay
        /// Display-lokale Punkte, Ursprung oben links.
        var sourceRect: CGRect
        var pixelSize: CGSize
        var excludedApps: [SCRunningApplication]
        var fps: Int
        var showsCursor: Bool
        var microphone: Bool
        var hevc = false
        var showsClicks = false
    }

    let url: URL
    var onStreamError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "de.birkgroup.knips.recorder", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var started = false
    private var firstPTS = CMTime.invalid
    private var lastPTS = CMTime.invalid
    private var fps = 30

    init(url: URL) {
        self.url = url
    }

    func start(_ o: Options) async throws {
        fps = o.fps
        let w = Int(o.pixelSize.width), h = Int(o.pixelSize.height)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // HEVC braucht für gleiche Qualität gut die Hälfte der Bitrate.
        let bitsPerPixel = o.hevc ? 0.05 : 0.09
        let bitrate = max(1_500_000, min(40_000_000, Int(Double(w * h * o.fps) * bitsPerPixel)))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: o.fps,
            AVVideoMaxKeyFrameIntervalKey: o.fps * 2,
        ]
        if !o.hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: o.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecorderError.writer("Videospur") }
        writer.add(video)

        var wantsMic = false
        if o.microphone, #available(macOS 15.0, *) {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ])
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
                wantsMic = true
            }
        }
        guard writer.startWriting() else { throw RecorderError.writer(writer.error?.localizedDescription ?? "Start") }
        self.writer = writer
        self.videoInput = video

        let filter = SCContentFilter(display: o.display, excludingApplications: o.excludedApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = o.sourceRect
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(o.fps))
        config.showsCursor = o.showsCursor
        config.queueDepth = 6
        // YUV 4:2:0 direkt aus ScreenCaptureKit: halb so viele Bytes pro Bild wie BGRA, keine Umrechnung im Encoder.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        if o.showsClicks, #available(macOS 15.0, *) { config.showMouseClicks = true }
        config.capturesAudio = false
        if wantsMic, #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if wantsMic, #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    /// Beendet die Aufnahme und liefert die Dauer in Sekunden.
    func stop() async throws -> Double {
        let endHost = CMClockGetTime(CMClockGetHostTimeClock())
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Double, Error>) in
            queue.async { [self] in
                guard let writer, started else {
                    writer?.cancelWriting()
                    cont.resume(throwing: RecorderError.noFrames)
                    return
                }
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                // SCStream liefert nur bei Bildänderungen neue Frames — das letzte Bild bis zum Stopp halten.
                var end = endHost
                let gap = CMTimeSubtract(endHost, lastPTS).seconds
                if !gap.isFinite || gap < 0 || gap > 3600 { end = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: CMTimeScale(fps))) }
                writer.endSession(atSourceTime: end)
                let duration = CMTimeSubtract(end, firstPTS).seconds
                writer.finishWriting {
                    if writer.status == .completed {
                        cont.resume(returning: duration)
                    } else {
                        cont.resume(throwing: RecorderError.writer(writer.error?.localizedDescription ?? "Abschluss"))
                    }
                }
            }
        }
    }

    func cancel() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        queue.sync {
            writer?.cancelWriting()
            writer = nil
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer, writer.status == .writing else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: raw), status == .complete,
                  let videoInput else { return }
            let pts = sampleBuffer.presentationTimeStamp
            if !started {
                writer.startSession(atSourceTime: pts)
                started = true
                firstPTS = pts
            }
            if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
                lastPTS = pts
            }
            return
        }
        if #available(macOS 15.0, *), type == .microphone {
            guard started, let audioInput, audioInput.isReadyForMoreMediaData,
                  CMTimeCompare(sampleBuffer.presentationTimeStamp, firstPTS) >= 0 else { return }
            audioInput.append(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }
}
