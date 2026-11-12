#!/bin/sh
# Assemble the Kindle install tree and zip it:
#   tome/        -> copy to /mnt/us/tome
#   extensions/  -> copy to /mnt/us/extensions (KUAL menu entry)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/build/package"
BIN="${ROOT}/build/kindle/tome"
[ -x "${BIN}" ] || { echo "missing ${BIN}; run tools/build_kindle.sh first" >&2; exit 1; }

rm -rf "${OUT}"
mkdir -p "${OUT}/tome" "${OUT}/extensions"
cp "${BIN}" "${OUT}/tome/tome-luajit"
cp "${ROOT}/main.lua" "${ROOT}/platform/kindle/tome.sh" "${OUT}/tome/"
cp -r "${ROOT}/tome" "${ROOT}/fonts" "${ROOT}/plugins" "${OUT}/tome/"
cp "${ROOT}/config.example.lua" "${OUT}/tome/config.example.lua"
cp -r "${ROOT}/platform/kindle/extensions/tome" "${OUT}/extensions/"
chmod +x "${OUT}/tome/tome-luajit" "${OUT}/tome/tome.sh"
(cd "${OUT}" && zip -qr ../tome-kindle.zip tome extensions)
echo "wrote ${ROOT}/build/tome-kindle.zip"
