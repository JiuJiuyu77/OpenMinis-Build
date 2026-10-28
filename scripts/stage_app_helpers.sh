#!/bin/bash
# Stage and sign the native helpers that live inside the app bundle.
#
# The runtime layer needs three things inside `<App>.app/Helpers/`:
#
#   bash.real    a real bash (Darwin syscalls + posix_spawn), NOT the Linux
#                busybox inside the iSH rootfs. Compiled binaries call it as
#                their shell, so scripts, `make` and node-gyp all work.
#   codex-sign   App Store-style CodeDirectory signer (TeamID + cdhashes).
#                `ldid` alone leaves the binary in a state AMFI rejects with
#                `Bad executable` / `Killed: 9`.
#   (optional)   ldid, when the Theos runtime does not provide one.
#
# Put the binaries in `Configs/Helpers/` and add one Xcode "Run Script" build
# phase (before the app is signed) that calls this script:
#
#   "${SRCROOT}/scripts/stage_app_helpers.sh"
#
# The script is a no-op when `Configs/Helpers/` is empty, so a checkout without
# the binaries still builds.
#
# Environment (from Xcode): BUILT_PRODUCTS_DIR, WRAPPER_NAME, SRCROOT, plus
# CONFIGURATION_BUILD_DIR/EXPANDED_CODE_SIGN_IDENTITY when present.

set -euo pipefail

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PRODUCTS_DIR="${BUILT_PRODUCTS_DIR:-${CONFIGURATION_BUILD_DIR:-}}"
WRAPPER="${WRAPPER_NAME:-}"

if [ -z "$PRODUCTS_DIR" ] || [ -z "$WRAPPER" ]; then
  echo "stage_app_helpers: no BUILT_PRODUCTS_DIR/WRAPPER_NAME, skipping (not an Xcode build)"
  exit 0
fi

SOURCE_DIR="${SRCROOT}/Configs/Helpers"
if [ ! -d "$SOURCE_DIR" ]; then
  echo "stage_app_helpers: ${SOURCE_DIR} does not exist, nothing to stage"
  exit 0
fi

shopt -s nullglob
# 只把真正的二进制当候选：目录里放 README 说明时也算「没有可暂存的文件」，
# 否则「空目录 no-op」的判断会被一份文档打破。
files=()
for candidate in "$SOURCE_DIR"/*; do
  case "$(basename "$candidate")" in
    *.md|.gitkeep|.DS_Store|README*) continue ;;
  esac
  files+=("$candidate")
done
if [ ${#files[@]} -eq 0 ]; then
  echo "stage_app_helpers: ${SOURCE_DIR} has no binaries, nothing to stage"
  exit 0
fi

APP="${PRODUCTS_DIR}/${WRAPPER}"
DEST="${APP}/Helpers"
mkdir -p "$DEST"

for file in "${files[@]}"; do
  name="$(basename "$file")"
  case "$name" in
    *.md|.gitkeep|.DS_Store) continue ;;
  esac
  install -m 0755 "$file" "${DEST}/${name}"
  echo "stage_app_helpers: staged ${name}"
done

# Compatibility symlinks: the runtime probes `bash`, `sh` and the single-binary
# coreutils. Keep them pointing at real files inside the same directory so a
# copied bundle never dangles.
if [ -f "${DEST}/bash.real" ]; then
  ln -sf bash.real "${DEST}/bash"
fi
if [ -f "${DEST}/ca-filetool" ]; then
  for alias in cat chmod cp date dirname du find grep head ln ls mkdir mv realpath \
               rm sed sh sort stat tail tar tee touch uname wc which; do
    ln -sf ca-filetool "${DEST}/${alias}"
  done
fi

# Ad-hoc sign what we just copied so the bundle's signature stays consistent.
# The runtime re-signs its own binaries through ldid + codex-sign; this step
# only keeps the app bundle itself valid.
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && command -v codesign >/dev/null 2>&1; then
  for file in "${DEST}"/*; do
    case "$(basename "$file")" in
      *.txt|*.md) continue ;;
    esac
    [ -f "$file" ] || continue
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --preserve-metadata=identifier,entitlements "$file" 2>/dev/null \
      || echo "stage_app_helpers: warning: could not sign $(basename "$file")"
  done
fi

echo "stage_app_helpers: done -> ${DEST}"
