#!/usr/bin/env python3
"""
Merge Splats Script for DreamBrush 3DGS Pipeline

This script merges per-frame PLY files (from SHARP inference) into a single
coherent PLY file, using camera poses from the capture bundle metadata.

Pipeline:
1. Load per-frame PLY files and frame metadata
2. Transform splats from camera space to world space using ARKit poses
3. Optional: Depth-aware pruning
4. Voxel-grid merge/deduplication
5. Export final PLY compatible with MetalSplatter

Usage (requires 'ml' conda environment):
    conda activate ml
    python merge_splats.py \\
        --bundle /path/to/CaptureBundle_XXX \\
        --ply-dir /path/to/ply_per_frame \\
        --output /path/to/merged.ply
"""

from __future__ import annotations

import argparse
import json
import logging
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import numpy as np

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
LOGGER = logging.getLogger(__name__)
DEFAULT_CONFIG_PATH = Path(__file__).parent.parent / "config" / "defaults.yaml"


# =============================================================================
# PLY I/O Utilities
# =============================================================================

@dataclass
class GaussianSplat:
    """Represents a single Gaussian splat with all parameters."""
    position: np.ndarray      # (3,) xyz
    normal: np.ndarray        # (3,) nx ny nz (often unused, can be zeros)
    color_dc: np.ndarray      # (3,) f_dc_0, f_dc_1, f_dc_2 (spherical harmonics DC)
    opacity: float            # logit opacity
    scale: np.ndarray         # (3,) log-scale values
    rotation: np.ndarray      # (4,) quaternion (w, x, y, z or x, y, z, w depending on source)


@dataclass
class GaussianCloud:
    """Collection of Gaussian splats as structured arrays."""
    positions: np.ndarray       # (N, 3)
    normals: np.ndarray         # (N, 3)
    colors_dc: np.ndarray       # (N, 3)
    opacities: np.ndarray       # (N,)
    scales: np.ndarray          # (N, 3)
    rotations: np.ndarray       # (N, 4)
    
    @property
    def count(self) -> int:
        return len(self.positions)
    
    def filter_by_mask(self, mask: np.ndarray) -> "GaussianCloud":
        """Return a new cloud with only the splats where mask is True."""
        return GaussianCloud(
            positions=self.positions[mask],
            normals=self.normals[mask],
            colors_dc=self.colors_dc[mask],
            opacities=self.opacities[mask],
            scales=self.scales[mask],
            rotations=self.rotations[mask],
        )
    
    @staticmethod
    def concatenate(clouds: list["GaussianCloud"]) -> "GaussianCloud":
        """Concatenate multiple clouds into one."""
        return GaussianCloud(
            positions=np.concatenate([c.positions for c in clouds]),
            normals=np.concatenate([c.normals for c in clouds]),
            colors_dc=np.concatenate([c.colors_dc for c in clouds]),
            opacities=np.concatenate([c.opacities for c in clouds]),
            scales=np.concatenate([c.scales for c in clouds]),
            rotations=np.concatenate([c.rotations for c in clouds]),
        )


