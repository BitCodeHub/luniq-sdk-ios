import Foundation
import UIKit
import ReplayKit
import AVFoundation

final class SessionReplay {
    private let config: LuniqConfig
    private let identity: IdentityManager
    private var sessionId: String?
    private var started: Date?
    private var frameCount = 0

    // Video pipeline
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var segmentIndex = 0
    private var currentSegmentURL: URL?
    private var sessionStartTime: CMTime = .invalid
    private var segmentStartTime: CMTime = .invalid
    private var isCapturing = false
    private var segmentTimer: Timer?
    /// Short rotations so a partial recording uploads quickly even if the user
    /// only spends a few seconds in the app. Production tools like FullStory
    /// and LogRocket use 5–10 s segments for the same reason.
    private let segmentDuration: TimeInterval = 8.0

    // Event buffer (non-frame analytics events)
    private let ioQueue = DispatchQueue(label: "ai.luniq.sdk.replay", qos: .utility)
    private var eventBuffer: [[String: Any]] = []
    private let maxBuffer = 20

    init(config: LuniqConfig, identity: IdentityManager) {
        self.config = config
        self.identity = identity
    }

    /// Becomes true the moment start() is invoked and stays true until the
    /// async begin() round-trip resolves. Without this, start() called twice
    /// in quick succession (e.g. autoCapture-on-launch + scenePhase .active)
    /// would both pass the sessionId == nil guard and trigger two ReplayKit
    /// permission prompts.
    private var startInFlight = false

    func start() {
        guard sessionId == nil, !startInFlight else { return }
        startInFlight = true
        begin { [weak self] in
            guard let self else { return }
            self.started = Date()
            self.frameCount = 0
            self.startVideoCapture()
            self.startInFlight = false
        }
    }

