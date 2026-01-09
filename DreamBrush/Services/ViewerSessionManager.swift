//
//  ViewerSessionManager.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/6.
//

import ARKit
import os.log
import simd

@Observable
final class ViewerSessionManager: NSObject {
    struct ViewerConfig {
        var relocalizationTimeout: TimeInterval = 20
        var trackingLimitedTimeout: TimeInterval = 6
        var poseJumpDistance: Float = 0.4
        var poseJumpHoldDuration: TimeInterval = 1
        var anchorPositionTolerance: Float = 0.2
        var anchorAngleTolerance: Float = .pi / 18 // 10 degrees
    }

    var isSessionRunning = false
    var trackingState: ARCamera.TrackingState = .notAvailable
    var worldMappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    var isRelocalized = false
    var mismatchDetected = false
    var mismatchReason: String?
    var relocalizationMessage: String = "Move to the scanned area"
    var relocalizationElapsed: TimeInterval = 0
    var alignmentTransform: simd_float4x4?
    var anchorPositionError: Float?
    var anchorAngleError: Float?
    var relocalizationEnabled = true

    var shouldRender: Bool {
        if !relocalizationEnabled {
            return trackingState == .normal
        }
        return isRelocalized && !mismatchDetected
    }

    var config = ViewerConfig()

    private let logger = Logger(subsystem: "com.scottsun.DreamBrush", category: "ViewerSession")
    private(set) var session: ARSession?
    private var loadedBundle: CaptureBundle?
    private var expectedAnchorName = "CaptureOrigin"
    private var captureAnchorTransform: simd_float4x4?
    private var currentAnchorTransform: simd_float4x4?
    private var modelToCaptureTransform = matrix_identity_float4x4
    private var relocalizationStartDate: Date?
    private var limitedTrackingDuration: TimeInterval = 0
    private var lastFrameTimestamp: TimeInterval?
    private var lastCameraTransform: simd_float4x4?
    private var lastPoseJumpDate: Date?
    private var lastPoseJumpDistance: Float?
    private var anchorFound = false

    func startSession(for bundle: CaptureBundle, modelToCapture: simd_float4x4?, relocalizationEnabled: Bool) throws {
        self.relocalizationEnabled = relocalizationEnabled
        let worldMap: ARWorldMap?
        let anchors: AnchorData?
        if relocalizationEnabled {
            worldMap = try CaptureBundleManager.shared.loadWorldMap(from: bundle.bundleURL)
            anchors = try CaptureBundleManager.shared.loadAnchors(from: bundle.bundleURL)
        } else {
            worldMap = nil
            anchors = nil
        }

        loadedBundle = bundle
        if let anchors {
            expectedAnchorName = anchors.rootAnchor.name
            let matrixLayout = bundle.manifest.coordinateConventions.matrixLayout
            captureAnchorTransform = Self.matrix(from: anchors.rootAnchor.transform, layout: matrixLayout)
        } else {
            expectedAnchorName = "CaptureOrigin"
            captureAnchorTransform = nil
        }
        modelToCaptureTransform = modelToCapture ?? matrix_identity_float4x4

        resetState()

        let session = ARSession()
        session.delegate = self
        self.session = session

        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = worldMap
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
        relocalizationStartDate = Date()
        relocalizationMessage = relocalizationEnabled ? "Searching for original location..." : "Relocalization off"
        logger.info("Viewer session started for bundle: \(bundle.manifest.bundleId)")
    }

    /// Start session without a bundle (no relocalization, renders at camera position)
    func startSessionWithoutBundle(modelToCapture: simd_float4x4?) throws {
        self.relocalizationEnabled = false
        loadedBundle = nil
        expectedAnchorName = "CaptureOrigin"
        captureAnchorTransform = nil
        modelToCaptureTransform = modelToCapture ?? matrix_identity_float4x4

        resetState()

        let session = ARSession()
        session.delegate = self
        self.session = session

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
        relocalizationMessage = "Rendering without alignment"
        logger.info("Viewer session started without bundle (no relocalization)")
    }

    func pauseSession() {
        session?.pause()
        isSessionRunning = false
    }

