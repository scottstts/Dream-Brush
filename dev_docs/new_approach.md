
## New Approach: Panorama-Style Capture + SHARP Inference

## Why we are changing direction
The previous pipeline captured a large bundle and trained 3DGS from scratch. That approach is computationally heavy and yields unpredictable quality. We are pivoting to a simpler, faster pipeline that uses **image-to-splats inference** (Apple SHARP) and relies on **strong pose alignment at capture time** to merge results into a navigable scene.

This doc defines the philosophy, capture ethos, and end-to-end approach. It is the backbone for the upcoming code overhaul.

---

## Core idea (one sentence)
**Capture a panorama-style sweep (upright-only), run SHARP per frame, then align and fuse splats using ARKit poses + depth metadata.**

---

## Guiding ethos
- **Panorama UX, not slot-based capture.** One manual first frame, then auto-capture as the user pans.
- **Upright-only enforcement.** We do not gate on translation; only uprightness + tracking quality.
- **Metadata-rich, inference-light.** Capture sufficient poses + depth per frame; run SHARP per frame.
- **Avoid heavy compute in the loop.** No COLMAP, no full 3DGS training. SHARP inference only.

---

## Capture philosophy (panorama-style, upright-only)
We treat capture like a panorama photo:
- User taps **Capture First Wall** once the phone is upright.
- The app automatically captures a new frame whenever the view moves far enough
  (yaw-based step derived from camera FOV + overlap).
- Capture continues until ~360° coverage is reached.

**Gating rules (strict, but minimal):**
- Must be upright in portrait.
- Tracking must be normal.
- Exposure must be stable (avoid motion blur).

---

## Lens strategy
**Wide lens**
- Wide lens reduces distortion and alignment error.
- Exposure/ISO is stabilized via capture gating (ARKit does not allow hard locks).

---

## Depth usage
Depth is **captured for every frame when available** and used for alignment:
- **Scale anchoring**: match SHARP scale to real-world meters.
- **Pruning**: remove splats far from measured depth surfaces.
- **Pose/scale validation** during merge.

---

## Virtual world coordinate system (the backbone)
At capture start, establish a **capture origin** (ARKit world anchor).
All poses and splats are mapped into this coordinate system.

We know:
- Where the capture origin is.
- The pose of each capture (position + orientation).
- Optional real-world distances (from depth or known offsets).

This forms a **rough 3D scaffold** of the room into which all splats are placed.

---

## Alignment pipeline (lightweight)
For each frame:
1. **Run SHARP** on the image to produce a splat PLY (camera frame).
2. **Transform splats into world space** using the ARKit pose.
3. **Scale correction** (if needed) using depth and intrinsics.
4. **Fuse splats** with minimal heuristics:
   - Voxel-grid merge.
   - Keep highest-confidence splats per voxel.
   - Prune low-opacity or extreme-covariance splats.

This avoids training, avoids heavy optimization, and remains fast.

---

## Extensibility by design
We explicitly design the capture schema for growth:
- Capture is **panorama-like**, not fixed slots.
- Frame step size is derived from **FOV + overlap** and can be tuned.
- Metadata includes per-frame **panorama info** for alignment and QA.

---

## System architecture (end-to-end)
1. **iOS capture app**: guided capture + metadata.
2. **Mac inference node**: run SHARP per image.
3. **Alignment + fusion**: apply poses, scale, and merge.
4. **Stream back to iOS**: render splats for navigation.

This is a local, lightweight workflow, not a backend service.

---

## Non-goals (for now)
- On-device SHARP inference.
- Full 3DGS training or long optimization loops.
- COLMAP or heavy SfM.
- Perfect photorealism; the goal is **usable navigable scenes**, not perfect scans.

---

## Known risks and mitigations
- **Pose drift**: require good tracking state and upright-only capture.
- **Motion blur**: gate capture on angular velocity + exposure stability.
- **Low overlap**: derive step size from FOV + overlap settings.
- **Scale mismatch**: use depth + intrinsics per frame.

---

## What this means for the codebase
We are rebuilding capture assumptions around:
- **Panorama-style auto capture**
- **Upright-only gating**
- **Metadata-rich frames for alignment**

We will reuse existing AR session scaffolding where it makes sense, but the old training-oriented capture/export logic is no longer the center of the product.

---

## Immediate next steps
- Ensure capture output matches the new export spec.
- Tune capture overlap/step size for usable inference counts.
- Implement SHARP inference + splat fusion pipeline.
