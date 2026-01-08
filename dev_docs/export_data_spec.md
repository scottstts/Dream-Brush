# Export Data Bundle Spec (DreamBrush iOS)

This document describes the capture bundle exported by the iOS app. It is derived **only** from the Swift code in the app (not from training scripts). The export is the bundle folder itself, not a zip.

## Overview
- Each capture creates a folder named `CaptureBundle_<bundleId>` in the app's Application Support directory.
- Export returns that folder as-is.
- The bundle contains RGB frames, optional depth frames, per-frame metadata, keyframe JPEGs, and JSON manifest/anchor data.

## Bundle layout
```
CaptureBundle_<bundleId>/
  manifest.json
  anchors.json
  worldmap.arexperience            (optional)
  keyframes/
    000001.jpg
    000123.jpg
    ...
  frames/
    rgb/
      000001.jpg
      000002.jpg
      ...
    depth/
      000001.png                   (optional per-frame)
      000002.png
      ...
    meta/
      000001.json
      000002.json
      ...
  thumb.jpg                        (optional)
```

### Required vs optional
- Required files/dirs by validation logic:
  - `manifest.json`
  - `anchors.json`
  - `frames/rgb/`
  - `frames/depth/`
  - `frames/meta/`
  - `keyframes/`
- Optional files:
  - `worldmap.arexperience` (absent in older or failed captures; used for relocalization)
  - `thumb.jpg` (read by UI if present; not created by capture code)

## Naming and indexing
- Frames are numbered with **6-digit, zero-padded, 1-based indices**.
  - Example: `000001.jpg`, `000001.json`, `000001.png`.
- `frames/rgb/*.jpg` and `frames/meta/*.json` exist for every captured frame.
- `frames/depth/*.png` is only written when depth data is available for that frame.
- `keyframes/*.jpg` is a subset of the RGB frames, using the same index as the source frame.

## File formats
### manifest.json
- JSON, pretty-printed, sorted keys.
- Date fields are ISO-8601 strings.

Schema (types are the Swift `Codable` definitions):
```
CaptureManifest
- version: String                // currently "1.0"
- bundleId: String               // UUID, also used in folder name
- createdAt: Date                // ISO-8601
- appVersion: String
- appBuild: String
- iosVersion: String
- deviceModel: String            // e.g. hardware identifier
- deviceName: String
- captureSettings: CaptureSettings
- captureStats: CaptureStats
- coordinateConventions: CoordinateConventions
- relocalizationQuality: RelocalizationQuality?  // optional

CaptureSettings
- targetFPS: Int
- depthEnabled: Bool
- meshReconstructionEnabled: Bool
- smoothedDepth: Bool
- captureResolution: CaptureResolutionPreset     // "max" | "twoK" | "p1080"

CaptureStats
- durationSeconds: Double
- frameCount: Int
- keyframeCount: Int
- depthFrameCount: Int
- averageTrackingQuality: Double                 // computed as framesWithDepth / totalFrames
- finalMappingStatus: String                     // "notAvailable" | "limited" | "extending" | "mapped" | "unknown"
- estimatedSizeBytes: Int64

CoordinateConventions
- handedness: String         // "right"
- matrixLayout: String       // "row_major"
- transformDirection: String // "camera_to_world"
- intrinsicsLayout: String?  // "row_major"
- upAxis: String             // "Y"
- units: String              // "meters"

RelocalizationQuality (optional)
- goodTrackingPercentage: Double      // 0.0 - 1.0
- mappingStatusReached: Bool
- averageDepthConfidence: Double      // 0.0 - 1.0
- worldMapSaved: Bool
- worldMapFeatureCount: Int?
- lastRelocalizationTestDate: Date?
- lastRelocalizationTestResult: RelocalizationTestResult?

RelocalizationTestResult (optional)
- success: Bool
- timeToRelocalize: TimeInterval?
- trackingStateAfterRelocalization: String?
- notes: String?
```

Notes:
- `captureResolution` is a preset only; the actual per-frame pixel size is recorded in `camera.imageResolution`.
- Preset targets (used to pick a video format):
  - `max`: highest available resolution.
  - `twoK`: prefers formats with long edge <= 2560.
  - `p1080`: prefers formats with long edge <= 1920.

