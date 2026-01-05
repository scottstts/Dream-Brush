# Next Step — Guide for “No Cloud Backend” On-Device Training (Option 1) vs Feed‑Forward Inference (Option 3)

This guide is intentionally code-agnostic and assumes only that you *can* capture RGB/poses/intrinsics/depth and render a splat on device after initial IOS app dev.

---

## A) Core difference to keep in mind (so you don’t mix goals)
- **Option 1 (On-device optimization):** You *solve* for the splat parameters for THIS user’s scan by minimizing error over many iterations. Quality can be excellent; compute is sustained.
- **Option 3 (Feed-forward inference):** You *predict* a splat quickly using a learned model (single image or few images), then optionally fuse/refine. Compute is bursty; results depend on the model’s prior.

In product terms:
- Option 1 is “processing time + battery” as your cost.
- Option 3 is “model complexity + training data + potential hallucination” as your cost.

---

## B) The “no-backend” reality check: you still pay—just not in dollars
If you refuse cloud GPUs, your costs become:
- **User time** (seconds → minutes)
- **Thermals** (device heat throttling)
- **Battery drain**
- **Memory pressure** (iOS jetsam risk)
- **Engineering complexity** (especially for Option 1)

Your product design must explicitly decide acceptable budgets for:
- max processing time per scan (e.g., 30s? 2 min? 10 min while charging?)
- max memory usage
- max storage size for captures + splats
- target device class (LiDAR-only? “any iPhone”?)

---

## C) Option 1 (On-device 3DGS optimization) — critical design choices

### 1) Initialization strategy (this determines whether it’s feasible at all)
**Do not start from random Gaussians.** Use depth to initialize:
- Back-project depth into 3D points (subsample to manage scale).
- Seed Gaussians at those points with:
  - initial scale tied to local depth uncertainty / neighborhood spacing
  - initial opacity low (to avoid early oversaturation)
  - initial color from RGB

Depth initialization reduces iterations dramatically compared to “photometric-only” optimization.

### 2) What you optimize (keep scope minimal first)
To make on-device optimization plausible, consider a staged approach:
- Stage 1 (fast): optimize only **color/opacity** with fixed positions (coarse but stable).
- Stage 2 (medium): allow **scale/rotation** updates.
- Stage 3 (expensive): allow **position** updates and any densification/splitting.

Avoid densification early; it can blow up memory for interiors.

### 3) How you schedule compute (UX matters)
You’ll likely need multiple “modes”:
- **Interactive mode:** quick, low-iteration, “preview-quality” output.
- **Background/charging mode:** higher-quality refinement when thermal headroom is better.
- **Room-by-room mode:** user scans a room, processes it, then moves on.

### 4) Scene partitioning (the single biggest lever for interiors)
Whole-house scenes are huge. Plan for tiling/chunking:
- Partition space into spatial tiles (e.g., 3–5m cubes) or per-room groups.
- Optimize and store tiles independently.
- Stream tiles into the renderer based on camera position.

This avoids “one giant splat that never fits in memory.”

### 5) Memory and storage budgets (define hard caps)
Define hard limits early:
- max Gaussians per tile
- max SH degree (appearance complexity)
- max texture/feature channels if you use latent features
- max input frame resolution and number of frames used per tile

If you don’t set caps, the project will collapse under scale.

### 6) Hardware utilization strategy (iPhone reality)
- The iterative rendering+gradient loop is naturally GPU/Metal compute work.
- The Neural Engine (NPU) is better for *feed-forward neural nets* than for custom differentiable splat optimization.
So for Option 1, assume:
- GPU does the heavy lifting
- NPU may help only for auxiliary tasks (depth denoising, segmentation, etc.)

### 7) Validation targets (so you can tell if it’s working)
Define a minimal “success metric” that you can measure on device:
- reprojection error / photometric loss on a held-out set of frames
- simple stability checks: does the model “swim” when moving viewpoint?
- tile seam visibility score (qualitative at first)

---

## D) Option 3 (Feed-forward image→3DGS inference) — critical design choices

### 1) Input modality (single image vs multi-view)
A single-image predictor can be fast, but for interiors:
- it may hallucinate geometry behind occlusions
- it may struggle with large planar surfaces (blank walls)

A practical compromise:
- run inference on multiple keyframes
- fuse outputs into a shared coordinate frame using poses (+ depth where available)

### 2) Fusion strategy (this is the hard part)
If you infer multiple local splats, you must merge them:
- align using ARKit poses
- deduplicate or blend overlapping Gaussians
- resolve conflicts in geometry/opacity

Depth helps enormously: it anchors predicted geometry to measured surfaces.

### 3) Refinement philosophy (keep it light)
Option 3’s main value is avoiding heavy optimization.
So your refinement should be:
- few iterations
- small parameter subset (mostly appearance, maybe scale)
- tile-based and bounded

### 4) Model packaging and runtime
If you want App Store viability:
- you’ll likely deploy inference via Core ML (or a Metal-based inference engine)
- you must plan for model size, memory spikes, and device compatibility tiers
- you must plan for model updates (in-app downloadable models vs baked-in)

### 5) Failure modes to plan UI for
Option 3 can look “confidently wrong.” Plan UX for:
- confidence estimation (even crude)
- fallback to “capture more frames” prompt
- allow user to accept a quick preview, then improve via Option 1-style refinement later

---

## E) A hybrid plan that often beats “pure Option 1” or “pure Option 3”
A very practical roadmap (if Part 1 works):
1) **Depth-seeded splat creation** (fast, deterministic) → gives a coarse 3D model quickly.
2) **Feed-forward inference** to propose better appearance/texture priors (optional).
3) **Small bounded optimization** to clean up artifacts (tiny Option 1, not full training).
4) **Compression + tiling** for long-term storage and real-time rendering.

This reduces the risk of a “thermal death spiral” while still improving quality over time.

---

## F) Stylization implications (because this is your end goal)
Regardless of Option 1 vs 3, decide where stylization lives:
- **Renderer-level post-process** (cheap, immediate, limited expressiveness)
- **Per-splat parameter transform** (still fast; more coherent than 2D patching)
- **Latent-feature + decoder** (most flexible; needs an on-device neural component)
- **Diffusion bake** (offline/charging mode; very expressive but expensive)

For a scalable app, the winning pattern is usually:
- fast style switching via per-splat appearance transforms or lightweight decoders
- optional “high quality stylize” mode that runs only when charging

---

## G) “Go / No-Go” questions to answer after Part 1
Before investing in Part 2, measure from Part 1 data:
- Typical scan size (GB) for a room and for a floor of a house
- Typical relocalization success rate (same day, next day, different lighting)
- Viewer FPS vs splat size
- Occlusion quality with LiDAR depth in your typical environment

Then choose Part 2 direction:
- If relocalization and rendering are solid but asset creation is slow/costly → prioritize Option 3/hybrid.
- If your capture data is clean (good depth + stable poses) → Option 1 becomes much more feasible (bounded, tile-based).

---

## H) Practical decision summary
- Choose **Option 1** if you want the most faithful reconstruction and can accept minutes of on-device processing (especially while charging) and you’re willing to build a Metal optimization pipeline.
- Choose **Option 3** if you want near-instant creation and can accept occasional plausible-but-wrong geometry, plus the complexity of training/maintaining a predictor model.
- Choose **Hybrid** if you want the best chance of shipping a consumer app without running a cloud GPU business.