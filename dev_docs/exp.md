# Problem Description

I'm building out an idea. The initial idea is:

> have an app which opens the camera and lidar, you just walk through your room, basically full coverage of the room interior, and then you would have both the lidar data and the video itself, and maybe use AI image gen to turn specific imagery into a different style while preserving the depth info, and then you can patch the generated images back and rearranged based on where that patch of image belongs in the 3d structure, and rerender the original 3d structure, and now you can hold your phone and walk around, and it will show you exactly the part of the house you are pointing at but in a different style, like a real time re-render of your room

After some digging, i basically settle on this basic plan:

1. **Capture app:** RGB + intrinsics + poses + depth + keyframes + `ARWorldMap` + a chosen root anchor transform.
2. **Desktop training:** start with Nerfstudio **Splatfacto** (expect ~6GB VRAM default / ~12GB for big) or use the INRIA repo if you need paper-like setup (24GB VRAM for eval-quality).
3. **iOS viewer:** MetalSplatter rendering + ARWorldMap relocalization gating + anchor-based coordinate alignment.
4. **Stylization:** prefer 3DGS-native appearance transforms (StyleGaussian/ReGS-style), doing per-style updates rather than per-frame patching; reserve diffusion-driven edits (Morpheus-style) for offline/batch.

This way, the “walk around and it sticks to the real house” feeling comes from step 3’s anchoring/relocalization discipline, and the “it doesn’t flicker when I move” comes from step 4 being 3D-native rather than 2D patchwork.

I intend to do this, make it work, create a proof of concept. If this works, later I will consider swapping out desktop training process and replace it with basically two other options:

1. Option 1: Do real 3DGS optimization on-device
2. Option 2: Skip iterative optimization: use amortized / feed-forward splats (use a pretrained generative model that can generate 3DGS based on scan data, so basically the app only run inference on that model)

For now, I will stick to the manual route: iPhone app scan -> transfer scan to Mac -> do offline training on the scan to produce a 3DGS -> import the 3DGS back to iPhone app -> view the render in real time with relocalization based on the original scan metadata

Now i have built the iOS app following the dev_plan.md, you can also see the app_spec.md, I can record my room and export the scan data, I can also view a 3DGS render (using a testing PLY) as AR in app's viewer in real time.

Now is the hard part. I need to essentially turn the scanned data exported from the IOS app, and train the 3DGS. I'm not entirely clear how to do this. In addition, I'm not entirely clear how to get from "I have the 3DGS model and can render it in real time in the IOS app" to "I can turn my room into a goth style or futuristic style or xxx style in real time". So these are the two major questions I have at this point.

# Solution I Got

Yep — you’ve already made the two decisions that save you from 90% of the usual misery:

* **“Stick to the real house”** comes from *relocalization + anchor discipline* (your step 3). 
* **“Doesn’t flicker when I move”** comes from *3D-native appearance edits* (your step 4), not 2D per-frame patchwork.

So what’s left is mostly plumbing + a couple of “coordinate systems are lying to you” traps.

Below is a practical way to get from your **CaptureBundle → trained 3DGS → styled variants → iOS real-time switching**, with a bias toward the fastest path to a convincing POC.

---

## 1) CaptureBundle → a Nerfstudio-ready dataset (the missing bridge)

From your spec, you already export exactly what a trainer wants: RGB frames, per-frame intrinsics, per-frame **camera-to-world** transforms, depth, plus a root anchor and world map. 

The trainer (Nerfstudio Splatfacto) basically wants a folder like:

```
my_scene/
  images/
    000001.jpg
    000002.jpg
    ...
  transforms.json
  sparse_pc.ply          (highly recommended for splat init)
```

### Why `sparse_pc.ply` matters a lot

Nerfstudio’s Splatfacto works *way* better when initialized from geometry (SfM points / point cloud). If you don’t provide that, it may initialize gaussians randomly and results can be… temperamental. ([docs.nerf.studio][1])

The good news: you have **LiDAR depth**. That is absolutely good enough to build a sparse point cloud initializer.

---

## 2) Coordinate conventions: what must be true (or everything looks mirrored)

### Your exported conventions (good + explicit)

* Right-handed, **column-major** matrices in JSON
* **Camera-to-world** transform
* Up axis **+Y**
* Units **meters**


### Nerfstudio camera convention (critical)

Nerfstudio uses the OpenGL/Blender camera convention: **+X right, +Y up, +Z backward**, and the camera “looks” along **-Z**. ([docs.nerf.studio][2])

