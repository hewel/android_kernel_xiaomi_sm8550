#!/usr/bin/env bash
# Standalone GKI kernel + boot.img build for Xiaomi SM8550 (kalama).
# Intended for GitHub Actions; also usable on a Linux host with clang in PATH.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

DEVICE="${DEVICE:-socrates}"
ARCH="${ARCH:-arm64}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
JOBS="${JOBS:-$(nproc)}"
CLANG_PATH="${CLANG_PATH:-}"
# full | thin | none  (full matches Lineage/GKI; thin/none are safer on small CI runners)
LTO_MODE="${LTO_MODE:-full}"
LOCALVERSION="${LOCALVERSION:--resukisu}"
BUILD_BOOT_IMG="${BUILD_BOOT_IMG:-1}"
# Optional stock/Lineage boot.img URL; if set, magiskboot replaces the kernel instead of mkbootimg
BASE_BOOT_URL="${BASE_BOOT_URL:-}"

DEFCONFIG_BASE="arch/${ARCH}/configs/gki_defconfig"
FRAGMENT_KALAMA="arch/${ARCH}/configs/vendor/kalama_GKI.config"
FRAGMENT_DEVICE="arch/${ARCH}/configs/vendor/${DEVICE}_GKI.config"

log() { printf '::group::%s\n' "$*"; }
endlog() { printf '::endgroup::\n'; }

die() { echo "error: $*" >&2; exit 1; }

require_file() {
  [[ -f "$1" ]] || die "missing required file: $1"
}

setup_toolchain() {
  log "Toolchain"
  if [[ -n "$CLANG_PATH" ]]; then
    export PATH="${CLANG_PATH}/bin:${PATH}"
  fi

  command -v clang >/dev/null || die "clang not found in PATH (set CLANG_PATH)"
  command -v ld.lld >/dev/null || die "ld.lld not found in PATH"

  echo "clang: $(clang --version | head -1)"
  echo "ld.lld: $(ld.lld --version | head -1)"
  echo "jobs: ${JOBS}"
  echo "device: ${DEVICE}"
  echo "lto: ${LTO_MODE}"
  endlog
}

make_kernel() {
  # LLVM=1 selects the full clang/llvm binutils set used by modern GKI trees.
  make -C "$ROOT_DIR" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 LLVM_IAS=1 \
    LOCALVERSION="$LOCALVERSION" "$@"
}

configure_kernel() {
  log "Configure (${DEVICE})"
  require_file "$DEFCONFIG_BASE"
  require_file "$FRAGMENT_KALAMA"
  require_file "$FRAGMENT_DEVICE"

  mkdir -p "$OUT_DIR"
  rm -f "${OUT_DIR}/.config"

  # Base GKI defconfig, then merge vendor + device fragments (Lineage order).
  make_kernel gki_defconfig
  ./scripts/kconfig/merge_config.sh -m -O "$OUT_DIR" \
    "${OUT_DIR}/.config" \
    "$FRAGMENT_KALAMA" \
    "$FRAGMENT_DEVICE"
  make_kernel olddefconfig

  case "$LTO_MODE" in
    full)
      ./scripts/config --file "${OUT_DIR}/.config" \
        --enable LTO_CLANG_FULL --disable LTO_CLANG_THIN --disable LTO_NONE
      ;;
    thin)
      ./scripts/config --file "${OUT_DIR}/.config" \
        --disable LTO_CLANG_FULL --enable LTO_CLANG_THIN --disable LTO_NONE
      ;;
    none)
      ./scripts/config --file "${OUT_DIR}/.config" \
        --disable LTO_CLANG_FULL --disable LTO_CLANG_THIN --enable LTO_NONE
      ;;
    *)
      die "unknown LTO_MODE=${LTO_MODE} (use full|thin|none)"
      ;;
  esac
  make_kernel olddefconfig

  echo "--- key config symbols ---"
  grep -E '^(CONFIG_LTO|CONFIG_CFI|CONFIG_KSU|CONFIG_TARGET_PRODUCT|CONFIG_LOCALVERSION)' \
    "${OUT_DIR}/.config" || true
  endlog
}

build_image() {
  log "Build Image"
  make_kernel -j"$JOBS" Image
  require_file "${OUT_DIR}/arch/${ARCH}/boot/Image"
  endlog
}

