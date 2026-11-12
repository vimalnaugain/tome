#!/bin/sh
# Zip the KOReader recap plugin: build/recap.koplugin.zip
# Unzip it into koreader/plugins/ on the device.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "${ROOT}/build"
rm -f "${ROOT}/build/recap.koplugin.zip"
(cd "${ROOT}/koreader" && zip -qr "${ROOT}/build/recap.koplugin.zip" recap.koplugin -x '*/.*')
echo "wrote ${ROOT}/build/recap.koplugin.zip"