def load_ply(ply_path: Path) -> GaussianCloud:
    """
    Load a 3DGS PLY file into a GaussianCloud.
    
    Supports standard 3DGS format with:
    x, y, z, (nx, ny, nz), f_dc_0, f_dc_1, f_dc_2, opacity, scale_0, scale_1, scale_2, rot_0, rot_1, rot_2, rot_3
    """
    with open(ply_path, "rb") as f:
        # Parse header
        header_lines = []
        while True:
            line = f.readline().decode("utf-8").strip()
            header_lines.append(line)
            if line == "end_header":
                break
        
        # Parse header for vertex count and properties
        vertex_count = 0
        properties = []
        in_vertex = False
        
        for line in header_lines:
            if line.startswith("element vertex"):
                vertex_count = int(line.split()[-1])
                in_vertex = True
            elif line.startswith("element ") and in_vertex:
                in_vertex = False
            elif line.startswith("property ") and in_vertex:
                parts = line.split()
                prop_type = parts[1]
                prop_name = parts[2]
                properties.append((prop_name, prop_type))
        
        if vertex_count == 0:
            return GaussianCloud(
                positions=np.zeros((0, 3)),
                normals=np.zeros((0, 3)),
                colors_dc=np.zeros((0, 3)),
                opacities=np.zeros((0,)),
                scales=np.zeros((0, 3)),
                rotations=np.zeros((0, 4)),
            )
        
        # Build numpy dtype
        type_map = {
            "float": "f4",
            "double": "f8",
            "uchar": "u1",
            "char": "i1",
            "ushort": "u2",
            "short": "i2",
            "uint": "u4",
            "int": "i4",
        }
        dtype = [(name, type_map.get(ptype, "f4")) for name, ptype in properties]
        
        # Read binary data
        data = np.frombuffer(f.read(), dtype=dtype, count=vertex_count)
    
    # Extract fields
    positions = np.stack([data["x"], data["y"], data["z"]], axis=-1).astype(np.float32)
    
    # Normals (may not exist in all PLY files)
    if "nx" in data.dtype.names:
        normals = np.stack([data["nx"], data["ny"], data["nz"]], axis=-1).astype(np.float32)
    else:
        normals = np.zeros_like(positions)
    
    # Colors (spherical harmonics DC)
    colors_dc = np.stack([data["f_dc_0"], data["f_dc_1"], data["f_dc_2"]], axis=-1).astype(np.float32)
    
    # Opacity (logit)
    opacities = data["opacity"].astype(np.float32)
    
    # Scale (log-scale)
    scales = np.stack([data["scale_0"], data["scale_1"], data["scale_2"]], axis=-1).astype(np.float32)
    
    # Rotation (quaternion)
    rotations = np.stack([data["rot_0"], data["rot_1"], data["rot_2"], data["rot_3"]], axis=-1).astype(np.float32)
    
    return GaussianCloud(
        positions=positions,
        normals=normals,
        colors_dc=colors_dc,
        opacities=opacities,
        scales=scales,
        rotations=rotations,
    )


def save_ply(cloud: GaussianCloud, output_path: Path, remove_obj_info: bool = True):
    """
    Save a GaussianCloud to a PLY file in the MetalSplatter-compatible format.
    
    Schema:
    x y z nx ny nz f_dc_0 f_dc_1 f_dc_2 opacity scale_0 scale_1 scale_2 rot_0 rot_1 rot_2 rot_3
    """
    header = f"""ply
format binary_little_endian 1.0
element vertex {cloud.count}
property float x
property float y
property float z
property float nx
property float ny
property float nz
property float f_dc_0
property float f_dc_1
property float f_dc_2
property float opacity
property float scale_0
property float scale_1
property float scale_2
property float rot_0
property float rot_1
property float rot_2
property float rot_3
end_header
"""
    
    with open(output_path, "wb") as f:
        f.write(header.encode("utf-8"))
        
        # Write vertex data
        for i in range(cloud.count):
            f.write(struct.pack(
                "<17f",
                cloud.positions[i, 0], cloud.positions[i, 1], cloud.positions[i, 2],
                cloud.normals[i, 0], cloud.normals[i, 1], cloud.normals[i, 2],
                cloud.colors_dc[i, 0], cloud.colors_dc[i, 1], cloud.colors_dc[i, 2],
                cloud.opacities[i],
                cloud.scales[i, 0], cloud.scales[i, 1], cloud.scales[i, 2],
                cloud.rotations[i, 0], cloud.rotations[i, 1], cloud.rotations[i, 2], cloud.rotations[i, 3],
            ))
    
    LOGGER.info(f"Saved {cloud.count} splats to {output_path}")


# =============================================================================
# Coordinate Transformations
# =============================================================================

def load_frame_metadata(meta_path: Path) -> dict:
    """Load per-frame metadata from JSON."""
    with open(meta_path, "r") as f:
        return json.load(f)


def load_defaults(config_path: Path) -> dict:
    """Load defaults from YAML config. Returns empty dict on failure."""
    if not config_path.exists():
        return {}
    try:
        import yaml
    except Exception as exc:
        LOGGER.warning(f"Config load skipped (PyYAML unavailable): {exc}")
        return {}
    try:
        with open(config_path, "r") as f:
            data = yaml.safe_load(f)
        return data if isinstance(data, dict) else {}
    except Exception as exc:
        LOGGER.warning(f"Config load failed: {exc}")
        return {}


def matrix_from_list(mat_list: list[list[float]]) -> np.ndarray:
    """Convert a row-major 4x4 matrix list to numpy array."""
    return np.array(mat_list, dtype=np.float32)


