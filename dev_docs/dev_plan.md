# What We Are Building

We’re building a native iOS proof-of-concept app that lets you scan an interior space using ARKit (camera + LiDAR depth when available), record a structured “capture bundle” containing RGB frames, per-frame camera intrinsics and poses, depth maps, and ARKit relocalization artifacts (ARWorldMap + a stable root anchor), then export that bundle to a Mac for offline 3D Gaussian Splat training. The app also supports importing a pre-trained 3DGS asset back onto the device (via standard file transfer), and viewing it in AR using MetalSplatter with strict relocalization gating and coordinate alignment so the splats only render when the phone is correctly relocalized to the original scan location (preventing location mismatch/drift). Finally, the viewer includes simple, fast appearance-only “style” controls (basic color/tonemapping presets) to validate the end-to-end loop before attempting any on-device training or advanced stylization.

# Dev Plan — iOS “Capture → Export → Import → Relocalized Viewer → Simple Style” Dev Plan (Swift / Native)

## 0) Product goal, constraints, and definitions (lock these first)
**Goal:** A proof‑of‑concept iOS app that:
- Captures an interior scan session using iPhone camera + LiDAR (when available).
- Records enough data for offline 3D Gaussian Splat (3DGS) reconstruction.
- Exports the full capture bundle to a Mac via standard file transfer (Files / AirDrop / Finder).
- Imports a pre-trained 3DGS asset back onto the device (manual transfer is fine).
- Renders the 3DGS in AR with correct relocalization/alignment to the physical space.
- Provides simple “style” controls (appearance-only, lightweight; no heavy ML needed for Part 1).

**Non-goals for Part 1:**
- On-device 3DGS training (that’s Part 2).
- Cloud/GPU backend services.
- Complex diffusion stylization.
- Multi-user shared AR persistence.

**Key definitions:**
- **Capture Bundle** = everything recorded during scanning (RGB frames + per-frame metadata + depth + ARKit map + anchors).
- **Splat Asset** = a 3DGS file or package ready for rendering (e.g., PLY, SPZ, or your own internal format).
- **Session Coordinate Frames:**
  - ARKit World (runtime coordinate space)
  - Capture Anchor Space (your chosen stable origin at scan time)
  - Splat Model Space (the coordinate space your training produces)
  - Viewer Alignment Transform(s) linking these at render time

**Milestone (verifiable):**
- A one-page “App Spec” document exists with the above goal/non-goals and a chosen Capture Bundle format and naming convention.

---

## 1) Project setup + device requirements + dependencies
**Create an Xcode project** (Swift, iOS target consistent with ARKit features you need).
**Choose UI stack**: SwiftUI + UIViewRepresentable for AR view, or UIKit. Either is acceptable; keep it simple.
**Apple frameworks/APIs to use (Part 1):**
- `ARKit` (core tracking, frames, depth, world map)
- `RealityKit` *or* `SceneKit` (optional, but helpful for debug visualization; not required for splat rendering)
- `Metal` + `MetalKit` (for MetalSplatter rendering)
- `AVFoundation` (camera/image formats/utilities; optional if ARKit frames suffice)
- `UniformTypeIdentifiers` (custom file types / import-export)
- `Compression` (optional: compress/decompress bundles)
- `OSLog` (structured logging)
- `Photos`/`PhotoKit` only if you decide to write to Photos; otherwise avoid

**Third-party dependency:**
- Integrate **MetalSplatter** (prefer via Swift Package Manager) and validate you can render a small known splat file in a non-AR test screen first.

**Permissions / entitlements:**
- Camera usage description (`NSCameraUsageDescription`)
- If you write to Files, you generally don’t need special permission, but you must implement proper document pickers/sharing.

**Milestone (verifiable):**
- App launches on a LiDAR-capable device (or simulator with camera mocked) and shows:
  - A “Capture” tab/button
  - A “Viewer” tab/button
  - A “Files”/“Library” screen listing saved bundles/assets (empty is fine)

---

## 2) Define the Capture Bundle format (this is the backbone)
Design a deterministic on-disk format for a scan session. Recommended structure:

