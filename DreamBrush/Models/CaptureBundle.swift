//
//  CaptureBundle.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import Foundation
import UIKit

struct CaptureBundle: Identifiable, Codable {
    var id: String { manifest.bundleId }

    let manifest: CaptureManifest
    let bundleURL: URL

    var thumbnail: UIImage? {
        let thumbURL = bundleURL.appendingPathComponent("thumb.jpg")
        guard let data = try? Data(contentsOf: thumbURL) else { return nil }
        return UIImage(data: data)
    }

    enum CodingKeys: String, CodingKey {
        case manifest
        case bundleURL
    }
}

struct CaptureManifest: Codable {
    let version: String
    let bundleId: String
    let createdAt: Date
    let appVersion: String
    let appBuild: String
    let iosVersion: String
    let deviceModel: String
    let deviceName: String

    let captureSettings: CaptureSettings
    let capturePlan: CapturePlan?
    var captureStats: CaptureStats
    let coordinateConventions: CoordinateConventions
    var relocalizationQuality: RelocalizationQuality?

    static let currentVersion = "1.0"

    init(
        bundleId: String = UUID().uuidString,
        captureSettings: CaptureSettings = CaptureSettings(),
        capturePlan: CapturePlan? = nil
    ) {
        self.version = Self.currentVersion
        self.bundleId = bundleId
        self.createdAt = Date()
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        self.appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        self.iosVersion = UIDevice.current.systemVersion
        self.deviceModel = Self.deviceModelIdentifier()
        self.deviceName = UIDevice.current.name
        self.captureSettings = captureSettings
        self.capturePlan = capturePlan
        self.captureStats = CaptureStats()
        self.coordinateConventions = CoordinateConventions()
        self.relocalizationQuality = nil
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }
}

struct CaptureSettings: Codable {
    let targetFPS: Int
    let depthEnabled: Bool
    let meshReconstructionEnabled: Bool
    let smoothedDepth: Bool
    let captureResolution: CaptureResolutionPreset
    let depthConfidenceDownsampleFactor: Int?

    init(
        targetFPS: Int = 10,
        depthEnabled: Bool = true,
        meshReconstructionEnabled: Bool = false,
        smoothedDepth: Bool = true,
        captureResolution: CaptureResolutionPreset = .max,
        depthConfidenceDownsampleFactor: Int? = nil
    ) {
        self.targetFPS = targetFPS
        self.depthEnabled = depthEnabled
        self.meshReconstructionEnabled = meshReconstructionEnabled
        self.smoothedDepth = smoothedDepth
        self.captureResolution = captureResolution
        self.depthConfidenceDownsampleFactor = depthConfidenceDownsampleFactor
    }
}

enum CaptureResolutionPreset: String, Codable, CaseIterable, Identifiable {
    case max
    case twoK
    case p1080

    var id: String { rawValue }

    var title: String {
        switch self {
        case .max: return "Max"
        case .twoK: return "2K"
        case .p1080: return "1080p"
        }
    }

    var subtitle: String {
        switch self {
        case .max: return "Best quality"
        case .twoK: return "Smaller files"
        case .p1080: return "Fastest training"
        }
    }

    var targetLongEdge: Int? {
        switch self {
        case .max: return nil
        case .twoK: return 2560
        case .p1080: return 1920
        }
    }
}

struct CaptureStats: Codable {
    var durationSeconds: Double
    var frameCount: Int
    var keyframeCount: Int
    var depthFrameCount: Int
    var averageTrackingQuality: Double
    var finalMappingStatus: String
    var estimatedSizeBytes: Int64

    init() {
        self.durationSeconds = 0
        self.frameCount = 0
        self.keyframeCount = 0
        self.depthFrameCount = 0
        self.averageTrackingQuality = 0
        self.finalMappingStatus = "notAvailable"
        self.estimatedSizeBytes = 0
    }
}

/// Summary of relocalization quality metrics for a capture bundle
struct RelocalizationQuality: Codable {
    /// Percentage of frames with good tracking (0.0-1.0)
    let goodTrackingPercentage: Double
    /// Whether the mapping status reached .mapped during capture
    let mappingStatusReached: Bool
    /// Average depth confidence across all depth frames (0.0-1.0)
    let averageDepthConfidence: Double
    /// Whether an ARWorldMap was successfully saved
    let worldMapSaved: Bool
    /// Total feature points in the saved world map (if available)
    let worldMapFeatureCount: Int?
    /// Timestamp when relocalization was last tested (nil if never tested)
    var lastRelocalizationTestDate: Date?
    /// Result of the last relocalization test (nil if never tested)
    var lastRelocalizationTestResult: RelocalizationTestResult?

