# PLY Viewer Alignment (DreamBrush)

This note documents how the iOS viewer expects and renders Gaussian Splat PLY assets, and how that aligns with the training output produced by `training/train_3dgs.ipynb`.

## Summary
- The app does **not** reinterpret Gaussian parameters in Swift.
- PLY parsing and rendering are delegated to **MetalSplatter** (`SplatRenderer.readPLY`).
- The expected PLY schema matches standard 3DGS exports (position, normal, DC color, logit opacity, log-scale, quaternion).
- The training notebook exports PLY via `ns-export gaussian-splat`, which matches MetalSplatter's expected schema.

## Expected PLY Schema (as used by the app)
The app expects a standard 3DGS PLY with the following fields for each vertex (Gaussian):

```
x y z
nx ny nz
f_dc_0 f_dc_1 f_dc_2
opacity
scale_0 scale_1 scale_2
rot_0 rot_1 rot_2 rot_3
```

This is confirmed by the test assets in:
- `test_assets/test_splat.ply`
- `test_assets/sphere_test_asset.ply`

Those assets use:
- **log-scale** values (e.g., `scale_* = -1`)
- **logit opacity** (e.g., `opacity = 4.0`)
which is the standard 3DGS parameterization.

## How the App Renders PLY
Rendering is fully delegated to MetalSplatter:

- **Validation and import** use:
  - `SplatAssetManager.validateWithMetalSplatter(at:)`
  - `SplatRenderer.readPLY(from:)`

- **Runtime rendering** uses:
  - `ViewerARViewContainer.Coordinator` -> `SplatRenderer.readPLY(from:)`
  - `SplatRenderer.willRender` / `render` each frame

No custom decoding, scaling, or parameter conversion occurs in Swift.
The only PLY modification is removal of `obj_info` header lines (MetalSplatter's parser is strict).

Files:
- `DreamBrush/Services/SplatAssetManager.swift`
- `DreamBrush/Views/ViewerARViewContainer.swift`

## Alignment with Training Output
The training notebook exports with:

```
ns-export gaussian-splat --load-config <...> --output-dir <...>
```

`ns-export gaussian-splat` emits the standard 3DGS PLY schema used above.
Since the app uses MetalSplatter's PLY parser directly, the viewer and training output are aligned without additional conversion.

Notebook reference:
- `training/train_3dgs.ipynb`

## Potential Pitfalls (not in app code)
- Exporting a **non-standard PLY schema** (different property names or parameterization) can render incorrectly.
- If higher-order SH terms are exported (e.g., `f_rest_*`), MetalSplatter may ignore them; this affects color/lighting but not geometry.
- Extreme values in `scale_*` or `opacity` from training can still produce smear, but that is a training/export issue, not a viewer interpretation issue.

## Dependency
The app uses MetalSplatter via SwiftPM:
- `https://github.com/scier/MetalSplatter.git` (see `DreamBrush.xcodeproj/.../Package.resolved`)
