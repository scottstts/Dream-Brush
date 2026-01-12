#!/usr/bin/env python3
"""Precompute training-ready data from a Nerfstudio dataset or raw CaptureBundle.

Two modes:
1) Direct dataset mode: provide --data (nerfstudio dataset with transforms.json).
2) Raw bundle mode: provide --gdrive-url or --bundle-zip to download/extract a CaptureBundle
   and build a nerfstudio dataset before precomputing.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Dict, Optional, Tuple

import cv2
import numpy as np


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def _save_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2))


def _extract_gdrive_file_id(url: str) -> Optional[str]:
    if not url:
        return None
    match = re.search(r"/d/([a-zA-Z0-9_-]+)", url)
    if match:
        return match.group(1)
    match = re.search(r"id=([a-zA-Z0-9_-]+)", url)
    if match:
        return match.group(1)
    return None


def _download_from_gdrive(url: str, out_path: Path) -> Path:
    if out_path.exists():
        return out_path
    file_id = _extract_gdrive_file_id(url)
    if not file_id:
        raise ValueError("Could not extract file id from GDRIVE_URL. Use a share link or '?id=' URL.")
    try:
        import gdown  # type: ignore
    except ImportError as exc:
        raise RuntimeError("Missing dependency 'gdown'. Install it to download from Google Drive.") from exc

    download_url = f"https://drive.google.com/uc?id={file_id}"
    gdown.download(download_url, str(out_path), quiet=False)
    if not out_path.exists():
        raise RuntimeError("Download failed; file not found after gdown.")
    return out_path


def _extract_zip(zip_path: Path, out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(out_dir)
    return out_dir


def _find_capture_bundle(root: Path) -> Path:
    bundle_dirs = [p for p in root.rglob("CaptureBundle_*") if p.is_dir()]
    non_macos = [p for p in bundle_dirs if "__MACOSX" not in p.parts]
    if not bundle_dirs:
        raise FileNotFoundError("No CaptureBundle_* folder found in extracted archive")
    return non_macos[0] if non_macos else bundle_dirs[0]


def _rows_to_matrix(rows: list[list[float]]) -> np.ndarray:
    return np.array(rows, dtype=np.float32)


def _intrinsics_from_meta(meta: dict) -> Tuple[float, float, float, float, int, int]:
    intr = meta["camera"]["intrinsics"]
    fx = intr[0][0]
    fy = intr[1][1]
    cx = intr[0][2]
    cy = intr[1][2]
    w = meta["camera"]["imageResolution"]["width"]
    h = meta["camera"]["imageResolution"]["height"]
    return float(fx), float(fy), float(cx), float(cy), int(w), int(h)


def _load_frame_meta(frames_meta_dir: Path, frame_id: int) -> dict:
    meta_path = frames_meta_dir / f"{frame_id:06d}.json"
    if not meta_path.exists():
        raise FileNotFoundError(f"Missing meta for frame {frame_id}: {meta_path}")
    return json.loads(meta_path.read_text())


def _unproject_depth(
    depth_m: np.ndarray,
    fx: float,
    fy: float,
    cx: float,
    cy: float,
    stride: int,
    min_depth_m: float,
    max_depth_m: float,
    confidence: Optional[np.ndarray] = None,
    min_confidence: Optional[int] = None,
):
    h, w = depth_m.shape
    us = np.arange(0, w, stride)
    vs = np.arange(0, h, stride)
    uu, vv = np.meshgrid(us, vs)
    z = depth_m[np.ix_(vs, us)]
    mask = (z > min_depth_m) & (z < max_depth_m)

    if confidence is not None and min_confidence is not None:
        conf_h, conf_w = confidence.shape
        u_conf = np.clip((uu * (conf_w / w)).astype(np.int32), 0, conf_w - 1)
        v_conf = np.clip((vv * (conf_h / h)).astype(np.int32), 0, conf_h - 1)
        conf_vals = confidence[v_conf, u_conf]
        mask &= conf_vals >= min_confidence

    u = uu[mask]
    v = vv[mask]
    z = z[mask]

    x = (u - cx) / fx * z
    y = (v - cy) / fy * z
    pts = np.stack([x, y, z], axis=1).astype(np.float32)
    return pts, (u, v)


def _voxel_downsample(points: np.ndarray, colors: Optional[np.ndarray], voxel_size: float):
    if voxel_size <= 0:
        return points, colors
    voxel = np.floor(points / voxel_size).astype(np.int32)
    _, unique_idx = np.unique(voxel, axis=0, return_index=True)
    if colors is None:
        return points[unique_idx], None
    return points[unique_idx], colors[unique_idx]


def _write_ply_ascii(path: Path, points: np.ndarray, colors: Optional[np.ndarray] = None) -> None:
    with path.open("w", encoding="ascii") as f:
        f.write("ply\nformat ascii 1.0\n")
        f.write(f"element vertex {len(points)}\n")
        f.write("property float x\nproperty float y\nproperty float z\n")
        if colors is not None:
            f.write("property uchar red\nproperty uchar green\nproperty uchar blue\n")
        f.write("end_header\n")
        if colors is None:
            for x, y, z in points:
                f.write(f"{x} {y} {z}\n")
        else:
            for (x, y, z), (r, g, b) in zip(points, colors):
                f.write(f"{x} {y} {z} {int(r)} {int(g)} {int(b)}\n")


def _build_sparse_point_cloud(
    bundle_dir: Path,
    dataset_dir: Path,
    t_root_world: np.ndarray,
    apply_camera_axis_conversion: bool,
    use_confidence: bool,
    min_confidence: int,
    depth_stride: int,
    min_depth_m: float,
    max_depth_m: float,
    voxel_size_m: float,
    max_points_per_frame: int,
) -> None:
    frames_meta_dir = bundle_dir / "frames" / "meta"
    frames_depth_dir = bundle_dir / "frames" / "depth"
    frames_confidence_dir = bundle_dir / "frames" / "confidence"
    frames_rgb_dir = bundle_dir / "frames" / "rgb"
    keyframes_dir = bundle_dir / "keyframes"

    depth_frame_ids = sorted([int(p.stem) for p in frames_depth_dir.glob("*.png")])
    if not depth_frame_ids:
        return

    all_points = []
    all_colors = []

    for frame_id in depth_frame_ids:
        meta = _load_frame_meta(frames_meta_dir, frame_id)
        depth_meta = meta.get("depth") or {}
        if not depth_meta.get("available"):
            continue

        depth_path = frames_depth_dir / f"{frame_id:06d}.png"
        if not depth_path.exists():
            continue

        depth = cv2.imread(str(depth_path), cv2.IMREAD_UNCHANGED)
        if depth is None:
            continue
        if depth.dtype != np.uint16:
            depth = depth.astype(np.uint16)
        depth_m = depth.astype(np.float32) / 1000.0

        confidence = None
        if use_confidence:
            conf_path = frames_confidence_dir / f"{frame_id:06d}.png"
            if conf_path.exists():
                conf = cv2.imread(str(conf_path), cv2.IMREAD_UNCHANGED)
                if conf is not None:
                    confidence = conf.astype(np.uint8)

        fx, fy, cx, cy, w, h = _intrinsics_from_meta(meta)
        depth_h, depth_w = depth_m.shape
        fx_d = fx * (depth_w / w)
        fy_d = fy * (depth_h / h)
        cx_d = cx * (depth_w / w)
        cy_d = cy * (depth_h / h)

        pts_cam, (u_depth, v_depth) = _unproject_depth(
            depth_m,
            fx_d,
            fy_d,
            cx_d,
            cy_d,
            depth_stride,
            min_depth_m,
            max_depth_m,
            confidence=confidence,
            min_confidence=min_confidence if confidence is not None else None,
        )
        if pts_cam.shape[0] == 0:
            continue

        t_cam_world = _rows_to_matrix(meta["camera"]["transform"])
        t_cam_anchor = np.linalg.inv(t_root_world) @ t_cam_world
        if apply_camera_axis_conversion:
            t_cam_anchor = t_cam_anchor @ np.diag([1.0, 1.0, -1.0, 1.0]).astype(np.float32)

        ones = np.ones((pts_cam.shape[0], 1), dtype=np.float32)
        pts_h = np.concatenate([pts_cam, ones], axis=1)
        pts_anchor = (t_cam_anchor @ pts_h.T).T[:, :3]

        img_path = frames_rgb_dir / f"{frame_id:06d}.jpg"
        if not img_path.exists():
            img_path = keyframes_dir / f"{frame_id:06d}.jpg"
        colors = None
        if img_path.exists():
            rgb = cv2.imread(str(img_path), cv2.IMREAD_COLOR)
            if rgb is not None:
                rgb = cv2.cvtColor(rgb, cv2.COLOR_BGR2RGB)
                rgb_h, rgb_w, _ = rgb.shape
                u_rgb = np.clip((u_depth * (rgb_w / depth_w)).astype(np.int32), 0, rgb_w - 1)
                v_rgb = np.clip((v_depth * (rgb_h / depth_h)).astype(np.int32), 0, rgb_h - 1)
                colors = rgb[v_rgb, u_rgb]

        if colors is None:
            colors = np.full((pts_anchor.shape[0], 3), 128, dtype=np.uint8)

        if max_points_per_frame and pts_anchor.shape[0] > max_points_per_frame:
            idx = np.random.choice(pts_anchor.shape[0], max_points_per_frame, replace=False)
            pts_anchor = pts_anchor[idx]
            colors = colors[idx]

        all_points.append(pts_anchor)
        all_colors.append(colors)

    if not all_points:
        return

    points = np.concatenate(all_points, axis=0)
    colors = np.concatenate(all_colors, axis=0)
    points, colors = _voxel_downsample(points, colors, voxel_size_m)

    sparse_path = dataset_dir / "sparse_pc.ply"
    _write_ply_ascii(sparse_path, points, colors)


def _build_dataset_from_bundle(
    bundle_dir: Path,
    dataset_root: Path,
    use_keyframes: bool,
    frame_stride: int,
    max_frames: Optional[int],
    use_confidence: bool,
    min_confidence: int,
    use_per_frame_intrinsics: bool,
    intrinsics_spread_threshold: float,
    apply_camera_axis_conversion: bool,
    build_sparse_pc: bool,
    depth_stride: int,
    min_depth_m: float,
    max_depth_m: float,
    voxel_size_m: float,
    max_points_per_frame: int,
) -> Path:
    anchors = _load_json(bundle_dir / "anchors.json")
    root_transform = anchors.get("rootAnchor", {}).get("transform")
    if root_transform:
        t_root_world = np.array(root_transform, dtype=np.float32)
    else:
        t_root_world = np.eye(4, dtype=np.float32)

    keyframes_dir = bundle_dir / "keyframes"
    frames_meta_dir = bundle_dir / "frames" / "meta"
    frames_rgb_dir = bundle_dir / "frames" / "rgb"
    frames_depth_dir = bundle_dir / "frames" / "depth"
    frames_confidence_dir = bundle_dir / "frames" / "confidence"

    if use_keyframes:
        frame_ids = sorted([int(p.stem) for p in keyframes_dir.glob("*.jpg")])
    else:
        frame_ids = sorted([int(p.stem) for p in frames_rgb_dir.glob("*.jpg")])

    frame_ids = frame_ids[:: max(1, frame_stride)]
    if max_frames:
        frame_ids = frame_ids[:max_frames]

    dataset_name = bundle_dir.name
    dataset_dir = dataset_root / dataset_name
    images_dir = dataset_dir / "images"
    depth_out_dir = dataset_dir / "depth"
    confidence_out_dir = dataset_dir / "confidence"
    images_dir.mkdir(parents=True, exist_ok=True)
    depth_out_dir.mkdir(parents=True, exist_ok=True)
    confidence_out_dir.mkdir(parents=True, exist_ok=True)

    frames = []
    intrinsics_list = []

    for frame_id in frame_ids:
        meta = _load_frame_meta(frames_meta_dir, frame_id)
        fx, fy, cx, cy, w, h = _intrinsics_from_meta(meta)
        intrinsics_list.append([fx, fy, cx, cy, w, h])

        src_img = frames_rgb_dir / f"{frame_id:06d}.jpg"
        if not src_img.exists() and use_keyframes:
            src_img = keyframes_dir / f"{frame_id:06d}.jpg"
        dst_img = images_dir / f"{frame_id:06d}.jpg"
        if not dst_img.exists():
            shutil.copy2(src_img, dst_img)

        t_cam_world = _rows_to_matrix(meta["camera"]["transform"])
        t_cam_anchor = np.linalg.inv(t_root_world) @ t_cam_world
        if apply_camera_axis_conversion:
            t_cam_anchor = t_cam_anchor @ np.diag([1.0, 1.0, -1.0, 1.0]).astype(np.float32)

        frame_entry = {
            "file_path": f"images/{frame_id:06d}.jpg",
            "transform_matrix": t_cam_anchor.tolist(),
        }

        depth_src = frames_depth_dir / f"{frame_id:06d}.png"
        if depth_src.exists():
            depth_dst = depth_out_dir / f"{frame_id:06d}.png"
            if not depth_dst.exists():
                shutil.copy2(depth_src, depth_dst)
            frame_entry["depth_file_path"] = f"depth/{frame_id:06d}.png"

            if use_confidence:
                confidence_src = frames_confidence_dir / f"{frame_id:06d}.png"
                if confidence_src.exists():
                    confidence_dst = confidence_out_dir / f"{frame_id:06d}.png"
                    if not confidence_dst.exists():
                        shutil.copy2(confidence_src, confidence_dst)
                    frame_entry["confidence_file_path"] = f"confidence/{frame_id:06d}.png"

        frames.append(frame_entry)

    intrinsics_arr = np.array(intrinsics_list)
    max_spread = intrinsics_arr.max(axis=0) - intrinsics_arr.min(axis=0)
    use_per_frame = (
        use_per_frame_intrinsics
        or np.any(max_spread[:4] > intrinsics_spread_threshold)
        or np.any(max_spread[4:] > 0)
    )

    if use_per_frame:
        for frame_entry, (fx, fy, cx, cy, w, h) in zip(frames, intrinsics_list):
            frame_entry.update(
                {
                    "fl_x": float(fx),
                    "fl_y": float(fy),
                    "cx": float(cx),
                    "cy": float(cy),
                    "w": int(w),
                    "h": int(h),
                }
            )
        transforms = {
            "camera_model": "OPENCV",
            "ply_file_path": "sparse_pc.ply",
            "frames": frames,
        }
    else:
        fx, fy, cx, cy, w, h = intrinsics_list[0]
        transforms = {
            "camera_model": "OPENCV",
            "fl_x": float(fx),
            "fl_y": float(fy),
            "cx": float(cx),
            "cy": float(cy),
            "w": int(w),
            "h": int(h),
            "ply_file_path": "sparse_pc.ply",
            "frames": frames,
        }

    _save_json(dataset_dir / "transforms.json", transforms)

    if build_sparse_pc:
        _build_sparse_point_cloud(
            bundle_dir=bundle_dir,
            dataset_dir=dataset_dir,
            t_root_world=t_root_world,
            apply_camera_axis_conversion=apply_camera_axis_conversion,
            use_confidence=use_confidence,
            min_confidence=min_confidence,
            depth_stride=depth_stride,
            min_depth_m=min_depth_m,
            max_depth_m=max_depth_m,
            voxel_size_m=voxel_size_m,
            max_points_per_frame=max_points_per_frame,
        )

    return dataset_dir


def _distortion_params_from_frame(meta: dict, frame: dict) -> np.ndarray:
    if "distortion_params" in frame:
        params = frame["distortion_params"]
    elif "distortion_params" in meta:
        params = meta["distortion_params"]
    else:
        params = [
            frame.get("k1", meta.get("k1", 0.0)),
            frame.get("k2", meta.get("k2", 0.0)),
            frame.get("k3", meta.get("k3", 0.0)),
            frame.get("k4", meta.get("k4", 0.0)),
            frame.get("p1", meta.get("p1", 0.0)),
            frame.get("p2", meta.get("p2", 0.0)),
        ]
    return np.array(params, dtype=np.float32)


def _intrinsics_from_frame(meta: dict, frame: dict) -> Tuple[float, float, float, float, int, int]:
    fx = frame.get("fl_x", meta.get("fl_x"))
    fy = frame.get("fl_y", meta.get("fl_y"))
    cx = frame.get("cx", meta.get("cx"))
    cy = frame.get("cy", meta.get("cy"))
    w = frame.get("w", meta.get("w"))
    h = frame.get("h", meta.get("h"))
    if any(v is None for v in (fx, fy, cx, cy, w, h)):
        missing = [k for k, v in (("fl_x", fx), ("fl_y", fy), ("cx", cx), ("cy", cy), ("w", w), ("h", h)) if v is None]
        raise ValueError(f"Missing intrinsics fields: {missing}")
    return float(fx), float(fy), float(cx), float(cy), int(w), int(h)


def _build_maps(
    w: int,
    h: int,
    fx: float,
    fy: float,
    cx: float,
    cy: float,
    distortion_params: np.ndarray,
) -> Tuple[Optional[np.ndarray], Optional[np.ndarray], np.ndarray, Tuple[int, int, int, int]]:
    K = np.array([[fx, 0.0, cx], [0.0, fy, cy], [0.0, 0.0, 1.0]], dtype=np.float32)
    K[0, 2] -= 0.5
    K[1, 2] -= 0.5

    if distortion_params.shape[0] < 6:
        raise ValueError("distortion_params must have at least 6 values")
    if distortion_params[3] != 0:
        raise ValueError("k4 (distortion_params[3]) must be 0 for perspective undistort")

    dist = np.array(
        [
            distortion_params[0],
            distortion_params[1],
            distortion_params[4],
            distortion_params[5],
            distortion_params[2],
        ],
        dtype=np.float32,
    )

    if np.any(dist):
        newK, roi = cv2.getOptimalNewCameraMatrix(K, dist, (w, h), 0)
        map1, map2 = cv2.initUndistortRectifyMap(
            K,
            dist,
            None,
            newK,
            (w, h),
            cv2.CV_32FC1,
        )
    else:
        newK = K
        roi = (0, 0, w, h)
        map1, map2 = None, None

    x, y, rw, rh = roi
    newK = newK.copy()
    newK[0, 2] -= x
    newK[1, 2] -= y
    newK[0, 2] += 0.5
    newK[1, 2] += 0.5
    return map1, map2, newK, (x, y, rw, rh)


def _apply_map(image: np.ndarray, map1: Optional[np.ndarray], map2: Optional[np.ndarray]) -> np.ndarray:
    if map1 is None or map2 is None:
        return image
    return cv2.remap(image, map1, map2, interpolation=cv2.INTER_LINEAR)


def _resolve_depth_target_size(
    mode: str,
    source_h: int,
    source_w: int,
    image_h: int,
    image_w: int,
    max_edge: int,
) -> Tuple[int, int]:
    if mode == "image":
        return image_h, image_w
    if mode == "native":
        return source_h, source_w
    if mode == "max_edge":
        max_edge = max(1, int(max_edge))
        max_source = max(source_h, source_w)
        if max_source <= max_edge:
            return source_h, source_w
        scale = max_edge / float(max_source)
        target_h = max(1, int(round(source_h * scale)))
        target_w = max(1, int(round(source_w * scale)))
        return target_h, target_w
    raise ValueError(f"Unknown depth resize mode: {mode}")


def _process_frame(
    frame: dict,
    meta: dict,
    input_dir: Path,
    output_dir: Path,
    depth_resize_mode: str,
    depth_max_edge: int,
    skip_undistort: bool,
    skip_confidence: bool,
    map_cache: Dict[Tuple, Tuple[Optional[np.ndarray], Optional[np.ndarray], np.ndarray, Tuple[int, int, int, int]]],
) -> Tuple[dict, Tuple[int, int, float, float, float, float]]:
    image_path = input_dir / frame["file_path"]
    if not image_path.exists():
        raise FileNotFoundError(f"Missing image: {image_path}")

    image = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
    if image is None:
        raise RuntimeError(f"Failed to read image {image_path}")

    fx, fy, cx, cy, w, h = _intrinsics_from_frame(meta, frame)
    distortion_params = _distortion_params_from_frame(meta, frame)

    if (image.shape[1], image.shape[0]) != (w, h):
        w, h = image.shape[1], image.shape[0]

    if skip_undistort or not np.any(distortion_params):
        map1, map2, newK, roi = None, None, np.array([[fx, 0.0, cx], [0.0, fy, cy], [0.0, 0.0, 1.0]], dtype=np.float32), (0, 0, w, h)
        undistorted = image
    else:
        cache_key = (w, h, fx, fy, cx, cy, tuple(distortion_params.tolist()))
        if cache_key in map_cache:
            map1, map2, newK, roi = map_cache[cache_key]
        else:
            map1, map2, newK, roi = _build_maps(w, h, fx, fy, cx, cy, distortion_params)
            map_cache[cache_key] = (map1, map2, newK, roi)

        undistorted = _apply_map(image, map1, map2)

    x, y, rw, rh = roi
    undistorted = undistorted[y : y + rh, x : x + rw]

    out_image_path = output_dir / frame["file_path"]
    out_image_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out_image_path), undistorted)

    if "mask_path" in frame:
        mask_path = input_dir / frame["mask_path"]
        if mask_path.exists():
            mask = cv2.imread(str(mask_path), cv2.IMREAD_UNCHANGED)
            if mask is not None:
                if map1 is not None and map2 is not None:
                    mask = cv2.remap(mask, map1, map2, interpolation=cv2.INTER_NEAREST)
                mask = mask[y : y + rh, x : x + rw]
                out_mask_path = output_dir / frame["mask_path"]
                out_mask_path.parent.mkdir(parents=True, exist_ok=True)
                cv2.imwrite(str(out_mask_path), mask)

    if "depth_file_path" in frame:
        depth_path = input_dir / frame["depth_file_path"]
        if depth_path.exists():
            depth = cv2.imread(str(depth_path), cv2.IMREAD_UNCHANGED)
            if depth is not None:
                target_h, target_w = _resolve_depth_target_size(
                    depth_resize_mode,
                    depth.shape[0],
                    depth.shape[1],
                    undistorted.shape[0],
                    undistorted.shape[1],
                    depth_max_edge,
                )
                if depth.shape[0] != target_h or depth.shape[1] != target_w:
                    depth = cv2.resize(depth, (target_w, target_h), interpolation=cv2.INTER_NEAREST)
                out_depth_path = output_dir / frame["depth_file_path"]
                out_depth_path.parent.mkdir(parents=True, exist_ok=True)
                cv2.imwrite(str(out_depth_path), depth)

    if not skip_confidence and "confidence_file_path" in frame:
        conf_path = input_dir / frame["confidence_file_path"]
        if conf_path.exists():
            conf = cv2.imread(str(conf_path), cv2.IMREAD_UNCHANGED)
            if conf is not None:
                target_h, target_w = _resolve_depth_target_size(
                    depth_resize_mode,
                    conf.shape[0],
                    conf.shape[1],
                    undistorted.shape[0],
                    undistorted.shape[1],
                    depth_max_edge,
                )
                if conf.shape[0] != target_h or conf.shape[1] != target_w:
                    conf = cv2.resize(conf, (target_w, target_h), interpolation=cv2.INTER_NEAREST)
                out_conf_path = output_dir / frame["confidence_file_path"]
                out_conf_path.parent.mkdir(parents=True, exist_ok=True)
                cv2.imwrite(str(out_conf_path), conf)

    new_fx = float(newK[0, 0])
    new_fy = float(newK[1, 1])
    new_cx = float(newK[0, 2])
    new_cy = float(newK[1, 2])

    return frame, (undistorted.shape[1], undistorted.shape[0], new_fx, new_fy, new_cx, new_cy)


def _precompute_dataset(
    input_dir: Path,
    output_dir: Path,
    depth_resize_mode: str,
    depth_max_edge: int,
    skip_undistort: bool,
    skip_confidence: bool,
    cv2_threads: Optional[int],
    workers: Optional[int],
) -> None:
    transforms_path = input_dir / "transforms.json"
    if not transforms_path.exists():
        raise FileNotFoundError(f"Missing transforms.json at {transforms_path}")

    if cv2_threads is not None:
        cv2.setNumThreads(cv2_threads)

    meta = _load_json(transforms_path)
    frames = meta.get("frames", [])
    if not frames:
        raise ValueError("transforms.json has no frames")

    camera_model = str(meta.get("camera_model", "")).lower()
    if "fisheye" in camera_model and not skip_undistort:
        print("Warning: fisheye camera model detected; skipping undistort in precompute.")
        skip_undistort = True

    map_cache: Dict[Tuple, Tuple[Optional[np.ndarray], Optional[np.ndarray], np.ndarray, Tuple[int, int, int, int]]] = {}

    def worker(idx: int, frame: dict):
        frame_copy = dict(frame)
        updated_frame, (w, h, fx, fy, cx, cy) = _process_frame(
            frame=frame_copy,
            meta=meta,
            input_dir=input_dir,
            output_dir=output_dir,
            depth_resize_mode=depth_resize_mode,
            depth_max_edge=depth_max_edge,
            skip_undistort=skip_undistort,
            skip_confidence=skip_confidence,
            map_cache=map_cache,
        )

        updated_frame["w"] = int(w)
        updated_frame["h"] = int(h)
        updated_frame["fl_x"] = float(fx)
        updated_frame["fl_y"] = float(fy)
        updated_frame["cx"] = float(cx)
        updated_frame["cy"] = float(cy)
        updated_frame["distortion_params"] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        for key in ("k1", "k2", "k3", "k4", "p1", "p2"):
            updated_frame.pop(key, None)

        return idx, updated_frame

    max_workers = workers or (os.cpu_count() or 4)
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        results = executor.map(lambda pair: worker(*pair), enumerate(frames))
        processed = list(results)

    processed.sort(key=lambda x: x[0])
    processed_frames = [frame for _, frame in processed]

    for key in (
        "fl_x",
        "fl_y",
        "cx",
        "cy",
        "w",
        "h",
        "k1",
        "k2",
        "k3",
        "k4",
        "p1",
        "p2",
        "distortion_params",
    ):
        meta.pop(key, None)

    meta["frames"] = processed_frames
    _save_json(output_dir / "transforms.json", meta)

    info = {
        "source": str(input_dir),
        "depth_resize_mode": depth_resize_mode,
        "depth_max_edge": depth_max_edge,
        "skip_undistort": skip_undistort,
        "skip_confidence": skip_confidence,
        "version": 1,
    }
    _save_json(output_dir / "precomputed.json", info)

    for filename in ("sparse_pc.ply", "points3D.ply"):
        src = input_dir / filename
        if src.exists():
            shutil.copy2(src, output_dir / filename)

    colmap_dir = input_dir / "colmap"
    if colmap_dir.exists():
        shutil.copytree(colmap_dir, output_dir / "colmap", dirs_exist_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Precompute training-ready Nerfstudio dataset")
    parser.add_argument("--data", type=Path, help="Input nerfstudio dataset dir")
    parser.add_argument("--gdrive-url", type=str, help="Google Drive URL for raw CaptureBundle zip")
    parser.add_argument("--bundle-zip", type=Path, help="Path to raw CaptureBundle zip")
    parser.add_argument("--work-dir", type=Path, default=Path.cwd(), help="Working directory for downloads/extract")
    parser.add_argument("--output", type=Path, required=True, help="Output preprocessed dataset dir")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite output if it exists")
    parser.add_argument("--keep-intermediate", action="store_true", help="Keep intermediate dataset when building from raw")

    # Raw bundle -> dataset options
    parser.add_argument("--use-keyframes", action="store_true", help="Use keyframes only")
    parser.add_argument("--frame-stride", type=int, default=1)
    parser.add_argument("--max-frames", type=int, default=0)
    parser.add_argument("--use-confidence", action="store_true")
    parser.add_argument("--no-confidence", dest="use_confidence", action="store_false")
    parser.add_argument("--min-confidence", type=int, default=1)
    parser.add_argument("--use-per-frame-intrinsics", action="store_true")
    parser.add_argument("--no-per-frame-intrinsics", dest="use_per_frame_intrinsics", action="store_false")
    parser.add_argument("--intrinsics-spread-threshold", type=float, default=0.5)
    parser.add_argument("--apply-camera-axis-conversion", action="store_true")
    parser.add_argument("--build-sparse-pc", action="store_true")
    parser.add_argument("--no-build-sparse-pc", dest="build_sparse_pc", action="store_false")
    parser.add_argument("--depth-stride", type=int, default=2)
    parser.add_argument("--min-depth-m", type=float, default=0.2)
    parser.add_argument("--max-depth-m", type=float, default=5.0)
    parser.add_argument("--voxel-size-m", type=float, default=0.01)
    parser.add_argument("--max-points-per-frame", type=int, default=300000)

    # Precompute options
    parser.add_argument("--depth-resize-mode", choices=["image", "native", "max_edge"], default="image")
    parser.add_argument("--depth-max-edge", type=int, default=480)
    parser.add_argument("--skip-undistort", action="store_true", help="Skip undistortion (copies images)")
    parser.add_argument("--skip-confidence", action="store_true", help="Skip confidence map processing")
    parser.add_argument("--cv2-threads", type=int, default=None, help="Override OpenCV thread count")
    parser.add_argument("--workers", type=int, default=None, help="Number of worker threads")
    parser.set_defaults(use_confidence=True, use_per_frame_intrinsics=True, build_sparse_pc=True)
    args = parser.parse_args()

    if args.output.exists() and args.overwrite:
        shutil.rmtree(args.output)
    args.output.mkdir(parents=True, exist_ok=True)

    dataset_dir: Optional[Path] = None
    intermediate_dir: Optional[Path] = None

    if args.data:
        dataset_dir = args.data
    elif args.gdrive_url or args.bundle_zip:
        work_dir = args.work_dir
        downloads_dir = work_dir / "downloads"
        extract_dir = work_dir / "bundles"
        downloads_dir.mkdir(parents=True, exist_ok=True)
        extract_dir.mkdir(parents=True, exist_ok=True)

        if args.bundle_zip:
            zip_path = args.bundle_zip
        else:
            zip_path = downloads_dir / "capture_bundle.zip"
            zip_path = _download_from_gdrive(args.gdrive_url, zip_path)

        bundle_root = extract_dir / zip_path.stem
        if not bundle_root.exists():
            _extract_zip(zip_path, bundle_root)

        bundle_dir = _find_capture_bundle(bundle_root)
        dataset_root = work_dir / "nerfstudio_dataset"
        dataset_root.mkdir(parents=True, exist_ok=True)
        dataset_dir = _build_dataset_from_bundle(
            bundle_dir=bundle_dir,
            dataset_root=dataset_root,
            use_keyframes=args.use_keyframes,
            frame_stride=args.frame_stride,
            max_frames=args.max_frames or None,
            use_confidence=args.use_confidence,
            min_confidence=args.min_confidence,
            use_per_frame_intrinsics=args.use_per_frame_intrinsics,
            intrinsics_spread_threshold=args.intrinsics_spread_threshold,
            apply_camera_axis_conversion=args.apply_camera_axis_conversion,
            build_sparse_pc=args.build_sparse_pc,
            depth_stride=args.depth_stride,
            min_depth_m=args.min_depth_m,
            max_depth_m=args.max_depth_m,
            voxel_size_m=args.voxel_size_m,
            max_points_per_frame=args.max_points_per_frame,
        )
        intermediate_dir = dataset_dir
    else:
        raise ValueError("Provide --data or --gdrive-url/--bundle-zip.")

    if dataset_dir is None:
        raise RuntimeError("Dataset directory could not be resolved.")

    _precompute_dataset(
        input_dir=dataset_dir,
        output_dir=args.output,
        depth_resize_mode=args.depth_resize_mode,
        depth_max_edge=args.depth_max_edge,
        skip_undistort=args.skip_undistort,
        skip_confidence=args.skip_confidence,
        cv2_threads=args.cv2_threads,
        workers=args.workers,
    )

    if intermediate_dir and not args.keep_intermediate:
        shutil.rmtree(intermediate_dir, ignore_errors=True)

    print("Precompute complete.")
    print(f"Output: {args.output}")


if __name__ == "__main__":
    main()
