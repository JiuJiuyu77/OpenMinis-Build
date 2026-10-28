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

# 二进制放在仓库根的 Configs/Helpers/。Xcode 里 SRCROOT 是 <repo>/src/ios，
# 独立调用时 SRCROOT 可能就是仓库根，也可能压根没设 —— 所以先按「本脚本所在
# 位置」推仓库根（scripts/ 的上一级），推不出来再退回 SRCROOT 的几种层级。
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR=""
for candidate in "${REPO_ROOT}/Configs/Helpers" \
                 "${SRCROOT:-/nonexistent}/Configs/Helpers" \
                 "${SRCROOT:-/nonexistent}/../Configs/Helpers" \
                 "${SRCROOT:-/nonexistent}/../../Configs/Helpers"; do
  if [ -d "$candidate" ]; then SOURCE_DIR="$candidate"; break; fi
done
if [ ! -d "$SOURCE_DIR" ]; then
  echo "stage_app_helpers: ${SOURCE_DIR} does not exist, nothing to stage"
  exit 0
fi

# Explicit allowlist: never stage an app executable, agent, model/account
# config, a notices directory as an executable, or arbitrary downloaded files.
files=()
for name in bash.real codex-sign ldid; do
  candidate="$SOURCE_DIR/$name"
  [ -f "$candidate" ] && files+=("$candidate")
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

# A shell alias must be a real shell, not MT's account-bound multicall helper.
if [ -f "${DEST}/bash.real" ]; then
  ln -sf bash.real "${DEST}/bash"
  ln -sf bash.real "${DEST}/sh"
fi
# Notices and CA store remain data, never chmod +x or code-sign them.
if [ -d "$SOURCE_DIR/Notices" ]; then
  mkdir -p "$DEST/Notices"
  cp -R "$SOURCE_DIR/Notices/." "$DEST/Notices/"
fi
for name in cacert.pem CA_NOTICE.txt provenance.json; do
  [ ! -f "$SOURCE_DIR/$name" ] || install -m 0644 "$SOURCE_DIR/$name" "$DEST/$name"
done

# Ad-hoc sign what we just copied so the bundle's signature stays consistent.
# The runtime re-signs its own binaries through ldid + codex-sign; this step
# only keeps the app bundle itself valid.
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && command -v codesign >/dev/null 2>&1; then
  for name in bash.real codex-sign ldid; do
    file="$DEST/$name"
    [ -f "$file" ] || continue
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --preserve-metadata=identifier,entitlements "$file" 2>/dev/null \
      || echo "stage_app_helpers: warning: could not sign $(basename "$file")"
  done
fi

echo "stage_app_helpers: done -> ${DEST}"