    func retryRelocalization() {
        guard let bundle = loadedBundle else { return }
        do {
            try startSession(
                for: bundle,
                modelToCapture: modelToCaptureTransform,
                relocalizationEnabled: true
            )
        } catch {
            mismatchDetected = true
            mismatchReason = error.localizedDescription
            logger.error("Failed to restart viewer session: \(error.localizedDescription)")
        }
    }

    private func resetState() {
        isRelocalized = false
        mismatchDetected = false
        mismatchReason = nil
        relocalizationElapsed = 0
        limitedTrackingDuration = 0
        lastFrameTimestamp = nil
        lastCameraTransform = nil
        lastPoseJumpDate = nil
        lastPoseJumpDistance = nil
        anchorFound = false
        currentAnchorTransform = nil
        alignmentTransform = nil
        anchorPositionError = nil
        anchorAngleError = nil
    }
}

// MARK: - ARSessionDelegate

extension ViewerSessionManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        trackingState = frame.camera.trackingState
        worldMappingStatus = frame.worldMappingStatus

        updateRelocalizationElapsed()
        updateTrackingTimers(frame: frame)
        updatePoseJumpDetection(frame: frame)
        updateRelocalizationState()
        updateAlignmentTransform()
        updateRelocalizationMessage()
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updateAnchorTransforms(from: anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updateAnchorTransforms(from: anchors)
    }
}

// MARK: - Relocalization + Mismatch Detection

private extension ViewerSessionManager {
    func updateRelocalizationElapsed() {
        if let startDate = relocalizationStartDate {
            relocalizationElapsed = Date().timeIntervalSince(startDate)
        }
    }

    func updateTrackingTimers(frame: ARFrame) {
        let timestamp = frame.timestamp
        let delta = lastFrameTimestamp.map { timestamp - $0 } ?? 0
        lastFrameTimestamp = timestamp

        switch trackingState {
        case .normal:
            limitedTrackingDuration = 0
        case .limited, .notAvailable:
            limitedTrackingDuration += delta
        }
    }

    func updatePoseJumpDetection(frame: ARFrame) {
        let currentTransform = frame.camera.transform
        if let previous = lastCameraTransform {
            let distance = simd_length(currentTransform.translation - previous.translation)
            if distance > config.poseJumpDistance {
                lastPoseJumpDate = Date()
                lastPoseJumpDistance = distance
            }
        }
        lastCameraTransform = currentTransform
    }

    func updateRelocalizationState() {
        if !relocalizationEnabled {
            isRelocalized = trackingState == .normal
            mismatchDetected = false
            mismatchReason = nil
            return
        }

        let hasGoodTracking = trackingState == .normal
        isRelocalized = hasGoodTracking && anchorFound

        var mismatch: String?

        if let anchorMismatch = anchorMismatchReason() {
            mismatch = anchorMismatch
        } else if let poseJump = poseJumpReason() {
            mismatch = poseJump
        } else if !isRelocalized, relocalizationElapsed > config.relocalizationTimeout {
            mismatch = "Relocalization timed out (\(Int(relocalizationElapsed))s)"
        } else if limitedTrackingDuration > config.trackingLimitedTimeout {
            mismatch = "Tracking limited for \(Int(limitedTrackingDuration))s"
        }

        mismatchDetected = mismatch != nil
        mismatchReason = mismatch
    }

    func updateAnchorTransforms(from anchors: [ARAnchor]) {
        guard relocalizationEnabled else { return }
        guard let anchor = anchors.first(where: { $0.name == expectedAnchorName }) else { return }
        anchorFound = true
        currentAnchorTransform = anchor.transform
    }

    func anchorMismatchReason() -> String? {
        guard trackingState == .normal,
              let captured = captureAnchorTransform,
              let current = currentAnchorTransform,
              !Self.isIdentity(captured) else {
            anchorPositionError = nil
            anchorAngleError = nil
            return nil
        }

        let positionError = simd_length(captured.translation - current.translation)
        let angleError = Self.rotationAngleBetween(captured, current)
        anchorPositionError = positionError
        anchorAngleError = angleError

        if positionError > config.anchorPositionTolerance || angleError > config.anchorAngleTolerance {
            return String(
                format: "Anchor mismatch (%.2fm, %.1fdeg)",
                positionError,
                angleError * 180 / .pi
            )
        }

        return nil
    }

