#!/usr/bin/env python3
"""
Check camera convention consistency by cross-frame reprojection using depth.

This script samples 3D points from frame A depth, transforms them into frame B
using poses, then compares predicted depth in frame B to the measured depth map.
It evaluates multiple camera axis and matrix interpretation conventions to help
spot mismatches (e.g., +Z vs -Z, Y up vs down, row-major vs column-major).
"""

from __future__ import annotations

import argparse
import json
import os
import random
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Tuple

import numpy as np

try:
    import imageio.v3 as iio
except Exception:  # pragma: no cover - optional dependency
    iio = None
    try:
        from PIL import Image
    except Exception:  # pragma: no cover
        Image = None


@dataclass
class FrameData:
    index: int
    meta: dict
    depth: np.ndarray
    rgb_w: int
    rgb_h: int
    depth_w: int
    depth_h: int
    K_rgb: np.ndarray
    K_depth: np.ndarray
    T_raw: np.ndarray


@dataclass
class PairData:
    a: int
    b: int
    samples: List[Tuple[int, int, float]]  # (u_d, v_d, depth_m)


def load_json(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def read_depth_png(path: str) -> np.ndarray:
    if iio is not None:
        arr = iio.imread(path)
    elif Image is not None:
        img = Image.open(path)
        arr = np.array(img)
    else:
        raise RuntimeError(
            "Missing image reader. Install `imageio` (recommended) or `Pillow`."
        )
    if arr.dtype != np.uint16:
        arr = arr.astype(np.uint16)
    if arr.ndim != 2:
        raise ValueError(f"Depth image must be single-channel, got shape {arr.shape}")
    return arr


def scale_intrinsics(K: np.ndarray, rgb_w: int, rgb_h: int, depth_w: int, depth_h: int) -> np.ndarray:
    sx = depth_w / float(rgb_w)
    sy = depth_h / float(rgb_h)
    Kd = K.copy().astype(np.float64)
    Kd[0, 0] *= sx
    Kd[0, 2] *= sx
    Kd[1, 1] *= sy
    Kd[1, 2] *= sy
    return Kd


def list_depth_frames(meta_dir: str, depth_dir: str) -> List[int]:
    indices = []
    for name in sorted(os.listdir(meta_dir)):
        if not name.endswith(".json"):
            continue
        stem = os.path.splitext(name)[0]
        try:
            idx = int(stem)
        except ValueError:
            continue
        depth_path = os.path.join(depth_dir, f"{idx:06d}.png")
        if os.path.exists(depth_path):
            indices.append(idx)
    return indices


def choose_pairs(indices: List[int], pairs: int, stride: int) -> List[Tuple[int, int]]:
    max_start = len(indices) - stride - 1
    if max_start < 0:
        return []
    valid_starts = list(range(0, max_start + 1))
    if not valid_starts:
        return []
    if pairs <= 0:
        return []
    if pairs >= len(valid_starts):
        chosen_starts = valid_starts
    elif pairs == 1:
        chosen_starts = [valid_starts[len(valid_starts) // 2]]
    else:
        # Evenly spaced selections across valid starts
        chosen_starts = []
        for k in range(pairs):
            idx = int(round(k * (len(valid_starts) - 1) / (pairs - 1)))
            chosen_starts.append(valid_starts[idx])
        # Deduplicate if rounding caused repeats
        seen = set()
        chosen_starts = [s for s in chosen_starts if not (s in seen or seen.add(s))]

    return [(indices[i], indices[i + stride]) for i in chosen_starts]


def sample_depth_points(depth: np.ndarray, count: int, rng: random.Random) -> List[Tuple[int, int, float]]:
    ys, xs = np.where(depth > 0)
    if len(xs) == 0:
        return []
    total = len(xs)
    if count >= total:
        choices = list(range(total))
    else:
        choices = rng.sample(range(total), count)
    out = []
    for idx in choices:
        x = int(xs[idx])
        y = int(ys[idx])
        z_mm = int(depth[y, x])
        if z_mm <= 0:
            continue
        out.append((x, y, z_mm / 1000.0))
    return out


def unproject(
    u: float,
    v: float,
    depth_m: float,
    K: np.ndarray,
    sign_y: int,
    sign_z: int,
) -> np.ndarray:
    fx = K[0, 0]
    fy = K[1, 1]
    cx = K[0, 2]
    cy = K[1, 2]
    z = depth_m * float(sign_z)
    x = (u - cx) / fx * z
    y = (v - cy) / fy * z * float(sign_y)
    return np.array([x, y, z, 1.0], dtype=np.float64)


def project(
    p_cam: np.ndarray,
    K: np.ndarray,
    sign_y: int,
) -> Tuple[float, float]:
    x, y, z = p_cam[0], p_cam[1], p_cam[2]
    u = K[0, 0] * (x / z) + K[0, 2]
    v = K[1, 1] * (y / z) * float(sign_y) + K[1, 2]
    return u, v


def build_frame_data(bundle: str, indices: Iterable[int]) -> Dict[int, FrameData]:
    meta_dir = os.path.join(bundle, "frames", "meta")
    depth_dir = os.path.join(bundle, "frames", "depth")
    out: Dict[int, FrameData] = {}
    for idx in indices:
        meta_path = os.path.join(meta_dir, f"{idx:06d}.json")
        depth_path = os.path.join(depth_dir, f"{idx:06d}.png")
        meta = load_json(meta_path)
        depth = read_depth_png(depth_path)
        rgb_w = int(meta["camera"]["imageResolution"]["width"])
        rgb_h = int(meta["camera"]["imageResolution"]["height"])
        depth_h, depth_w = depth.shape
        K_rgb = np.array(meta["camera"]["intrinsics"], dtype=np.float64)
        K_depth = scale_intrinsics(K_rgb, rgb_w, rgb_h, depth_w, depth_h)
        T_raw = np.array(meta["camera"]["transform"], dtype=np.float64)
        out[idx] = FrameData(
            index=idx,
            meta=meta,
            depth=depth,
            rgb_w=rgb_w,
            rgb_h=rgb_h,
            depth_w=depth_w,
            depth_h=depth_h,
            K_rgb=K_rgb,
            K_depth=K_depth,
            T_raw=T_raw,
        )
    return out


def interpret_c2w(T_raw: np.ndarray, layout: str, direction: str) -> np.ndarray:
    if layout == "column":
        T = T_raw.T
    else:
        T = T_raw
    if direction == "w2c":
        T = np.linalg.inv(T)
    return T


def evaluate_combo(
    frames: Dict[int, FrameData],
    pairs: List[PairData],
    layout: str,
    direction: str,
    sign_y: int,
    sign_z: int,
    use_pixel_center: bool,
    max_depth_m: Optional[float],
) -> dict:
    errors: List[float] = []
    attempted = 0
    projected = 0
    compared = 0

    # Precompute c2w per frame for this interpretation
    c2w: Dict[int, np.ndarray] = {}
    w2c: Dict[int, np.ndarray] = {}
    for idx, frame in frames.items():
        c2w_i = interpret_c2w(frame.T_raw, layout, direction)
        c2w[idx] = c2w_i
        w2c[idx] = np.linalg.inv(c2w_i)

    for pair in pairs:
        fa = frames[pair.a]
        fb = frames[pair.b]
        for u_d, v_d, depth_m in pair.samples:
            attempted += 1
            if max_depth_m is not None and depth_m > max_depth_m:
                continue
            u = float(u_d) + (0.5 if use_pixel_center else 0.0)
            v = float(v_d) + (0.5 if use_pixel_center else 0.0)
            p_cam_a = unproject(u, v, depth_m, fa.K_depth, sign_y, sign_z)
            p_world = c2w[fa.index] @ p_cam_a
            p_cam_b = w2c[fb.index] @ p_world
            z_cam_b = float(p_cam_b[2])
            if sign_z * z_cam_b <= 1e-6:
                continue
            projected += 1
            u_rgb, v_rgb = project(p_cam_b, fb.K_rgb, sign_y)
            if not (0.0 <= u_rgb < fb.rgb_w and 0.0 <= v_rgb < fb.rgb_h):
                continue
            u_depth = int(round(u_rgb * fb.depth_w / fb.rgb_w))
            v_depth = int(round(v_rgb * fb.depth_h / fb.rgb_h))
            if not (0 <= u_depth < fb.depth_w and 0 <= v_depth < fb.depth_h):
                continue
            z_mm = int(fb.depth[v_depth, u_depth])
            if z_mm <= 0:
                continue
            compared += 1
            z_meas = z_mm / 1000.0
            z_pred = sign_z * z_cam_b
            errors.append(abs(z_pred - z_meas))

    if errors:
        errs = np.array(errors)
        mean_err = float(np.mean(errs))
        med_err = float(np.median(errs))
        pct_2 = float(np.mean(errs < 0.02))
        pct_5 = float(np.mean(errs < 0.05))
        pct_10 = float(np.mean(errs < 0.10))
    else:
        mean_err = med_err = pct_2 = pct_5 = pct_10 = float("nan")

    return {
        "layout": layout,
        "direction": direction,
        "sign_y": sign_y,
        "sign_z": sign_z,
        "attempted": attempted,
        "projected": projected,
        "compared": compared,
        "mean_err": mean_err,
        "median_err": med_err,
        "pct_2cm": pct_2,
        "pct_5cm": pct_5,
        "pct_10cm": pct_10,
        "errors": errors,
    }


def format_summary(res: dict) -> str:
    def pct(x: float) -> str:
        if np.isnan(x):
            return "nan"
        return f"{x*100:.1f}%"

    def cm(x: float) -> str:
        if np.isnan(x):
            return "nan"
        return f"{x*100:.2f}cm"

    return (
        f"layout={res['layout']}, dir={res['direction']}, "
        f"sign_z={res['sign_z']:+d}, sign_y={res['sign_y']:+d} | "
        f"compared={res['compared']}/{res['attempted']} "
        f"mean={cm(res['mean_err'])} median={cm(res['median_err'])} "
        f"<2cm={pct(res['pct_2cm'])} <5cm={pct(res['pct_5cm'])} <10cm={pct(res['pct_10cm'])}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Cross-frame depth reprojection sanity check")
    parser.add_argument("bundle", nargs="?", default=None, help="Path to CaptureBundle_*")
    parser.add_argument("--pairs", type=int, default=3, help="Number of frame pairs to test")
    parser.add_argument("--pair-stride", type=int, default=1, help="Stride between pair frames")
    parser.add_argument("--samples", type=int, default=500, help="Samples per pair")
    parser.add_argument("--seed", type=int, default=0, help="RNG seed for sampling")
    parser.add_argument("--max-depth", type=float, default=None, help="Ignore samples beyond this depth (meters)")
    parser.add_argument("--no-pixel-center", action="store_true", help="Use integer pixel corner coordinates")
    parser.add_argument("--layouts", default="row,column", help="Comma list: row,column")
    parser.add_argument("--directions", default="c2w,w2c", help="Comma list: c2w,w2c")
    parser.add_argument("--sign-y", default="-1,1", help="Comma list of Y signs (image down vs up)")
    parser.add_argument("--sign-z", default="1,-1", help="Comma list of Z signs (forward vs backward)")
    args = parser.parse_args()

    bundle = args.bundle
    if bundle is None:
        # Default to the first matching sample bundle.
        samples_dir = os.path.join(os.getcwd(), "export_bundle_samples")
        if os.path.isdir(samples_dir):
            for name in sorted(os.listdir(samples_dir)):
                if name.startswith("CaptureBundle_"):
                    bundle = os.path.join(samples_dir, name)
                    break
    if bundle is None or not os.path.isdir(bundle):
        raise SystemExit("Capture bundle not found. Provide a path to CaptureBundle_*.")

    meta_dir = os.path.join(bundle, "frames", "meta")
    depth_dir = os.path.join(bundle, "frames", "depth")
    if not os.path.isdir(meta_dir) or not os.path.isdir(depth_dir):
        raise SystemExit("Invalid bundle: missing frames/meta or frames/depth")

    indices = list_depth_frames(meta_dir, depth_dir)
    if not indices:
        raise SystemExit("No depth frames found in bundle")

    pairs_idx = choose_pairs(indices, args.pairs, args.pair_stride)
    if not pairs_idx:
        raise SystemExit("Not enough frames to form pairs with the given stride")

    frame_indices = set([i for p in pairs_idx for i in p])
    frames = build_frame_data(bundle, frame_indices)

    rng = random.Random(args.seed)
    pairs: List[PairData] = []
    for a, b in pairs_idx:
        fa = frames[a]
        samples = sample_depth_points(fa.depth, args.samples, rng)
        pairs.append(PairData(a=a, b=b, samples=samples))

    layouts = [s.strip() for s in args.layouts.split(",") if s.strip()]
    directions = [s.strip() for s in args.directions.split(",") if s.strip()]
    sign_y_list = [int(s.strip()) for s in args.sign_y.split(",") if s.strip()]
    sign_z_list = [int(s.strip()) for s in args.sign_z.split(",") if s.strip()]

    print(f"Bundle: {bundle}")
    print(f"Depth frames: {len(indices)} | Testing pairs: {pairs_idx}")
    print(f"Samples per pair: {args.samples} | stride={args.pair_stride} | seed={args.seed}")
    print("-")

    results = []
    for layout in layouts:
        for direction in directions:
            for sign_y in sign_y_list:
                for sign_z in sign_z_list:
                    res = evaluate_combo(
                        frames,
                        pairs,
                        layout=layout,
                        direction=direction,
                        sign_y=sign_y,
                        sign_z=sign_z,
                        use_pixel_center=not args.no_pixel_center,
                        max_depth_m=args.max_depth,
                    )
                    results.append(res)
                    print(format_summary(res))

    # Rank by median error then mean error (lower is better)
    ranked = sorted(
        results,
        key=lambda r: (
            float("inf") if np.isnan(r["median_err"]) else r["median_err"],
            float("inf") if np.isnan(r["mean_err"]) else r["mean_err"],
            -r["compared"],
        ),
    )

    print("-")
    print("Best candidates (lowest median depth error):")
    for res in ranked[:3]:
        print("  " + format_summary(res))


if __name__ == "__main__":
    main()
