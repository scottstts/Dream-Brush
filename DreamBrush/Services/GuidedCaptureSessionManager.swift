//
//  GuidedCaptureSessionManager.swift
//  DreamBrush
//
//  Panorama-style capture with upright-only enforcement.
//

import ARKit
import Observation
import os.log
import UIKit
import UniformTypeIdentifiers

@Observable
final class GuidedCaptureSessionManager: NSObject {
    // MARK: - State

    var isSessionRunning = false
    var isCapturing = false
    var isCaptureComplete = false
    var trackingState: ARCamera.TrackingState = .notAvailable
    var worldMappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    var depthAvailable = false

    var isUpright = false
    var canManualCapture = false
    var alignmentHint = "Hold the phone upright"
    var captureCount = 0
    var yawProgressDegrees: Float = 0
    var directionLabel = "Left or Right"

    // MARK: - Configuration

    struct Config {
        var requireNormalTracking = true
        var requirePortrait = true
        var uprightToleranceDegrees: Float = 10
        var captureOverlap: Float = 0.45
        var minStepDegrees: Float = 16
        var maxStepDegrees: Float = 40
        var directionLockThreshold: Float = 6
        var completionThresholdDegrees: Float = 355
        var minFinalGapDegrees: Float = 5
        var maxAngularVelocityDegPerSec: Float = 120
        var maxExposureDurationSeconds: Double = 1.0 / 45.0
        var exposureStableDeltaRatio: Double = 0.08
        var exposureStableSamples: Int = 3
        var saveDepthWhenAvailable = true
        var useSmoothedDepth = true
        var captureResolution: CaptureResolutionPreset = .max
    }

    var config = Config()

    // MARK: - Private

    private let logger = Logger(subsystem: "com.scottsun.DreamBrush", category: "PanoramaCapture")
    private(set) var session: ARSession?
    private var currentBundle: CaptureBundle?
    private var captureOriginTransform: simd_float4x4?
    private var captureStartTimestamp: TimeInterval?
    private var currentFrame: ARFrame?

    private var rootAnchorSet = false
    private var rootAnchor: ARAnchor?
    private var rootAnchorTransform: simd_float4x4?

    private var anchorYawDegrees: Float?
    private var lastCaptureYawDegrees: Float?
    private var lastSampleYawDegrees: Float?
    private var cumulativeYawDegrees: Float = 0
    private var lastCaptureProgressDegrees: Float = 0
    private var panDirection: Float?
    private var isCapturingFrame = false
    private var pendingFinalize = false
    private var lastMotionTimestamp: TimeInterval?
    private var lastMotionYawDegrees: Float?
    private var lastExposureDuration: Double?
    private var stableExposureCount = 0
    private var lastAngularVelocity: Float = 0
    private var lastUprightDeviation: Float = 0

    private let writeQueue = DispatchQueue(label: "com.scottsun.DreamBrush.panoramaWriter", qos: .userInitiated)