package_artifacts() {
  log "Package artifacts"
  mkdir -p "$DIST_DIR"
  local image="${OUT_DIR}/arch/${ARCH}/boot/Image"
  local release
  release="$(cat "${OUT_DIR}/include/config/kernel.release" 2>/dev/null || echo unknown)"
  local stamp
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  local short_sha="${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo local)}"
  short_sha="${short_sha:0:12}"

  cp -f "$image" "${DIST_DIR}/Image"
  cp -f "${OUT_DIR}/.config" "${DIST_DIR}/config"
  printf '%s\n' "$release" > "${DIST_DIR}/kernel.release"
  {
    echo "device=${DEVICE}"
    echo "kernel.release=${release}"
    echo "git=${short_sha}"
    echo "built_utc=${stamp}"
    echo "lto=${LTO_MODE}"
    echo "localversion=${LOCALVERSION}"
    clang --version | head -1
  } > "${DIST_DIR}/build-info.txt"

  if [[ "$BUILD_BOOT_IMG" == "1" ]]; then
    build_boot_img "$image" "${DIST_DIR}/boot.img"
  fi

  # Convenience tarball
  tar -C "$DIST_DIR" -czf \
    "${DIST_DIR}/kernel-${DEVICE}-${short_sha}.tar.gz" \
    Image config kernel.release build-info.txt \
    $( [[ -f "${DIST_DIR}/boot.img" ]] && echo boot.img )

  ls -lh "$DIST_DIR"
  endlog
}

build_boot_img() {
  local image="$1"
  local out_boot="$2"

  if [[ -n "$BASE_BOOT_URL" ]]; then
    echo "Repacking boot.img from base: $BASE_BOOT_URL"
    local base="${DIST_DIR}/base-boot.img"
    curl -fL --retry 3 -o "$base" "$BASE_BOOT_URL"
    if command -v magiskboot >/dev/null; then
      local work
      work="$(mktemp -d)"
      (
        cd "$work"
        magiskboot unpack "$base"
        cp -f "$image" kernel
        magiskboot repack "$base" "$out_boot"
      )
      rm -rf "$work"
      echo "Repacked $(du -h "$out_boot" | awk '{print $1}') boot.img via magiskboot"
      return
    fi
    echo "magiskboot not found; falling back to header-v4 packer" >&2
  fi

  # GKI / header v4: kernel only (ramdisk is in init_boot / vendor_boot on SM8550).
  python3 - "$image" "$out_boot" <<'PY'
import struct, sys
from pathlib import Path

kernel_path, out_path = sys.argv[1], sys.argv[2]
kernel = Path(kernel_path).read_bytes()
page_size = 4096
header_size = 1584  # BOOT_IMAGE_HEADER_V4_SIZE
# os_version: (a << 14) | (b << 7) | c  for a.b.c  (Android 16.0.0)
# os_patch_level: ((year-2000) << 4) | month
os_version = (16 << 14) | (0 << 7) | 0
os_patch_level = ((2026 - 2000) << 4) | 6
os_field = (os_version << 11) | os_patch_level

# struct boot_img_hdr_v3/v4 (see system/tools/mkbootimg/include/bootimg/bootimg.h)
hdr = bytearray(header_size)
hdr[0:8] = b"ANDROID!"
struct.pack_into("<I", hdr, 8, len(kernel))          # kernel_size
struct.pack_into("<I", hdr, 12, 0)                    # ramdisk_size
struct.pack_into("<I", hdr, 16, os_field)             # os_version
struct.pack_into("<I", hdr, 20, header_size)          # header_size
# reserved[4] @ 24..39 already zero
struct.pack_into("<I", hdr, 40, 4)                    # header_version
# cmdline[1536] @ 44 already zero
struct.pack_into("<I", hdr, 44 + 1536, 0)             # signature_size

def pad(n: int) -> int:
    return (n + page_size - 1) // page_size * page_size

out = bytearray(pad(header_size))
out[0:header_size] = hdr
out += kernel
out += b"\0" * (pad(len(kernel)) - len(kernel))
Path(out_path).write_bytes(out)
print(f"Wrote {out_path} ({len(out)} bytes, kernel={len(kernel)})")
PY

  echo "Created $(du -h "$out_boot" | awk '{print $1}') boot.img"
}

ensure_kernelsu_link() {
  # ReSukiSU is a submodule; drivers/kernelsu must point at it.
  if [[ ! -e drivers/kernelsu/Kconfig ]]; then
    if [[ -d KernelSU/kernel ]]; then
      ln -sfn ../KernelSU/kernel drivers/kernelsu
      echo "linked drivers/kernelsu -> ../KernelSU/kernel"
    else
      die "KernelSU submodule missing (run: git submodule update --init --recursive)"
    fi
  fi
}

main() {
  echo "Building Xiaomi SM8550 GKI kernel for device=${DEVICE}"
  ensure_kernelsu_link
  setup_toolchain
  configure_kernel
  build_image
  package_artifacts
  echo "Done. Artifacts in ${DIST_DIR}"
}

main "$@"
