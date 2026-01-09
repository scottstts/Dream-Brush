# DreamBrush App Specification

## Product Goal

DreamBrush is a proof-of-concept iOS app that enables:

1. **Capture**: Panorama-style sweep using iPhone camera + LiDAR (when available) via ARKit, upright-only gating
2. **Export**: Record structured "capture bundles" containing RGB frames, camera intrinsics/poses, depth maps, and ARKit relocalization artifacts for offline **SHARP inference** and splat merge on Mac
3. **Import**: Accept pre-trained 3DGS assets back onto the device via standard file transfer
4. **View**: Render 3DGS in AR with strict relocalization gating and coordinate alignment
5. **Style**: Provide simple appearance-only "style" controls (color/tonemapping presets)

## Constraints & Non-Goals (Part 1)

- **No on-device 3DGS training** - SHARP inference + merge happens offline on Mac
- **No cloud/GPU backend services** - all processing is local
- **No complex diffusion stylization** - only basic color adjustments
- **No multi-user shared AR persistence** - single-user workflow only
- **No real-time collaboration features**

## Target Devices

- iPhone with LiDAR (iPhone 12 Pro and later, iPad Pro with LiDAR)
- Graceful fallback for non-LiDAR devices (RGB-only capture, no depth)
- iOS 17.0+ minimum deployment target

## Core Frameworks & Dependencies

### Apple Frameworks
- `ARKit` - Core tracking, frames, depth, world map
- `Metal` + `MetalKit` - GPU rendering for MetalSplatter
- `RealityKit` - Optional debug visualization
- `AVFoundation` - Camera/image format utilities
- `UniformTypeIdentifiers` - Custom file types for import/export
- `Compression` - Bundle compression/decompression
- `OSLog` - Structured logging

### Third-Party
- `MetalSplatter` (via Swift Package Manager) - 3DGS rendering

---

# Capture Bundle Format Specification (Panorama Capture)

## Directory Structure

```
CaptureBundle_<UUID>/
├── manifest.json           # Global metadata and settings
├── worldmap.arexperience   # Serialized ARWorldMap bytes
├── anchors.json            # Root anchor and additional anchors
├── frames/
│   ├── rgb/                # All recorded RGB frames
│   │   ├── 000000.jpg
│   │   ├── 000001.jpg
│   │   └── ...
│   ├── depth/              # Depth maps (when available)
│   │   ├── 000000.png      # 16-bit PNG, millimeters
│   │   ├── 000001.png
│   │   └── ...
│   └── meta/               # Per-frame metadata
│       ├── 000000.json
│       ├── 000001.json
│       └── ...
```

## File Formats

### manifest.json

```json
{
  "version": "1.0",
  "bundleId": "<UUID>",
  "createdAt": "<ISO8601 timestamp>",
  "appVersion": "1.0.0",
  "appBuild": "1",
  "iosVersion": "17.0",
  "deviceModel": "iPhone15,3",
  "deviceName": "iPhone 14 Pro Max",

  "captureSettings": {
    "targetFPS": 0,
    "depthEnabled": true,
    "meshReconstructionEnabled": false,
    "smoothedDepth": true
  },

  "captureStats": {
    "durationSeconds": 60.5,
    "frameCount": 10,
    "keyframeCount": 10,
    "depthFrameCount": 10,
    "averageTrackingQuality": 0.95,
    "finalMappingStatus": "mapped",
    "estimatedSizeBytes": 524288000
  },

  "coordinateConventions": {
    "handedness": "right",
    "matrixLayout": "row_major",
    "transformDirection": "camera_to_world",
    "upAxis": "Y",
    "units": "meters"
  }
}
```

### anchors.json

```json
{
  "rootAnchor": {
    "id": "<UUID>",
    "name": "CaptureOrigin",
    "transform": [
      [1.0, 0.0, 0.0, 0.0],
      [0.0, 1.0, 0.0, 0.0],
      [0.0, 0.0, 1.0, 0.0],
      [0.0, 0.0, 0.0, 1.0]
    ],
    "createdAt": "<ISO8601 timestamp>",
    "trackingState": "normal"
  },
  "additionalAnchors": []
}
```

### Per-Frame Metadata (frames/meta/NNNNNN.json)

```json
{
  "frameIndex": 1,
  "timestamp": 1234567890.123,
  "timestampSinceStart": 0.0,

  "camera": {
    "intrinsics": [
      [fx, 0.0, cx],
      [0.0, fy, cy],
      [0.0, 0.0, 1.0]
    ],
    "imageResolution": {
      "width": 1920,
      "height": 1440
    },
    "transform": [
      [r00, r01, r02, tx],
      [r10, r11, r12, ty],
      [r20, r21, r22, tz],
      [0.0, 0.0, 0.0, 1.0]
    ],
    "projectionMatrix": [/* 4x4 matrix */],
    "eulerAngles": {
      "pitch": 0.0,
      "yaw": 0.0,
      "roll": 0.0
    }
  },

  "tracking": {
    "state": "normal",
    "stateReason": "none",
    "worldMappingStatus": "mapped"
  },

  "depth": {
    "available": true,
    "width": 256,
    "height": 192,
    "confidenceSummary": {
      "high": 0.85,
      "medium": 0.10,
      "low": 0.05
    },
    "intrinsics": [
      [fx, 0.0, cx],
      [0.0, fy, cy],
      [0.0, 0.0, 1.0]
    ],
    "scaleFromRGB": {
      "x": 0.5,
      "y": 0.5
    }
  },

  "exposure": {
    "duration": 0.033,
    "iso": null,
    "whiteBalance": null
  },

  "panorama": {
    "anchorYawDegrees": 0.0,
    "relativeYawDegrees": 45.0,
    "yawProgressDegrees": 135.0,
    "panDirection": "left",
    "stepDegrees": 32.0,
    "uprightDeviationDegrees": 2.5,
    "angularVelocityDegPerSec": 60.0
  },

  "isKeyframe": false
}
```

## Coordinate System Conventions

1. **Handedness**: Right-handed (ARKit native)
2. **Matrix Layout**: Row-major when serialized to JSON arrays
3. **Transform Direction**: Camera-to-world (ARCamera.transform)
4. **Up Axis**: +Y is up
5. **Units**: Meters

## File Naming

- Frame files use 6-digit zero-padded indices: `000001`, `000002`, etc.
- Bundle folders use format: `CaptureBundle_<UUID>`
- Timestamps in ISO 8601 format with timezone

## Depth Encoding

- Format: 16-bit grayscale PNG
- Units: Millimeters (0.001m precision)
- Invalid/missing depth: 0
- Maximum depth: 65.535 meters (65535mm)

---

# Session Coordinate Frames

1. **ARKit World Space**: Runtime coordinate space, origin at session start
2. **Capture Anchor Space**: Stable origin defined by root anchor at scan time
3. **Splat Model Space**: Coordinate space produced by offline training
4. **Viewer Alignment Transform**: Runtime composition linking all spaces for rendering
