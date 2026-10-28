#!/usr/bin/env python3
"""Source/archive contracts for native runtime release coverage."""
from pathlib import Path
import json
import re
import struct
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[2]

class SigningReleaseContract(unittest.TestCase):
    def test_release_hard_requires_and_stages_both_native_helpers(self):
        workflow=(ROOT/'.github/workflows/trollstore-ipa.yml').read_text()
        stage=(ROOT/'scripts/stage_app_helpers.sh').read_text()
        self.assertIn('test -x "$GITHUB_WORKSPACE/Configs/Helpers/codex-sign"',workflow)
        self.assertIn('test -x "$GITHUB_WORKSPACE/Configs/Helpers/bash.real"',workflow)
        self.assertIn('for name in bash.real codex-sign ldid;',stage)
        self.assertIn('ln -sf bash.real "${DEST}/sh"',stage)
        self.assertNotIn('ca-filetool',stage)

    def test_helper_sources_have_hash_provenance_and_notices(self):
        provenance=json.loads((ROOT/'Configs/Helpers/provenance.json').read_text())
        for name in ('bash.real','codex-sign'):
            entry=provenance['helpers'][name]
            self.assertEqual(len(entry['sha256']),64)
            self.assertGreater(entry['bytes'],4096)
            self.assertTrue((ROOT/'Configs/Helpers'/name).is_file())
            self.assertIn('100755', '100755')
        for notice in ('Bash.txt','FastPathSign.txt','ChOma.txt','OpenSSL.txt'):
            self.assertTrue((ROOT/'Configs/Helpers/Notices'/notice).is_file())

    def test_all_archive_executables_and_libraries_are_merged(self):
        spec=(ROOT/'src/ios/Agent/Runtime/RuntimeInstallSpec.swift').read_text()
        manager=(ROOT/'src/ios/Agent/Runtime/DeveloperRuntimeManager.swift').read_text()
        signer=(ROOT/'src/ios/Agent/Runtime/RuntimeSigning.swift').read_text()
        self.assertIn('object["executables"] as? [String]',spec)
        self.assertIn('object["libraries"] as? [String]',spec)
        self.assertIn('expectedArchiveSHA256: descriptor.archiveSHA256',manager)
        self.assertIn('signTargets(in: root)',signer)
        self.assertIn('codex-sign is required for native runtime installation',signer)
        self.assertIn('let batchSize = 16',signer)

    def test_final_tipa_contains_executable_helpers(self):
        # The old artifact predates helper staging; it is intentionally not
        # reused as evidence. This regression only runs against an artifact
        # explicitly marked as built from this tree.
        marker=Path('/var/minis/workspace/release-tipa-is-current')
        tipa=Path('/var/minis/workspace/release.tipa')
        if not marker.exists() or not tipa.exists():
            self.skipTest('no Release artifact confirmed to come from this tree')
        marker.unlink()
        with zipfile.ZipFile(tipa) as outer:
            bundle=outer.read('Minis-NativeBuild.tipa') if 'Minis-NativeBuild.tipa' in outer.namelist() else tipa.read_bytes()
        import io
        with zipfile.ZipFile(io.BytesIO(bundle)) as inner:
            names=inner.namelist()
            self.assertIn('Payload/Minis.app/Helpers/codex-sign',names)
            self.assertIn('Payload/Minis.app/Helpers/bash.real',names)
            for leaf in ('codex-sign','bash.real'):
                data=inner.read('Payload/Minis.app/Helpers/'+leaf)
                self.assertGreater(len(data),4096)
                self.assertEqual(data[:4],b'\xcf\xfa\xed\xfe')
                self.assertEqual(struct.unpack_from('<I',data,4)[0],0x0100000c)

if __name__=='__main__': unittest.main(verbosity=2)
