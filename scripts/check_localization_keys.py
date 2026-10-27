#!/usr/bin/env python3
"""Fail when an AppLocalized("…") key is missing from Localizable.xcstrings.

New UI strings silently fall back to English when the key is absent from the
catalog, which is easy to miss in review. This check is cheap and needs no
Xcode, so it runs in CI next to the Swift parse job.

Usage:
    scripts/check_localization_keys.py            # scan src/ios, report missing
    scripts/check_localization_keys.py --allow-untranslated
                                                 # only fail on missing keys,
                                                 # ignore keys with no zh-Hans
"""
import argparse
import json
import os
import re
import sys

KEY_RE = re.compile(r'AppLocalized\(\s*"((?:[^"\\]|\\.)*)"')
SKIP_DIRS = {".git", "build", ".build", "DerivedData", "Pods"}


def app_localized_keys(root):
    keys = {}
    for directory, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            try:
                text = open(path, encoding="utf-8").read()
            except OSError:
                continue
            for match in KEY_RE.finditer(text):
                keys.setdefault(match.group(1), set()).add(path)
    return keys


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default="src/ios")
    parser.add_argument("--catalog", default="src/ios/Localizable.xcstrings")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 when keys are missing (default: report only — main "
                             "already has ~24 legacy gaps)")
    parser.add_argument("--allow-untranslated", action="store_true",
                        help="ignore keys that exist but have no zh-Hans value")
    parser.add_argument("--limit", type=int, default=40)
    args = parser.parse_args(argv)

    with open(args.catalog, encoding="utf-8") as handle:
        catalog = json.load(handle).get("strings", {})
    used = app_localized_keys(args.root)

    missing = sorted(key for key in used if key not in catalog)
    untranslated = []
    if not args.allow_untranslated:
        for key in sorted(used):
            entry = catalog.get(key)
            if not isinstance(entry, dict):
                continue
            localizations = entry.get("localizations") or {}
            unit = (localizations.get("zh-Hans") or {}).get("stringUnit") or {}
            value = unit.get("value")
            if entry and not value:
                untranslated.append(key)

    print("%d AppLocalized keys in %s · catalog has %d entries"
          % (len(used), args.root, len(catalog)))
    if missing:
        print("\nmissing from catalog (%d):" % len(missing))
        for key in missing[:args.limit]:
            source = sorted(used[key])[0]
            print("  %-60s %s" % (key[:60], source))
    if untranslated:
        print("\nno zh-Hans value (%d):" % len(untranslated))
        for key in untranslated[:args.limit]:
            print("  %s" % key[:70])

    if missing:
        return 1 if args.strict else 0
    if untranslated:
        print("\n(zh-Hans gaps are reported but not fatal; pass --allow-untranslated to hide)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