If your poses were in OpenCV convention (common in SLAM/SfM), you’d need a conversion (Y/Z flips) — this is a classic “everything is rotated/flipped” failure mode. ([GitHub][3])

**ARKit is *usually already* in a compatible “camera looks along -Z” style convention** (Apple describes +Z pointing toward the viewer/screen side in camera coordinates, which implies the viewing direction is -Z). ([Apple Developer][4])
So you *may* not need an OpenCV→OpenGL flip — but you *do* need to be fanatically consistent about:

* column-major vs row-major when you parse JSON
* whether your matrix is camera→world (it is) 

---

## 3) The simplest robust dataset conversion (recommended for your setup)

You have 3 spaces in your spec: **ARKit World**, **Capture Anchor Space**, **Splat Model Space**. 
For training + later AR alignment, you want your dataset poses to be expressed in **Capture Anchor Space**.

### 3.1 Convert poses into Capture Anchor Space

Let:

* `T_root_world` = root anchor transform stored in `anchors.json` 
* `T_cam_world[i]` = per-frame ARCamera.transform in your per-frame meta JSON 

Then:

**`T_cam_anchor[i] = inverse(T_root_world) * T_cam_world[i]`**

That makes the root anchor the origin for the whole scan — which is exactly what your viewer alignment math expects later. 

### 3.2 Write `transforms.json`

A Nerfstudio-style `transforms.json` needs intrinsics and a `transform_matrix` per frame.

You already store intrinsics as:

```json
"intrinsics": [
  [fx, 0, cx],
  [0, fy, cy],
  [0, 0, 1]
]
```

and `imageResolution` (w,h). 

So you populate `fl_x, fl_y, cx, cy, w, h` and for each frame:

* `file_path`: `images/000123.jpg`
* `transform_matrix`: the 4×4 `T_cam_anchor[i]`

**One big gotcha:** your matrices are serialized column-major. 
Most Python/numpy code assumes row-major in-memory. The safest approach is:

* treat the JSON as a literal 4×4 numeric table
* verify by applying it to a known basis point and sanity-checking camera forward/up.

If you get a mirrored scene, it’s *almost always* a convention flip like this. ([GitHub][3])

---

## 4) Build `sparse_pc.ply` from your depth maps (this is your secret weapon)

Your depth encoding is very workable:

* 16-bit PNG
* millimeters
* 0 = invalid


### 4.1 Depth-to-3D unprojection (per pixel)

At depth resolution `(Wd, Hd)` (you store width/height in meta), with depth `z` in **meters**:

```
X = (u - cx_d) / fx_d * z
Y = (v - cy_d) / fy_d * z
Z = z
```

You’ll need **intrinsics at the depth resolution**. If your intrinsics are for the RGB image (e.g., 1920×1440) and depth is 256×192, scale:

* `fx_d = fx * (Wd / Wrgb)`
* `fy_d = fy * (Hd / Hrgb)`
* `cx_d = cx * (Wd / Wrgb)`
* `cy_d = cy * (Hd / Hrgb)`

(ARKit’s scene depth is typically aligned to the camera, just lower-res — this scaling is the common fix.)

### 4.2 Transform points into Capture Anchor Space

You already have `T_cam_anchor[i]` for that frame.

For each depth sample point `p_cam`, compute:

`p_anchor = T_cam_anchor[i] * [p_cam, 1]`

### 4.3 Downsample aggressively

If you project every depth pixel from 600 frames, you’ll create a point tsunami.

Do something like:

* sample stride 2–6 pixels
* ignore `z == 0`
* clamp `z` to something sane (e.g. 0.2m–8m for indoor)
* voxel downsample (e.g. 1–3 cm voxels)

Then write a standard PLY (positions; colors optional).

### 4.4 Consistency warning

If the point cloud coordinate convention doesn’t match the pose convention, splat init can go sideways (misaligned points vs cameras). People run into this when mixing SfM/SLAM sources. ([GitHub][5])
In your case: since both poses + depth originate from the same ARKit frames, you’re in great shape as long as you keep the transforms consistent.

---

## 5) Training Splatfacto: what you can realistically run where

### CUDA reality check

Nerfstudio’s **Splatfacto training currently requires CUDA** in the usual setup. ([GitHub][6])
So:

* If your “Mac” is Apple Silicon only: you can preprocess on it, but training on it is not straightforward with stock Nerfstudio.
* You’ll want an **NVIDIA GPU box** for the training step (could still be “local”, not cloud).

There *are* experimental/alternative routes:

