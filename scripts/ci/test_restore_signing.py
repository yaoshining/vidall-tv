import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('signing', Path(__file__).with_name('restore_signing.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
PROFILE = '{"app":{"signingConfigs":[{"name":"default","material":{"keyAlias":"test","keyPassword":"encrypted-key","storePassword":"encrypted-store", "certpath":"old.cer", "storeFile":"old.p12", "profile":"old.p7b"}}]}}'


def bundle(transform=lambda files: files, member_transform=lambda m: m):
    files = {name: b'test' for name in signing.FILES}
    files.update({f'material/{group}/' + 'a' * 32: b'test' for group in signing.MATERIAL_GROUPS})
    files['vidall_tv_debug.cer'] = b'-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----'
    manifest = {'schema': 1, 'config_sha256': signing.config_digest(PROFILE),
                'files': {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}}
    files['manifest.json'] = json.dumps(manifest).encode()
    files = transform(files)
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as archive:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member_transform(member), io.BytesIO(data))
    return base64.b64encode(output.getvalue()).decode()


class SigningTests(unittest.TestCase):
    def test_matching_bundle_restores_only_private_files_and_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile = root / 'build-profile.json5'
            profile.write_text(PROFILE)
            with patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
                signing.restore(bundle(), root / 'signing', profile)
            self.assertEqual(signing.signing_values(profile.read_text()), signing.signing_values(PROFILE))
            self.assertEqual((root / 'signing/vidall_tv_debug.p12').stat().st_mode & 0o777, 0o600)
            self.assertIn(str(root / 'signing'), profile.read_text())

    def test_missing_extra_corrupt_link_and_mixed_configuration_rejected(self):
        samples = [bundle(lambda d: {k: v for k, v in d.items() if k != 'material/ac/' + 'a' * 32}),
                   bundle(lambda d: {**d, '../outside': b'bad'}),
                   bundle(lambda d: {**d, 'material/ac/' + 'a' * 32: b'different'}),
                   bundle(member_transform=lambda m: self.make_link(m) if m.name == 'material/ac/' + 'a' * 32 else m)]
        for value in samples:
            with self.subTest(sample=value[:16]), self.assertRaises(ValueError):
                signing.unpack_bundle(value, PROFILE)
        with self.assertRaises(ValueError):
            signing.unpack_bundle(bundle(), PROFILE.replace('encrypted-store', 'other'))

    @staticmethod
    def make_link(member):
        member.type = tarfile.SYMTYPE
        member.linkname = '/tmp/unsafe'
        member.size = 0
        return member

    def test_expired_certificate_does_not_write_or_patch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile = root / 'build-profile.json5'
            profile.write_text(PROFILE)
            with patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
                with self.assertRaisesRegex(ValueError, '过期'):
                    signing.restore(bundle(), root / 'signing', profile)
            self.assertFalse((root / 'signing').exists())
            self.assertEqual(profile.read_text(), PROFILE)


if __name__ == '__main__':
    unittest.main()
