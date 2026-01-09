#!/usr/bin/env python3
"""
SHARP Inference Script for DreamBrush Capture Bundles

This script runs SHARP inference on each frame in a capture bundle,
producing per-frame PLY files in camera coordinate space.

Usage (requires 'sharp' conda environment):
    conda activate sharp
    python run_sharp.py --bundle /path/to/CaptureBundle_XXX --output /path/to/output
    
If no output is specified, outputs go to 3dgs/work/ply_per_frame/
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Optional

import numpy as np
import torch
import torch.nn.functional as F

# Sharp imports
from sharp.models import PredictorParams, create_predictor
from sharp.utils import io as sharp_io
from sharp.utils.gaussians import Gaussians3D, save_ply, unproject_gaussians

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
LOGGER = logging.getLogger(__name__)


def load_bundle_manifest(bundle_path: Path) -> dict:
    """Load and validate the capture bundle manifest."""
    manifest_path = bundle_path / "manifest.json"
    if not manifest_path.exists():
        raise FileNotFoundError(f"Manifest not found: {manifest_path}")
    
    with open(manifest_path, "r") as f:
        manifest = json.load(f)
    
    LOGGER.info(f"Loaded bundle: {manifest.get('bundleId', 'unknown')}")
    LOGGER.info(f"  Created: {manifest.get('createdAt', 'unknown')}")
    LOGGER.info(f"  Device: {manifest.get('deviceModel', 'unknown')}")
    LOGGER.info(f"  Frame count: {manifest.get('captureStats', {}).get('frameCount', 0)}")
    
    return manifest


def get_frame_list(bundle_path: Path) -> list[tuple[int, Path, Path, Optional[Path]]]:
    """
    Enumerate frames in the bundle.
    
    Returns list of tuples: (frame_index, rgb_path, meta_path, depth_path or None)
    """
    rgb_dir = bundle_path / "frames" / "rgb"
    meta_dir = bundle_path / "frames" / "meta"
    depth_dir = bundle_path / "frames" / "depth"
    
    if not rgb_dir.exists():
        raise FileNotFoundError(f"RGB directory not found: {rgb_dir}")
    if not meta_dir.exists():
        raise FileNotFoundError(f"Meta directory not found: {meta_dir}")
    
    frames = []
    for rgb_path in sorted(rgb_dir.glob("*.jpg")):
        frame_idx = int(rgb_path.stem)
        meta_path = meta_dir / f"{rgb_path.stem}.json"
        depth_path = depth_dir / f"{rgb_path.stem}.png"
        
        if not meta_path.exists():
            LOGGER.warning(f"Skipping frame {frame_idx}: missing metadata")
            continue
        
        frames.append((
            frame_idx,
            rgb_path,
            meta_path,
            depth_path if depth_path.exists() else None
        ))
    
    LOGGER.info(f"Found {len(frames)} valid frames")
    return frames


def load_frame_metadata(meta_path: Path) -> dict:
    """Load per-frame metadata."""
    with open(meta_path, "r") as f:
        return json.load(f)


def filter_frames(
    frames: list[tuple[int, Path, Path, Optional[Path]]],
    max_angular_velocity: float = 120.0,
    max_exposure_duration: float = 0.05,
    max_upright_deviation: float = 20.0,
) -> list[tuple[int, Path, Path, Optional[Path], dict]]:
    """
    Apply quality filtering to frames.
    
    Reject frames with:
    - High angular velocity (motion blur risk)
    - Long exposure duration (blur risk)
    - Large upright deviation
    
    Returns filtered list with metadata included.
    """
    filtered = []
    
    for frame_idx, rgb_path, meta_path, depth_path in frames:
        meta = load_frame_metadata(meta_path)
        
        # Check panorama metadata if available
        panorama = meta.get("panorama", {})
        angular_velocity = panorama.get("angularVelocityDegPerSec", 0.0)
        upright_deviation = panorama.get("uprightDeviationDegrees", 0.0)
        
        # Check exposure
        exposure = meta.get("exposure", {})
        exposure_duration = exposure.get("duration", 0.0)
        
        # Apply filters
        if angular_velocity > max_angular_velocity:
            LOGGER.debug(f"Frame {frame_idx}: rejected (angular velocity {angular_velocity:.1f}°/s)")
            continue
        
        if exposure_duration > max_exposure_duration:
            LOGGER.debug(f"Frame {frame_idx}: rejected (exposure {exposure_duration:.3f}s)")
            continue
        
        if upright_deviation > max_upright_deviation:
            LOGGER.debug(f"Frame {frame_idx}: rejected (upright deviation {upright_deviation:.1f}°)")
            continue
        
        filtered.append((frame_idx, rgb_path, meta_path, depth_path, meta))
    
    LOGGER.info(f"After filtering: {len(filtered)} frames (rejected {len(frames) - len(filtered)})")
    return filtered


def load_predictor(checkpoint_path: Optional[Path], device: torch.device):
    """Load the SHARP predictor model."""
    DEFAULT_MODEL_URL = "https://ml-site.cdn-apple.com/models/sharp/sharp_2572gikvuh.pt"
    
    if checkpoint_path is None:
        LOGGER.info("No checkpoint provided. Downloading default model...")
        state_dict = torch.hub.load_state_dict_from_url(DEFAULT_MODEL_URL, progress=True)
    else:
        LOGGER.info(f"Loading checkpoint from {checkpoint_path}")
        state_dict = torch.load(checkpoint_path, weights_only=True)
    
    predictor = create_predictor(PredictorParams())
    predictor.load_state_dict(state_dict)
    predictor.eval()
    predictor.to(device)
    
    return predictor


@torch.no_grad()
def predict_image(
    predictor,
    image: np.ndarray,
    f_px: float,
    device: torch.device,
) -> Gaussians3D:
    """
    Run SHARP inference on an image.
    
    Returns Gaussians3D in camera coordinate space (OpenCV convention: x right, y down, z forward).
    """
    internal_shape = (1536, 1536)
    
    # Preprocess image
    image_pt = torch.from_numpy(image.copy()).float().to(device).permute(2, 0, 1) / 255.0
    _, height, width = image_pt.shape
    disparity_factor = torch.tensor([f_px / width]).float().to(device)
    
    image_resized_pt = F.interpolate(
        image_pt[None],
        size=(internal_shape[1], internal_shape[0]),
        mode="bilinear",
        align_corners=True,
    )
    
    # Run inference (produces NDC-space Gaussians)
    gaussians_ndc = predictor(image_resized_pt, disparity_factor)
    
    # Build intrinsics matrix
    intrinsics = (
        torch.tensor([
            [f_px, 0, width / 2, 0],
            [0, f_px, height / 2, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1],
        ])
        .float()
        .to(device)
    )
    intrinsics_resized = intrinsics.clone()
    intrinsics_resized[0] *= internal_shape[0] / width
    intrinsics_resized[1] *= internal_shape[1] / height
    
    # Convert to metric space (camera coordinates)
    gaussians = unproject_gaussians(
        gaussians_ndc, torch.eye(4).to(device), intrinsics_resized, internal_shape
    )
    
    return gaussians


def run_inference(
    bundle_path: Path,
    output_dir: Path,
    checkpoint_path: Optional[Path] = None,
    device_str: str = "default",
    skip_existing: bool = True,
    max_angular_velocity: float = 120.0,
    max_exposure_duration: float = 0.05,
    max_upright_deviation: float = 20.0,
):
    """
    Run SHARP inference on all frames in a capture bundle.
    
    Args:
        bundle_path: Path to CaptureBundle directory
        output_dir: Directory to save per-frame PLY files
        checkpoint_path: Path to SHARP checkpoint (or None to download)
        device_str: Device to use ('cpu', 'mps', 'cuda', or 'default')
        skip_existing: Skip frames that already have output PLY files
    """
    # Validate bundle
    manifest = load_bundle_manifest(bundle_path)
    
    # Get and filter frames
    frames = get_frame_list(bundle_path)
    filtered_frames = filter_frames(
        frames,
        max_angular_velocity=max_angular_velocity,
        max_exposure_duration=max_exposure_duration,
        max_upright_deviation=max_upright_deviation,
    )
    
    if len(filtered_frames) == 0:
        LOGGER.error("No frames passed filtering. Exiting.")
        return
    
    # Determine device
    if device_str == "default":
        if torch.cuda.is_available():
            device = torch.device("cuda")
        elif torch.backends.mps.is_available():
            device = torch.device("mps")
        else:
            device = torch.device("cpu")
    else:
        device = torch.device(device_str)
    LOGGER.info(f"Using device: {device}")
    
    # Load model
    predictor = load_predictor(checkpoint_path, device)
    
    # Create output directory
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Also save a summary of which frames were processed
    summary = {
        "bundle_id": manifest.get("bundleId"),
        "bundle_path": str(bundle_path),
        "frames_processed": [],
        "coordinate_conventions": manifest.get("coordinateConventions", {}),
    }
    
    # Process each frame
    for i, (frame_idx, rgb_path, meta_path, depth_path, meta) in enumerate(filtered_frames):
        output_ply = output_dir / f"{frame_idx:06d}.ply"
        
        if skip_existing and output_ply.exists():
            LOGGER.info(f"[{i+1}/{len(filtered_frames)}] Frame {frame_idx}: skipping (exists)")
            summary["frames_processed"].append({
                "frame_index": frame_idx,
                "ply_path": str(output_ply),
                "skipped": True,
            })
            continue
        
        LOGGER.info(f"[{i+1}/{len(filtered_frames)}] Processing frame {frame_idx}...")
        
        # Load image
        image, _, f_px_default = sharp_io.load_rgb(rgb_path)
        height, width = image.shape[:2]
        
        # Use intrinsics from metadata if available
        camera_meta = meta.get("camera", {})
        intrinsics = camera_meta.get("intrinsics", [])
        if intrinsics and len(intrinsics) >= 2:
            # intrinsics is 3x3 row-major: [[fx, 0, cx], [0, fy, cy], [0, 0, 1]]
            f_px = intrinsics[0][0]  # fx
        else:
            f_px = f_px_default
            LOGGER.warning(f"Frame {frame_idx}: using default focal length {f_px}")
        
        # Run inference
        gaussians = predict_image(predictor, image, f_px, device)
        
        # Save PLY
        save_ply(gaussians, f_px, (height, width), output_ply)
        LOGGER.info(f"  Saved: {output_ply}")
        
        # Track in summary
        summary["frames_processed"].append({
            "frame_index": frame_idx,
            "ply_path": str(output_ply),
            "image_size": [width, height],
            "focal_length": f_px,
            "skipped": False,
        })
    
    # Save summary
    summary_path = output_dir / "inference_summary.json"
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    LOGGER.info(f"Saved inference summary: {summary_path}")
    
    LOGGER.info("Inference complete!")


def main():
    parser = argparse.ArgumentParser(
        description="Run SHARP inference on a DreamBrush capture bundle"
    )
    parser.add_argument(
        "--bundle", "-b",
        type=Path,
        required=True,
        help="Path to CaptureBundle directory",
    )
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=None,
        help="Output directory for per-frame PLY files (default: 3dgs/work/ply_per_frame/)",
    )
    parser.add_argument(
        "--checkpoint", "-c",
        type=Path,
        default=None,
        help="Path to SHARP checkpoint (downloads default if not provided)",
    )
    parser.add_argument(
        "--device",
        type=str,
        default="default",
        choices=["cpu", "mps", "cuda", "default"],
        help="Device to run inference on",
    )
    parser.add_argument(
        "--no-skip",
        action="store_true",
        help="Re-process frames even if output PLY already exists",
    )
    parser.add_argument(
        "--max-angular-velocity",
        type=float,
        default=120.0,
        help="Max angular velocity in deg/sec to accept frame (default: 120.0)",
    )
    parser.add_argument(
        "--max-exposure",
        type=float,
        default=0.05,
        help="Max exposure duration in seconds to accept frame (default: 0.05)",
    )
    parser.add_argument(
        "--max-upright-deviation",
        type=float,
        default=20.0,
        help="Max upright deviation in degrees to accept frame (default: 20.0)",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable debug logging",
    )
    
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Default output directory
    if args.output is None:
        script_dir = Path(__file__).parent.parent
        args.output = script_dir / "work" / "ply_per_frame"
    
    # Validate bundle path
    if not args.bundle.exists():
        LOGGER.error(f"Bundle not found: {args.bundle}")
        sys.exit(1)
    
    run_inference(
        bundle_path=args.bundle,
        output_dir=args.output,
        checkpoint_path=args.checkpoint,
        device_str=args.device,
        skip_existing=not args.no_skip,
        max_angular_velocity=args.max_angular_velocity,
        max_exposure_duration=args.max_exposure,
        max_upright_deviation=args.max_upright_deviation,
    )


if __name__ == "__main__":
    main()