    init(
        goodTrackingPercentage: Double = 0,
        mappingStatusReached: Bool = false,
        averageDepthConfidence: Double = 0,
        worldMapSaved: Bool = false,
        worldMapFeatureCount: Int? = nil,
        lastRelocalizationTestDate: Date? = nil,
        lastRelocalizationTestResult: RelocalizationTestResult? = nil
    ) {
        self.goodTrackingPercentage = goodTrackingPercentage
        self.mappingStatusReached = mappingStatusReached
        self.averageDepthConfidence = averageDepthConfidence
        self.worldMapSaved = worldMapSaved
        self.worldMapFeatureCount = worldMapFeatureCount
        self.lastRelocalizationTestDate = lastRelocalizationTestDate
        self.lastRelocalizationTestResult = lastRelocalizationTestResult
    }

    /// Overall quality score (0.0-1.0) based on all metrics
    var overallScore: Double {
        var score = 0.0
        var weights = 0.0

        // World map saved is critical (40% weight)
        if worldMapSaved {
            score += 0.4
        }
        weights += 0.4

        // Mapping status reached (30% weight)
        if mappingStatusReached {
            score += 0.3
        }
        weights += 0.3

        // Good tracking percentage (20% weight)
        score += goodTrackingPercentage * 0.2
        weights += 0.2

        // Depth confidence (10% weight)
        score += averageDepthConfidence * 0.1
        weights += 0.1

        return weights > 0 ? score / weights : 0
    }

    /// Human-readable quality assessment
    var qualityAssessment: String {
        let score = overallScore
        if score >= 0.8 { return "Excellent" }
        if score >= 0.6 { return "Good" }
        if score >= 0.4 { return "Fair" }
        return "Poor"
    }
}

/// Result of a relocalization test
struct RelocalizationTestResult: Codable {
    let success: Bool
    let timeToRelocalize: TimeInterval?
    let trackingStateAfterRelocalization: String?
    let notes: String?

    init(
        success: Bool,
        timeToRelocalize: TimeInterval? = nil,
        trackingStateAfterRelocalization: String? = nil,
        notes: String? = nil
    ) {
        self.success = success
        self.timeToRelocalize = timeToRelocalize
        self.trackingStateAfterRelocalization = trackingStateAfterRelocalization
        self.notes = notes
    }
}

struct CoordinateConventions: Codable {
    let handedness: String
    let matrixLayout: String
    let transformDirection: String
    let intrinsicsLayout: String?
    let upAxis: String
    let units: String

    init() {
        self.handedness = "right"
        self.matrixLayout = "row_major"
        self.transformDirection = "camera_to_world"
        self.intrinsicsLayout = "row_major"
        self.upAxis = "Y"
        self.units = "meters"
    }
}

struct AnchorData: Codable {
    let rootAnchor: AnchorInfo
    let additionalAnchors: [AnchorInfo]

    init(rootAnchor: AnchorInfo) {
        self.rootAnchor = rootAnchor
        self.additionalAnchors = []
    }
}

struct AnchorInfo: Codable {
    let id: String
    let name: String
    let transform: [[Float]]
    let createdAt: Date
    let trackingState: String

    init(
        id: String = UUID().uuidString,
        name: String = "CaptureOrigin",
        transform: [[Float]] = [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1]
        ],
        trackingState: String = "normal"
    ) {
        self.id = id
        self.name = name
        self.transform = transform
        self.createdAt = Date()
        self.trackingState = trackingState
    }
}

struct FrameMetadata: Codable {
    let frameIndex: Int
    let timestamp: Double
    let timestampSinceStart: Double

    let camera: CameraMetadata
    let tracking: TrackingMetadata
    let depth: DepthMetadata?
    let exposure: ExposureMetadata?
    let panorama: PanoramaMetadata?

    var isKeyframe: Bool
}

struct CameraMetadata: Codable {
    let intrinsics: [[Float]]
    let imageResolution: ImageResolution
    let transform: [[Float]]
    let projectionMatrix: [[Float]]
    let eulerAngles: EulerAngles
}

struct ImageResolution: Codable {
    let width: Int
    let height: Int
}

struct EulerAngles: Codable {
    let pitch: Float
    let yaw: Float
    let roll: Float
}

struct TrackingMetadata: Codable {
    let state: String
    let stateReason: String
    let worldMappingStatus: String
}

struct DepthMetadata: Codable {
    let available: Bool
    let width: Int
    let height: Int
    let confidenceSummary: ConfidenceSummary
    let intrinsics: [[Float]]?
    let scaleFromRGB: Scale2D?
}

struct ConfidenceSummary: Codable {
    let high: Float
    let medium: Float
    let low: Float
}

struct ExposureMetadata: Codable {
    let duration: Double
    let iso: Float?
    let whiteBalance: Int?
}

struct PanoramaMetadata: Codable {
    let anchorYawDegrees: Float
    let relativeYawDegrees: Float
    let yawProgressDegrees: Float
    let panDirection: String
    let stepDegrees: Float
    let uprightDeviationDegrees: Float
    let angularVelocityDegPerSec: Float
}

struct Scale2D: Codable {
    let x: Float
    let y: Float
}