def quaternion_from_rotation_matrix(R: np.ndarray) -> np.ndarray:
    """
    Convert a 3x3 rotation matrix to quaternion (w, x, y, z).
    Using the algorithm from:
    https://www.euclideanspace.com/maths/geometry/rotations/conversions/matrixToQuaternion/
    """
    trace = R[0, 0] + R[1, 1] + R[2, 2]
    
    if trace > 0:
        s = 0.5 / np.sqrt(trace + 1.0)
        w = 0.25 / s
        x = (R[2, 1] - R[1, 2]) * s
        y = (R[0, 2] - R[2, 0]) * s
        z = (R[1, 0] - R[0, 1]) * s
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        s = 2.0 * np.sqrt(1.0 + R[0, 0] - R[1, 1] - R[2, 2])
        w = (R[2, 1] - R[1, 2]) / s
        x = 0.25 * s
        y = (R[0, 1] + R[1, 0]) / s
        z = (R[0, 2] + R[2, 0]) / s
    elif R[1, 1] > R[2, 2]:
        s = 2.0 * np.sqrt(1.0 + R[1, 1] - R[0, 0] - R[2, 2])
        w = (R[0, 2] - R[2, 0]) / s
        x = (R[0, 1] + R[1, 0]) / s
        y = 0.25 * s
        z = (R[1, 2] + R[2, 1]) / s
    else:
        s = 2.0 * np.sqrt(1.0 + R[2, 2] - R[0, 0] - R[1, 1])
        w = (R[1, 0] - R[0, 1]) / s
        x = (R[0, 2] + R[2, 0]) / s
        y = (R[1, 2] + R[2, 1]) / s
        z = 0.25 * s
    
    return np.array([w, x, y, z], dtype=np.float32)


def quaternion_multiply(q1: np.ndarray, q2: np.ndarray) -> np.ndarray:
    """
    Multiply two quaternions (w, x, y, z format).
    q1 * q2
    """
    w1, x1, y1, z1 = q1
    w2, x2, y2, z2 = q2
    
    return np.array([
        w1*w2 - x1*x2 - y1*y2 - z1*z2,
        w1*x2 + x1*w2 + y1*z2 - z1*y2,
        w1*y2 - x1*z2 + y1*w2 + z1*x2,
        w1*z2 + x1*y2 - y1*x2 + z1*w2,
    ], dtype=np.float32)


def convert_sharp_to_arkit_frame(cloud: GaussianCloud) -> GaussianCloud:
    """
    Convert SHARP output (OpenCV convention) to ARKit convention.
    
    SHARP uses OpenCV: x right, y down, z forward
    ARKit uses: x right, y up, z backward (out of screen)
    
    Conversion matrix:
    [1,  0,  0]
    [0, -1,  0]
    [0,  0, -1]
    """
    # Transform positions
    positions = cloud.positions.copy()
    positions[:, 1] = -positions[:, 1]  # flip y
    positions[:, 2] = -positions[:, 2]  # flip z
    
    # Transform normals
    normals = cloud.normals.copy()
    normals[:, 1] = -normals[:, 1]
    normals[:, 2] = -normals[:, 2]
    
    # Transform quaternions
    # Rotation that flips y and z
    R_convert = np.array([
        [1,  0,  0],
        [0, -1,  0],
        [0,  0, -1],
    ], dtype=np.float32)
    q_convert = quaternion_from_rotation_matrix(R_convert)
    
    rotations = cloud.rotations.copy()
    # SHARP uses (x, y, z, w) quaternion format, we need to handle this
    # Check if it's (w, x, y, z) or (x, y, z, w) by looking at typical values
    # Standard 3DGS uses rot_0, rot_1, rot_2, rot_3 which is typically (w, x, y, z)
    # We'll assume (w, x, y, z) and apply the coordinate transformation
    for i in range(len(rotations)):
        # Apply rotation: q_new = q_convert * q_original
        # But for Gaussians, we need to conjugate: q_new = q_convert * q_original * q_convert^{-1}
        # Since R_convert is its own inverse (R^2 = I), q_convert^{-1} = q_convert (conjugate)
        q_orig = rotations[i]
        q_conj = np.array([q_convert[0], -q_convert[1], -q_convert[2], -q_convert[3]])
        q_temp = quaternion_multiply(q_convert, q_orig)
        rotations[i] = quaternion_multiply(q_temp, q_conj)
    
    return GaussianCloud(
        positions=positions,
        normals=normals,
        colors_dc=cloud.colors_dc.copy(),
        opacities=cloud.opacities.copy(),
        scales=cloud.scales.copy(),
        rotations=rotations,
    )


