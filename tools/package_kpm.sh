#!/bin/sh
# Build Tome as a KPM package (.kpkg) and a KPM repository folder.
#
#   tools/package_kpm.sh            uses build/kindle/tome (tools/build_kindle.sh)
#   TOME_BIN=path tools/package_kpm.sh   use another binary (tests)
#
# Output:
#   build/kpm/tome_<version>_kindlepw2-kindlehf.kpkg
#   build/kpm-repo/   -> publish this folder (e.g. GitHub Pages); its
#                        manifest.json URL is what `kpm add-repo` takes.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.2.0}"
BIN="${TOME_BIN:-${ROOT}/build/kindle/tome}"
[ -f "${BIN}" ] || { echo "missing ${BIN}; run tools/build_kindle.sh first" >&2; exit 1; }

STAGE="${ROOT}/build/kpm/stage"
rm -rf "${STAGE}" && mkdir -p "${STAGE}/assets"
cp "${BIN}" "${STAGE}/tome-luajit"
cp "${ROOT}/main.lua" "${ROOT}/config.example.lua" "${ROOT}/LICENSE" "${STAGE}/"
cp "${ROOT}/platform/kindle/tome.sh" "${STAGE}/"
cp -r "${ROOT}/tome" "${ROOT}/fonts" "${ROOT}/plugins" "${STAGE}/"
cp "${ROOT}/platform/kindle/kpm/install.sh" "${ROOT}/platform/kindle/kpm/launch.sh" \
   "${ROOT}/platform/kindle/kpm/uninstall.sh" "${STAGE}/"
cp -r "${ROOT}/platform/kindle/kpm/scriptlet" "${ROOT}/platform/kindle/kpm/kual" "${STAGE}/"
(cd "${ROOT}" && luajit tools/make_icon.lua "${STAGE}/assets/tome-icon.png")

python3 - "${ROOT}" "${STAGE}" "${VERSION}" <<'PY'
import json, os, sys, tarfile, shutil
root, stage, version = sys.argv[1], sys.argv[2], sys.argv[3]
ver = [int(x) for x in version.split(".")]
platforms = ["kindlepw2", "kindlehf"]  # one static ARMv7 binary runs on both
manifest = {
    "manifest_version": 2,
    "id": "tome",
    "name": "Tome",
    "author": "Tome",
    "description": "EPUB reader with book covers, reading stats and spoiler-free story recaps",
    "version": ver,
    "dependencies": [],
    "supported_platforms": platforms,
}
with open(os.path.join(stage, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)

name = f"tome_{version}_{'-'.join(platforms)}.kpkg"
out = os.path.join(root, "build", "kpm", name)

def exe_filter(info):
    # keep scripts and the binary executable for KPM's extractor
    if info.isfile() and (info.name.endswith(".sh") or info.name == "tome-luajit"):
        info.mode = 0o755
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    return info

with tarfile.open(out, "w:gz", compresslevel=6) as tar:
    for item in sorted(os.listdir(stage)):
        tar.add(os.path.join(stage, item), arcname=item, filter=exe_filter)

# Repository folder in KPM's layout
repo = os.path.join(root, "build", "kpm-repo")
art_rel = f"packages/tome/artifacts/{name}"
os.makedirs(os.path.join(repo, os.path.dirname(art_rel)), exist_ok=True)
shutil.copy(out, os.path.join(repo, art_rel))
repo_manifest = {
    "manifest_version": 2,
    "id": "tome",
    "name": "Tome",
    "description": "Tome EPUB reader for Kindle",
    "packages": {
        "tome": {
            "name": manifest["name"],
            "author": manifest["author"],
            "description": manifest["description"],
            "artifacts": [{
                "url": art_rel,
                "version": ver,
                "dependencies": [],
                "supported_platforms": platforms,
            }],
        }
    },
}
with open(os.path.join(repo, "manifest.json"), "w") as f:
    json.dump(repo_manifest, f, indent=2)
print("package:", out)
print("repository:", repo)
PY