    private static let sharedCIContext: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }()

    private var ciContext: CIContext { Self.sharedCIContext }

    // MARK: - Session Management

    func createSession() -> ARSession {
        let session = ARSession()
        session.delegate = self
        self.session = session
        return session
    }

    func startSession() {
        guard let session else {
            logger.error("No ARSession available")
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        configuration.isAutoFocusEnabled = true

        if config.saveDepthWhenAvailable,
           ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            if config.useSmoothedDepth,
               ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            } else {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            depthAvailable = true
        } else {
            depthAvailable = false
        }

        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        if let preferredFormat = selectVideoFormat(from: formats, targetLongEdge: config.captureResolution.targetLongEdge) {
            configuration.videoFormat = preferredFormat
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
    }

    func pauseSession() {
        session?.pause()
        isSessionRunning = false
    }

    // MARK: - Capture Control

    func beginCapture() throws -> CaptureBundle {
        guard isSessionRunning else {
            throw GuidedCaptureError.sessionNotRunning
        }
        guard let frame = currentFrame else {
            throw GuidedCaptureError.noFrameAvailable
        }

        resetCaptureState()
        captureOriginTransform = frame.camera.transform
        captureStartTimestamp = nil

        let settings = CaptureSettings(
            targetFPS: 0,
            depthEnabled: config.saveDepthWhenAvailable && depthAvailable,
            meshReconstructionEnabled: false,
            smoothedDepth: config.useSmoothedDepth,
            captureResolution: config.captureResolution,
            depthConfidenceDownsampleFactor: nil
        )

        let bundle = try CaptureBundleManager.shared.createBundle(settings: settings)
        currentBundle = bundle
        isCapturing = true
        isCaptureComplete = false
        updateAlignment(for: frame)
        return bundle
    }

    func cancelCapture() {
        isCapturing = false
        resetCaptureState()
        currentBundle = nil
    }

    func captureFirstManually() {
        guard isCapturing,
              canManualCapture,
              !isCapturingFrame,
              let frame = currentFrame else { return }
        captureFrame(frame, isFirst: true)
    }

    private func finalizeCapture() {
        guard var bundle = currentBundle else { return }

        do {
            try CaptureBundleManager.shared.updateManifest(for: &bundle) { manifest in
                manifest.captureStats.frameCount = captureCount
                manifest.captureStats.keyframeCount = captureCount
                manifest.captureStats.depthFrameCount = depthAvailable ? captureCount : 0
                manifest.captureStats.estimatedSizeBytes = 0
                manifest.captureStats.durationSeconds = 0
                manifest.captureStats.finalMappingStatus = worldMappingStatus.description
            }
            currentBundle = bundle
        } catch {
            logger.error("Failed to update manifest: \(error.localizedDescription)")
        }

        if !rootAnchorSet, let frame = currentFrame, let session {
            setRootAnchorIfReady(frame: frame, session: session)
        }

        if let anchorInfo = buildRootAnchorInfo() {
            let anchors = AnchorData(rootAnchor: anchorInfo)
            try? CaptureBundleManager.shared.writeAnchors(anchors, to: bundle.bundleURL)
        }

        session?.getCurrentWorldMap { [weak self] worldMap, error in
            guard let self, let bundle = self.currentBundle else { return }
            if let error {
                self.logger.warning("Failed to get world map: \(error.localizedDescription)")
                return
            }
            guard let worldMap else { return }
            try? CaptureBundleManager.shared.writeWorldMap(worldMap, to: bundle.bundleURL)
        }

        isCapturing = false
        isCaptureComplete = true
    }

    // MARK: - Alignment + Panorama Logic

    private func updateAlignment(for frame: ARFrame) {
        guard isCapturing else { return }

        trackingState = frame.camera.trackingState
        worldMappingStatus = frame.worldMappingStatus

        if config.requireNormalTracking, frame.camera.trackingState != .normal {
            isUpright = false
            canManualCapture = false
            alignmentHint = "Tracking unstable"
            return
        }

        let orientation = currentInterfaceOrientation()
        let uprightDeviation = uprightDeviationDegrees(from: frame.camera, orientation: orientation)
        let isPortrait = orientation == .portrait || orientation == .portraitUpsideDown
        isUpright = (!config.requirePortrait || isPortrait) && uprightDeviation <= config.uprightToleranceDegrees
        lastUprightDeviation = uprightDeviation

        if !isUpright {
            canManualCapture = false
            alignmentHint = config.requirePortrait ? "Hold upright (portrait)" : "Hold upright"
            return
        }

        if !exposureIsStable(for: frame.camera) {
            canManualCapture = false
            alignmentHint = "Hold steady for exposure"
            return
        }

        guard let currentYaw = frame.camera.transform.yawDegreesOptional else {
            canManualCapture = false
            alignmentHint = "Hold steady"
            return
        }

        let angularVelocity = updateAngularVelocity(currentYaw: currentYaw, timestamp: frame.timestamp)
        if angularVelocity > config.maxAngularVelocityDegPerSec {
            canManualCapture = false
            alignmentHint = "Move slower"
            return
        }

        if anchorYawDegrees == nil {
            canManualCapture = true
            alignmentHint = "Tap Capture First Wall"
            return
        }

        canManualCapture = false
        let captureStep = captureStepDegrees(from: frame.camera)

        if panDirection == nil, let anchorYawDegrees {
            let delta = angleDeltaDegrees(currentYaw, anchorYawDegrees)
            if abs(delta) >= config.directionLockThreshold {
                panDirection = delta >= 0 ? 1 : -1
                directionLabel = panDirection == 1 ? "Right" : "Left"
            } else {
                alignmentHint = "Turn left or right"
            }
        }

        updateCumulativeYaw(currentYaw: currentYaw)
        yawProgressDegrees = abs(cumulativeYawDegrees)

        if yawProgressDegrees >= config.completionThresholdDegrees {
            let gap = yawProgressDegrees - lastCaptureProgressDegrees
            if gap >= config.minFinalGapDegrees, !isCapturingFrame {
                pendingFinalize = true
                captureFrame(frame, isFirst: false)
            } else if !isCapturingFrame {
                finalizeCapture()
            }
            return
        }

        guard let lastCaptureYawDegrees, let panDirection else {
            return
        }

        let deltaFromLast = angleDeltaDegrees(currentYaw, lastCaptureYawDegrees) * panDirection
        if deltaFromLast >= captureStep, !isCapturingFrame {
            captureFrame(frame, isFirst: false)
        } else if abs(deltaFromLast) < 1 {
            alignmentHint = "Hold steady"
        } else {
            alignmentHint = "Keep panning \(directionLabel)"
        }
    }

    private func captureFrame(_ frame: ARFrame, isFirst: Bool) {
        guard let bundle = currentBundle else { return }
        isCapturingFrame = true

        let frameIndex = captureCount
        let shouldCaptureDepth = config.saveDepthWhenAvailable && depthAvailable
        let yaw = frame.camera.transform.yawDegrees

        if isFirst {
            captureStartTimestamp = frame.timestamp
            anchorYawDegrees = yaw
            lastCaptureYawDegrees = yaw
            lastSampleYawDegrees = yaw
            cumulativeYawDegrees = 0
            panDirection = nil
            directionLabel = "Left or Right"
        }

        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                let cgImage = try self.makeCGImage(from: frame.capturedImage)
                _ = try self.writeRGBFrame(cgImage, index: frameIndex, to: bundle)

                if shouldCaptureDepth,
                   let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap {
                    let depthData = try self.encodeDepthTo16BitPNG(depthMap)
                    _ = try self.writeDepthData(depthData, index: frameIndex, to: bundle)
                }

                let metadata = self.buildFrameMetadata(from: frame, index: frameIndex, isKeyframe: true)
                _ = try self.writeFrameMetadata(metadata, index: frameIndex, to: bundle)

                Task { @MainActor in
                    self.captureCount += 1
                    self.lastCaptureYawDegrees = yaw
                    self.lastCaptureProgressDegrees = abs(self.cumulativeYawDegrees)
                    self.isCapturingFrame = false
                    self.alignmentHint = "Keep panning \(self.directionLabel)"
                    if self.pendingFinalize {
                        self.pendingFinalize = false
                        self.finalizeCapture()
                    }
                }
            } catch {
                Task { @MainActor in
                    self.logger.error("Failed to capture frame: \(error.localizedDescription)")
                    self.isCapturingFrame = false
                }
            }
        }
    }

    private func updateCumulativeYaw(currentYaw: Float) {
        guard let lastSampleYawDegreesValue = lastSampleYawDegrees else {
            lastSampleYawDegrees = currentYaw
            return
        }

        let delta = angleDeltaDegrees(currentYaw, lastSampleYawDegreesValue)
        if let panDirection {
            let signed = delta * panDirection
            if signed >= -1 {
                cumulativeYawDegrees += delta
                lastSampleYawDegrees = currentYaw
            }
        } else {
            cumulativeYawDegrees += delta
            lastSampleYawDegrees = currentYaw
        }
    }

    private func resetCaptureState() {
        anchorYawDegrees = nil
        lastCaptureYawDegrees = nil
        lastSampleYawDegrees = nil
        cumulativeYawDegrees = 0
        lastCaptureProgressDegrees = 0
        panDirection = nil
        isCapturingFrame = false
        pendingFinalize = false
        canManualCapture = false
        isUpright = false
        alignmentHint = "Hold the phone upright"
        captureCount = 0
        yawProgressDegrees = 0
        directionLabel = "Left or Right"
        captureStartTimestamp = nil
        lastMotionTimestamp = nil
        lastMotionYawDegrees = nil
        lastExposureDuration = nil
        stableExposureCount = 0
        lastAngularVelocity = 0
        lastUprightDeviation = 0
        rootAnchorSet = false
        rootAnchor = nil
        rootAnchorTransform = nil
    }

    // MARK: - Utilities

    private func captureStepDegrees(from camera: ARCamera) -> Float {
        let width = Float(camera.imageResolution.width)
        let fx = camera.intrinsics.columns.0.x
        let fovRadians = 2 * atan(width / (2 * fx))
        let fovDegrees = fovRadians * 180 / .pi
        let step = fovDegrees * (1 - config.captureOverlap)
        return min(max(step, config.minStepDegrees), config.maxStepDegrees)
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

    private func angleDeltaDegrees(_ current: Float, _ target: Float) -> Float {
        var delta = current - target
        delta.formTruncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private func makeCGImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw GuidedCaptureError.imageConversionFailed
        }
        return cgImage
    }

    private func writeRGBFrame(_ cgImage: CGImage, index: Int, to bundle: CaptureBundle) throws -> Int64 {
        let uiImage = UIImage(cgImage: cgImage)
        let fileName = String(format: "%06d", index)
        let jpegURL = bundle.bundleURL.appendingPathComponent("frames/rgb/\(fileName).jpg")
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.9) else {
            throw GuidedCaptureError.imageConversionFailed
        }
        try jpegData.write(to: jpegURL, options: .atomic)

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
            throw GuidedCaptureError.depthConversionFailed
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)

        var uint16Data = [UInt16](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let floatIndex = y * bytesPerRow / MemoryLayout<Float32>.size + x
                let depthMeters = floatBuffer[floatIndex]
                let depthMM = depthMeters * 1000.0
                let clampedDepth = max(0, min(65535, depthMM))
                uint16Data[y * width + x] = UInt16(clampedDepth).bigEndian
            }
        }

        let bitsPerComponent = 16
        let bitsPerPixel = 16
        let bytesPerRowOut = width * 2

        let bitmapInfo = CGBitmapInfo.byteOrder16Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))

        guard let providerRef = CGDataProvider(
            data: Data(bytes: &uint16Data, count: uint16Data.count * MemoryLayout<UInt16>.size) as CFData
        ) else {
            throw GuidedCaptureError.depthConversionFailed
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRowOut,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: bitmapInfo,
            provider: providerRef,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw GuidedCaptureError.depthConversionFailed
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw GuidedCaptureError.depthConversionFailed
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw GuidedCaptureError.depthConversionFailed
        }

        return mutableData as Data
    }

    private func writeFrameMetadata(_ metadata: FrameMetadata, index: Int, to bundle: CaptureBundle) throws -> Int64 {
        let fileName = String(format: "%06d.json", index)
        let metaURL = bundle.bundleURL.appendingPathComponent("frames/meta/\(fileName)")
        let data = try JSONEncoder.iso8601Pretty().encode(metadata)
        try data.write(to: metaURL, options: .atomic)
        return Int64(data.count)
    }

    private func buildFrameMetadata(from frame: ARFrame, index: Int, isKeyframe: Bool) -> FrameMetadata {
        let camera = frame.camera
        let timestamp = frame.timestamp
        if captureStartTimestamp == nil {
            captureStartTimestamp = timestamp
        }
        let startTimestamp = captureStartTimestamp ?? timestamp

        let intrinsics = camera.intrinsics
        let intrinsicsArray: [[Float]] = [
            [intrinsics.columns.0.x, intrinsics.columns.1.x, intrinsics.columns.2.x],
            [intrinsics.columns.0.y, intrinsics.columns.1.y, intrinsics.columns.2.y],
            [intrinsics.columns.0.z, intrinsics.columns.1.z, intrinsics.columns.2.z]
        ]

        let transformArray = matrixToRowMajorArray(camera.transform)
        let projectionArray = matrixToRowMajorArray(camera.projectionMatrix)

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

        let trackingMetadata = TrackingMetadata(
            state: camera.trackingState.description,
            stateReason: trackingStateReason(camera.trackingState),
            worldMappingStatus: frame.worldMappingStatus.description
        )

        let exposureDuration = camera.exposureDuration
        let exposureMetadata = ExposureMetadata(
            duration: exposureDuration,
            iso: nil,
            whiteBalance: nil
        )

        var depthMetadata: DepthMetadata? = nil
        if let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap,
           let confidenceMap = frame.smoothedSceneDepth?.confidenceMap ?? frame.sceneDepth?.confidenceMap {
            let confidenceSummary = calculateConfidenceSummary(confidenceMap)
            let depthWidth = CVPixelBufferGetWidth(depthMap)
            let depthHeight = CVPixelBufferGetHeight(depthMap)
            let scaleX = Float(depthWidth) / Float(camera.imageResolution.width)
            let scaleY = Float(depthHeight) / Float(camera.imageResolution.height)
            let depthIntrinsics = [
                [intrinsics.columns.0.x * scaleX, intrinsics.columns.1.x * scaleX, intrinsics.columns.2.x * scaleX],
                [intrinsics.columns.0.y * scaleY, intrinsics.columns.1.y * scaleY, intrinsics.columns.2.y * scaleY],
                [intrinsics.columns.0.z, intrinsics.columns.1.z, intrinsics.columns.2.z]
            ]
            depthMetadata = DepthMetadata(
                available: true,
                width: depthWidth,
                height: depthHeight,
                confidenceSummary: confidenceSummary,
                intrinsics: depthIntrinsics,
                scaleFromRGB: Scale2D(x: scaleX, y: scaleY)
            )
        }

        let panorama = buildPanoramaMetadata(for: frame)

        return FrameMetadata(
            frameIndex: index,
            timestamp: timestamp,
            timestampSinceStart: timestamp - startTimestamp,
            camera: cameraMetadata,
            tracking: trackingMetadata,
            depth: depthMetadata,
            exposure: exposureMetadata,
            panorama: panorama,
            isKeyframe: isKeyframe
        )
    }

    private func buildPanoramaMetadata(for frame: ARFrame) -> PanoramaMetadata? {
        guard let anchorYawDegrees else { return nil }
        let currentYaw = frame.camera.transform.yawDegrees
        let relativeYaw = angleDeltaDegrees(currentYaw, anchorYawDegrees)
        let step = captureStepDegrees(from: frame.camera)
        let direction: String
        if let panDirection {
            direction = panDirection >= 0 ? "left" : "right"
        } else {
            direction = "unknown"
        }

        return PanoramaMetadata(
            anchorYawDegrees: anchorYawDegrees,
            relativeYawDegrees: relativeYaw,
            yawProgressDegrees: abs(cumulativeYawDegrees),
            panDirection: direction,
            stepDegrees: step,
            uprightDeviationDegrees: lastUprightDeviation,
            angularVelocityDegPerSec: lastAngularVelocity
        )
    }

    private func matrixToRowMajorArray(_ matrix: simd_float4x4) -> [[Float]] {
        [
            [matrix.columns.0.x, matrix.columns.1.x, matrix.columns.2.x, matrix.columns.3.x],
            [matrix.columns.0.y, matrix.columns.1.y, matrix.columns.2.y, matrix.columns.3.y],
            [matrix.columns.0.z, matrix.columns.1.z, matrix.columns.2.z, matrix.columns.3.z],
            [matrix.columns.0.w, matrix.columns.1.w, matrix.columns.2.w, matrix.columns.3.w]
        ]
    }

    private func trackingStateReason(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .notAvailable:
            return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return "excessiveMotion"
            case .insufficientFeatures: return "insufficientFeatures"
            case .initializing: return "initializing"
            case .relocalizing: return "relocalizing"
            @unknown default: return "unknown"
            }
        case .normal:
            return "normal"
        }
    }

    private func calculateConfidenceSummary(_ confidenceMap: CVPixelBuffer) -> ConfidenceSummary {
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }

        let width = CVPixelBufferGetWidth(confidenceMap)
        let height = CVPixelBufferGetHeight(confidenceMap)
        let count = width * height

        guard let baseAddress = CVPixelBufferGetBaseAddress(confidenceMap) else {
            return ConfidenceSummary(high: 0, medium: 0, low: 0)
        }

        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        var high = 0
        var medium = 0
        var low = 0

        for i in 0..<count {
            switch ARConfidenceLevel(rawValue: Int(buffer[i])) {
            case .high: high += 1
            case .medium: medium += 1
            case .low: low += 1
            default: low += 1
            }
        }

        let total = Float(max(count, 1))
        return ConfidenceSummary(
            high: Float(high) / total,
            medium: Float(medium) / total,
            low: Float(low) / total
        )
    }

    private func buildRootAnchorInfo() -> AnchorInfo? {
        guard let transform = rootAnchorTransform else { return nil }
        return AnchorInfo(
            id: rootAnchor?.identifier.uuidString ?? UUID().uuidString,
            name: "CaptureOrigin",
            transform: matrixToRowMajorArray(transform),
            trackingState: trackingState.description
        )
    }

    private func uprightDeviationDegrees(from camera: ARCamera, orientation: UIInterfaceOrientation) -> Float {
        let viewMatrix = camera.viewMatrix(for: orientation)
        let orientedTransform = simd_inverse(viewMatrix)
        let upVector = SIMD3<Float>(orientedTransform.columns.1.x, orientedTransform.columns.1.y, orientedTransform.columns.1.z)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let dot = simd_dot(simd_normalize(upVector), worldUp)
        let clamped = min(1, max(-1, dot))
        let angle = acos(clamped)
        return angle * 180 / .pi
    }

    private func updateAngularVelocity(currentYaw: Float, timestamp: TimeInterval) -> Float {
        guard let lastTimestamp = lastMotionTimestamp,
              let lastYaw = lastMotionYawDegrees else {
            lastMotionTimestamp = timestamp
            lastMotionYawDegrees = currentYaw
            lastAngularVelocity = 0
            return 0
        }

        let dt = max(timestamp - lastTimestamp, 1e-3)
        let delta = abs(angleDeltaDegrees(currentYaw, lastYaw))
        let velocity = Float(delta / Float(dt))
        lastMotionTimestamp = timestamp
        lastMotionYawDegrees = currentYaw
        lastAngularVelocity = velocity
        return velocity
    }

    private func exposureIsStable(for camera: ARCamera) -> Bool {
        let duration = camera.exposureDuration

        let exposureOk = duration <= config.maxExposureDurationSeconds || config.maxExposureDurationSeconds <= 0
        guard exposureOk else {
            stableExposureCount = 0
            lastExposureDuration = duration
            return false
        }

        if let lastDuration = lastExposureDuration {
            let durationDelta = abs(duration - lastDuration) / max(lastDuration, 1e-6)
            if durationDelta <= config.exposureStableDeltaRatio {
                stableExposureCount += 1
            } else {
                stableExposureCount = 0
            }
        } else {
            stableExposureCount = 0
        }

        lastExposureDuration = duration

        return stableExposureCount >= config.exposureStableSamples
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes
        for scene in scenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            return windowScene.effectiveGeometry.interfaceOrientation
        }
        return .portrait
    }

    private func setRootAnchorIfReady(frame: ARFrame, session: ARSession) {
        guard !rootAnchorSet else { return }
        guard trackingState == .normal else { return }
        guard worldMappingStatus == .extending || worldMappingStatus == .mapped else { return }

        let cameraPose = frame.camera.transform
        let anchor = ARAnchor(name: "CaptureOrigin", transform: cameraPose)
        session.add(anchor: anchor)
        rootAnchor = anchor
        rootAnchorTransform = cameraPose
        rootAnchorSet = true
    }
}