def transform_cloud_to_world(cloud: GaussianCloud, T_c2w: np.ndarray) -> GaussianCloud:
    """
    Transform a GaussianCloud from camera space to world space.
    
    Args:
        cloud: GaussianCloud in camera coordinates
        T_c2w: 4x4 camera-to-world transformation matrix (row-major, as stored in metadata)
    
    Returns:
        GaussianCloud in world coordinates
    """
    # Extract rotation and translation
    R = T_c2w[:3, :3]
    t = T_c2w[:3, 3]
    
    # Transform positions: p_world = R @ p_cam + t
    positions = (cloud.positions @ R.T) + t
    
    # Transform normals: n_world = R @ n_cam (no translation for normals)
    normals = cloud.normals @ R.T
    
    # Transform rotations
    q_R = quaternion_from_rotation_matrix(R)
    rotations = np.zeros_like(cloud.rotations)
    for i in range(len(cloud.rotations)):
        rotations[i] = quaternion_multiply(q_R, cloud.rotations[i])
    
    return GaussianCloud(
        positions=positions,
        normals=normals,
        colors_dc=cloud.colors_dc.copy(),
        opacities=cloud.opacities.copy(),
        scales=cloud.scales.copy(),
        rotations=rotations,
    )


# =============================================================================
# Depth-Aware Pruning
# =============================================================================

def load_depth_map(depth_path: Path) -> np.ndarray:
    """
    Load a 16-bit PNG depth map.
    Returns depth in meters (converted from millimeters).
    """
    import imageio.v3 as iio
    
    depth_mm = iio.imread(depth_path).astype(np.float32)
    depth_m = depth_mm / 1000.0  # Convert mm to meters
    
    # Mark invalid depth (0) as NaN
    depth_m[depth_mm == 0] = np.nan
    
    return depth_m


def prune_by_depth(
    cloud: GaussianCloud,
    depth_map: np.ndarray,
    depth_intrinsics: np.ndarray,
    T_c2w: np.ndarray,
    depth_threshold: float = 0.5,
) -> GaussianCloud:
    """
    Remove splats that significantly disagree with the depth map.
    
    Args:
        cloud: GaussianCloud in world coordinates
        depth_map: Depth map in meters (H, W)
        depth_intrinsics: 3x3 depth camera intrinsics
        T_c2w: Camera-to-world transform
        depth_threshold: Max allowed depth difference in meters
    
    Returns:
        Filtered GaussianCloud
    """
    # Transform world positions to camera coordinates
    R = T_c2w[:3, :3]
    t = T_c2w[:3, 3]
    T_w2c = np.eye(4, dtype=np.float32)
    T_w2c[:3, :3] = R.T
    T_w2c[:3, 3] = -R.T @ t
    
    positions_cam = (cloud.positions - t) @ R
    
    # Project to depth image coordinates
    H, W = depth_map.shape
    fx, fy = depth_intrinsics[0, 0], depth_intrinsics[1, 1]
    cx, cy = depth_intrinsics[0, 2], depth_intrinsics[1, 2]
    
    # Depth intrinsics + depth map use OpenCV-style coords (z forward).
    # ARKit camera coords are x right, y up, z backward (toward viewer),
    # so flip y and z to compare in the same space.
    x = positions_cam[:, 0]
    y = -positions_cam[:, 1]
    z = -positions_cam[:, 2]
    
    # Project to pixel coordinates
    u = np.rint(fx * x / z + cx).astype(np.int32)
    v = np.rint(fy * y / z + cy).astype(np.int32)
    
    # Create mask for valid projections
    valid_proj = (u >= 0) & (u < W) & (v >= 0) & (v < H) & (z > 1e-6)
    
    # Compare against range (distance along the ray), not just z.
    keep_mask = np.ones(cloud.count, dtype=bool)
    valid_indices = np.where(valid_proj)[0]
    if len(valid_indices) == 0:
        return cloud
    
    measured_depth = depth_map[v[valid_indices], u[valid_indices]]
    finite = np.isfinite(measured_depth)
    if np.count_nonzero(finite) < 1500:
        LOGGER.debug("Depth pruning skipped: insufficient finite depth samples")
        return cloud
    
    pred_range = np.sqrt(
        x[valid_indices] ** 2 +
        y[valid_indices] ** 2 +
        z[valid_indices] ** 2
    )
    
    # Adaptive threshold: base + proportional-to-range term.
    adaptive_thresh = depth_threshold + 0.2 * measured_depth
    diff = np.abs(pred_range - measured_depth)
    
    keep_mask_valid = np.ones_like(measured_depth, dtype=bool)
    keep_mask_valid[finite] = diff[finite] <= adaptive_thresh[finite]
    
    inlier_ratio = np.mean(keep_mask_valid[finite])
    if inlier_ratio < 0.5:
        LOGGER.debug(f"Depth pruning skipped: low inlier ratio ({inlier_ratio:.2f})")
        return cloud
    
    keep_mask[valid_indices] = keep_mask_valid
    
    pruned_count = cloud.count - np.sum(keep_mask)
    LOGGER.debug(f"Depth pruning: removed {pruned_count}/{cloud.count} splats")
    
    return cloud.filter_by_mask(keep_mask)