* a community MPS port of `gsplat` exists but is not “boring and reliable” yet ([GitHub][7])
* OpenSplat has a Metal/Apple GPU build path (different toolchain than Nerfstudio) ([DeepWiki][8])

### Canonical Nerfstudio flow once dataset is ready

Train:

* `ns-train splatfacto --data /path/to/my_scene`

Export to PLY:

* `ns-export gaussian-splat --load-config <outputs/.../config.yml> --output-dir exports/splat`
  ([docs.nerf.studio][1])

---

## 6) Getting alignment right in the iOS viewer

Your own plan already states the correct composition:

* Offline: produce **Splat Model Space → Capture Anchor Space** transform
* Runtime: get **Capture Anchor Space → Current ARKit World Space** from the relocalized root anchor
* Compose for rendering


In the “best case” pipeline (training directly in anchor space with no extra normalization), your **model→anchor** can be identity.

In practice, many trainers/dataparsers apply some centering/scaling internally. Nerfstudio dataparsers explicitly talk about “applied transforms” and scaling being part of the pipeline. ([docs.nerf.studio][9])
So the robust approach is:

* During export, also write an `alignment.json` (or include in your SplatPackage) containing:

  * `model_to_anchor_4x4`
  * optional `scale`

Then your app does exactly what your dev plan says it must do. 

---

# Part 2: “Make it goth/futuristic in real time” without flicker

There are two different meanings of “real time” here:

1. **Real-time rendering** (60fps AR view): you already have this with MetalSplatter. 
2. **Real-time *generation* of a new style** (type a prompt, instantly restyle): this is still bleeding-edge and heavy, especially on-device.

So for a strong POC, the winning move is:

### “Real-time style switching” (POC-friendly)

Precompute one or more **stylized variants** offline, then swap them instantly on-device.

That gives users the *feeling* of “I’m walking around in a different world” with zero flicker, and no on-device ML headache.

---

## 7) Stylization ladder (from easiest to spiciest)

### Level 0 — shader color grading (you already planned this)

This is your Part 1 “style presets” (contrast/saturation/gamma, etc.). 
It can sell “noir/goth-ish” surprisingly well, but it won’t invent new textures/materials.

### Level 1 — 3DGS appearance-only variants (best next step)

You keep geometry fixed, and create **one PLY per style** that differs mainly in color/SH (spherical harmonics) coefficients.

This is exactly the “3D-native, no flicker” approach you described.

Two research directions you can borrow from:

* **StyleGaussian**: embeds 2D VGG features into the Gaussians, transforms features to match a style image, decodes to stylized RGB, designed to preserve multi-view consistency and real-time rendering (they report ~10fps stylization pipeline). ([arXiv][10])
* **ReGS**: “reference-based controllable scene stylization” for 3DGS, aiming at real-time stylized view synthesis by editing appearance with depth regularization to preserve geometry. ([arXiv][11])

**How this becomes an iOS feature:**

* Desktop outputs: `base.ply`, `goth.ply`, `futuristic.ply`
* iOS: load whichever PLY the user selects, fade between them

No per-frame patching. No flicker. It just “sticks.”

### Level 2 — text-driven edits via 2D diffusion + re-optimization (offline, heavier)

This is the family you already flagged as “batch/offline”:

* **GaussCtrl**: render multiple views, edit using diffusion (ControlNet) from a text prompt, then optimize the 3DGS for multi-view consistency. ([arXiv][12])
* **Morpheus**: text-driven stylization that can change *shape and color*, using an RGBD diffusion model with explicit strength controls, and then trains a stylized 3DGS from the stylized frames. ([CVF Open Access][13])

These are awesome, but they’re not “tap-to-goth at 60fps on iPhone” yet. They *are* “create a goth version in 5–30 minutes on a GPU, then ship it back to the phone.”

---

## 8) A concrete POC plan that gets you to “walk around my goth room”

This is the shortest path that still respects your anchoring/relocalization discipline:

### Step A — Convert CaptureBundle → `my_scene/` dataset

* Use keyframes (50 is okay to start; 150–300 is often nicer)
* Create `transforms.json` from your poses **in Capture Anchor Space** 
* Create `sparse_pc.ply` from depth (downsample it hard)

### Step B — Train base 3DGS (Splatfacto)

* Train on CUDA machine (stock Nerfstudio) ([GitHub][6])
* Export PLY ([docs.nerf.studio][1])
* Save `model_to_anchor` alignment alongside it (even if identity)

### Step C — Make 2–3 stylized variants offline

Pick one method depending on ambition:

