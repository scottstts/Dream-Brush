//
//  CaptureSessionManager.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import ARKit
import Combine
import os.log
import UIKit

@Observable
final class CaptureSessionManager: NSObject {
    // MARK: - Published State

    var isSessionRunning = false
    var isRecording = false
    var trackingState: ARCamera.TrackingState = .notAvailable
    var worldMappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    var depthAvailable = false

    // Recording stats
    var frameCount = 0
    var keyframeCount = 0
    var depthFrameCount = 0
    var estimatedStorageBytes: Int64 = 0
    var recordingDuration: TimeInterval = 0
    var depthAvailabilityRate: Double = 0

    // Relocalization tracking
    var hasReachedMappedStatus = false
    var rootAnchorSet = false
    private var rootAnchor: ARAnchor?
    private var rootAnchorTransform: simd_float4x4?

    /// Whether the scan can be finalized (mapping status is good enough)
    var canFinalizeScan: Bool {
        worldMappingStatus == .mapped || worldMappingStatus == .extending
    }

    /// Human-readable reason why scan cannot be finalized
    var finalizationBlockedReason: String? {
        guard isRecording else { return nil }
        switch worldMappingStatus {
        case .notAvailable:
            return "Waiting for AR tracking to start..."
        case .limited:
            return "Move around to map more of the space"
        case .extending, .mapped:
            return nil
        @unknown default:
            return "Unknown mapping status"
        }
    }

    // MARK: - Configuration

    struct CaptureConfig {
        var targetFPS: Int = 10
        var enableDepth: Bool = true
        var enableSmoothedDepth: Bool = true
        var enableMeshReconstruction: Bool = false
        var captureResolution: CaptureResolutionPreset = .max

        // Keyframe selection thresholds
        var translationThreshold: Float = 0.05 // 5cm
        var rotationThreshold: Float = 0.1 // ~5.7 degrees in radians
        var maxKeyframes: Int = 300
    }

    var config = CaptureConfig()

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.scottsun.DreamBrush", category: "CaptureSession")
    private(set) var session: ARSession?
    private var currentBundle: CaptureBundle?
    private var recordingStartTime: Date?
    private var recordingStartFrameTimestamp: TimeInterval?
    private var lastFrameTime: TimeInterval = 0
    private var lastKeyframePose: simd_float4x4?
    private var frameIndex = 0
    private var totalFramesWithDepth = 0
    private var totalFramesProcessed = 0
    private var totalFramesWithGoodTracking = 0
    private var totalDepthConfidence: Double = 0
    private var depthConfidenceCount = 0

    // Frame writing queue
    private let writeQueue = DispatchQueue(label: "com.scottsun.DreamBrush.frameWriter", qos: .userInitiated)
    private let writeGroup = DispatchGroup()

