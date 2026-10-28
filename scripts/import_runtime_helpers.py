#!/usr/bin/env python3
"""Import only standalone bash/sign helpers from a user-supplied IPA/TIPA.

No app executable, AI agent, ca-filetool, account data or model config is copied.
Use locally: python3 scripts/import_runtime_helpers.py /path/to/reference.tipa
The caller is responsible for the corresponding source/licence obligations
before redistributing imported binaries. This script does not upload anything.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile

ALLOWED = ('bash.real', 'codex-sign')
NOTICES = ('Bash.txt', 'FastPathSign.txt', 'ChOma.txt', 'OpenSSL.txt', 'Runtime-Components.txt')

def validate_macho(data, name):
    if len(data) < 4096 or data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError(f'{name}: expected a non-truncated thin arm64 Mach-O')
    if struct.unpack_from('<I', data, 4)[0] != 0x0100000c:
        raise ValueError(f'{name}: not arm64')
    commands, size = struct.unpack_from('<II', data, 16)
    if 32 + size > len(data):
        raise ValueError(f'{name}: truncated load commands')
    offset, signed = 32, False
    for _ in range(commands):
        cmd, length = struct.unpack_from('<II', data, offset)
        if length < 8 or offset + length > 32 + size:
            raise ValueError(f'{name}: malformed load command')
        if cmd == 0x1d:
            start, count = struct.unpack_from('<II', data, offset + 8)
            signed = count > 0 and start + count <= len(data)
        offset += length
    if not signed:
        raise ValueError(f'{name}: missing or truncated code signature')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--dest', type=Path, default=Path(__file__).resolve().parents[1] / 'Configs/Helpers')
    args = parser.parse_args()
    with zipfile.ZipFile(args.archive) as archive:
        roots = sorted({n.split('/')[1] for n in archive.namelist() if n.startswith('Payload/') and '.app/' in n})
        if len(roots) != 1:
            raise ValueError('expected exactly one top-level app')
        prefix = 'Payload/' + roots[0] + '/'
        payloads = {}
        for name in ALLOWED:
            payloads[name] = archive.read(prefix + 'Helpers/' + name)
            validate_macho(payloads[name], name)
        for name in NOTICES:
            payloads['Notices/' + name] = archive.read(prefix + 'ThirdPartyNotices/' + name)
        for name in ('cacert.pem', 'CA_NOTICE.txt'):
            key = prefix + name
            if key in archive.namelist():
                payloads[name] = archive.read(key)
        provenance = {'archive_sha256': hashlib.sha256(args.archive.read_bytes()).hexdigest(),
            'helpers': {n: {'sha256': hashlib.sha256(payloads[n]).hexdigest(), 'bytes': len(payloads[n])} for n in ALLOWED},
            'excluded': ['CodexApp executable', 'Codex agent/app-server', 'ca-filetool and MT authorisation hooks'],
            'redistribution': 'Provide complete corresponding sources/build scripts and notices before redistributing.'}
        for name, data in payloads.items():
            target = args.dest / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            if name in ALLOWED:
                target.chmod(0o755)
        (args.dest / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    print('Imported standalone helpers locally:', ', '.join(ALLOWED))
    print('No Codex agent or ca-filetool imported. Check source/licence obligations before redistribution.')

if __name__ == '__main__':
    main()
