#!/usr/bin/env python3
"""
Patch nerfstudio in the current Python environment with DreamBrush overrides.

This script replaces nerfstudio's splatfacto model with the customized version
in refs/splatfacto.py (depth loss + camera optimizer flags).
"""

from __future__ import annotations

import inspect
from pathlib import Path


def replace_file(src: Path, dst: Path) -> None:
    if not src.exists():
        raise FileNotFoundError(f"Missing source patch file: {src}")
    if not dst.exists():
        raise FileNotFoundError(f"Target file not found: {dst}")

    backup = dst.with_suffix(dst.suffix + ".bak")
    if not backup.exists():
        backup.write_text(dst.read_text())

    dst.write_text(src.read_text())
    print(f"Patched {dst}")
    print(f"Backup: {backup}")


def main() -> None:
    import nerfstudio  # type: ignore

    cwd_root = Path.cwd()
    script_root = Path(__file__).resolve().parent

    def locate_patch(name: str) -> Path:
        primary = cwd_root / name
        if primary.exists():
            return primary
        return script_root / name

    splat_patch = locate_patch("splatfacto.py")

    # Locate installed nerfstudio splatfacto.py
    import nerfstudio.models.splatfacto as splatfacto  # type: ignore

    splat_path = Path(inspect.getsourcefile(splatfacto) or "")
    if not splat_path.exists():
        raise FileNotFoundError("Could not locate nerfstudio.models.splatfacto")

    replace_file(splat_patch, splat_path)

    # Patch nerfstudio_dataparser to include confidence filenames if provided.
    dataparser_patch = locate_patch("nerfstudio_dataparser.py")
    if dataparser_patch.exists():
        import nerfstudio.data.dataparsers.nerfstudio_dataparser as dp  # type: ignore

        dp_path = Path(inspect.getsourcefile(dp) or "")
        if dp_path.exists():
            replace_file(dataparser_patch, dp_path)

    # Optional: patch datamanager if a local patch exists.
    datamanager_patch = locate_patch("full_images_datamanager.py")
    if datamanager_patch.exists():
        import nerfstudio.data.datamanagers.full_images_datamanager as dm  # type: ignore

        dm_path = Path(inspect.getsourcefile(dm) or "")
        if dm_path.exists():
            replace_file(datamanager_patch, dm_path)


if __name__ == "__main__":
    main()
