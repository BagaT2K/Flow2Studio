"""Write and verify the disk image's Finder settings without GUI automation."""
from pathlib import Path
import argparse
import os
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / "vendor"))
from ds_store import DSStore
from mac_alias import Alias

WINDOW = "{{160, 120}, {560, 360}}"
POSITIONS = {"Flow2Studio.app": (140, 150), "Applications": (420, 150)}


def verify_layout(volume):
    volume = Path(volume)
    background = volume / ".background/installer.png"
    if background.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Installer background is not a PNG")
    if not (volume / "Applications").is_symlink():
        raise ValueError("Missing Applications shortcut")
    with DSStore.open(str(volume / ".DS_Store"), "r") as store:
        window = store["."]["bwsp"]
        icons = store["."]["icvp"]
        if window["WindowBounds"] != WINDOW or window["ShowToolbar"] or window["ShowSidebar"]:
            raise ValueError("Installer window settings were not saved")
        if icons["iconSize"] != 160.0 or icons["backgroundType"] != 2 or icons["arrangeBy"] != "none":
            raise ValueError("Installer icon/background settings were not saved")
        alias = Alias.from_bytes(icons["backgroundImageAlias"])
        target = alias.target.posix_path
        if isinstance(target, bytes):
            target = target.decode("utf-8")
        if target.lstrip("/") != ".background/installer.png":
            raise ValueError("Background alias does not point inside the image")
        for name, position in POSITIONS.items():
            if store[name]["Iloc"] != position:
                raise ValueError("Installer icon position was not saved: " + name)


def write_layout(volume, background_alias=None):
    volume = Path(volume)
    if background_alias is None:
        background_alias = Alias.for_file(str(volume / ".background/installer.png"))
    with DSStore.open(str(volume / ".DS_Store"), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["icvl"] = ("type", b"icnv")
        store["."]["bwsp"] = {
            "WindowBounds": WINDOW,
            "ShowStatusBar": False,
            "ShowToolbar": False,
            "ShowSidebar": False,
            "ContainerShowSidebar": False,
            "ShowTabView": False,
            "ShowPathbar": False,
            "PreviewPaneVisibility": False,
            "SidebarWidth": 0,
        }
        store["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "backgroundType": 2,
            "backgroundImageAlias": background_alias.to_bytes(),
            "backgroundColorRed": 1.0,
            "backgroundColorGreen": 1.0,
            "backgroundColorBlue": 1.0,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "gridSpacing": 100.0,
            "arrangeBy": "none",
            "showIconPreview": False,
            "showItemInfo": False,
            "labelOnBottom": True,
            "textSize": 13.0,
            "iconSize": 160.0,
            "scrollPositionX": 0.0,
            "scrollPositionY": 0.0,
        }
        for name, position in POSITIONS.items():
            store[name]["Iloc"] = position
    with open(volume / ".DS_Store", "r+b") as file:
        os.fsync(file.fileno())
    verify_layout(volume)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("volume")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.verify:
        verify_layout(args.volume)
    else:
        write_layout(args.volume)
    print("DMG layout verified: 560x360, white background, 160px icons and drag arrow.")
