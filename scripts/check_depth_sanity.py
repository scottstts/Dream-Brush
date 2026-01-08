#!/usr/bin/env python3
"""
Sanity-check depth PNG values in a CaptureBundle.

Reports per-frame depth statistics, saturation/zero rates, and compares
raw vs byte-swapped interpretations to detect endianness issues.
"""

from __future__ import annotations

import argparse
import os
import random
from dataclasses import dataclass
from typing import Iterable, List, Tuple

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
class FrameStats:
    frame_id: int
    zero_frac: float
    sat_frac: float
    over_10m_frac: float
    over_20m_frac: float
    min_m: float
    p01_m: float
    p05_m: float
    p50_m: float
    p95_m: float
    p99_m: float
    max_m: float
    swap_p50_m: float
    swap_p95_m: float


def read_depth_png(path: str) -> np.ndarray:
    if iio is not None:
        arr = iio.imread(path)
    elif Image is not None:
        img = Image.open(path)
        arr = np.array(img)
    else:
        raise RuntimeError("Missing image reader. Install `imageio` or `Pillow`.")
    if arr.dtype != np.uint16:
        arr = arr.astype(np.uint16)
    if arr.ndim != 2:
        raise ValueError(f"Depth image must be single-channel, got shape {arr.shape}")
    return arr


def list_depth_frames(depth_dir: str) -> List[int]:
    ids = []
    for name in sorted(os.listdir(depth_dir)):
        if not name.endswith(".png"):
            continue
        stem = os.path.splitext(name)[0]
        try:
            ids.append(int(stem))
        except ValueError:
            continue
    return ids


