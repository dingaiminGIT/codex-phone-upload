import contextlib
import http.client
import importlib.util
import io
import json
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "phone_upload.py"
SPEC = importlib.util.spec_from_file_location("phone_upload", SCRIPT_PATH)
phone_upload = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(phone_upload)


PNG = b"\x89PNG\r\n\x1a\n" + b"test-image"


def multipart_body(files, boundary="codex-test-boundary"):
    chunks = []
    for name, data, content_type in files:
        chunks.extend([
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="images"; filename="{name}"\r\n'.encode(),
            f"Content-Type: {content_type}\r\n\r\n".encode(),
            data,
            b"\r\n",
        ])
    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


class RunningUploadServer:
    def __init__(self, root, expires_at=None):
        self.root = Path(root)
        self.original_staging_root = phone_upload.STAGING_ROOT
        phone_upload.STAGING_ROOT = self.root / "staging"
        self.save_dir = phone_upload.STAGING_ROOT / "session"
        self.save_dir.mkdir(parents=True)
        self.state_path = self.root / "session.json"
        self.request_log = self.root / "requests.log"
        self.token = "test-token"
        self.state = {
            "status": "ready",
            "save_dir": str(self.save_dir),
        }
        phone_upload.atomic_json(self.state_path, self.state)
        self.server = phone_upload.UploadServer(
            ("127.0.0.1", 0),
            phone_upload.UploadHandler,
            {
                "token": self.token,
                "project_name": "test-project",
                "save_dir": str(self.save_dir),
                "expires_at": expires_at or time.time() + 60,
                "state_path": str(self.state_path),
                "request_log": str(self.request_log),
                "state": self.state,
                "mode": "local",
            },
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def port(self):
        return self.server.server_address[1]

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        payload = response.read()
        connection.close()
        return response.status, payload

    def close(self):
        if self.thread.is_alive():
            self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        phone_upload.STAGING_ROOT = self.original_staging_root


class PhoneUploadTests(unittest.TestCase):
    def assert_removed_eventually(self, path, timeout=1):
        deadline = time.time() + timeout
        while Path(path).exists() and time.time() < deadline:
            time.sleep(0.01)
        self.assertFalse(Path(path).exists())

    def test_cleanup_staging_dir_removes_tree_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            staging_root = Path(temporary) / "staging"
            staging = staging_root / "session"
            staging.mkdir(parents=True)
            (staging / "image.png").write_bytes(PNG)

            with mock.patch.object(phone_upload, "STAGING_ROOT", staging_root):
                self.assertTrue(phone_upload.cleanup_staging_dir(staging))
                self.assertFalse(staging.exists())
                self.assertTrue(phone_upload.cleanup_staging_dir(staging))

    def test_cleanup_rejects_root_external_nested_and_symlink_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            staging_root = root / "staging"
            staging_root.mkdir()
            external = root / "external"
            external.mkdir()
            (external / "keep.txt").write_text("keep", encoding="utf-8")
            nested = staging_root / "session" / "nested"
            nested.mkdir(parents=True)
            linked = staging_root / "linked"
            linked.symlink_to(external, target_is_directory=True)

            with mock.patch.object(phone_upload, "STAGING_ROOT", staging_root):
                self.assertFalse(phone_upload.cleanup_staging_dir(staging_root))
                self.assertFalse(phone_upload.cleanup_staging_dir(external))
                self.assertFalse(phone_upload.cleanup_staging_dir(nested))
                self.assertFalse(phone_upload.cleanup_staging_dir(linked))

            self.assertTrue((external / "keep.txt").is_file())
            self.assertTrue(nested.is_dir())
            self.assertTrue(linked.is_symlink())

    def test_successful_upload_removes_staged_images(self):
        with tempfile.TemporaryDirectory() as temporary:
            running = RunningUploadServer(temporary)
            observed = []
            body, content_type = multipart_body([("phone.png", PNG, "image/png")])
            try:
                def paste(paths):
                    observed.extend(paths)
                    self.assertTrue(all(path.is_file() for path in paths))

                with mock.patch.object(phone_upload, "paste_into_codex", side_effect=paste), \
                     mock.patch.object(phone_upload, "SHUTDOWN_DELAY_SECONDS", 0.01):
                    status, payload = running.request(
                        "POST",
                        "/upload/test-token",
                        body,
                        {"Content-Type": content_type, "Accept-Language": "en"},
                    )

                self.assertEqual(status, 200)
                self.assertEqual(json.loads(payload), {"count": 1})
                self.assertEqual(len(observed), 1)
                self.assert_removed_eventually(running.save_dir)
                self.assertEqual(phone_upload.read_state(running.state_path)["status"], "completed")
            finally:
                running.close()

    def test_failed_paste_cleans_staging_and_allows_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            running = RunningUploadServer(temporary)
            body, content_type = multipart_body([("phone.png", PNG, "image/png")])
            headers = {"Content-Type": content_type, "Accept-Language": "en"}
            try:
                with mock.patch.object(phone_upload, "paste_into_codex", side_effect=RuntimeError("paste failed")):
                    status, _ = running.request("POST", "/upload/test-token", body, headers)
                self.assertEqual(status, 500)
                self.assert_removed_eventually(running.save_dir)

                with mock.patch.object(phone_upload, "paste_into_codex", return_value=None), \
                     mock.patch.object(phone_upload, "SHUTDOWN_DELAY_SECONDS", 0.01):
                    status, payload = running.request("POST", "/upload/test-token", body, headers)
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(payload), {"count": 1})
                self.assert_removed_eventually(running.save_dir)
            finally:
                running.close()

    def test_wrong_or_expired_token_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            running = RunningUploadServer(temporary, expires_at=time.time() - 1)
            try:
                status, _ = running.request("GET", "/upload/test-token")
                self.assertEqual(status, 410)
                status, _ = running.request("GET", "/upload/wrong-token")
                self.assertEqual(status, 410)
            finally:
                running.close()

    def test_empty_and_malformed_uploads_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            running = RunningUploadServer(temporary)
            try:
                status, _ = running.request(
                    "POST",
                    "/upload/test-token",
                    b"",
                    {"Content-Type": "multipart/form-data; boundary=x"},
                )
                self.assertEqual(status, 413)

                status, _ = running.request(
                    "POST",
                    "/upload/test-token",
                    b"not-multipart",
                    {"Content-Type": "multipart/form-data; boundary=x"},
                )
                self.assertEqual(status, 400)
            finally:
                running.close()

    def test_concurrent_upload_is_rejected_without_touching_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            running = RunningUploadServer(temporary)
            body, content_type = multipart_body([("phone.png", PNG, "image/png")])
            try:
                running.server.upload_lock.acquire()
                status, payload = running.request(
                    "POST",
                    "/upload/test-token",
                    body,
                    {"Content-Type": content_type, "Accept-Language": "en"},
                )
                self.assertEqual(status, 409)
                self.assertIn("Another batch", json.loads(payload)["error"])
                self.assertTrue(running.save_dir.exists())
                self.assertEqual(list(running.save_dir.iterdir()), [])
            finally:
                if running.server.upload_lock.locked():
                    running.server.upload_lock.release()
                running.close()

    def test_expired_server_removes_staging_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            save_dir = root / "staging" / "session"
            state_path = root / "session" / "session.json"
            args = SimpleNamespace(
                project=str(root),
                state=str(state_path),
                save_dir=str(save_dir),
                expires_at=str(time.time() + 0.15),
                port=phone_upload.free_port(),
                mode="local",
                local_ip="127.0.0.1",
                token="expiry-token",
                session_nonce="expiry-nonce",
            )

            def fake_qr(_, output_path):
                Path(output_path).write_bytes(PNG)

            with mock.patch.object(phone_upload, "STAGING_ROOT", root / "staging"), \
                 mock.patch.object(phone_upload, "generate_qr", side_effect=fake_qr):
                phone_upload.run_server(args)

            self.assertFalse(save_dir.exists())
            self.assertEqual(phone_upload.read_state(state_path)["status"], "expired")

    def test_qr_generation_failure_removes_staging_and_closes_port(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            save_dir = root / "staging" / "session"
            state_path = root / "session" / "session.json"
            port = phone_upload.free_port()
            args = SimpleNamespace(
                project=str(root),
                state=str(state_path),
                save_dir=str(save_dir),
                expires_at=str(time.time() + 60),
                port=port,
                mode="local",
                local_ip="127.0.0.1",
                token="failure-token",
                session_nonce="failure-nonce",
            )

            with mock.patch.object(phone_upload, "STAGING_ROOT", root / "staging"), \
                 mock.patch.object(phone_upload, "generate_qr", side_effect=RuntimeError("QR failed")):
                with self.assertRaisesRegex(RuntimeError, "QR failed"):
                    phone_upload.run_server(args)

            self.assertFalse(save_dir.exists())
            with phone_upload.socket.socket(phone_upload.socket.AF_INET, phone_upload.socket.SOCK_STREAM) as sock:
                sock.bind(("127.0.0.1", port))

    def test_mobile_page_marks_local_and_remote_modes(self):
        local_page = phone_upload.upload_page("/upload/token", "project", time.time() + 60, "local")
        remote_page = phone_upload.upload_page("/upload/token", "project", time.time() + 60, "remote")

        self.assertIn("LOCAL_MODE=true", local_page)
        self.assertIn("LOCAL_MODE=false", remote_page)
        self.assertIn("trusted Wi-Fi", local_page)
        self.assertNotIn("__LOCAL_MODE__", local_page)

    def test_stop_session_removes_recorded_staging_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary)
            state_root = project / "private-state"
            staging_root = project / "staging"
            save_dir = staging_root / "session"
            save_dir.mkdir(parents=True)
            (save_dir / "image.png").write_bytes(PNG)

            with mock.patch.object(phone_upload, "SESSION_STATE_ROOT", state_root), \
                 mock.patch.object(phone_upload, "STAGING_ROOT", staging_root):
                state_path = phone_upload.state_path_for_project(project)
                phone_upload.atomic_json(state_path, {
                    "status": "ready",
                    "pid": -1,
                    "save_dir": str(save_dir),
                })
                with contextlib.redirect_stdout(io.StringIO()):
                    phone_upload.stop_session(SimpleNamespace(project=str(project)))

                self.assertFalse(save_dir.exists())
                self.assertEqual(phone_upload.read_state(state_path)["status"], "stopped")

    def test_malicious_legacy_state_cannot_delete_external_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary) / "project"
            project.mkdir()
            external = Path(temporary) / "external"
            external.mkdir()
            keep = external / "keep.txt"
            keep.write_text("keep", encoding="utf-8")
            legacy_state = phone_upload.legacy_state_path_for_project(project)
            phone_upload.atomic_json(legacy_state, {
                "status": "ready",
                "pid": -1,
                "save_dir": str(external),
            })

            with mock.patch.object(phone_upload, "SESSION_STATE_ROOT", Path(temporary) / "state"), \
                 mock.patch.object(phone_upload, "STAGING_ROOT", Path(temporary) / "staging"), \
                 contextlib.redirect_stdout(io.StringIO()):
                phone_upload.stop_session(SimpleNamespace(project=str(project)))

            self.assertEqual(keep.read_text(encoding="utf-8"), "keep")

    def test_unrelated_pid_is_never_terminated(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "session.json"
            process = subprocess.Popen(["/bin/sleep", "30"])
            try:
                phone_upload.atomic_json(state_path, {
                    "status": "ready",
                    "pid": process.pid,
                    "session_nonce": "not-this-process",
                })
                self.assertFalse(phone_upload.stop_state_process(state_path))
                self.assertIsNone(process.poll())
            finally:
                process.terminate()
                process.wait(timeout=2)

    def test_process_identity_requires_state_path_and_nonce(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "session.json"
            script_path = str(phone_upload.SCRIPT_PATH) if hasattr(phone_upload, "SCRIPT_PATH") else str(SCRIPT_PATH)
            staging_root = Path(temporary) / "staging"
            save_dir = staging_root / "session"
            matching = (
                f"/usr/bin/python3 {script_path} serve --project /tmp/project "
                f"--state {state_path.resolve()} --save-dir {save_dir.resolve()} "
                "--session-nonce expected-session-nonce --token secret"
            )
            state = {
                "pid": 123,
                "session_nonce": "expected-session-nonce",
                "save_dir": str(save_dir),
            }
            with mock.patch.object(phone_upload, "STAGING_ROOT", staging_root), \
                 mock.patch.object(phone_upload, "process_command", return_value=matching):
                self.assertTrue(phone_upload.state_process_matches(123, state_path, state))
                self.assertFalse(phone_upload.state_process_matches(
                    123, state_path, {
                        "pid": 123,
                        "session_nonce": "wrong-session-nonce-value",
                        "save_dir": str(save_dir),
                    }
                ))


if __name__ == "__main__":
    unittest.main()
