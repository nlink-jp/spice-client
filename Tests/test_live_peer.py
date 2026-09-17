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

    def test_agent_status_distinguishes_started_error_and_pending(self):
        with tempfile.TemporaryDirectory() as work:
            log = Path(work) / 'guest.log'
            log.write_text('GUEST ready\n')
            self.assertEqual(run(f'. ./lib.sh; live_peer_agent_status "{log}"').returncode, 1)
            log.write_text('GUEST ready\nAGENT_ERROR Xorg unavailable\n')
            self.assertEqual(run(f'. ./lib.sh; live_peer_agent_status "{log}"').returncode, 2)
            log.write_text('GUEST ready\nAGENT_STACK_STARTED\n')
            self.assertEqual(run(f'. ./lib.sh; live_peer_agent_status "{log}"').returncode, 0)
            # The serial console ends lines with CR LF.
            log.write_text('GUEST ready\r\nAGENT_STACK_STARTED\r\n')
            self.assertEqual(run(f'. ./lib.sh; live_peer_agent_status "{log}"').returncode, 0)

    def test_audio_check_requires_the_guest_to_have_started_playing(self):
        with tempfile.TemporaryDirectory() as work:
            log = Path(work) / 'guest.log'
            log.write_text('GUEST ready\nAUDIO_ERROR no playback device\n')
            self.assertNotEqual(run(f'. ./lib.sh; live_peer_guest_audio_started "{log}"').returncode, 0)
            log.write_text('GUEST ready\r\nAUDIO_PLAYING\r\n')
            self.assertEqual(run(f'. ./lib.sh; live_peer_guest_audio_started "{log}"').returncode, 0)

    def test_agent_log_check_is_ordered_and_rejects_withheld_tokens(self):
        import hashlib
        with tempfile.TemporaryDirectory() as work:
            receipt, log = Path(work) / 'receipt', Path(work) / 'guest.log'
            sha = lambda token: hashlib.sha256(f'spice-client host clipboard {token}'.encode()).hexdigest()
            receipt.write_text('clipboardFollowsSharingAndFocusInBothDirections\ndelivered aa\nwithheld bb\ndelivered cc\nlatency x 12\nmode 1024x768\nmode 1280x800\n')
            good = f'XRANDR_MODE 1280x800\nCLIPBOARD_OBSERVED bytes=31 sha256={sha("aa")}\nCLIPBOARD_OBSERVED bytes=31 sha256={sha("cc")}\nXRANDR_MODE 1024x768\nXRANDR_MODE 1280x800\n'
            log.write_text(good)
            self.assertEqual(run(f'. ./lib.sh; live_peer_agent_log_matches "{receipt}" "{log}"').returncode, 0)
            log.write_text(good.replace('\n', '\r\n'))
            self.assertEqual(run(f'. ./lib.sh; live_peer_agent_log_matches "{receipt}" "{log}"').returncode, 0)
            log.write_text(good + f'CLIPBOARD_OBSERVED bytes=31 sha256={sha("bb")}\n')
            self.assertNotEqual(run(f'. ./lib.sh; live_peer_agent_log_matches "{receipt}" "{log}"').returncode, 0)
            # The startup mode line alone must not satisfy the second request.
            log.write_text(f'XRANDR_MODE 1280x800\nCLIPBOARD_OBSERVED bytes=31 sha256={sha("aa")}\nCLIPBOARD_OBSERVED bytes=31 sha256={sha("cc")}\nXRANDR_MODE 1024x768\n')
            self.assertNotEqual(run(f'. ./lib.sh; live_peer_agent_log_matches "{receipt}" "{log}"').returncode, 0)
            # Order matters: cc observed before aa is a failure.
            log.write_text(f'CLIPBOARD_OBSERVED bytes=31 sha256={sha("cc")}\nCLIPBOARD_OBSERVED bytes=31 sha256={sha("aa")}\nXRANDR_MODE 1024x768\nXRANDR_MODE 1280x800\n')
            self.assertNotEqual(run(f'. ./lib.sh; live_peer_agent_log_matches "{receipt}" "{log}"').returncode, 0)

    def test_pinned_unapplied_mode_fails_when_the_mode_does_arrive(self):
        import hashlib
        with tempfile.TemporaryDirectory() as work:
            receipt, log = Path(work) / 'receipt', Path(work) / 'guest.log'
            receipt.write_text('mode 1024x768\nunapplied 1280x800\n')
            # The mode the guest booted with precedes the request, which is fine.
            log.write_text('XRANDR_MODE 1280x800\nXRANDR_MODE 1024x768\n')
            self.assertEqual(run(f'. ./lib.sh; live_peer_agent_log_matches "{receipt}" "{log}"').returncode, 0)
            # Applied after the first request: the defect is fixed, so the gate must fail.
            log.write_text('XRANDR_MODE 1280x800\nXRANDR_MODE 1024x768\nXRANDR_MODE 1280x800\n')
            result = run(f'. ./lib.sh; live_peer_agent_log_matches "{receipt}" "{log}"')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('looks fixed', result.stdout + result.stderr)

    def test_changed_guest_sources_invalidate_the_recorded_build(self):
        import hashlib
        with tempfile.TemporaryDirectory() as work:
            record = Path(work) / 'guest.json'
            init_sha = hashlib.sha256((LIVE / 'guest/init').read_bytes()).hexdigest()
            build_sha = hashlib.sha256((LIVE / 'guest/build-in-container.sh').read_bytes()).hexdigest()
            self.assertNotEqual(run(f'. ./lib.sh; live_peer_guest_current "{work}" guest').returncode, 0)
            record.write_text(json.dumps({'init_sha256': init_sha, 'build_sha256': build_sha}))
            self.assertEqual(run(f'. ./lib.sh; live_peer_guest_current "{work}" guest').returncode, 0)
            record.write_text(json.dumps({'init_sha256': 'stale', 'build_sha256': build_sha}))
            self.assertNotEqual(run(f'. ./lib.sh; live_peer_guest_current "{work}" guest').returncode, 0)

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
