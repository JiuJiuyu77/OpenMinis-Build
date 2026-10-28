#!/usr/bin/env python3
"""Validate the published developer-runtime manifest against this app's installer.

The manifest is data: a new runtime ships without a new app build, which also
means a bad entry reaches users directly. This checker runs in CI and fails when
the manifest advertises something the installer cannot honour:

  * schema drift (must stay 4)
  * an unknown `handler` (the app would list it but not install it)
  * an archive format the installer cannot unpack (only tar.gz / tgz / deb)
  * `install` blocks that would let a broken tree pass: absolute or `..` paths,
    a probe executable outside `required_paths`, `sign_paths` outside
    `required_paths`, environment values without `${RUNTIME_ROOT}`
  * digests that are not 64 lowercase hex characters
  * a manifest with no runtime providing a capability the app depends on

Usage:
    check_runtime_manifest.py [--manifest PATH_OR_URL] [--required-capability X]
    check_runtime_manifest.py --manifest Runtime/runtime-manifest.json

Python 3 standard library only, so it runs on any runner.
"""

import argparse
import json
import os
import sys
import urllib.request

MANIFEST_SCHEMA = 4
SUPPORTED_HANDLERS = {"portable-v1", "python", "theos", "reverse_tools"}
SUPPORTED_ARCHIVES = (".tar.gz", ".tgz", ".deb")
# Minis consumes the toolchain runtimes only. `codex` (Codex CLI / app-server /
# Code Mode) belongs to another app's agent stack and is intentionally ignored,
# so its capabilities must NOT be required here.
DEFAULT_REQUIRED_CAPABILITIES = ("ios.toolchain", "ios.package")
IGNORED_HANDLERS = {"codex"}

errors: list[str] = []
warnings: list[str] = []


def error(message: str) -> None:
    errors.append(message)


def warn(message: str) -> None:
    warnings.append(message)


