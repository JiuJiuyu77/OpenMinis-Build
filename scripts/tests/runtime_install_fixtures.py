#!/usr/bin/env python3
"""Deterministic tiny archive fixtures for production Swift extractor tests."""
import gzip
import io
from pathlib import Path
import sys
import tarfile
root = Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
def archive(name, members):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        for info, payload in members:
            tar.addfile(info, io.BytesIO(payload))
    data = gzip.compress(raw.getvalue(), mtime=0)
    (root / (name + '.tar.gz')).write_bytes(data)
    return data

def file(name, data, mode=0o644):
    info = tarfile.TarInfo(name); info.size = len(data); info.mode = mode
    return info, data

good = archive('good', [file('bin/tool', b'#!/bin/sh\nexit 0\n', 0o755), file('file', b'fixture')])
archive('traversal', [file('../outside', b'escape')])
link = tarfile.TarInfo('escape'); link.type = tarfile.SYMTYPE; link.linkname = '../../outside'
archive('symlink-escape', [(link, b''), file('escape/payload', b'escape')])
(root / 'truncated.tar.gz').write_bytes(good[:-8])
