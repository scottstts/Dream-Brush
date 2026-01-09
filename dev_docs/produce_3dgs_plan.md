
## Producing 3DGS From Panorama Capture (Offline)

This document describes the **offline pipeline** for converting a panorama-style capture bundle into a **single merged 3D Gaussian scene**. This is the next step after capture/export. The code for this pipeline should live under:

```
3dgs/
```

We **do not** implement this in the iOS app. This is an offline Python pipeline that:
1) runs SHARP inference per image, and  
2) merges the resulting splats into one coherent PLY using capture metadata.

---

## Goals
- Use the captured **frames + metadata + depth** to build a **single merged splat**.
- Avoid heavy SfM / COLMAP.
- Produce a PLY that renders correctly in the app viewer (see `dev_docs/ply_viewer_alignment.md`).

---

## Inputs
From a CaptureBundle (exported from iOS):

```
CaptureBundle_<id>/
  manifest.json
  anchors.json
  worldmap.arexperience (optional, keep)
  frames/
    rgb/*.jpg
    depth/*.png        (16-bit depth in mm, optional per frame)
    meta/*.json
```

Key per-frame metadata used:
- `camera.transform` (4x4 row-major, camera_to_world)
- `camera.intrinsics` (3x3 row-major, RGB intrinsics)
- `depth.intrinsics` (optional; scaled to depth size)
- `depth.scaleFromRGB` (optional)
- `panorama.*` (anchor yaw, relative yaw, progress, angular velocity)
- `exposure.duration` (for quality gating)

---

## Output
- A **single merged PLY** containing all Gaussians, aligned to the capture origin.
- Optional: a debug JSON with merge stats (counts per frame, pruning, voxel stats).

**Viewer compatibility requirement (must match `dev_docs/ply_viewer_alignment.md`):**
The merged PLY must use the standard 3DGS schema that MetalSplatter expects:
```
x y z
nx ny nz
f_dc_0 f_dc_1 f_dc_2
opacity
scale_0 scale_1 scale_2
rot_0 rot_1 rot_2 rot_3
```
- `opacity` is **logit opacity**.
- `scale_*` are **log-scale** values.
- Remove any `obj_info` lines in the PLY header (MetalSplatter is strict).

---

## Pipeline overview

### Stage 0 — Load & validate bundle
**Actions**
- Parse `manifest.json`, `anchors.json`.
- Enumerate frames by matching `frames/rgb` and `frames/meta`.
- Load depth if available.

**Checks**
- Ensure per-frame transforms exist.
- Verify camera intrinsics and depth intrinsics are valid.
- Confirm `camera.transform` is camera-to-world (C2W) row-major.

---

### Stage 1 — Frame quality selection (lightweight, no manual selection)
We **do not** want a manual selection process. However, we do apply **light filtering** to reject obviously bad frames.

**Reject frames if:**
- Missing metadata.
- `panorama.angularVelocityDegPerSec` is too high.
- Exposure duration is very long (blur risk).
- Depth is missing (optional; can keep RGB-only frames if necessary).

**Keep frames if:**
- Upright deviation is within tolerance.
- Angular velocity and exposure are stable.

**Outcome:** a filtered list of frames to run SHARP on.

---

### Stage 2 — SHARP inference (per frame)
**Actions**
- For each frame in the filtered list, run SHARP inference on `frames/rgb/<id>.jpg`.
- Output PLY per frame:
  ```
  3dgs/work/ply_per_frame/<frameIndex>.ply
  ```

**Notes**
- Keep each splat set in **camera coordinate space** (as produced by SHARP).
- Do not align/merge yet.

---

### Stage 3 — Transform splats into world space
**Actions**
- For each PLY, load per-frame camera transform `T_c2w` from metadata.
- Apply transform to each Gaussian center:
  ```
  X_world = T_c2w * X_camera
  ```
- Rotate covariance (or orientation) using `R_c2w` from transform.

**Key details**
- Respect coordinate conventions from `manifest.json`:
  - row-major matrices
  - camera_to_world
  - right-handed, Y-up

---

### Stage 4 — Depth-aware pruning (optional, recommended)
**Goal**
Remove splats that clearly disagree with depth.

**Method**
For each frame:
1) For each Gaussian center in world space, project it into the frame.
2) Compare its depth with the recorded depth map.
3) Remove splats that are much farther/closer than measured depth.

**Depth alignment uses:**
- Depth intrinsics (from metadata)
- Depth scale (from `depth.scaleFromRGB`)
- Depth in millimeters from PNG

---

### Stage 5 — Merge / de-duplicate
**Goal**
Combine all frame splats into one coherent splat set without excessive overlap.

**Strategy**
1) **Voxel-grid merge** in world coordinates.
2) For each voxel, cluster splats by similarity (position, covariance, color).
3) Keep best or blend:
   - Higher opacity
   - Smaller covariance
   - Lower depth error

**Outputs**
Single merged set of Gaussians.

---

### Stage 6 — Final alignment sanity check
**Goal**
Ensure the merged PLY renders correctly in the app viewer.

**Checks**
- Bounding box size looks reasonable (meters).
- Visual test in viewer (relocalized in AR).
- Optional reprojection test against depth.

---

## Suggested directory layout (inside `3dgs/`)
```
3dgs/
  scripts/
    run_sharp.py
    merge_splats.py
    prune_with_depth.py
  work/
    ply_per_frame/
    merged/
  config/
    defaults.yaml
```

---

## Merge details (practical heuristics)
- **Voxel size**: start with 2–5 cm.
- **Depth threshold**: 5–10 cm tolerance.
- **Opacity threshold**: drop very low opacity splats.
- **Covariance size**: drop overly large covariances.

---

## Notes on panorama capture
Because capture is panorama-style, most frames share a consistent origin.
Use `panorama.relativeYawDegrees` to track expected ordering and debug alignment.

---

## Future extensions
- Use RGB-only frames if depth missing.
- Add optional multi-view refinement (photometric loss).
- Use panoramic tile inference (if SHARP on panorama becomes viable).