    func stop() {
        // Hold a UIBackgroundTask so iOS doesn't suspend the app before the
        // final segment finishes encoding + uploading. Without this, a user
        // who opens the app, lets it record briefly, then switches away will
        // produce a session row with zero segments — exactly the bug we hit
        // before this guard existed.
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "luniq.replay.stop") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        stopVideoCapture { [weak self] in
            guard let self, let sid = self.sessionId else {
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                return
            }
            self.flush(force: true)
            let duration = Int64((Date().timeIntervalSince(self.started ?? Date())) * 1000)
            self.end(sid: sid, durationMs: duration) {
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            }
            self.sessionId = nil
        }
    }

    func recordEvent(name: String, properties: [String: Any]) {
        ioQueue.async { [weak self] in
            guard let self, self.sessionId != nil else { return }
            var ev: [String: Any] = ["t": self.nowMs(), "type": "event", "name": name]
            ev["props"] = properties
            self.eventBuffer.append(ev)
            if self.eventBuffer.count >= self.maxBuffer { self.flush(force: false) }
        }
    }

    // MARK: - Video capture

    private func startVideoCapture() {
        guard RPScreenRecorder.shared().isAvailable else { return }
        startNewSegment()

        RPScreenRecorder.shared().startCapture(handler: { [weak self] sampleBuffer, bufferType, error in
            guard let self, error == nil, bufferType == .video else { return }
            self.appendVideoSample(sampleBuffer)
        }) { [weak self] error in
            // ReplayKit permission denied or unavailable — recording simply won't happen
            if error != nil { self?.isCapturing = false }
        }
        isCapturing = true

        DispatchQueue.main.async {
            self.segmentTimer = Timer.scheduledTimer(
                withTimeInterval: self.segmentDuration, repeats: true
            ) { [weak self] _ in self?.rotateSegment() }
        }
    }

    private func stopVideoCapture(completion: @escaping () -> Void) {
        segmentTimer?.invalidate(); segmentTimer = nil
        guard isCapturing else { completion(); return }
        isCapturing = false

        RPScreenRecorder.shared().stopCapture { [weak self] _ in
            guard let self else { completion(); return }
            self.finaliseSegment(index: self.segmentIndex, completion: completion)
        }
    }

    private func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Record the very first PTS of the whole session
        if sessionStartTime == .invalid { sessionStartTime = pts }

        // Record the PTS of the current segment's first frame
        if segmentStartTime == .invalid { segmentStartTime = pts }

        guard let writer = assetWriter, let input = videoInput else { return }

        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: segmentStartTime)
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
        frameCount += 1
    }

    private func startNewSegment() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("luniq-seg-\(segmentIndex)-\(nowMs()).mp4")
        currentSegmentURL = url
        segmentStartTime = .invalid

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }

        let screenScale = UIScreen.main.scale
        let screenSize  = UIScreen.main.bounds.size
        let w = Int(screenSize.width  * screenScale)
        let h = Int(screenSize.height * screenScale)

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:       800_000,  // 800 kbps — clear on phone screens
                AVVideoMaxKeyFrameIntervalKey:  60,
                AVVideoProfileLevelKey:         AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true

        writer.add(input)
        assetWriter = writer
        videoInput  = input
    }

    private func rotateSegment() {
        let finishedWriter = assetWriter
        let finishedURL    = currentSegmentURL
        let finishedIndex  = segmentIndex

        segmentIndex += 1
        startNewSegment()

        finalise(writer: finishedWriter, url: finishedURL, index: finishedIndex, completion: nil)
    }

    private func finaliseSegment(index: Int, completion: @escaping () -> Void) {
        finalise(writer: assetWriter, url: currentSegmentURL, index: index) {
            completion()
        }
    }

    private func finalise(writer: AVAssetWriter?, url: URL?, index: Int, completion: (() -> Void)?) {
        guard let writer, let url else { completion?(); return }
        // markAsFinished + finishWriting both require the writer to be in
        // .writing. If the segment was created but never started (no frames
        // arrived before stop, e.g. a sub-second app launch), status is
        // .unknown and calling markAsFinished raises
        // NSInternalInconsistencyException, killing the whole app.
        guard writer.status == .writing else {
            try? FileManager.default.removeItem(at: url)
            completion?()
            return
        }
        writer.inputs.forEach { $0.markAsFinished() }
        writer.finishWriting { [weak self] in
            // Wait for the upload before reporting completion so the caller
            // (typically stop()'s background-task wrapper) can keep the app
            // alive long enough to flush bytes to the server.
            if writer.status == .completed {
                self?.uploadVideoSegment(url: url, index: index) {
                    try? FileManager.default.removeItem(at: url)
                    completion?()
                }
            } else {
                try? FileManager.default.removeItem(at: url)
                completion?()
            }
        }
    }

    // MARK: - Upload

    private func uploadVideoSegment(url: URL, index: Int, completion: (() -> Void)? = nil) {
        guard let sid = sessionId, let data = try? Data(contentsOf: url) else { completion?(); return }
        guard let endpoint = URL(string: "\(config.endpoint)/v1/sdk/replay/\(sid)/video-segment") else { completion?(); return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        req.setValue("\(index)", forHTTPHeaderField: "X-Luniq-Seg")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { _, _, _ in completion?() }.resume()
    }

    // MARK: - Session lifecycle (unchanged)

    private func begin(_ done: @escaping () -> Void) {
        guard let url = URL(string: "\(config.endpoint)/v1/sdk/replay/start") else {
            startInFlight = false
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        let body: [String: Any] = [
            "visitorId":  identity.visitorId ?? "",
            "accountId":  identity.accountId ?? "",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "deviceModel": DeviceInfo.model,
            "startedAt":  ISO8601DateFormatter().string(from: Date()),
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            if let data,
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = j["id"] as? String {
                self.sessionId = id
                done()
            } else {
                self.startInFlight = false
            }
        }.resume()
    }

    private func end(sid: String, durationMs: Int64, completion: (() -> Void)? = nil) {
        guard let url = URL(string: "\(config.endpoint)/v1/sdk/replay/\(sid)/end") else { completion?(); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "durationMs": durationMs, "frameCount": frameCount,
        ])
        URLSession.shared.dataTask(with: req) { _, _, _ in completion?() }.resume()
    }

    // MARK: - Event flush (analytics events, not video frames)

    private func flush(force: Bool) {
        guard let sid = sessionId, !eventBuffer.isEmpty else { return }
        let chunk = eventBuffer; eventBuffer.removeAll()
        guard let url = URL(string: "\(config.endpoint)/v1/sdk/replay/\(sid)/chunk") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        req.setValue("\(nowMs())", forHTTPHeaderField: "X-Luniq-Seq")
        var body = Data()
        for rec in chunk {
            if let d = try? JSONSerialization.data(withJSONObject: rec) {
                body.append(d); body.append(0x0A)
            }
        }
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
