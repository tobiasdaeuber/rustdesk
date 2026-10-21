#!/usr/bin/env python3
"""Render remotehelp/branding/icon.svg into every icon the Windows client uses, and the logos into the
logo the client shows at the top of its home page.

Needs Pillow and Microsoft Edge (headless rendering of the SVG). Run from anywhere:
    python remotehelp/branding/make_icons.py
The outputs are committed, so the CI build does not need to run this.

icon.svg, logo-light.png and logo-dark.png are copies of the RemoteHelp server repository's
wwwroot/img/remotehelp-icon.svg and branding/remotehelp-logo(-dark).png (rendered there by
tools/Render-Branding.ps1); copy them again when the branding changes there.
"""

import os
import subprocess
import tempfile
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
BRANDING = Path(__file__).resolve().parent
SVG = BRANDING / "icon.svg"
# The home page shows assets/logo_light.png in the light theme and assets/logo_dark.png in the dark one
# (flutter/lib/common.dart, loadLogo), at most 300 x 60. logo-light.png has dark text for the light theme.
LOGOS = {"logo-light.png": "flutter/assets/logo_light.png", "logo-dark.png": "flutter/assets/logo_dark.png"}
LOGO_MAX = (600, 120)  # twice the displayed size, for high-DPI screens
EDGE = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Microsoft/Edge/Application/msedge.exe"
RENDER_SIZE = 1024
ICO_SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
TRAY_SIZES = [16, 20, 24, 32, 40, 48, 64]


def render(tmp: Path) -> Image.Image:
    # Inlined and sized explicitly: a bare SVG document does not scale to the window.
    svg = SVG.read_text(encoding="utf-8").replace(
        "<svg ", f"<svg width='{RENDER_SIZE}' height='{RENDER_SIZE}' style='display:block' ", 1)
    html = tmp / "icon.html"
    html.write_text(
        f"<html><body style='margin:0;background:transparent'>{svg}</body></html>",
        encoding="utf-8",
    )
    png = tmp / "icon.png"
    subprocess.run(
        [
            str(EDGE),
            "--headless=new",
            # Own profile, or a running Edge takes the call over and nothing is written.
            f"--user-data-dir={tmp / 'profile'}",
            "--disable-gpu",
            "--hide-scrollbars",
            "--allow-file-access-from-files",
            "--default-background-color=00000000",
            f"--window-size={RENDER_SIZE},{RENDER_SIZE}",
            f"--screenshot={png}",
            html.as_uri(),
        ],
        check=True,
        capture_output=True,
    )
    # msedge.exe can return before its headless child has written the screenshot.
    for _ in range(60):
        if png.exists() and png.stat().st_size > 0:
            break
        time.sleep(0.5)
    time.sleep(0.5)
    image = Image.open(png).convert("RGBA")
    if image.getbbox() is None:
        raise SystemExit("Edge rendered an empty image")
    return image


def save_png(image: Image.Image, size: int, *paths: str) -> None:
    resized = image.resize((size, size), Image.LANCZOS)
    for p in paths:
        resized.save(ROOT / p)
        print(f"{p} ({size}px)")


def save_ico(image: Image.Image, sizes: list, *paths: str) -> None:
    for p in paths:
        image.save(ROOT / p, format="ICO", sizes=[(s, s) for s in sizes])
        print(f"{p} ({', '.join(map(str, sizes))})")


def save_logos() -> None:
    for source, target in LOGOS.items():
        image = Image.open(BRANDING / source).convert("RGBA")
        # Without the transparent margins, so the logo uses the whole 300 x 60 the client gives it.
        image = image.crop(image.getbbox())
        image.thumbnail(LOGO_MAX, Image.LANCZOS)
        image.save(ROOT / target)
        print(f"{target} ({image.width}x{image.height})")


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        image = render(Path(tmp))
    save_ico(image, ICO_SIZES,
             "res/icon.ico",
             "flutter/windows/runner/resources/app_icon.ico",
             "flutter/assets/icon.ico")
    save_ico(image, TRAY_SIZES, "res/tray-icon.ico")
    save_png(image, 512, "res/icon.png", "flutter/assets/icon.png")
    save_png(image, 32, "res/32x32.png")
    save_png(image, 64, "res/64x64.png")
    save_png(image, 128, "res/128x128.png")
    save_png(image, 256, "res/128x128@2x.png")
    save_logos()


if __name__ == "__main__":
    main()