extension GuidedCaptureSessionManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        currentFrame = frame
        if isCapturing {
            trackingState = frame.camera.trackingState
            worldMappingStatus = frame.worldMappingStatus
            setRootAnchorIfReady(frame: frame, session: session)
            updateAlignment(for: frame)
        } else {
            trackingState = frame.camera.trackingState
            worldMappingStatus = frame.worldMappingStatus
        }
    }
}

enum GuidedCaptureError: LocalizedError {
    case sessionNotRunning
    case noFrameAvailable
    case imageConversionFailed
    case depthConversionFailed

    var errorDescription: String? {
        switch self {
        case .sessionNotRunning:
            return "ARSession is not running."
        case .noFrameAvailable:
            return "No AR frame available yet."
        case .imageConversionFailed:
            return "Failed to convert image."
        case .depthConversionFailed:
            return "Failed to encode depth data."
        }
    }
}

private extension JSONEncoder {
    static func iso8601Pretty() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension simd_float4x4 {
    var yawDegrees: Float {
        let forward = -SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z)
        let flat = SIMD2<Float>(forward.x, forward.z)
        let length = simd_length(flat)
        guard length > 0.0001 else { return 0 }
        let normalized = flat / length
        let yaw = atan2(normalized.x, -normalized.y)
        return yaw * 180 / .pi
    }

    var yawDegreesOptional: Float? {
        let forward = -SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z)
        let flat = SIMD2<Float>(forward.x, forward.z)
        let length = simd_length(flat)
        guard length > 0.0001 else { return nil }
        let normalized = flat / length
        let yaw = atan2(normalized.x, -normalized.y)
        return yaw * 180 / .pi
    }
}