    // Reusable CIContext for image processing (expensive to create)
    private static let sharedCIContext: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false // Reduce memory usage
        ])
    }()

    private var ciContext: CIContext { Self.sharedCIContext }

    // Semaphore to limit concurrent frame processing
    private let frameSemaphore = DispatchSemaphore(value: 3)

    // Track if we're under memory pressure
    private var isUnderMemoryPressure = false

    // MARK: - Initialization

    override init() {
        super.init()
        setupMemoryWarningObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func handleMemoryWarning() {
        logger.warning("Received memory warning - temporarily reducing capture rate")
        isUnderMemoryPressure = true

        // Reset after a delay to resume normal operation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.isUnderMemoryPressure = false
        }
    }

    // MARK: - Session Management

    func createSession() -> ARSession {
        let session = ARSession()
        session.delegate = self
        self.session = session
        return session
    }

    func startSession() {
        guard let session = session else {
            logger.error("No ARSession available")
            return
        }

        let configuration = ARWorldTrackingConfiguration()

        // Enable depth if available and requested
        if self.config.enableDepth && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            if self.config.enableSmoothedDepth && ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
                logger.info("Enabled smoothed scene depth")
            } else {
                configuration.frameSemantics.insert(.sceneDepth)
                logger.info("Enabled scene depth")
            }
            depthAvailable = true
        } else {
            depthAvailable = false
            logger.info("Depth not available or disabled")
        }

        // Enable mesh reconstruction if requested (for debugging/occlusion)
        if self.config.enableMeshReconstruction && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
            logger.info("Enabled mesh reconstruction")
        }

        // Configure capture resolution
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        if let preferredFormat = selectVideoFormat(from: formats, targetLongEdge: self.config.captureResolution.targetLongEdge) {
            configuration.videoFormat = preferredFormat
            logger.info("Using video format: \(preferredFormat.imageResolution.width)x\(preferredFormat.imageResolution.height) (\(self.config.captureResolution.title))")
        }

        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        configuration.isAutoFocusEnabled = true

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
        logger.info("ARSession started")
    }

    func updateCaptureResolution(_ preset: CaptureResolutionPreset) {
        config.captureResolution = preset
        guard isSessionRunning, !isRecording else { return }
        startSession()
    }

    func updateCoverageOverlayEnabled(_ enabled: Bool) {
        config.enableMeshReconstruction = enabled
        guard isSessionRunning, !isRecording else { return }
        startSession()
    }

    private func selectVideoFormat(from formats: [ARConfiguration.VideoFormat], targetLongEdge: Int?) -> ARConfiguration.VideoFormat? {
        guard !formats.isEmpty else { return nil }

        func longEdge(for format: ARConfiguration.VideoFormat) -> Int {
            let width = Int(format.imageResolution.width.rounded())
            let height = Int(format.imageResolution.height.rounded())
            return max(width, height)
        }

        func area(for format: ARConfiguration.VideoFormat) -> Int {
            let width = Int(format.imageResolution.width.rounded())
            let height = Int(format.imageResolution.height.rounded())
            return width * height
        }

        guard let targetLongEdge else {
            return formats.max { area(for: $0) < area(for: $1) }
        }

        let belowOrEqual = formats.filter { longEdge(for: $0) <= targetLongEdge }
        if let best = belowOrEqual.max(by: { (longEdge(for: $0), area(for: $0)) < (longEdge(for: $1), area(for: $1)) }) {
            return best
        }

        let above = formats.filter { longEdge(for: $0) > targetLongEdge }
        return above.min(by: { (longEdge(for: $0), area(for: $0)) < (longEdge(for: $1), area(for: $1)) })
            ?? formats.max { area(for: $0) < area(for: $1) }
    }

    func pauseSession() {
        session?.pause()
        isSessionRunning = false
        logger.info("ARSession paused")
    }

    // MARK: - Recording Control

    func startRecording() throws -> CaptureBundle {
        guard isSessionRunning else {
            throw CaptureError.sessionNotRunning
        }

        let settings = CaptureSettings(
            targetFPS: config.targetFPS,
            depthEnabled: config.enableDepth && depthAvailable,
            meshReconstructionEnabled: config.enableMeshReconstruction,
            smoothedDepth: config.enableSmoothedDepth,
            captureResolution: config.captureResolution
        )

        let bundle = try CaptureBundleManager.shared.createBundle(settings: settings)
        currentBundle = bundle
        recordingStartTime = Date()
        recordingStartFrameTimestamp = nil
        lastFrameTime = 0
        lastKeyframePose = nil
        frameIndex = 0
        frameCount = 0
        keyframeCount = 0
        depthFrameCount = 0
        estimatedStorageBytes = 0
        totalFramesWithDepth = 0
        totalFramesProcessed = 0
        totalFramesWithGoodTracking = 0
        totalDepthConfidence = 0
        depthConfidenceCount = 0

        // Reset relocalization tracking
        hasReachedMappedStatus = false
        rootAnchorSet = false
        rootAnchor = nil
        rootAnchorTransform = nil

        isRecording = true
        logger.info("Started recording to bundle: \(bundle.manifest.bundleId)")

        return bundle
    }

    func stopRecording() async throws -> CaptureBundle {
        guard isRecording, let bundle = currentBundle else {
            throw CaptureError.notRecording
        }

        isRecording = false

        // Calculate final stats
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())

        // Save ARWorldMap for relocalization
        var worldMapSaved = false
        var worldMapFeatureCount: Int?
        if let session = session {
            do {
                let worldMap = try await getWorldMap(from: session)
                try CaptureBundleManager.shared.writeWorldMap(worldMap, to: bundle.bundleURL)
                worldMapSaved = true
                // ARWorldMap doesn't expose feature count directly, but we can estimate from anchors
                worldMapFeatureCount = worldMap.anchors.count
                logger.info("Saved ARWorldMap with \(worldMap.anchors.count) anchors")
            } catch {
                logger.error("Failed to save world map: \(error.localizedDescription)")
            }
        }

        // Save root anchor data
        let anchorData = buildAnchorData()
        try CaptureBundleManager.shared.writeAnchors(anchorData, to: bundle.bundleURL)

        // Wait for any in-flight frame writes to finish before finalizing stats.
        await waitForPendingWrites()
        // Ensure queued main-thread stat updates have landed.
        await MainActor.run { }

        // Calculate relocalization quality metrics
        let goodTrackingPercentage = totalFramesProcessed > 0
            ? Double(totalFramesWithGoodTracking) / Double(totalFramesProcessed)
            : 0
        let averageDepthConfidence = depthConfidenceCount > 0
            ? totalDepthConfidence / Double(depthConfidenceCount)
            : 0

        let relocalizationQuality = RelocalizationQuality(
            goodTrackingPercentage: goodTrackingPercentage,
            mappingStatusReached: hasReachedMappedStatus,
            averageDepthConfidence: averageDepthConfidence,
            worldMapSaved: worldMapSaved,
            worldMapFeatureCount: worldMapFeatureCount
        )

        // Update manifest with final stats and relocalization quality
        var updatedBundle = bundle
        try CaptureBundleManager.shared.updateManifest(for: &updatedBundle) { manifest in
            manifest.captureStats.durationSeconds = duration
            manifest.captureStats.frameCount = frameCount
            manifest.captureStats.keyframeCount = keyframeCount
            manifest.captureStats.depthFrameCount = depthFrameCount
            manifest.captureStats.estimatedSizeBytes = estimatedStorageBytes
            manifest.captureStats.averageTrackingQuality = calculateAverageTrackingQuality()
            manifest.captureStats.finalMappingStatus = worldMappingStatus.description
            manifest.relocalizationQuality = relocalizationQuality
        }

        logger.info("Stopped recording. Frames: \(self.frameCount), Keyframes: \(self.keyframeCount), Depth: \(self.depthFrameCount), WorldMapSaved: \(worldMapSaved)")

        currentBundle = nil
        recordingStartTime = nil

        return updatedBundle
    }

    /// Retrieves the current ARWorldMap from the session
    private func getWorldMap(from session: ARSession) async throws -> ARWorldMap {
        try await withCheckedThrowingContinuation { continuation in
            session.getCurrentWorldMap { worldMap, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let worldMap = worldMap {
                    continuation.resume(returning: worldMap)
                } else {
                    continuation.resume(throwing: CaptureError.worldMapNotAvailable)
                }
            }
        }
    }

    private func waitForPendingWrites() async {
        await withCheckedContinuation { continuation in
            writeGroup.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume()
            }
        }
    }

    /// Builds anchor data including the root anchor
    private func buildAnchorData() -> AnchorData {
        let rootAnchorInfo: AnchorInfo
        if let transform = rootAnchorTransform {
            rootAnchorInfo = AnchorInfo(
                id: rootAnchor?.identifier.uuidString ?? UUID().uuidString,
                name: "CaptureOrigin",
                transform: simdToArray(transform),
                trackingState: "normal"
            )
        } else {
            // Fallback to identity if no root anchor was set
            rootAnchorInfo = AnchorInfo()
        }
        return AnchorData(rootAnchor: rootAnchorInfo)
    }

    /// Converts simd_float4x4 to nested Float array for JSON serialization
    private func simdToArray(_ matrix: simd_float4x4) -> [[Float]] {
        [
            [matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w],
            [matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w],
            [matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w],
            [matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w]
        ]
    }

    // MARK: - Relocalization Testing

    /// State for relocalization testing
    var isTestingRelocalization = false
    var relocalizationTestStartTime: Date?
    var relocalizationTestStatus: String = ""
    private var relocalizationAnchorFound = false
    private var expectedAnchorName = "CaptureOrigin"

    /// Tests relocalization by loading a saved world map and waiting for ARKit to relocalize
    /// - Parameters:
    ///   - bundle: The capture bundle to test relocalization for
    ///   - timeout: Maximum time to wait for relocalization (default 30 seconds)
    /// - Returns: The result of the relocalization test
    func testRelocalization(for bundle: CaptureBundle, timeout: TimeInterval = 30) async throws -> RelocalizationTestResult {
        guard !isRecording else {
            throw CaptureError.relocalizationFailed("Cannot test while recording")
        }

        // Load the world map
        let worldMap: ARWorldMap
        do {
            worldMap = try CaptureBundleManager.shared.loadWorldMap(from: bundle.bundleURL)
        } catch {
            return RelocalizationTestResult(
                success: false,
                notes: "Failed to load world map: \(error.localizedDescription)"
            )
        }

        // Configure session with the loaded world map
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = worldMap

        if config.enableDepth && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            if config.enableSmoothedDepth && ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            } else {
                configuration.frameSemantics.insert(.sceneDepth)
            }
        }

        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        configuration.isAutoFocusEnabled = true

        // Start relocalization test
        isTestingRelocalization = true
        relocalizationTestStartTime = Date()
        relocalizationTestStatus = "Starting relocalization test..."
        relocalizationAnchorFound = false // Reset anchor detection flag

        guard let session = session else {
            isTestingRelocalization = false
            throw CaptureError.sessionNotRunning
        }

        // Run session with the world map
        session.run(configuration, options: [.resetTracking])
        isSessionRunning = true
        logger.info("Started relocalization test for bundle: \(bundle.manifest.bundleId)")

        // Wait for relocalization with timeout
        let result = await waitForRelocalization(timeout: timeout)

        isTestingRelocalization = false
        relocalizationTestStatus = result.success ? "Relocalization successful!" : "Relocalization failed"

        logger.info("Relocalization test completed: \(result.success ? "SUCCESS" : "FAILED")")

        return result
    }

    /// Waits for relocalization to complete or timeout
    /// Relocalization is considered successful when BOTH:
    /// 1. Tracking state becomes .normal (not .limited(.relocalizing))
    /// 2. The saved "CaptureOrigin" anchor is detected by ARKit
    private func waitForRelocalization(timeout: TimeInterval) async -> RelocalizationTestResult {
        let startTime = Date()

        // Poll for relocalization status
        while Date().timeIntervalSince(startTime) < timeout {
            // Check if tracking is normal AND we found the original anchor
            // Both conditions are required for true relocalization success
            if case .normal = trackingState, relocalizationAnchorFound {
                let timeToRelocalize = Date().timeIntervalSince(startTime)
                return RelocalizationTestResult(
                    success: true,
                    timeToRelocalize: timeToRelocalize,
                    trackingStateAfterRelocalization: "normal",
                    notes: "Successfully relocalized to original capture location in \(String(format: "%.1f", timeToRelocalize)) seconds"
                )
            }

            // Update status for UI based on current state
            if case .limited(let reason) = trackingState {
                switch reason {
                case .relocalizing:
                    let elapsed = Date().timeIntervalSince(startTime)
                    relocalizationTestStatus = "Relocalizing... (\(String(format: "%.0f", elapsed))s)"
                case .initializing:
                    relocalizationTestStatus = "Initializing AR session..."
                case .excessiveMotion:
                    relocalizationTestStatus = "Slow down - excessive motion detected"
                case .insufficientFeatures:
                    relocalizationTestStatus = "Move to area with more visual features"
                @unknown default:
                    relocalizationTestStatus = "Limited tracking..."
                }
            } else if case .normal = trackingState {
                // Tracking is normal but anchor not found yet - we're in a different location
                let elapsed = Date().timeIntervalSince(startTime)
                relocalizationTestStatus = "Searching for original location... (\(String(format: "%.0f", elapsed))s)"
            }

            // Small delay to avoid busy-waiting
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        // Timeout reached - provide informative failure message
        var failureNotes = "Relocalization timed out after \(Int(timeout)) seconds."
        if case .normal = trackingState {
            failureNotes += " Tracking was stable but original capture location was not found. Make sure you're in the same physical space where the scan was captured."
        } else {
            failureNotes += " Tracking state: \(trackingState.description)"
        }

        return RelocalizationTestResult(
            success: false,
            timeToRelocalize: nil,
            trackingStateAfterRelocalization: trackingState.description,
            notes: failureNotes
        )
    }

    /// Cancels an ongoing relocalization test
    func cancelRelocalizationTest() {
        isTestingRelocalization = false
        relocalizationTestStatus = "Test cancelled"
        logger.info("Relocalization test cancelled")
    }

    private func calculateAverageTrackingQuality() -> Double {
        // Simple metric based on depth availability rate as proxy for quality
        guard totalFramesProcessed > 0 else { return 0 }
        return Double(totalFramesWithDepth) / Double(totalFramesProcessed)
    }

    // MARK: - Frame Processing

    private func shouldCaptureFrame(at timestamp: TimeInterval) -> Bool {
        guard isRecording else { return false }

        // Reduce FPS under memory pressure
        let effectiveFPS = isUnderMemoryPressure ? max(config.targetFPS / 2, 2) : config.targetFPS
        let targetInterval = 1.0 / Double(effectiveFPS)
        let elapsed = timestamp - lastFrameTime

        return elapsed >= targetInterval
    }

    private func isKeyframe(currentPose: simd_float4x4) -> Bool {
        guard let lastPose = lastKeyframePose else {
            return true // First frame is always a keyframe
        }

        guard keyframeCount < config.maxKeyframes else {
            return false // Reached max keyframes
        }

        // Check translation distance
        let currentPos = currentPose.columns.3
        let lastPos = lastPose.columns.3
        let translation = simd_distance(
            simd_float3(currentPos.x, currentPos.y, currentPos.z),
            simd_float3(lastPos.x, lastPos.y, lastPos.z)
        )

        if translation > config.translationThreshold {
            return true
        }

        // Check rotation difference (simplified: compare forward vectors)
        let currentForward = simd_float3(currentPose.columns.2.x, currentPose.columns.2.y, currentPose.columns.2.z)
        let lastForward = simd_float3(lastPose.columns.2.x, lastPose.columns.2.y, lastPose.columns.2.z)
        let dotProduct = simd_dot(simd_normalize(currentForward), simd_normalize(lastForward))
        let angle = acos(min(max(dotProduct, -1.0), 1.0))

        return angle > config.rotationThreshold
    }

    /// Holds copied frame data that's safe to use after ARSession delegate returns
    private struct CapturedFrameData {
        let rgbImage: CGImage
        let depthData: Data? // Pre-encoded 16-bit PNG depth
        let metadata: FrameMetadata
        let isKeyframe: Bool
    }

    private func processFrame(_ frame: ARFrame) {
        guard isRecording, let bundle = currentBundle else { return }

        let timestamp = frame.timestamp

        guard shouldCaptureFrame(at: timestamp) else { return }

        // Check if we're backed up with frame processing
        if frameSemaphore.wait(timeout: .now()) == .timedOut {
            logger.debug("Skipping frame - write queue backed up")
            return
        }

        let pose = frame.camera.transform
        let isKeyframe = isKeyframe(currentPose: pose)
        let nextFrameIndex = frameIndex + 1

        // CRITICAL: Copy all frame data SYNCHRONOUSLY before dispatching
        // ARFrame's pixel buffers become invalid after delegate returns
        guard let capturedData = captureFrameData(frame, index: nextFrameIndex, isKeyframe: isKeyframe) else {
            frameSemaphore.signal()
            logger.error("Failed to capture frame data for index \(nextFrameIndex)")
            return
        }

        lastFrameTime = timestamp
        frameIndex = nextFrameIndex
        totalFramesProcessed += 1
        if isKeyframe {
            lastKeyframePose = pose
        }

        // Now safely process on background queue
        writeGroup.enter()
        let frameSemaphore = self.frameSemaphore
        let writeGroup = self.writeGroup
        writeQueue.async { [weak self] in
            guard let self = self else {
                frameSemaphore.signal()
                writeGroup.leave()
                return
            }

            defer {
                self.frameSemaphore.signal()
                writeGroup.leave()
            }

            // Use autorelease pool to ensure timely memory cleanup
            autoreleasepool {
                do {
                    // Write RGB frame
                    let rgbSize = try self.writeRGBFrame(capturedData.rgbImage, index: nextFrameIndex, to: bundle, isKeyframe: isKeyframe)

                    // Write depth if available
                    var depthSize: Int64 = 0
                    if let depthData = capturedData.depthData {
                        depthSize = try self.writeDepthData(depthData, index: nextFrameIndex, to: bundle)
                        DispatchQueue.main.async {
                            self.depthFrameCount += 1
                            self.totalFramesWithDepth += 1
                        }
                    }

                    // Write metadata
                    let metaSize = try self.writeFrameMetadata(capturedData.metadata, index: nextFrameIndex, to: bundle)

                    if capturedData.metadata.tracking.state == "normal" {
                        self.totalFramesWithGoodTracking += 1
                    }
                    if let depth = capturedData.metadata.depth {
                        self.totalDepthConfidence += Double(depth.confidenceSummary.high)
                        self.depthConfidenceCount += 1
                    }

                    // Update stats on main thread
                    DispatchQueue.main.async {
                        self.frameCount += 1
                        if isKeyframe {
                            self.keyframeCount += 1
                        }
                        self.estimatedStorageBytes += rgbSize + depthSize + metaSize
                        self.recordingDuration = Date().timeIntervalSince(self.recordingStartTime ?? Date())
                        self.depthAvailabilityRate = self.totalFramesProcessed > 0
                            ? Double(self.totalFramesWithDepth) / Double(self.totalFramesProcessed)
                            : 0
                    }

                } catch {
                    self.logger.error("Failed to write frame \(nextFrameIndex): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Captures frame data synchronously - MUST be called on main thread before ARFrame becomes invalid
    private func captureFrameData(_ frame: ARFrame, index: Int, isKeyframe: Bool) -> CapturedFrameData? {
        // Convert pixel buffer to CGImage immediately
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            logger.error("Failed to create CGImage from pixel buffer")
            return nil
        }

        // Encode depth data immediately if available
        var depthData: Data? = nil
        if let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap {
            do {
                depthData = try encodeDepthTo16BitPNG(depthMap)
            } catch {
                logger.error("Failed to encode depth: \(error.localizedDescription)")
            }
        }

        // Build metadata immediately
        let metadata = buildFrameMetadata(from: frame, index: index, isKeyframe: isKeyframe)

        return CapturedFrameData(
            rgbImage: cgImage,
            depthData: depthData,
            metadata: metadata,
            isKeyframe: isKeyframe
        )
    }

    /// Builds frame metadata from current frame - called synchronously
    private func buildFrameMetadata(from frame: ARFrame, index: Int, isKeyframe: Bool) -> FrameMetadata {
        let camera = frame.camera
        let timestamp = frame.timestamp
        if recordingStartFrameTimestamp == nil {
            recordingStartFrameTimestamp = timestamp
        }
        let startTime = recordingStartFrameTimestamp ?? timestamp

        // Build camera metadata
        let intrinsics = camera.intrinsics
        let intrinsicsArray: [[Float]] = [
            [intrinsics.columns.0.x, intrinsics.columns.1.x, intrinsics.columns.2.x],
            [intrinsics.columns.0.y, intrinsics.columns.1.y, intrinsics.columns.2.y],
            [intrinsics.columns.0.z, intrinsics.columns.1.z, intrinsics.columns.2.z]
        ]

        let transform = camera.transform
        let transformArray: [[Float]] = [
            [transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w],
            [transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w],
            [transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w],
            [transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w]
        ]

        let projection = camera.projectionMatrix
        let projectionArray: [[Float]] = [
            [projection.columns.0.x, projection.columns.0.y, projection.columns.0.z, projection.columns.0.w],
            [projection.columns.1.x, projection.columns.1.y, projection.columns.1.z, projection.columns.1.w],
            [projection.columns.2.x, projection.columns.2.y, projection.columns.2.z, projection.columns.2.w],
            [projection.columns.3.x, projection.columns.3.y, projection.columns.3.z, projection.columns.3.w]
        ]

        let cameraMetadata = CameraMetadata(
            intrinsics: intrinsicsArray,
            imageResolution: ImageResolution(
                width: Int(camera.imageResolution.width),
                height: Int(camera.imageResolution.height)
            ),
            transform: transformArray,
            projectionMatrix: projectionArray,
            eulerAngles: EulerAngles(
                pitch: camera.eulerAngles.x,
                yaw: camera.eulerAngles.y,
                roll: camera.eulerAngles.z
            )
        )

        // Tracking metadata
        let cameraTrackingState = camera.trackingState
        let trackingMetadata = TrackingMetadata(
            state: cameraTrackingState.description,
            stateReason: trackingStateReason(cameraTrackingState),
            worldMappingStatus: frame.worldMappingStatus.description
        )

        // Depth metadata
        var depthMetadata: DepthMetadata? = nil
        if let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap,
           let confidenceMap = frame.smoothedSceneDepth?.confidenceMap ?? frame.sceneDepth?.confidenceMap {
            let confidenceSummary = calculateConfidenceSummary(confidenceMap)
            depthMetadata = DepthMetadata(
                available: true,
                width: CVPixelBufferGetWidth(depthMap),
                height: CVPixelBufferGetHeight(depthMap),
                confidenceSummary: confidenceSummary
            )
        }

        return FrameMetadata(
            frameIndex: index,
            timestamp: timestamp,
            timestampSinceStart: timestamp - startTime,
            camera: cameraMetadata,
            tracking: trackingMetadata,
            depth: depthMetadata,
            exposure: nil,
            isKeyframe: isKeyframe
        )
    }

    // MARK: - Frame Writing

    private func writeRGBFrame(_ cgImage: CGImage, index: Int, to bundle: CaptureBundle, isKeyframe: Bool) throws -> Int64 {
        let uiImage = UIImage(cgImage: cgImage)

        let fileName = String(format: "%06d", index)
        let jpegURL = bundle.bundleURL.appendingPathComponent("frames/rgb/\(fileName).jpg")
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.88) else {
            throw CaptureError.imageConversionFailed
        }
        try jpegData.write(to: jpegURL, options: .atomic)

        if isKeyframe {
            let keyframeURL = bundle.bundleURL.appendingPathComponent("keyframes/\(fileName).jpg")
            try jpegData.write(to: keyframeURL, options: .atomic)
        }

        return Int64(jpegData.count)
    }

    private func writeDepthData(_ pngData: Data, index: Int, to bundle: CaptureBundle) throws -> Int64 {
        let fileName = String(format: "%06d.png", index)
        let depthURL = bundle.bundleURL.appendingPathComponent("frames/depth/\(fileName)")
        try pngData.write(to: depthURL, options: .atomic)
        return Int64(pngData.count)
    }

    private func encodeDepthTo16BitPNG(_ depthMap: CVPixelBuffer) throws -> Data {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw CaptureError.depthConversionFailed
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)

        // Create 16-bit grayscale image data
        var uint16Data = [UInt16](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let floatIndex = y * bytesPerRow / MemoryLayout<Float32>.size + x
                let depthMeters = floatBuffer[floatIndex]

                // Convert to millimeters, clamp to UInt16 range
                let depthMM = depthMeters * 1000.0
                let clampedDepth = max(0, min(65535, depthMM))
                uint16Data[y * width + x] = UInt16(clampedDepth)
            }
        }

        // Create CGImage from 16-bit data
        let bitsPerComponent = 16
        let bitsPerPixel = 16
        let bytesPerRowOut = width * 2

        guard let provider = CGDataProvider(data: Data(bytes: &uint16Data, count: uint16Data.count * 2) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: bitsPerComponent,
                  bitsPerPixel: bitsPerPixel,
                  bytesPerRow: bytesPerRowOut,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: 0),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw CaptureError.depthConversionFailed
        }

        // Encode as PNG
        let uiImage = UIImage(cgImage: cgImage)
        guard let pngData = uiImage.pngData() else {
            throw CaptureError.depthConversionFailed
        }

        return pngData
    }

    private func writeFrameMetadata(_ metadata: FrameMetadata, index: Int, to bundle: CaptureBundle) throws -> Int64 {
        let fileName = String(format: "%06d.json", index)
        let metaURL = bundle.bundleURL.appendingPathComponent("frames/meta/\(fileName)")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metaURL, options: .atomic)

        return Int64(data.count)
    }

    private func calculateConfidenceSummary(_ confidenceMap: CVPixelBuffer) -> ConfidenceSummary {
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }

        let width = CVPixelBufferGetWidth(confidenceMap)
        let height = CVPixelBufferGetHeight(confidenceMap)
        let totalPixels = width * height

        guard let baseAddress = CVPixelBufferGetBaseAddress(confidenceMap) else {
            return ConfidenceSummary(high: 0, medium: 0, low: 0)
        }

        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        var highCount = 0
        var mediumCount = 0
        var lowCount = 0

        for i in 0..<totalPixels {
            switch ARConfidenceLevel(rawValue: Int(buffer[i])) {
            case .high: highCount += 1
            case .medium: mediumCount += 1
            case .low: lowCount += 1
            default: lowCount += 1
            }
        }

        return ConfidenceSummary(
            high: Float(highCount) / Float(totalPixels),
            medium: Float(mediumCount) / Float(totalPixels),
            low: Float(lowCount) / Float(totalPixels)
        )
    }

    private func trackingStateReason(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .notAvailable:
            return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "initializing"
            case .excessiveMotion: return "excessiveMotion"
            case .insufficientFeatures: return "insufficientFeatures"
            case .relocalizing: return "relocalizing"
            @unknown default: return "unknown"
            }
        case .normal:
            return "none"
        }
    }
}