def choose_samples(indices: List[int], count: int, rng: random.Random) -> List[int]:
    if not indices:
        return []
    if count <= 0 or count >= len(indices):
        return indices
    # Evenly spread selection for deterministic coverage
    if count == 1:
        return [indices[len(indices) // 2]]
    chosen = []
    for k in range(count):
        idx = int(round(k * (len(indices) - 1) / (count - 1)))
        chosen.append(indices[idx])
    # Randomly jitter duplicates if rounding caused repeats
    uniq = []
    seen = set()
    for v in chosen:
        if v in seen:
            v = rng.choice(indices)
        uniq.append(v)
        seen.add(v)
    return uniq


def compute_stats(depth: np.ndarray) -> Tuple[float, float, float, float, float, float, float]:
    vals = depth[depth > 0].astype(np.float64)
    if vals.size == 0:
        return (float("nan"),) * 7
    p01, p05, p50, p95, p99 = np.percentile(vals, [1, 5, 50, 95, 99])
    return (
        float(vals.min()),
        float(p01),
        float(p05),
        float(p50),
        float(p95),
        float(p99),
        float(vals.max()),
    )


def to_meters(mm: float) -> float:
    return mm / 1000.0


def analyze_frame(frame_id: int, depth_path: str) -> FrameStats:
    depth = read_depth_png(depth_path)
    total = depth.size
    zeros = np.count_nonzero(depth == 0)
    sats = np.count_nonzero(depth == 65535)
    over_10m = np.count_nonzero(depth > 10000)
    over_20m = np.count_nonzero(depth > 20000)

    min_mm, p01_mm, p05_mm, p50_mm, p95_mm, p99_mm, max_mm = compute_stats(depth)

    # Byte-swapped check
    swapped = depth.byteswap()
    _, _, _, swap_p50_mm, swap_p95_mm, _, _ = compute_stats(swapped)

    return FrameStats(
        frame_id=frame_id,
        zero_frac=zeros / total,
        sat_frac=sats / total,
        over_10m_frac=over_10m / total,
        over_20m_frac=over_20m / total,
        min_m=to_meters(min_mm),
        p01_m=to_meters(p01_mm),
        p05_m=to_meters(p05_mm),
        p50_m=to_meters(p50_mm),
        p95_m=to_meters(p95_mm),
        p99_m=to_meters(p99_mm),
        max_m=to_meters(max_mm),
        swap_p50_m=to_meters(swap_p50_mm),
        swap_p95_m=to_meters(swap_p95_mm),
    )


def format_stats(s: FrameStats) -> str:
    return (
        f"{s.frame_id:06d} | "
        f"zero={s.zero_frac*100:.1f}% sat={s.sat_frac*100:.1f}% "
        f">10m={s.over_10m_frac*100:.1f}% >20m={s.over_20m_frac*100:.1f}% | "
        f"p50={s.p50_m:.2f}m p95={s.p95_m:.2f}m p99={s.p99_m:.2f}m max={s.max_m:.2f}m | "
        f"swap_p50={s.swap_p50_m:.2f}m swap_p95={s.swap_p95_m:.2f}m"
    )


def heuristic_verdict(stats: List[FrameStats]) -> str:
    if not stats:
        return "No frames analyzed."
    med_p50 = np.nanmedian([s.p50_m for s in stats])
    med_p95 = np.nanmedian([s.p95_m for s in stats])
    avg_zero = float(np.mean([s.zero_frac for s in stats]))
    avg_sat = float(np.mean([s.sat_frac for s in stats]))
    avg_over10 = float(np.mean([s.over_10m_frac for s in stats]))

    # Compare raw vs swapped plausibility
    swap_plausible = 0
    raw_plausible = 0
    for s in stats:
        if 0.2 <= s.swap_p50_m <= 6.0 and 0.5 <= s.swap_p95_m <= 20.0:
            swap_plausible += 1
        if 0.2 <= s.p50_m <= 6.0 and 0.5 <= s.p95_m <= 20.0:
            raw_plausible += 1

    lines = []
    lines.append(f"Aggregate: median p50={med_p50:.2f}m, median p95={med_p95:.2f}m")
    lines.append(f"Aggregate: avg zero={avg_zero*100:.1f}% sat={avg_sat*100:.1f}% >10m={avg_over10*100:.1f}%")

    if avg_zero > 0.8:
        lines.append("Verdict: depth mostly missing (very high zero rate).")
    elif avg_sat > 0.05:
        lines.append("Verdict: many saturated 65535 values; encoding or clipping looks off.")
    elif med_p50 > 20.0 or med_p95 > 50.0:
        lines.append("Verdict: depth values are implausibly large for indoor scenes.")
    elif swap_plausible > raw_plausible * 2 and swap_plausible >= max(2, len(stats) // 2):
        lines.append("Verdict: byte order likely wrong (swapped values look more plausible).")
    elif raw_plausible == 0:
        lines.append("Verdict: raw depth values look implausible; encoding/interpretation likely wrong.")
    else:
        lines.append("Verdict: raw depth values look plausible on these samples.")

    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description="Depth PNG sanity check")
    parser.add_argument("bundle", nargs="?", default=None, help="Path to CaptureBundle_*")
    parser.add_argument("--samples", type=int, default=5, help="Number of depth frames to sample")
    parser.add_argument("--seed", type=int, default=0, help="RNG seed for selection")
    args = parser.parse_args()

    bundle = args.bundle
    if bundle is None:
        samples_dir = os.path.join(os.getcwd(), "export_bundle_samples")
        if os.path.isdir(samples_dir):
            for name in sorted(os.listdir(samples_dir)):
                if name.startswith("CaptureBundle_"):
                    bundle = os.path.join(samples_dir, name)
                    break
    if bundle is None or not os.path.isdir(bundle):
        raise SystemExit("Capture bundle not found. Provide a path to CaptureBundle_*.")

    depth_dir = os.path.join(bundle, "frames", "depth")
    if not os.path.isdir(depth_dir):
        raise SystemExit("Invalid bundle: missing frames/depth")

    indices = list_depth_frames(depth_dir)
    if not indices:
        raise SystemExit("No depth frames found")

    rng = random.Random(args.seed)
    sample_ids = choose_samples(indices, args.samples, rng)
    print(f"Bundle: {bundle}")
    print(f"Depth frames: {len(indices)} | Sampling: {sample_ids}")
    print("-")

    stats = []
    for frame_id in sample_ids:
        depth_path = os.path.join(depth_dir, f"{frame_id:06d}.png")
        s = analyze_frame(frame_id, depth_path)
        stats.append(s)
        print(format_stats(s))

    print("-")
    print(heuristic_verdict(stats))


if __name__ == "__main__":
    main()
