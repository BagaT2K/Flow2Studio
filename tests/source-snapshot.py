from pathlib import Path
import hashlib
import importlib.util
import json
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("source_snapshot", root / "scripts/source-manifest.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix="flow2 source ") as directory:
    directory = Path(directory)
    manifest_path, archive_path = directory / "manifest.json", directory / "source.zip"
    manifest = module.snapshot(root, manifest_path, archive_path)
    assert manifest["applicationVersion"] == "0.9.6"
    with zipfile.ZipFile(archive_path) as archive:
        assert archive.testzip() is None
        assert json.loads(archive.read("Flow2-Studio-0.9.6/source-manifest.json")) == manifest
        for entry in manifest["files"]:
            data = archive.read("Flow2-Studio-0.9.6/" + entry["path"])
            assert len(data) == entry["bytes"] and hashlib.sha256(data).hexdigest() == entry["sha256"]
        names = {entry["path"] for entry in manifest["files"]}
        assert {"LICENSE", "README.md", "firmware-bundle/NOTICE", "mac/Studio.m"} <= names
        assert not {"PRIVACY.md", "SECURITY.md", "DISTRIBUTION.md", "THIRD-PARTY-NOTICES.txt"} & names
        assert not any("__pycache__" in name or name.startswith("dist/") for name in names)
        mode = archive.getinfo("Flow2-Studio-0.9.6/Build-DMG.command").external_attr >> 16
        assert mode & 0o111
    fixture = directory / "fixture"
    (fixture / "mac").mkdir(parents=True)
    (fixture / "mac/secret.key").write_text("not for publication")
    (fixture / "mac/.env.production").write_text("not for publication")
    assert not module.collect_sources(fixture)
    (fixture / "mac/outside.m").symlink_to(root / "mac/Studio.m")
    try:
        module.collect_sources(fixture)
    except ValueError:
        pass
    else:
        raise AssertionError("Source symlink was followed")
print("Passed: archived source bytes match every recorded hash, MIT and component notices included, removed documents absent, executable modes preserved, output/cache/known secrets excluded and symlinks rejected.")