# =============================================================================
# Voxel-Grid Merge / Deduplication
# =============================================================================

def sigmoid(x: np.ndarray) -> np.ndarray:
    """Apply sigmoid function."""
    return 1.0 / (1.0 + np.exp(-np.clip(x, -20, 20)))


def voxel_grid_merge(
    cloud: GaussianCloud,
    voxel_size: float = 0.03,
    min_opacity_logit: float = -2.0,
    max_scale_log: float = 1.0,
) -> GaussianCloud:
    """
    Merge splats using a voxel grid approach.
    
    For each occupied voxel:
    - If multiple splats, keep the one with highest opacity
    - Prune splats with very low opacity or very large scale
    
    Args:
        cloud: Input GaussianCloud
        voxel_size: Size of voxels in meters
        min_opacity_logit: Minimum logit opacity to keep (below this = transparent)
        max_scale_log: Maximum log-scale value (above this = too large)
    
    Returns:
        Deduplicated GaussianCloud
    """
    if cloud.count == 0:
        return cloud
    
    LOGGER.info(f"Voxel merge: {cloud.count} splats, voxel size={voxel_size}m")
    
    # Pre-filter by opacity and scale
    opacity_mask = cloud.opacities >= min_opacity_logit
    scale_mask = np.all(cloud.scales <= max_scale_log, axis=1)
    pre_filter_mask = opacity_mask & scale_mask
    
    pre_filtered = cloud.filter_by_mask(pre_filter_mask)
    LOGGER.info(f"  Pre-filter: {cloud.count} -> {pre_filtered.count} (opacity/scale)")
    
    if pre_filtered.count == 0:
        return pre_filtered
    
    # Compute voxel indices
    voxel_indices = np.floor(pre_filtered.positions / voxel_size).astype(np.int32)
    
    # Create a dictionary to track splats per voxel
    voxel_to_splats: dict[tuple, list[int]] = {}
    for i in range(pre_filtered.count):
        key = tuple(voxel_indices[i])
        if key not in voxel_to_splats:
            voxel_to_splats[key] = []
        voxel_to_splats[key].append(i)
    
    # For each voxel, keep the splat with highest opacity
    keep_indices = []
    for voxel_key, splat_indices in voxel_to_splats.items():
        if len(splat_indices) == 1:
            keep_indices.append(splat_indices[0])
        else:
            # Find the one with highest opacity
            opacities = pre_filtered.opacities[splat_indices]
            best_idx = splat_indices[np.argmax(opacities)]
            keep_indices.append(best_idx)
    
    keep_indices = np.array(keep_indices, dtype=np.int32)
    merged = GaussianCloud(
        positions=pre_filtered.positions[keep_indices],
        normals=pre_filtered.normals[keep_indices],
        colors_dc=pre_filtered.colors_dc[keep_indices],
        opacities=pre_filtered.opacities[keep_indices],
        scales=pre_filtered.scales[keep_indices],
        rotations=pre_filtered.rotations[keep_indices],
    )
    
    LOGGER.info(f"  Voxel merge: {pre_filtered.count} -> {merged.count} ({len(voxel_to_splats)} voxels)")
    
    return merged