### anchors.json
- JSON, pretty-printed, sorted keys.
- Date fields are ISO-8601 strings.

Schema:
```
AnchorData
- rootAnchor: AnchorInfo
- additionalAnchors: [AnchorInfo]

AnchorInfo
- id: String
- name: String                 // "CaptureOrigin" for the root anchor
- transform: [[Float]]         // 4x4 row-major
- createdAt: Date              // ISO-8601
- trackingState: String        // e.g. "normal"
```

Notes:
- The root anchor is set once tracking is normal and mapping is at least `.extending`, using the current camera pose.
- If no root anchor was set, the app writes an identity transform.

### worldmap.arexperience (optional)
- Binary archive produced by `NSKeyedArchiver` of `ARWorldMap` (secure coding).

### frames/rgb/*.jpg
- JPEG encoded from `ARFrame.capturedImage` via CIImage -> CGImage -> UIImage.
- Compression quality: **0.88**.

### frames/depth/*.png
- 16-bit grayscale PNG.
- Each pixel is **depth in millimeters**, clamped to `[0, 65535]` and stored as `UInt16`.
- PNG is written only if a depth map is available for that frame.
- The depth map is taken from `ARFrame.smoothedSceneDepth` when available, otherwise `ARFrame.sceneDepth`.

### frames/meta/*.json
- JSON, pretty-printed, sorted keys.
- Per-frame metadata describing camera intrinsics/pose, tracking state, and depth summary.

Schema:
```
FrameMetadata
- frameIndex: Int
- timestamp: Double                    // ARFrame.timestamp (seconds)
- timestampSinceStart: Double          // seconds since first captured frame
- camera: CameraMetadata
- tracking: TrackingMetadata
- depth: DepthMetadata?                // optional
- exposure: ExposureMetadata?          // optional (currently not populated)
- isKeyframe: Bool

CameraMetadata
- intrinsics: [[Float]]                // 3x3 row-major
- imageResolution: ImageResolution     // in pixels
- transform: [[Float]]                 // 4x4 row-major (camera_to_world)
- projectionMatrix: [[Float]]          // 4x4 row-major
- eulerAngles: EulerAngles             // radians

ImageResolution
- width: Int
- height: Int

EulerAngles
- pitch: Float
- yaw: Float
- roll: Float

TrackingMetadata
- state: String                        // "notAvailable" | "limited" | "normal"
- stateReason: String                  // "notAvailable" | "initializing" | "excessiveMotion" | "insufficientFeatures" | "relocalizing" | "none" | "unknown"
- worldMappingStatus: String           // "notAvailable" | "limited" | "extending" | "mapped" | "unknown"

DepthMetadata (optional)
- available: Bool                       // true when present
- width: Int                            // depth map width
- height: Int                           // depth map height
- confidenceSummary: ConfidenceSummary  // fractions

ConfidenceSummary
- high: Float
- medium: Float
- low: Float

ExposureMetadata (optional)
- duration: Double
- iso: Float
- whiteBalance: Int
```

Notes:
- `depth` is only included when both a depth map and confidence map are available.
- `exposure` is currently always omitted (not populated in code).

### keyframes/*.jpg
- JPEGs copied from `frames/rgb/*.jpg` when a frame is selected as a keyframe.
- Keyframe selection logic:
  - First captured frame is always a keyframe.
  - A new keyframe is chosen if either:
    - Translation from last keyframe > 0.05 meters, or
    - Rotation angle between camera forward vectors > 0.1 radians (~5.7 degrees).
  - Maximum keyframes: 300.

## Coordinate and matrix conventions
The manifest explicitly defines the conventions used by matrices in metadata:
- Right-handed coordinate system.
- Matrices are stored **row-major**.
- Camera transform matrices are **camera_to_world**.
- Up axis is **Y**.
- Units are **meters**.

## Export behavior
- Export is the bundle folder itself (`CaptureBundle_<bundleId>`).
- No additional packaging or conversion happens during export.