* **Simple + surprisingly effective:** optimize only the per-Gaussian color/SH to match a reference style image loss (classic neural style transfer loss, but applied through renders of the splat).
* **More “paper-like”:** run a StyleGaussian/ReGS pipeline to produce a new PLY. ([arXiv][10])

### Step D — iOS “real-time” style switching

* Import `base.ply`, `goth.ply`, `futuristic.ply`
* Ensure each uses the same model space + same `model_to_anchor`
* Swap instantly, optionally crossfade

This gets you the magic trick: *the same physical wall, but with a different reality shader.*

---

## 9) Common failure modes (so you don’t spend a week arguing with matrices)

1. **Scene mirrored / inside-out**
   Almost always OpenCV vs OpenGL convention, or a transpose/column-major bug. ([docs.nerf.studio][2])

2. **Splat floats away from the real room in AR**
   That’s an alignment transform bookkeeping problem — exactly why your spec calls out *Splat Model Space → Capture Anchor Space* as an explicit artifact. 

3. **Training converges poorly / blobby mess**
   You didn’t initialize from geometry. Splatfacto is explicit about this. ([docs.nerf.studio][1])
   Your fix is `sparse_pc.ply` from depth.

4. **Apple Silicon training disappointment**
   Splatfacto + gsplat is CUDA-first right now. ([GitHub][6])
   (Workarounds exist, but they’re hacky today. ([GitHub][7]))

---

## Where the idea can evolve (without committing science fiction sins)

Once you have the offline loop working, *then* you can explore:

* **On-device 3DGS optimization** (hard because training is heavy + memory bandwidth hungry)
* **Amortized splats** (feed-forward prediction of splat params)
  This is plausible long-term, but you’ll want the boring pipeline first so you can measure quality/latency objectively.

---

If you keep the next milestone brutally concrete, I’d make it this:

**“Given one CaptureBundle zip, I can run one command that outputs:**

1. `base.ply` + `alignment.json`
2. `goth.ply` + `futuristic.ply` (same alignment)
   **and then my iOS app can import and instantly switch styles while staying anchored.”**

That’s a demo people immediately understand — and it forces all the right engineering discipline (dataset conversion, init geometry, alignment artifact, style variants).

[1]: https://docs.nerf.studio/nerfology/methods/splat.html?utm_source=chatgpt.com "Splatfacto - nerfstudio"
[2]: https://docs.nerf.studio/quickstart/data_conventions.html?utm_source=chatgpt.com "Data conventions - nerfstudio"
[3]: https://github.com/nerfstudio-project/nerfstudio/discussions/3252 "Transformations applied to the transforms.json file · nerfstudio-project nerfstudio · Discussion #3252 · GitHub"
[4]: https://developer.apple.com/documentation/arkit/arcamera/transform?utm_source=chatgpt.com "transform | Apple Developer Documentation"
[5]: https://github.com/nerfstudio-project/nerfstudio/issues/2876?utm_source=chatgpt.com "Splatfacto a pointcloud for initialization not from COLMAP"
[6]: https://github.com/nerfstudio-project/nerfstudio/issues/3290?utm_source=chatgpt.com "ns-train splatfacto fails to run on Apple Silicon, nerfacto works ok ..."
[7]: https://github.com/iffyloop/gsplat-mps?utm_source=chatgpt.com "GitHub - iffyloop/gsplat-mps: Metal/MPS (M1/Apple Silicon) accelerated ..."
[8]: https://deepwiki.com/pierotofy/OpenSplat/2.4-metalapple-gpu-build?utm_source=chatgpt.com "Metal/Apple GPU Build | pierotofy/OpenSplat | DeepWiki"
[9]: https://docs.nerf.studio/reference/api/data/dataparsers.html?utm_source=chatgpt.com "Data Parsers - nerfstudio"
[10]: https://arxiv.org/abs/2403.07807 "[2403.07807] StyleGaussian: Instant 3D Style Transfer with Gaussian Splatting"
[11]: https://arxiv.org/abs/2407.07220?utm_source=chatgpt.com "Reference-based Controllable Scene Stylization with Gaussian Splatting"
[12]: https://arxiv.org/abs/2403.08733?utm_source=chatgpt.com "GaussCtrl: Multi-View Consistent Text-Driven 3D Gaussian Splatting Editing"
[13]: https://openaccess.thecvf.com/content/CVPR2025/papers/Wynn_Morpheus_Text-Driven_3D_Gaussian_Splat_Shape_and_Color_Stylization_CVPR_2025_paper.pdf "Morpheus: Text-Driven 3D Gaussian Splat Shape and Color Stylization"