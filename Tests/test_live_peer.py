"""The live peer gate's own tests: its checks fail closed without Podman (ADR-0002)."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parents[1]
LIVE = ROOT / 'Integration/LivePeer'


def run(script, env=None):
    return subprocess.run(['bash', '-c', script], cwd=LIVE, capture_output=True, text=True,
                          env={**os.environ, **(env or {})})


class GateChecks(unittest.TestCase):
    def test_guest_log_check_requires_the_key_down_event(self):
        with tempfile.TemporaryDirectory() as work:
            log = Path(work) / 'guest.log'
            log.write_text('INPUT_EVENT /dev/input/event0\n 2b 18 ac 6a 00 00 00 00 72 ec 07 00 00 00 00 00 01 00 1e 00 01 00 00 00\n')
            self.assertEqual(run(f'. ./lib.sh; live_peer_guest_saw_key "{log}"').returncode, 0)
            log.write_text('INPUT_EVENT /dev/input/event0\n 2b 18 ac 6a 00 00 00 00 72 ec 07 00 00 00 00 00 01 00 1e 00 00 00 00 00\n')
            self.assertNotEqual(run(f'. ./lib.sh; live_peer_guest_saw_key "{log}"').returncode, 0)
            self.assertNotEqual(run(f'. ./lib.sh; live_peer_guest_saw_key "{work}/absent"').returncode, 0)

    def test_receipt_requires_every_named_test(self):
        with tempfile.TemporaryDirectory() as work:
            receipt = Path(work) / 'receipt'
            receipt.write_text('a\n')
            self.assertEqual(run(f'. ./lib.sh; live_peer_tests_ran "{receipt}" a').returncode, 0)
            self.assertNotEqual(run(f'. ./lib.sh; live_peer_tests_ran "{receipt}" a b').returncode, 0)
            receipt.write_text('')
            self.assertNotEqual(run(f'. ./lib.sh; live_peer_tests_ran "{receipt}" a').returncode, 0)

    def test_release_requires_a_clean_pass_on_the_same_commit(self):
        with tempfile.TemporaryDirectory() as work:
            record = Path(work) / 'last-pass.json'
            env = {'SPICE_CLIENT_LIVE_PEER_ARTIFACTS': work}
            self.assertNotEqual(run('./require-pass.sh abc', env).returncode, 0)
            for passed, dirty, head, expected in [(True, False, 'abc', 0), (True, True, 'abc', 1),
                                                  (True, False, 'def', 1), (False, False, 'abc', 1)]:
                record.write_text(json.dumps({'passed': passed, 'dirty': dirty, 'head': head}))
                self.assertEqual(run('./require-pass.sh abc', env).returncode, expected, (passed, dirty, head))
            record.write_text('not json')
            self.assertNotEqual(run('./require-pass.sh abc', env).returncode, 0)

    def test_run_fails_fast_without_guest_artifacts(self):
        with tempfile.TemporaryDirectory() as work:
            result = run(f'./run.sh "{work}/env"', {'SPICE_CLIENT_LIVE_PEER_ARTIFACTS': work})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('missing', result.stderr)
            self.assertFalse((Path(work) / 'env').exists())

    def test_tls_material_is_a_verifiable_chain_with_a_decoy_that_signed_nothing(self):
        with tempfile.TemporaryDirectory() as work:
            x509 = Path(work) / 'x509'
            self.assertEqual(run(f'. ./lib.sh; live_peer_make_x509 "{x509}"').returncode, 0)
            for name in ('ca-cert.pem', 'server-cert.pem', 'server-key.pem', 'decoy-ca-cert.pem'):
                self.assertTrue((x509 / name).stat().st_size > 0, name)
                self.assertEqual((x509 / name).stat().st_mode & 0o777, 0o600, name)
            verify = subprocess.run(['openssl', 'verify', '-CAfile', str(x509 / 'ca-cert.pem'), str(x509 / 'server-cert.pem')], capture_output=True, text=True)
            self.assertEqual(verify.returncode, 0, verify.stderr)
            decoy = subprocess.run(['openssl', 'verify', '-CAfile', str(x509 / 'decoy-ca-cert.pem'), str(x509 / 'server-cert.pem')], capture_output=True, text=True)
            self.assertNotEqual(decoy.returncode, 0)
            text = subprocess.run(['openssl', 'x509', '-noout', '-text', '-in', str(x509 / 'server-cert.pem')], capture_output=True, text=True).stdout
            self.assertIn('IP Address:127.0.0.1', text)
            self.assertIn('O=nlink-jp', text)
            self.assertIn('CN=spice-client-live-peer', text)
            self.assertEqual((x509 / 'subject.txt').read_text(), 'O=nlink-jp,CN=spice-client-live-peer')
            self.assertEqual(run(f'. ./lib.sh; live_peer_remove_x509 "{x509}"').returncode, 0)
            self.assertFalse(x509.exists())

    def test_scripts_and_guest_init_parse(self):
        for script in sorted(LIVE.glob('*.sh')):
            self.assertEqual(subprocess.run(['bash', '-n', str(script)]).returncode, 0, script.name)
        for script in ('guest/init', 'guest/build-in-container.sh'):
            self.assertEqual(subprocess.run(['sh', '-n', str(LIVE / script)]).returncode, 0, script)

    def test_containerfile_pins_the_base_image_by_digest(self):
        first = [line for line in (LIVE / 'Containerfile').read_text().splitlines() if line.startswith('FROM ')]
        self.assertEqual(len(first), 1)
        self.assertIn('@sha256:', first[0])


if __name__ == '__main__':
    unittest.main()