// MARK: - ARSessionDelegate

extension CaptureSessionManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Update tracking state
        trackingState = frame.camera.trackingState
        worldMappingStatus = frame.worldMappingStatus

        // Track when mapping status reaches .mapped
        if isRecording && worldMappingStatus == .mapped && !hasReachedMappedStatus {
            hasReachedMappedStatus = true
            logger.info("World mapping status reached .mapped")
        }

        // Set root anchor when tracking is good and mapping is sufficient
        if isRecording && !rootAnchorSet {
            setRootAnchorIfReady(frame: frame, session: session)
        }

        // Process frame if recording
        processFrame(frame)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // During relocalization testing, check if our saved anchors are being found
        if isTestingRelocalization {
            for anchor in anchors {
                // When ARKit successfully relocalizes, it will add anchors from the saved world map
                // Our CaptureOrigin anchor being added means relocalization found the original location
                if anchor.name == expectedAnchorName {
                    relocalizationAnchorFound = true
                    logger.info("Relocalization anchor '\(self.expectedAnchorName)' found!")
                }
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        logger.error("ARSession failed: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        logger.warning("ARSession interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        logger.info("ARSession interruption ended")
    }

    // MARK: - Root Anchor Management

    /// Sets the root anchor when conditions are met:
    /// - Tracking is normal
    /// - World mapping is at least .extending (preferably .mapped)
    private func setRootAnchorIfReady(frame: ARFrame, session: ARSession) {
        guard trackingState == .normal else { return }
        guard worldMappingStatus == .extending || worldMappingStatus == .mapped else { return }

        // Use the current camera pose as the root anchor
        let cameraPose = frame.camera.transform
        let anchor = ARAnchor(name: "CaptureOrigin", transform: cameraPose)

        session.add(anchor: anchor)
        rootAnchor = anchor
        rootAnchorTransform = cameraPose
        rootAnchorSet = true

        logger.info("Root anchor set at camera pose, mapping status: \(self.worldMappingStatus.description)")
    }
}

// MARK: - Error Types

enum CaptureError: LocalizedError {
    case sessionNotRunning
    case notRecording
    case imageConversionFailed
    case depthConversionFailed
    case worldMapNotAvailable
    case relocalizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotRunning: return "AR session is not running"
        case .notRecording: return "Not currently recording"
        case .imageConversionFailed: return "Failed to convert image"
        case .depthConversionFailed: return "Failed to convert depth map"
        case .worldMapNotAvailable: return "World map is not available"
        case .relocalizationFailed(let reason): return "Relocalization failed: \(reason)"
        }
    }
}

// MARK: - Extensions

extension ARCamera.TrackingState: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        case .normal: return "normal"
        }
    }
}

extension ARFrame.WorldMappingStatus: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "unknown"
        }
    }
}
