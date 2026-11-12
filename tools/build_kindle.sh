#!/bin/sh
# Cross-compile the Kindle binary: a static LuaJIT with tomecore built in.
#
# Output: build/kindle/tome  (static ARMv7 hard-float, musl). Being fully static,
# it does not depend on the Kindle's glibc version or its soft/hard-float userland.
#
# Needs: git, make, and Zig (as a cross C compiler). Easiest way to get Zig:
#   pip install ziglang        (then ZIG="python3 -m ziglang")
# or download it from ziglang.org and set ZIG=/path/to/zig.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/build/kindle"
LUAJIT_REPO="${LUAJIT_REPO:-https://github.com/LuaJIT/LuaJIT.git}"
LUAJIT_REF="${LUAJIT_REF:-v2.1}"
ZIG="${ZIG:-zig}"
TARGET="${TARGET:-arm-linux-musleabihf}"
CPU="${CPU:-cortex_a8}"

mkdir -p "${BUILD}/bin"
# Small wrappers so LuaJIT's Makefile sees ordinary compiler names.
cat > "${BUILD}/bin/host-cc" <<W
#!/bin/sh
exec ${ZIG} cc -target x86-linux-musl "\$@"
W
cat > "${BUILD}/bin/target-cc" <<W
#!/bin/sh
exec ${ZIG} cc -target ${TARGET} -mcpu=${CPU} "\$@"
W
cat > "${BUILD}/bin/target-ar" <<W
#!/bin/sh
exec ${ZIG} ar "\$@"
W
chmod +x "${BUILD}/bin/"*

if [ ! -d "${BUILD}/luajit" ]; then
    git clone --depth 1 --branch "${LUAJIT_REF}" "${LUAJIT_REPO}" "${BUILD}/luajit"
fi

# buildvm runs on the build machine but must match the target's pointer size,
# hence the 32-bit x86 host compiler. LUAJIT_NO_UNWIND: LuaJIT's own error
# unwinding, since Zig ships no libgcc ARM unwinder (__gnu_unwind_frame).
make -C "${BUILD}/luajit/src" -j"$(nproc 2>/dev/null || echo 4)" \
    HOST_CC="${BUILD}/bin/host-cc" \
    CC="${BUILD}/bin/target-cc" \
    TARGET_AR="${BUILD}/bin/target-ar rcus" \
    TARGET_STRIP=true \
    TARGET_SYS=Linux \
    BUILDMODE=static \
    XCFLAGS="-DLUAJIT_NO_UNWIND" \
    libluajit.a

"${BUILD}/bin/target-cc" -O2 -static \
    -I"${BUILD}/luajit/src" \
    "${ROOT}/native/tome_main.c" "${ROOT}/native/tomecore.c" "${ROOT}/native/arm_rt.c" \
    "${BUILD}/luajit/src/libluajit.a" -lm -s \
    -o "${BUILD}/tome"

echo "built ${BUILD}/tome"
file "${BUILD}/tome" 2>/dev/null || true
