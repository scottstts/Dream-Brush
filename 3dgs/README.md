# 3DGS Pipeline for DreamBrush

This directory contains the offline pipeline for converting panorama-style capture bundles into 3D Gaussian Splat (3DGS) assets.

## Overview

The pipeline takes a `CaptureBundle` exported from the iOS app and produces a single merged PLY file that can be imported back into the app for viewing.

```
CaptureBundle (iOS export)
    │
    ▼
┌─────────────────────────────────────┐
│  Stage 1: SHARP Inference           │
│  (per-frame PLY in camera space)    │
│  conda env: sharp                   │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│  Stage 2: Merge & Align             │
│  - Transform to world space         │
│  - Depth-aware pruning              │
│  - Voxel-grid deduplication         │
│  conda env: ml                      │
└─────────────────────────────────────┘
    │
    ▼
Merged PLY (world space, MetalSplatter-compatible)
```

## Prerequisites

### Conda Environments

1. **sharp** - For SHARP inference
   ```bash
   conda activate sharp
   # Should have: torch, sharp package, etc.
   ```

2. **ml** - For merge/alignment (general ML environment)
   ```bash
   conda activate ml
   # Needs: numpy, imageio
   pip install imageio  # if not already installed
   ```

### Model Checkpoint

The SHARP model checkpoint should be at:
```
3dgs/sharp_model.pt
```

If not present, the scripts will auto-download the default model from Apple's CDN.

## Usage

### Option 1: Full Pipeline (Recommended)

Run both stages with the convenience script:

```bash
cd 3dgs/scripts
./run_pipeline.sh /path/to/CaptureBundle_XXX
```

Or specify a custom output directory:
```bash
./run_pipeline.sh /path/to/CaptureBundle_XXX /path/to/output
```

### Option 2: Run Stages Separately

#### Stage 1: SHARP Inference

```bash
conda activate sharp
python scripts/run_sharp.py \
    --bundle /path/to/CaptureBundle_XXX \
    --output work/ply_per_frame/ \
    --checkpoint sharp_model.pt
```

Options:
- `--device cpu|mps|cuda|default` - Device for inference
- `--no-skip` - Re-process frames even if PLY already exists
- `-v` - Verbose logging

#### Stage 2: Merge & Align

```bash
conda activate ml
python scripts/merge_splats.py \
    --bundle /path/to/CaptureBundle_XXX \
    --ply-dir work/ply_per_frame/ \
    --output work/merged/merged.ply
```

Options:
- `--voxel-size 0.03` - Voxel size in meters for deduplication
- `--no-depth-prune` - Disable depth-based filtering
- `--depth-threshold 0.15` - Max depth disagreement in meters
- `--min-opacity -2.0` - Minimum opacity logit to keep
- `--max-scale 1.0` - Maximum log-scale to keep
- `-v` - Verbose logging

## Output

The pipeline produces:

```
work/
├── ply_per_frame/
│   └── CaptureBundle_XXX/
│       ├── 000000.ply          # Per-frame PLY (camera space)
│       ├── 000001.ply
│       ├── ...
│       └── inference_summary.json
└── merged/
    ├── CaptureBundle_XXX.ply   # Final merged PLY (world space)
    └── CaptureBundle_XXX.json  # Merge statistics
```

## PLY Format

The output PLY follows the standard 3DGS schema expected by MetalSplatter:

```
x y z                      # Position
nx ny nz                   # Normal (often zeros)
f_dc_0 f_dc_1 f_dc_2       # Spherical harmonics DC (color)
opacity                    # Logit opacity
scale_0 scale_1 scale_2    # Log-scale
rot_0 rot_1 rot_2 rot_3    # Quaternion rotation
```

Key details:
- **opacity**: Stored as logit (inverse sigmoid)
- **scale**: Stored as log-scale (apply exp() to get actual scale)
- **No `obj_info` lines**: MetalSplatter's parser is strict

## Coordinate Systems

### SHARP Output (OpenCV convention)
- X: right
- Y: down
- Z: forward (into scene)

### ARKit World Space (right-handed)
- X: right
- Y: up
- Z: backward (out of screen)

The merge script handles the conversion automatically using the camera-to-world transforms from the capture metadata.

## Troubleshooting

### "No frames passed filtering"
The quality filters may be too strict. Try:
- Check if frames have valid metadata
- Inspect `panorama.angularVelocityDegPerSec` values in frame metadata

### Empty or very sparse merged PLY
- Try reducing `--min-opacity` (e.g., `-3.0`)
- Try increasing `--max-scale` (e.g., `2.0`)
- Try increasing `--voxel-size` (e.g., `0.05`)

### PLY doesn't render correctly in app
- Verify the PLY schema matches expected format
- Check the merge stats JSON for bounding box - should be in reasonable meter range
- Try disabling depth pruning (`--no-depth-prune`)

## Configuration

Default parameters are in `config/defaults.yaml`. These document the default values used by the scripts.
