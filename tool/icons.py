#!/usr/bin/env python3
"""`moon run desktop:icons`: every platform's app icon, from resources/icon.svg.

Also the tray icons (lib/tray.dart): the mark alone, black on clear, as the
macOS menu bar's template image, and the tile for Windows' notification area.

Also the podcast apps' icons for the "Listen in…" menu, from
resources/podcast_apps/*.svg (taken from listenbox.app), as asset PNGs.

Release and profile builds get the icon as it is; debug builds get it with a
red DEBUG ribbon across the top-right corner, like Flutter's debug banner, so
a dev build is never mistaken for the installed app.

macOS only: Google Chrome renders the SVG (headless), sips resizes it. The
outputs are committed, so building needs neither.
"""
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "packages" / "desktop"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Flutter's debug banner: Color(0xA0B71C1C) over the icon, white bold text.
RIBBON = """<g clip-path="url(#tile)"><g transform="rotate(45 724 300)">
<rect x="224" y="230" width="1000" height="140" fill="#B71C1C"/>
<text x="724" y="300" dominant-baseline="central" text-anchor="middle"
 font-family="Helvetica Neue, Helvetica, Arial, sans-serif" font-weight="800"
 font-size="92" letter-spacing="8" fill="#fff">DEBUG</text></g></g>"""


def debug_svg(svg: str) -> str:
    """The icon with the ribbon, clipped to the icon's tile (its first path)."""
    tile = re.search(r'<path d="([^"]+)"', svg)
    if not tile:
        sys.exit("icon.svg: expected its first <path> to be the tile")
    head, body = re.match(r"(<svg[^>]*>)(.*)</svg>\s*$", svg, re.S).groups()
    clip = f'<defs><clipPath id="tile"><path d="{tile.group(1)}"/></clipPath></defs>'
    return f"{head}{clip}{body}{RIBBON}</svg>\n"


def render(svg: str, out: Path, work: Path) -> None:
    source = work / f"{out.stem}.svg"
    source.write_text(svg)
    subprocess.run(
        [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
         "--default-background-color=00000000", "--window-size=1024,1024",
         f"--screenshot={out}", source.as_uri()],
        check=True, capture_output=True,
    )


def resize(master: Path, size: int, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(master, out)
    if size != 1024:
        subprocess.run(["sips", "-z", str(size), str(size), str(out)], check=True, capture_output=True)


def ico(master: Path, out: Path, work: Path) -> None:
    """A Windows .ico of PNG entries (Vista and later)."""
    images = []
    for size in (16, 24, 32, 48, 64, 128, 256):
        png = work / f"{out.stem}-{size}.png"
        resize(master, size, png)
        images.append((size, png.read_bytes()))
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = len(header) + 16 * len(images)
    entries, data = b"", b""
    for size, png in images:
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(png), offset + len(data))
        data += png
    out.write_bytes(header + entries + data)


def sized(svg: str, px: int = 1024) -> str:
    """[svg] drawn at px × px, whatever its root says."""
    head = re.match(r"<svg[^>]*>", svg).group(0)
    bare = re.sub(r'\s(width|height)="[^"]*"', "", head)
    return svg.replace(head, bare.replace("<svg", f'<svg width="{px}" height="{px}"', 1), 1)


def podcast_app_icons(work: Path) -> None:
    """Menu icons, 24 logical pixels, at 1x, 2x and 3x (lib/podcast_apps.dart)."""
    assets = APP / "assets" / "podcast_apps"
    for source in sorted((ROOT / "resources" / "podcast_apps").glob("*.svg")):
        master = work / f"app-{source.stem}.png"
        render(sized(source.read_text()), master, work)
        for scale, folder in ((1, assets), (2, assets / "2.0x"), (3, assets / "3.0x")):
            resize(master, 24 * scale, folder / f"{source.stem}.png")


def tray_icons(svg: str, work: Path) -> None:
    """The tray's icons, as assets (lib/tray.dart)."""
    tray = APP / "assets" / "tray"
    # The mark: icon.svg's group over the tile, in its own 200-unit space.
    mark = re.search(r'<g transform="[^"]*">(.*?)</g>', svg, re.S).group(1)
    template = ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="38 38 124 124">'
                + mark.replace("#fff", "#000") + "</svg>")
    master = work / "tray-template.png"
    render(template, master, work)
    # 18pt in the menu bar, drawn at 2x.
    resize(master, 36, tray / "template.png")
    tile = work / "tray-tile.png"
    render(svg, tile, work)
    resize(tile, 32, tray / "tile.png")


def main() -> None:
    svg = (ROOT / "resources" / "icon.svg").read_text()
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for variant, text in (("release", svg), ("debug", debug_svg(svg))):
            master = work / f"{variant}.png"
            render(text, master, work)
            debug = variant == "debug"

            # macOS: an asset catalog per variant; the Debug configuration
            # compiles AppIconDebug (Runner.xcodeproj).
            catalog = APP / "macos/Runner/Assets.xcassets" / ("AppIconDebug.appiconset" if debug else "AppIcon.appiconset")
            catalog.mkdir(parents=True, exist_ok=True)
            shutil.copy(APP / "macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json", catalog / "Contents.json") if debug else None
            for size in (16, 32, 64, 128, 256, 512, 1024):
                resize(master, size, catalog / f"app_icon_{size}.png")

            # Android: the debug source set overrides main's launcher icon.
            res = APP / "android/app/src" / ("debug" if debug else "main") / "res"
            for density, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
                resize(master, size, res / f"mipmap-{density}" / "ic_launcher.png")

            # Windows: Runner.rc picks app_icon_debug.ico when _DEBUG is defined.
            ico(master, APP / "windows/runner/resources" / ("app_icon_debug.ico" if debug else "app_icon.ico"), work)

            # Linux: the runner sets the window icon from the bundle's data/.
            resize(master, 256, APP / "linux/runner/resources" / ("app_icon_debug.png" if debug else "app_icon.png"))
        podcast_app_icons(work)
        tray_icons(svg, work)
    print("icons written")


if __name__ == "__main__":
    main()