def fetch(source: str) -> dict:
    if os.path.exists(source):
        with open(source, "rb") as handle:
            return json.loads(handle.read().decode("utf-8"))
    request = urllib.request.Request(source, headers={"User-Agent": "minis-runtime-contract/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def is_hex64(value) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def archive_suffix(runtime: dict) -> str:
    name = (runtime.get("asset_name") or runtime.get("archive_url") or "").lower()
    for suffix in (".tar.gz", ".tgz", ".deb"):
        if name.endswith(suffix):
            return suffix
    return ""


def is_ignored(runtime_id: str, runtime: dict) -> bool:
    return (runtime_id.lower() == "codex" or runtime.get("handler") in IGNORED_HANDLERS
            or any(str(c).startswith("codex.") for c in runtime.get("provides", [])))


def safe_relative(value) -> bool:
    return (isinstance(value, str) and bool(value) and not value.startswith("/")
            and ".." not in value.split("/") and "\x00" not in value)


def check_runtime(runtime_id: str, runtime: dict, handlers_seen: set) -> None:
    where = f"runtimes.{runtime_id}"
    for key in ("display_name", "version", "archive_url", "handler"):
        if key not in runtime:
            error(f"{where}: missing {key}")

    handler = runtime.get("handler")
    handlers_seen.add(handler)
    if is_ignored(runtime_id, runtime):
        # Deliberately not installed by Minis; nothing to validate beyond the
        # shape checks below.
        return
    if handler not in SUPPORTED_HANDLERS:
        error(f"{where}: handler {handler!r} is not implemented by the installer "
              f"(supported: {', '.join(sorted(SUPPORTED_HANDLERS))})")

    url = runtime.get("archive_url") or ""
    if not url.startswith("https://"):
        error(f"{where}.archive_url: must be https")
    suffix = archive_suffix(runtime)
    if not suffix:
        error(f"{where}: archive is not one of {', '.join(SUPPORTED_ARCHIVES)} "
              f"(got {runtime.get('asset_name') or url})")

    if not is_hex64(runtime.get("archive_sha256")):
        error(f"{where}.archive_sha256: expected 64 lowercase hex characters")
    if "revision" in runtime and not is_hex64(runtime.get("revision")):
        error(f"{where}.revision: expected 64 lowercase hex characters")
    if "revision" not in runtime:
        warn(f"{where}: no revision; the app can only compare versions")

    install = runtime.get("install")
    if install is None:
        if handler == "portable-v1":
            warn(f"{where}: portable-v1 runtime publishes no install block; "
                 f"the installer cannot self-check it")
        return
    if not isinstance(install, dict):
        error(f"{where}.install: expected an object")
        return

    required = install.get("required_paths") or []
    if not required:
        error(f"{where}.install.required_paths: expected a non-empty list")
    for entry in required:
        if not safe_relative(entry):
            error(f"{where}.install.required_paths: must be a relative path inside the tree: {entry}")

    for entry in (install.get("path_entries") or []) + (install.get("persistent_path_entries") or []):
        if not safe_relative(entry):
            error(f"{where}.install: PATH entries must stay inside their root: {entry}")

    for key in ("sign_paths", "sign_paths_without_entitlements"):
        for entry in install.get(key) or []:
            if not safe_relative(entry):
                error(f"{where}.install.{key}: unsafe signing target: {entry}")

    probe = install.get("probe")
    if not probe:
        warn(f"{where}.install.probe: missing; nothing verifies the tree after unpacking")
    else:
        executable = probe.get("executable")
        if not executable:
            error(f"{where}.install.probe.executable: missing")
        elif executable not in required:
            error(f"{where}.install.probe.executable {executable!r} is not listed in required_paths")
        if not probe.get("contains"):
            warn(f"{where}.install.probe.contains: missing output assertion")
        if not isinstance(probe.get("arguments", []), list):
            error(f"{where}.install.probe.arguments: expected a list")

    for entry in install.get("sign_paths") or []:
        if entry not in required:
            warn(f"{where}.install.sign_paths {entry!r} is not in required_paths")

    for key, value in (install.get("environment") or {}).items():
        if "${RUNTIME_ROOT}" not in str(value):
            warn(f"{where}.install.environment.{key}: no ${{RUNTIME_ROOT}} placeholder")


def main(argv=None) -> int:
    errors.clear()
    warnings.clear()
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest",
                        default="https://raw.githubusercontent.com/JiuJiuyu77/MinisApp-Runtime/main/Runtime/runtime-manifest.json")
    parser.add_argument("--required-capability", action="append", default=None,
                        help="capability the app depends on (repeatable)")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    try:
        manifest = fetch(args.manifest)
    except Exception as exc:  # noqa: BLE001
        print(f"error   cannot load manifest {args.manifest}: {exc}")
        return 2

    if manifest.get("schema") != MANIFEST_SCHEMA:
        error(f"schema: expected {MANIFEST_SCHEMA}, found {manifest.get('schema')!r}")
    for prefix in manifest.get("download_proxy_prefixes") or []:
        if not prefix.endswith("/"):
            error(f"download_proxy_prefixes: entry must end with '/': {prefix}")

    runtimes = manifest.get("runtimes") or {}
    if not runtimes:
        error("runtimes: empty manifest")

    handlers_seen: set = set()
    provided: dict[str, list[str]] = {}
    for runtime_id, runtime in sorted(runtimes.items()):
        if not isinstance(runtime, dict):
            error(f"runtimes.{runtime_id}: expected an object")
            continue
        check_runtime(runtime_id, runtime, handlers_seen)
        if is_ignored(runtime_id, runtime):
            continue
        for capability in runtime.get("provides") or []:
            provided.setdefault(capability, []).append(runtime_id)

    for capability in args.required_capability or list(DEFAULT_REQUIRED_CAPABILITIES):
        if capability not in provided:
            error(f"no runtime provides {capability!r}, which the app depends on")

    for capability, owners in sorted(provided.items()):
        if len(owners) > 1:
            warn(f"capability {capability!r} is provided by {', '.join(sorted(owners))}")

    if args.json:
        print(json.dumps({"source": args.manifest, "errors": errors, "warnings": warnings,
                          "runtimes": sorted(runtimes), "handlers": sorted(str(h) for h in handlers_seen)},
                         indent=2))
    else:
        for message in errors:
            print(f"error   {message}")
        for message in warnings:
            print(f"warning {message}")
        print(f"{args.manifest}: {len(runtimes)} runtime(s), "
              f"{len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