# =============================================================================
# Main Pipeline
# =============================================================================

def merge_pipeline(
    bundle_path: Path,
    ply_dir: Path,
    output_path: Path,
    voxel_size: float = 0.03,
    depth_prune: bool = True,
    depth_threshold: float = 0.5,
    min_opacity_logit: float = -2.0,
    max_scale_log: float = 1.0,
):
    """
    Run the full merge pipeline.
    
    Args:
        bundle_path: Path to CaptureBundle directory
        ply_dir: Directory containing per-frame PLY files
        output_path: Path to save merged PLY
        voxel_size: Voxel size for deduplication (meters)
        depth_prune: Whether to use depth-aware pruning
        depth_threshold: Depth agreement threshold (meters)
        min_opacity_logit: Minimum opacity logit to keep
        max_scale_log: Maximum log-scale to keep
    """
    # Load manifest
    manifest_path = bundle_path / "manifest.json"
    with open(manifest_path, "r") as f:
        manifest = json.load(f)
    
    LOGGER.info(f"Processing bundle: {manifest.get('bundleId', 'unknown')}")
    
    # Get coordinate conventions
    conventions = manifest.get("coordinateConventions", {})
    LOGGER.info(f"Coordinate conventions: {conventions}")
    
    # Verify conventions
    if conventions.get("transformDirection") != "camera_to_world":
        LOGGER.warning("Expected camera_to_world transforms, got: " + conventions.get("transformDirection", "unknown"))
    
    # Find frames with PLY files
    meta_dir = bundle_path / "frames" / "meta"
    depth_dir = bundle_path / "frames" / "depth"
    
    all_clouds = []
    
    for ply_path in sorted(ply_dir.glob("*.ply")):
        if ply_path.name == "merged.ply":
            continue
        
        frame_idx = int(ply_path.stem)
        meta_path = meta_dir / f"{frame_idx:06d}.json"
        depth_path = depth_dir / f"{frame_idx:06d}.png"
        
        if not meta_path.exists():
            LOGGER.warning(f"Frame {frame_idx}: no metadata, skipping")
            continue
        
        LOGGER.info(f"Processing frame {frame_idx}...")
        
        # Load PLY
        cloud = load_ply(ply_path)
        LOGGER.info(f"  Loaded {cloud.count} splats from {ply_path.name}")
        
        if cloud.count == 0:
            continue
        
        # Load metadata
        meta = load_frame_metadata(meta_path)
        
        # Get camera transform (camera-to-world)
        camera_meta = meta.get("camera", {})
        T_c2w_list = camera_meta.get("transform")
        if T_c2w_list is None:
            LOGGER.warning(f"Frame {frame_idx}: no camera transform, skipping")
            continue
        
        T_c2w = matrix_from_list(T_c2w_list)
        
        # Convert from SHARP (OpenCV) to ARKit coordinate system
        cloud = convert_sharp_to_arkit_frame(cloud)
        
        # Transform to world space
        cloud = transform_cloud_to_world(cloud, T_c2w)
        
        # Depth pruning (optional)
        if depth_prune and depth_path.exists():
            depth_meta = meta.get("depth", {})
            depth_intrinsics_list = depth_meta.get("intrinsics")
            
            if depth_intrinsics_list is not None:
                try:
                    depth_map = load_depth_map(depth_path)
                    depth_intrinsics = np.array(depth_intrinsics_list, dtype=np.float32)
                    cloud = prune_by_depth(cloud, depth_map, depth_intrinsics, T_c2w, depth_threshold)
                except Exception as e:
                    LOGGER.warning(f"Frame {frame_idx}: depth pruning failed: {e}")
        
        LOGGER.info(f"  After processing: {cloud.count} splats")
        all_clouds.append(cloud)
    
    if len(all_clouds) == 0:
        LOGGER.error("No frames processed. Exiting.")
        return
    
    # Concatenate all clouds
    LOGGER.info(f"Concatenating {len(all_clouds)} frame clouds...")
    combined = GaussianCloud.concatenate(all_clouds)
    LOGGER.info(f"Total splats before merge: {combined.count}")
    
    # Voxel-grid merge
    merged = voxel_grid_merge(
        combined,
        voxel_size=voxel_size,
        min_opacity_logit=min_opacity_logit,
        max_scale_log=max_scale_log,
    )
    
    # Compute bounding box
    if merged.count > 0:
        min_pos = np.min(merged.positions, axis=0)
        max_pos = np.max(merged.positions, axis=0)
        bbox_size = max_pos - min_pos
        LOGGER.info(f"Bounding box: min={min_pos}, max={max_pos}, size={bbox_size}")
    
    # Save output
    output_path.parent.mkdir(parents=True, exist_ok=True)
    save_ply(merged, output_path)
    
    # Save merge stats
    stats_path = output_path.with_suffix(".json")
    stats = {
        "bundle_id": manifest.get("bundleId"),
        "frames_processed": len(all_clouds),
        "total_splats_before_merge": combined.count,
        "total_splats_after_merge": merged.count,
        "voxel_size": voxel_size,
        "depth_prune": depth_prune,
        "depth_threshold": depth_threshold,
        "min_opacity_logit": min_opacity_logit,
        "max_scale_log": max_scale_log,
    }
    if merged.count > 0:
        stats["bounding_box"] = {
            "min": min_pos.tolist(),
            "max": max_pos.tolist(),
            "size": bbox_size.tolist(),
        }
    
    with open(stats_path, "w") as f:
        json.dump(stats, f, indent=2)
    LOGGER.info(f"Saved merge stats: {stats_path}")
    
    LOGGER.info("Merge complete!")


