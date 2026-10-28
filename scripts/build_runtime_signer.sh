#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT/build/runtime-signer/codex-sign"
WORK="$ROOT/build/runtime-signer/work"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    -h|--help)
      printf '%s\n' 'usage: scripts/build_runtime_signer.sh [--output PATH] [--work PATH]'
      exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 64 ;;
  esac
done

TROLLSTORE_SHA=88424f683b2a08f34a3f88985f790f97d84ce1df
CHOMA_SHA=964023ddac2286ef8e843f90df64d44ac6a673df
OPENSSL_VERSION=openssl-3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/${OPENSSL_VERSION}/${OPENSSL_VERSION}.tar.gz"

for tool in git curl tar shasum xcrun xcodebuild make python3 grep; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 127; }
done
mkdir -p "$WORK" "$(dirname "$OUTPUT")"
TS="$WORK/TrollStore"
if [ ! -d "$TS/.git" ]; then
  git clone --no-checkout https://github.com/opa334/TrollStore.git "$TS"
fi
git -C "$TS" fetch --no-tags origin "$TROLLSTORE_SHA"
git -C "$TS" checkout --detach --force "$TROLLSTORE_SHA"
git -C "$TS" submodule update --init --recursive
[ "$(git -C "$TS" rev-parse HEAD)" = "$TROLLSTORE_SHA" ]
[ "$(git -C "$TS/ChOma" rev-parse HEAD)" = "$CHOMA_SHA" ]

ARCHIVE="$WORK/${OPENSSL_VERSION}.tar.gz"
if [ ! -f "$ARCHIVE" ]; then
  curl --fail --location --retry 3 "$OPENSSL_URL" -o "$ARCHIVE"
fi
printf '%s  %s\n' "$OPENSSL_SHA256" "$ARCHIVE" | shasum -a 256 -c -
OPENSSL_SRC="$WORK/$OPENSSL_VERSION"
if [ ! -f "$OPENSSL_SRC/Configure" ]; then
  rm -rf "$OPENSSL_SRC"
  tar -xzf "$ARCHIVE" -C "$WORK"
fi
printf '%s  %s\n' "$OPENSSL_SHA256" "$ARCHIVE" | shasum -a 256 -c -

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos --find clang)"
FP="$TS/Exploits/fastPathSign"
CHOMA="$TS/ChOma"
"$CC" -target arm64-apple-ios15.0 -isysroot "$SDK" -fsyntax-only \
  -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter \
  -I"$FP/src" -I"$CHOMA/src" \
  "$ROOT/scripts/runtime-signer/adapter.m"
CRYPTO="$WORK/crypto-ios"
if [ ! -f "$CRYPTO/lib/libcrypto.a" ]; then
  ( cd "$OPENSSL_SRC"
    ./Configure ios64-xcrun no-shared no-module no-tests \
      --prefix="$CRYPTO" --libdir=lib \
      -isysroot "$SDK" -miphoneos-version-min=15.0
    make -j"$(sysctl -n hw.ncpu)" build_libs
    make install_dev
  )
fi
test -f "$CRYPTO/lib/libcrypto.a"

FP="$TS/Exploits/fastPathSign"
CHOMA="$TS/ChOma"
BUILD="$WORK/adapter-build"
rm -rf "$BUILD"
mkdir -p "$BUILD"
"$CC" -target arm64-apple-ios15.0 -isysroot "$SDK" -O2 -fobjc-arc \
  -Wno-deprecated-declarations -Wno-unused-parameter \
  -I"$FP/src" -I"$CHOMA/src" -I"$CRYPTO/include" \
  "$ROOT/scripts/runtime-signer/adapter.m" \
  "$FP/src/codesign.m" "$FP/src/coretrust_bug.c" "$CHOMA"/src/*.c \
  "$CRYPTO/lib/libcrypto.a" \
  -framework Foundation -framework CoreFoundation -framework Security \
  -o "$BUILD/codex-sign"

xcrun lipo -info "$BUILD/codex-sign"
xcrun vtool -show-build "$BUILD/codex-sign"
xcrun otool -L "$BUILD/codex-sign" | tee "$BUILD/dependencies.txt"
if grep -Eqi '/opt/homebrew|/usr/local/opt|macos|darwin|openssl@' "$BUILD/dependencies.txt"; then
  echo 'unexpected host dependency in iOS codex-sign' >&2
  exit 1
fi
install -m 0755 "$BUILD/codex-sign" "$OUTPUT"

python3 - "$OUTPUT" "$ARCHIVE" "$ROOT/scripts/runtime-signer/adapter.m" "$WORK/provenance.json" <<'PY'
import hashlib, json, pathlib, sys
out, archive, adapter, provenance = map(pathlib.Path, sys.argv[1:])
def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024), b''): h.update(block)
    return h.hexdigest()
record={
  'schema': 1,
  'product': 'OpenMinis codex-sign',
  'source_build': True,
  'target': 'arm64-apple-ios15.0',
  'trollstore': {'repository':'https://github.com/opa334/TrollStore','commit':'88424f683b2a08f34a3f88985f790f97d84ce1df'},
  'choma': {'repository':'https://github.com/opa334/ChOma','commit':'964023ddac2286ef8e843f90df64d44ac6a673df'},
  'openssl': {'release':'openssl-3.5.9','sha256':'603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a'},
  'artifacts': {'codex-sign': {'sha256':sha(out),'bytes':out.stat().st_size}, 'adapter.m': {'sha256':sha(adapter),'bytes':adapter.stat().st_size}, 'openssl-3.5.9.tar.gz': {'sha256':sha(archive),'bytes':archive.stat().st_size}},
  'licenses': {'TrollStore':'MIT','ChOma':'MIT','OpenSSL':'Apache-2.0','GPL-3.0':'not a current dependency','MPL-2.0':'not a current dependency'},
  'runtime_policy': {'adhoc_only_never_calls_coretrust': True, 'fat_behavior':'preferred arm64 slice is extracted; other slices are discarded', 'failure_policy':'stage all files before commit; failed jobs leave originals unchanged'},
}
provenance.parent.mkdir(parents=True, exist_ok=True)
provenance.write_text(json.dumps(record, indent=2)+'\n')
PY
# Keep the complete fixed source inputs beside the output for redistribution review.
tar --exclude='*/.git' --exclude='*/build' -czf "$WORK/source-assets.tar.gz" \
  -C "$WORK" TrollStore "$OPENSSL_VERSION" "$(basename "$ARCHIVE")" \
  -C "$ROOT" scripts/build_runtime_signer.sh \
      scripts/runtime-signer/adapter.m scripts/runtime-signer/README.md \
      scripts/runtime-signer/THIRD_PARTY_NOTICES.md scripts/runtime-signer/provenance.json \
  -C "$WORK" provenance.json
printf 'built %s\n' "$OUTPUT"
printf 'provenance %s\n' "$WORK/provenance.json"
