"""Exercise the file protocol without sending any mouse input."""
import fcntl
import json
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest

CLIENT = pathlib.Path(__file__).resolve().parents[1] / "mouse_harness.py"


class BridgeProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def command(self, request):
        return [sys.executable, str(CLIENT), "--bridge-dir", str(self.root), request]

    def test_waits_for_matching_completed_response(self):
        process = subprocess.Popen(self.command('{"action":"status"}'),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 3
            while not (self.root / "request.json").exists():
                if time.monotonic() > deadline:
                    self.fail("Client did not publish a request")
                time.sleep(0.01)
            request = json.loads((self.root / "request.json").read_text())
            response = self.root / "response.json"
            response.write_text(json.dumps({"id": "stale", "state": "done"}))
            time.sleep(0.2)
            self.assertIsNone(process.poll(), "A stale result must not complete a new request")
            response.write_text(json.dumps({"id": request["id"], "state": "running"}))
            time.sleep(0.2)
            self.assertIsNone(process.poll(), "Running is not completion")
            response.write_text(json.dumps({"id": request["id"], "state": "done", "trusted": True}))
            stdout, stderr = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(json.loads(stdout)["id"], request["id"])
            self.assertLess(abs(time.time() - request["created"]), 5)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_concurrent_writer_cannot_overwrite_request(self):
        with (self.root / "client.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            original = '{"id":"existing-request"}'
            (self.root / "request.json").write_text(original)
            result = subprocess.run(self.command('{"action":"click","from":[0.5,0.5]}'),
                                    capture_output=True, text=True, timeout=3)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Another request is running", result.stderr)
            self.assertEqual((self.root / "request.json").read_text(), original)

    def test_cancel_is_available_during_an_active_request(self):
        with (self.root / "client.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = subprocess.run(self.command("cancel"), capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((self.root / "cancel").exists())


if __name__ == "__main__":
    unittest.main()
