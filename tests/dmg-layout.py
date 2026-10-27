"""Exercise the real binary Finder-settings writer and detect missing/corrupt layout."""
from pathlib import Path
from datetime import datetime, timezone
import importlib.util
import tempfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dmg_layout", root / "scripts/write-dmg-layout.py")
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)
from mac_alias import Alias, VolumeInfo, TargetInfo
from ds_store import DSStore

with tempfile.TemporaryDirectory(prefix="Flow2 DMG с пробелами ") as temp:
    volume = Path(temp)
    (volume / ".background").mkdir()
    (volume / ".background/installer.png").write_bytes(b"\x89PNG\r\n\x1a\n")
    (volume / "Flow2Studio.app").mkdir()
    (volume / "Applications").symlink_to("/Applications")
    now = datetime(2026, 10, 27, tzinfo=timezone.utc)
    alias = Alias(volume=VolumeInfo("Flow2Studio 1.0.2", now, b"H+", 0, 0, b"\0\0"),
                  target=TargetInfo(0, "installer.png", 16, 17, now, b"\0"*4, b"\0"*4,
                                    posix_path="/.background/installer.png"))
    layout.write_layout(volume, alias)
    layout.verify_layout(volume)
    with DSStore.open(str(volume / ".DS_Store"), "r+") as store:
        assert store["."]["icvp"]["iconSize"] == 160.0
        assert store["."]["bwsp"]["WindowBounds"] == "{{160, 120}, {560, 360}}"
        assert store["Flow2Studio.app"]["Iloc"] == (140, 150)
        assert store["Applications"]["Iloc"] == (420, 150)
        store["Applications"]["Iloc"] = (1, 1)
    try:
        layout.verify_layout(volume)
    except ValueError:
        pass
    else:
        raise AssertionError("Corrupt icon position was accepted")
    (volume / ".DS_Store").unlink()
    try:
        layout.verify_layout(volume)
    except FileNotFoundError:
        pass
    else:
        raise AssertionError("Missing Finder settings were accepted")
print("Passed: actual binary layout write/read, background alias, compact window, large icons, Unicode/spaces; missing and corrupted layout rejected. Finder rendering not tested.")
