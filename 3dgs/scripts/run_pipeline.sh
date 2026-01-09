#!/bin/bash
#
# Full 3DGS Pipeline: CaptureBundle -> Merged PLY
#
# This script runs both stages of the pipeline:
# 1. SHARP inference (per-frame PLY generation) - requires 'sharp' conda env
# 2. Merge/align PLYs into single world-space PLY - requires 'ml' conda env
#
# Usage:
#   ./run_pipeline.sh /path/to/CaptureBundle_XXX [output_dir]
#
# If output_dir is not specified, outputs go to 3dgs/work/
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_PATH="$1"
OUTPUT_DIR="${2:-$SCRIPT_DIR/../work}"

if [ -z "$BUNDLE_PATH" ]; then
    echo "Usage: $0 /path/to/CaptureBundle_XXX [output_dir]"
    exit 1
fi

if [ ! -d "$BUNDLE_PATH" ]; then
    echo "Error: Bundle not found: $BUNDLE_PATH"
    exit 1
fi

BUNDLE_NAME=$(basename "$BUNDLE_PATH")
PLY_DIR="$OUTPUT_DIR/ply_per_frame/$BUNDLE_NAME"
MERGED_DIR="$OUTPUT_DIR/merged"
MERGED_PLY="$MERGED_DIR/${BUNDLE_NAME}.ply"

echo "========================================"
echo "3DGS Pipeline"
echo "========================================"
echo "Bundle: $BUNDLE_PATH"
echo "Per-frame PLY dir: $PLY_DIR"
echo "Merged PLY: $MERGED_PLY"
echo "========================================"
echo ""

# Stage 1: SHARP inference
echo "[Stage 1] Running SHARP inference..."
echo "  Activating 'sharp' conda environment..."

# Use the checkpoint from 3dgs/ if it exists
CHECKPOINT_ARG=""
if [ -f "$SCRIPT_DIR/../sharp_model.pt" ]; then
    CHECKPOINT_ARG="--checkpoint $SCRIPT_DIR/../sharp_model.pt"
    echo "  Using local checkpoint: $SCRIPT_DIR/../sharp_model.pt"
fi

conda run -n sharp python "$SCRIPT_DIR/run_sharp.py" \
    --bundle "$BUNDLE_PATH" \
    --output "$PLY_DIR" \
    $CHECKPOINT_ARG

echo ""
echo "[Stage 1] Complete. Per-frame PLYs saved to: $PLY_DIR"
echo ""

# Stage 2: Merge and align
echo "[Stage 2] Merging and aligning splats..."
echo "  Activating 'ml' conda environment..."

conda run -n ml python "$SCRIPT_DIR/merge_splats.py" \
    --bundle "$BUNDLE_PATH" \
    --ply-dir "$PLY_DIR" \
    --output "$MERGED_PLY"

echo ""
echo "[Stage 2] Complete. Merged PLY saved to: $MERGED_PLY"
echo ""

echo "========================================"
echo "Pipeline complete!"
echo "========================================"
echo ""
echo "Output files:"
echo "  Per-frame PLYs: $PLY_DIR/"
echo "  Merged PLY:     $MERGED_PLY"
echo "  Merge stats:    ${MERGED_PLY%.ply}.json"
echo ""
echo "To import into DreamBrush app, copy the merged PLY to the device."
