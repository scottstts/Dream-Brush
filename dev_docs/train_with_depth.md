## What Nerfstudio already supports (the good news)

### 1) The *data format* already has a depth hook

Nerfstudio’s dataset convention supports a per-frame `depth_file_path` inside `transforms.json` frames. ([DeepWiki][1])

Your capture bundle already exports depth maps as **16-bit PNGs in millimeters** (`UInt16`, mm). 
So you’re sitting on the right kind of depth supervision signal.

### 2) The Nerfstudio dataparser already parses depth filenames + unit scale

`NerfstudioDataParser` collects `depth_filenames` into the dataparser outputs metadata and carries a `depth_unit_scale_factor` specifically for scaling depth units. ([Nerf Studio][2])

So: adding `depth_file_path` to `transforms.json` is *recognized* at the parsing layer.

---

## What’s missing (why it’s not “just a flag”)

### Splatfacto doesn’t currently consume phone-scanner depth as supervision

The Splatfacto docs explicitly note that using other data inputs like phone depth may be supported in the future — i.e., it’s not a first-class training feature today. ([Nerf Studio][3])

And community discussion around Splatfacto depth outputs repeatedly points out: **depth is viewable, but not depth-supervised**, which is why “floaters” and messy geometry happen in textureless indoor scenes. ([GitHub][4])

### The default `InputDataset` path doesn’t automatically feed depth into batches

Even though the dataparser knows about depth filenames, you still need a dataset/datamanager path that *loads depth per image and hands it to the model loss*. The canonical Nerfstudio way to do that is: **DataparserOutputs metadata → Dataset.get_metadata() → Datamanager batch → Model loss**. Nerfstudio maintainers describe this extension path directly. ([GitHub][5])

A concrete example exists in Nerfstudio’s `SDFDataset`, which overrides `get_metadata()` to return per-image extras (depth/SDF/whatever) for training. ([GitHub][6])

---

## Feasibility verdict

**Feasible:** yes.
**Effort:** medium (you’ll be writing a small Nerfstudio “method” fork/plugin: custom Dataset + custom Model loss; possibly a custom DataManager depending on how you want to sample).
**Risk:** the annoying parts are *depth definition + scaling + masking* (not the mechanics).

If you’re comfortable editing Nerfstudio source, this is a clean, standard extension.

---

## The most practical implementation path (with your exact setup)

### Step A — Export depth into the Nerfstudio dataset + reference it in transforms

Right now you build `transforms.json` frames like:

```py
frames.append({
  "file_path": f"images/{frame_id:06d}.jpg",
  "transform_matrix": ...
})
```



To enable depth supervision, you’d also:

1. Copy depth PNGs into e.g. `dataset_dir/depth/000001.png`
2. Add:

```json
"depth_file_path": "depth/000001.png"
```

per frame (only when available).

This matches Nerfstudio conventions. ([DeepWiki][1])

**Strong recommendation:** also export a *per-pixel confidence mask* (ARKit has it), because your current bundle only stores a *summary* (`high/med/low` fractions), not the per-pixel map. 
Depth supervision without masking tends to “bake in” LiDAR speckle.

---

### Step B — Add a Dataset that loads depth and returns it in metadata

Mirror the `SDFDataset` pattern: load the depth image for the given `image_idx` and return it in `get_metadata()` so it reaches the model. ([GitHub][6])

Key points:

* Your depth PNG is mm → convert to meters (×0.001) 
* Also multiply by whatever Nerfstudio `dataparser_scale` ends up using (because camera translations get scaled; your depth loss must live in the same coordinate scale).
* Mask invalid depth (0, out of range, low confidence).

---

### Step C — Add a depth loss term to Splatfacto

Splatfacto already renders a “depth-like” output channel (people inspect it for debugging), but it’s not supervised. ([GitHub][4])
So you extend the model (or wrap it) and in `get_loss_dict(...)` add something like:

* `L_depth = robust_L1(pred_depth, gt_depth)` on valid pixels
* Weight it: start small (e.g. 0.01–0.1 relative to RGB loss), ramp up after a few thousand steps.

**Important subtlety:** “depth” can mean:

* **range along ray** (what many sensors provide)
* **z-depth in camera coordinates** (what rasterizers often output)

Gaussian splatting implementations often talk about a z-depth pass / expected depth; mismatches here can create systematic bias. ([Journal of Machine Learning Research][7])
If your ARKit depth is ray-distance but your predicted depth is z-depth, convert GT accordingly (using ray direction cosines) *or* supervise inverse depth / normalized depth to be less sensitive.

---

## The “cheat code” option: use an existing depth-supervised splatting fork

If you want the fastest path to “does depth supervision help my data?” without building the whole extension first, look at **DN-Splatter**, which is explicitly about *depth/normal priors for 3D Gaussian Splatting* and is built in this ecosystem.
Even if you don’t adopt it wholesale, it’s a great reference for:

* what depth loss they use
* how they mask/filter depth
* how they keep it stable with splat densification

---

## Reality check: will depth supervision “drastically” improve your room scans?

For indoor AR captures with weak texture, yes — depth supervision is one of the biggest levers for:

* planar stability (walls stop “breathing”)
* fewer floaters
* less scale drift

…but only if you get these right:

1. correct unit/scale alignment (watch for “10× depth mismatch” type problems)
2. confidence masking + range clipping
3. depth definition match (ray vs z)


[1]: https://deepwiki.com/nerfstudio-project/nerfstudio/5.2-data-formats-and-parsers?utm_source=chatgpt.com "Data Management | nerfstudio-project/nerfstudio | DeepWiki"
[2]: https://docs.nerf.studio/_modules/nerfstudio/data/dataparsers/nerfstudio_dataparser.html "nerfstudio.data.dataparsers.nerfstudio_dataparser - nerfstudio"
[3]: https://docs.nerf.studio/nerfology/methods/splat.html?utm_source=chatgpt.com "Splatfacto - nerfstudio"
[4]: https://github.com/nerfstudio-project/nerfstudio/issues/3622?utm_source=chatgpt.com "What is the unit of rendered depth from splatfacto?! #3622"
[5]: https://github.com/nerfstudio-project/nerfstudio/issues/751?utm_source=chatgpt.com "Add depth supervision for better results · Issue #751 · nerfstudio ..."
[6]: https://github.com/nerfstudio-project/nerfstudio/blob/main/nerfstudio/data/datamanagers/full_images_datamanager.py "nerfstudio/nerfstudio/data/datamanagers/full_images_datamanager.py at main · nerfstudio-project/nerfstudio · GitHub"
[7]: https://jmlr.org/papers/volume26/24-1476/24-1476.pdf?utm_source=chatgpt.com "gsplat: An Open-Source Library for Gaussian Splatting"