**CaptureBundle/**
- `manifest.json` (global info: app version, iOS version, device model, capture settings, coordinate conventions)
- `worldmap.arexperience` (or your chosen extension) — serialized `ARWorldMap` bytes
- `anchors.json` (at minimum: a “root anchor” transform; optionally additional anchors)
- `keyframes/` (small set of selected key RGB frames + metadata pointers)
- `frames/`
  - `rgb/` (e.g., `000001.heic` or `.jpg`)
  - `depth/` (e.g., `000001.exr` or `.png` with a defined encoding)
  - `meta/` (e.g., `000001.json` per frame, or a single `frames.jsonl`)
- Optional: `mesh/` (if you store ARMeshAnchors for debugging/occlusion experiments)
- Optional: `thumb.jpg` (for UI listing)

**Per-frame metadata to store:**
- Timestamp
- Camera intrinsics (matrix + image resolution used)
- Camera pose/extrinsics (ARKit `ARCamera.transform`)
- Tracking state + mapping status snapshot (for debugging)
- Depth availability flag + depth confidence summary if available
- Exposure/ISO/white balance if you can access it (optional but useful later)

**Coordinate conventions (must be explicit):**
- Handedness (ARKit is right-handed)
- Matrix layout (column-major vs row-major when serialized)
- Whether transforms map camera→world or world→camera

**Milestone (verifiable):**
- The app can create a new CaptureBundle folder on device storage and write a valid `manifest.json` (validated by re-opening and parsing it within the app).

---

## 3) Build Capture Mode (ARSession configuration + live preview + record controls)
**Core components:**
- `ARSession` + `ARWorldTrackingConfiguration`
- Enable scene depth where available (`frameSemantics` including `sceneDepth` / `smoothedSceneDepth` depending on device support)
- Optionally enable mesh reconstruction (`sceneReconstruction`) for debugging and potential occlusion experiments

**UI requirements:**
- Live camera preview
- Start/stop recording controls
- A visible mapping quality indicator (based on `worldMappingStatus`)
- Real-time counters: frames recorded, estimated storage size, depth availability rate

**Sampling strategy (important for storage + training):**
- Record at a controlled cadence (e.g., N FPS or based on motion threshold) rather than every frame.
- Keyframe selection logic:
  - Save a “keyframe” when camera moved enough (translation/rotation thresholds) and tracking quality is good.
  - Keep a bounded number of keyframes (e.g., 50–300) for a room-scale scan.

**Data writing:**
- Write RGB + metadata incrementally (stream to disk); do not hold everything in memory.
- Depth: store either raw depth map or a compressed representation; define encoding precisely.

**Milestone (verifiable):**
- You can record a 30–60 second scan and the app produces a CaptureBundle that:
  - Contains at least 200 RGB frames (or your chosen target)
  - Contains matching metadata entries for each recorded frame
  - Contains depth files for frames where depth is available
  - Can be re-opened in-app to display a timeline/thumbnail scrubber

---

## 4) Persist relocalization data: ARWorldMap + stable root anchor
**During capture:**
- Monitor `ARFrame.worldMappingStatus` and only allow “Finalize Scan” once status is sufficiently good (e.g., `.mapped`).
- Define a **root anchor**:
  - Either the first stable camera pose after mapping is good
  - Or a user-placed anchor (tap-to-place on a detected plane)
- Serialize:
  - `ARWorldMap` via `ARSession.getCurrentWorldMap`
  - Root anchor transform
  - A list of selected “visual keyframes” (for future fallback alignment or debugging)

**Quality checks:**
- Store a small “relocalization checklist” summary:
  - % of frames with good tracking
  - mapping status reached?
  - average depth confidence?

**Milestone (verifiable):**
- A saved CaptureBundle can be “Relocalization Tested”:
  - Start a new ARSession, load the saved world map into configuration,
  - Walk back to the same room,
  - Confirm that ARKit reports relocalization success (tracking becomes stable),
  - And the app marks the bundle as “Relocalizable: Yes” in its UI.

---

## 5) Export Capture Bundle to Mac (no fancy infra, just files)
Implement at least one robust export path:
- Export via the Files app using `UIDocumentPickerViewController` (folder export or zip export)
- Share via `UIActivityViewController` (AirDrop, etc.)
- Optional: iTunes/Finder file sharing for developer convenience

Export format recommendation:
- Zip the entire CaptureBundle directory into a single archive with a deterministic name.

**Milestone (verifiable):**
- You can export a CaptureBundle to a Mac, unzip it, and verify:
  - `manifest.json` exists
  - A sample RGB frame opens on Mac
  - A frame metadata file exists and includes intrinsics + pose

---

## 6) Import 3DGS “Splat Assets” back into the app + asset management
**Supported asset types (choose upfront for Part 1):**
- At least one known format that MetalSplatter can load (commonly PLY or SPZ, depending on your chosen pipeline).
- Optionally define a custom “SplatPackage” folder that includes:
  - splat file
  - bounding box / stats
  - a pointer to the CaptureBundle it belongs to (so viewer knows which world map to use)

**iOS import UX:**
- Use `UIDocumentPickerViewController` for importing files from Files/AirDrop.
- Store imported assets inside the app sandbox (Application Support).
- Implement a simple “Asset Library” screen:
  - list splat assets
  - show stats (file size, gaussian count if available, preview thumbnail)
  - link each asset to its originating CaptureBundle (manual selection is okay for POC)

**Milestone (verifiable):**
- You can import a splat asset from Files and it appears in the in-app Asset Library with correct file size and a basic “load test” button that validates parsing succeeds.

---

## 7) Viewer Mode: relocalization gating + mismatch detection + alignment transforms
**Core requirement:**
Render only when the app can confidently align the current AR session with the capture session.

**Viewer startup flow:**
1. User selects a Splat Asset.
2. App looks up the associated CaptureBundle and loads:
   - the saved `ARWorldMap`
   - the root anchor transform
3. Start an `ARSession` configured with that world map.
4. Gate rendering:
   - Before relocalization: show “Move to scanned area” overlay + quality indicator.
   - After relocalization: fade in splat rendering.

**Mismatch detection signals:**
- ARKit tracking state is limited or mapping status never reaches a stable state.
- Camera pose uncertainty appears high (rapid drift).
- Optional heuristic: compare live camera features against stored keyframes (even just for a “confidence score” display).

**Alignment math (must be defined and implemented):**
- You need a transform that maps Splat Model Space → Capture Anchor Space (produced during offline training/export).
- Then at runtime you need Capture Anchor Space → Current ARKit World Space (from relocalized root anchor).
- Compose them to render splats correctly in the live AR view.

**Milestone (verifiable):**
- In the original scanned room: the splat appears anchored and stable.
- In a different room: the app refuses to render and shows a clear “Not relocalized / mismatch” state.
- If relocalization succeeds after walking back: rendering automatically activates.

---

## 8) Real-time rendering integration with MetalSplatter (AR compositing)
**Rendering pipeline requirements:**
- Use `MetalKit` view (or equivalent) to render splats each frame.
- Feed the renderer:
  - current camera view matrix and projection matrix (from `ARFrame.camera`)
  - camera intrinsics-based projection matching the capture resolution policy
- Composite over the camera feed (AR background):
  - Use ARKit-provided background rendering, or render camera image yourself, but keep it simple.

**Occlusion (optional but high impact):**
- Use ARKit depth (scene depth) as an occlusion mask:
  - If real-world depth is closer than splat depth → occlude splat pixels.
- Add a UI toggle: Occlusion ON/OFF for debugging.

**Performance controls:**
- Add quality presets:
  - target FPS (30/60)
  - maximum splats drawn
  - LOD or downsample factor if supported
- Add instrumentation: frame time, memory usage, thermal state indicator.

**Milestone (verifiable):**
- Viewer runs at a stable target FPS for a room-scale splat on your device.
- Occlusion toggle demonstrably changes compositing in a correct direction (e.g., real objects in front hide splats).

---

## 9) Simple “style controls” (appearance-only, POC-level)
For Part 1, keep it intentionally dumb-but-visible:
- Global color controls:
  - exposure/brightness
  - contrast
  - saturation
  - hue shift
  - gamma
- Style presets as named configurations (“Warm”, “Cool”, “Noir”, “Pastel”) that adjust the above.

Implementation notes:
- Prefer implementing style as a post-process in the splat shader/render path (fast, deterministic).
- Ensure style changes do not affect alignment (no geometry changes).

**Milestone (verifiable):**
- User can toggle between at least 4 style presets in Viewer Mode.
- Style changes are immediate and do not change pose/anchor stability.

---

## 10) Reliability, edge cases, and test checklist
**Must-handle runtime events:**
- App background/foreground transitions (ARSession interruptions)
- Device rotation changes
- Storage low conditions (warn + stop recording safely)
- Depth not available on some devices (graceful fallback to RGB-only capture)

**Testing matrix:**
- Small scan (1 minute), medium scan (3–5 minutes)
- Good lighting vs dim lighting
- Feature-rich room vs blank walls
- Relocalization success vs failure scenarios

**Milestone (verifiable):**
- A written test runbook exists and you can complete it without crashes:
  - capture → export → import splat → relocalize → render → style toggle → exit/re-enter app

---

## 11) Deliverables summary (what “done” means for Part 1)
- Capture mode records bundles with RGB+poses+intrinsics(+depth) and a saved ARWorldMap + root anchor.
- Export produces a single transferable archive per capture.
- Import accepts a splat asset and links it to a capture bundle.
- Viewer uses relocalization gating; renders only when aligned.
- Viewer provides basic style controls.
- Debug overlay + logs exist for diagnosing drift, mapping quality, and performance.

**Final Milestone (verifiable):**
- End-to-end demo on a real device:
  1) Scan a room (1–2 minutes)
  2) Export bundle to Mac
  3) Train splat offline by any means
  4) Import splat into phone
  5) Walk back to room, relocalize, and see stable AR splat with style toggles