    func poseJumpReason() -> String? {
        guard let lastPoseJumpDate, let distance = lastPoseJumpDistance else { return nil }
        let elapsed = Date().timeIntervalSince(lastPoseJumpDate)
        if elapsed > config.poseJumpHoldDuration {
            self.lastPoseJumpDate = nil
            self.lastPoseJumpDistance = nil
            return nil
        }
        return "Pose jump detected (\(String(format: "%.2f", distance))m)"
    }

    func updateAlignmentTransform() {
        if !relocalizationEnabled {
            alignmentTransform = modelToCaptureTransform
            return
        }

        guard let currentAnchorTransform else {
            alignmentTransform = nil
            return
        }
        alignmentTransform = currentAnchorTransform * modelToCaptureTransform
    }

    func updateRelocalizationMessage() {
        if !relocalizationEnabled {
            relocalizationMessage = "Relocalization off"
            return
        }
        if mismatchDetected {
            relocalizationMessage = mismatchReason ?? "Relocalization mismatch detected"
            return
        }

        if isRelocalized {
            relocalizationMessage = "Aligned to capture origin"
            return
        }

        switch trackingState {
        case .notAvailable:
            relocalizationMessage = "Initializing AR session..."
        case .limited(let reason):
            switch reason {
            case .relocalizing:
                relocalizationMessage = "Relocalizing... (\(Int(relocalizationElapsed))s)"
            case .insufficientFeatures:
                relocalizationMessage = "Move to area with more visual features"
            case .excessiveMotion:
                relocalizationMessage = "Slow down - excessive motion detected"
            case .initializing:
                relocalizationMessage = "Initializing tracking..."
            @unknown default:
                relocalizationMessage = "Limited tracking..."
            }
        case .normal:
            relocalizationMessage = "Searching for anchor..."
        }
    }
}

extension ViewerSessionManager {
    static func matrix(from array: [[Float]], layout: String?) -> simd_float4x4? {
        guard array.count == 4, array.allSatisfy({ $0.count == 4 }) else { return nil }
        let normalized = layout?.lowercased()
        if normalized == "row_major" {
            let c0 = SIMD4<Float>(array[0][0], array[1][0], array[2][0], array[3][0])
            let c1 = SIMD4<Float>(array[0][1], array[1][1], array[2][1], array[3][1])
            let c2 = SIMD4<Float>(array[0][2], array[1][2], array[2][2], array[3][2])
            let c3 = SIMD4<Float>(array[0][3], array[1][3], array[2][3], array[3][3])
            return simd_float4x4(columns: (c0, c1, c2, c3))
        }
        let c0 = SIMD4<Float>(array[0][0], array[0][1], array[0][2], array[0][3])
        let c1 = SIMD4<Float>(array[1][0], array[1][1], array[1][2], array[1][3])
        let c2 = SIMD4<Float>(array[2][0], array[2][1], array[2][2], array[2][3])
        let c3 = SIMD4<Float>(array[3][0], array[3][1], array[3][2], array[3][3])
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }

    static func rotationAngleBetween(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let qa = simd_quatf(a)
        let qb = simd_quatf(b)
        let delta = simd_normalize(qa * qb.inverse)
        return delta.angle
    }

    static func isIdentity(_ matrix: simd_float4x4, tolerance: Float = 1e-3) -> Bool {
        let identity = matrix_identity_float4x4
        let columns = [
            matrix.columns.0 - identity.columns.0,
            matrix.columns.1 - identity.columns.1,
            matrix.columns.2 - identity.columns.2,
            matrix.columns.3 - identity.columns.3
        ]
        let maxDelta = columns
            .flatMap { [$0.x, $0.y, $0.z, $0.w] }
            .map { abs($0) }
            .max() ?? 0
        return maxDelta < tolerance
    }
}