def main():
    defaults = load_defaults(DEFAULT_CONFIG_PATH)
    merge_defaults = defaults.get("merge", {}) if isinstance(defaults, dict) else {}
    depth_pruning_default = merge_defaults.get(
        "depth_pruning",
        merge_defaults.get("depth_prune", True),
    )

    parser = argparse.ArgumentParser(
        description="Merge per-frame PLY files into a single coherent 3DGS PLY"
    )
    parser.add_argument(
        "--bundle", "-b",
        type=Path,
        required=True,
        help="Path to CaptureBundle directory",
    )
    parser.add_argument(
        "--ply-dir", "-p",
        type=Path,
        required=True,
        help="Directory containing per-frame PLY files from run_sharp.py",
    )
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=None,
        help="Output path for merged PLY (default: 3dgs/work/merged/merged.ply)",
    )
    parser.add_argument(
        "--voxel-size",
        type=float,
        default=0.03,
        help="Voxel size for deduplication in meters (default: 0.03)",
    )
    depth_prune_group = parser.add_mutually_exclusive_group()
    depth_prune_group.add_argument(
        "--depth-prune",
        dest="depth_prune",
        action="store_true",
        default=depth_pruning_default,
        help="Enable depth-aware pruning",
    )
    depth_prune_group.add_argument(
        "--no-depth-prune",
        dest="depth_prune",
        action="store_false",
        help="Disable depth-aware pruning",
    )
    parser.add_argument(
        "--depth-threshold",
        type=float,
        default=0.5,
        help="Depth agreement threshold in meters (default: 0.5)",
    )
    parser.add_argument(
        "--min-opacity",
        type=float,
        default=-2.0,
        help="Minimum opacity logit to keep (default: -2.0)",
    )
    parser.add_argument(
        "--max-scale",
        type=float,
        default=1.0,
        help="Maximum log-scale to keep (default: 1.0)",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable debug logging",
    )
    
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Default output path
    if args.output is None:
        script_dir = Path(__file__).parent.parent
        args.output = script_dir / "work" / "merged" / "merged.ply"
    
    # Validate paths
    if not args.bundle.exists():
        LOGGER.error(f"Bundle not found: {args.bundle}")
        sys.exit(1)
    
    if not args.ply_dir.exists():
        LOGGER.error(f"PLY directory not found: {args.ply_dir}")
        sys.exit(1)
    
    merge_pipeline(
        bundle_path=args.bundle,
        ply_dir=args.ply_dir,
        output_path=args.output,
        voxel_size=args.voxel_size,
        depth_prune=args.depth_prune,
        depth_threshold=args.depth_threshold,
        min_opacity_logit=args.min_opacity,
        max_scale_log=args.max_scale,
    )


if __name__ == "__main__":
    main()
