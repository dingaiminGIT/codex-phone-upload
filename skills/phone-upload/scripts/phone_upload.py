#!/usr/bin/env python3
"""Create a one-time image upload page that pastes files into Codex."""

import argparse
import hashlib
import html
import json
import mimetypes
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from datetime import datetime, timezone
from email import policy
from email.parser import BytesParser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


DEFAULT_TTL_SECONDS = 10 * 60
SHUTDOWN_DELAY_SECONDS = 5
MAX_FILES = 12
MAX_FILE_BYTES = 25 * 1024 * 1024
MAX_REQUEST_BYTES = 100 * 1024 * 1024
ALLOWED_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".heif"}
URL_PATTERN = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")
STAGING_ROOT = Path(tempfile.gettempdir()) / "codex-phone-upload"
STAGING_MAX_AGE_SECONDS = 24 * 60 * 60
SESSION_STATE_ROOT = Path.home() / "Library" / "Application Support" / "CodexPhoneUpload" / "skill-sessions"


class PartialPasteError(RuntimeError):
    def __init__(self, attached, total, message):
        super().__init__(message)
        self.attached = attached
        self.total = total


def iso_utc(timestamp):
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace("+00:00", "Z")


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(str(temp), str(path))
    os.chmod(str(path), 0o600)


def process_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def read_state(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def process_command(pid):
    if not process_alive(pid):
        return ""
    try:
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "command="],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def state_process_matches(pid, state_path, state=None):
    state = state if state is not None else read_state(state_path)
    command = process_command(pid)
    if not command:
        return False
    try:
        nonce = state.get("session_nonce")
        save_dir = validated_staging_dir(state.get("save_dir", ""))
        if not isinstance(nonce, str) or len(nonce) < 20 or save_dir is None:
            return False
        script_path = Path(__file__).resolve()
        resolved_state_path = Path(state_path).expanduser().resolve()
        return all((
            f"{script_path} serve " in command,
            f"--state {resolved_state_path} --save-dir {save_dir} " in command,
            f"--session-nonce {nonce} --token " in command,
        ))
    except (OSError, RuntimeError, ValueError):
        return False


def stop_state_process(state_path):
    state = read_state(state_path)
    pid = state.get("pid")
    if not process_alive(pid) or not state_process_matches(pid, state_path, state):
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return False
    deadline = time.time() + 3
    while time.time() < deadline and process_alive(pid):
        time.sleep(0.1)
    if process_alive(pid) and state_process_matches(pid, state_path, state):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        deadline = time.time() + 1
        while time.time() < deadline and process_alive(pid):
            time.sleep(0.05)
    return not process_alive(pid)


def terminate_process(process, timeout=5):
    if process is None or process.poll() is not None:
        return
    try:
        process.terminate()
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=timeout)
    except OSError:
        pass


def validated_staging_dir(path):
    try:
        candidate_input = Path(path).expanduser()
        if not candidate_input.is_absolute() or candidate_input.is_symlink():
            return None
        root = STAGING_ROOT.expanduser().resolve()
        candidate = candidate_input.resolve()
        if candidate == root or candidate.parent != root:
            return None
        return candidate
    except (OSError, RuntimeError, ValueError):
        return None


def cleanup_staging_dir(path):
    candidate = validated_staging_dir(path)
    if candidate is None:
        return False
    try:
        shutil.rmtree(candidate)
        return True
    except FileNotFoundError:
        return True
    except OSError:
        return False


def clean_old_staging():
    if not STAGING_ROOT.is_dir():
        return
    cutoff = time.time() - STAGING_MAX_AGE_SECONDS
    for child in STAGING_ROOT.iterdir():
        try:
            if child.is_dir() and child.stat().st_mtime < cutoff:
                cleanup_staging_dir(child)
        except OSError:
            pass


def session_root_for_project(project):
    project = Path(project).expanduser().resolve()
    project_id = hashlib.sha256(str(project).encode("utf-8")).hexdigest()[:24]
    return SESSION_STATE_ROOT / project_id


def state_path_for_project(project):
    return session_root_for_project(project) / "session.json"


def legacy_state_path_for_project(project):
    return Path(project).expanduser().resolve() / ".codex" / "phone-upload" / "session.json"


def prepare_session_root(project):
    SESSION_STATE_ROOT.mkdir(parents=True, exist_ok=True)
    os.chmod(str(SESSION_STATE_ROOT), 0o700)
    session_root = session_root_for_project(project)
    session_root.mkdir(parents=True, exist_ok=True)
    os.chmod(str(session_root), 0o700)
    return session_root


def paste_into_codex(paths):
    helper = Path(__file__).with_name("paste_files")
    if not helper.is_file():
        raise RuntimeError("缺少 Codex 输入框粘贴组件")
    command = [str(helper)]
    if os.environ.get("CODEX_PHONE_UPLOAD_CLIPBOARD_ONLY") == "1":
        command.append("--clipboard-only")
    command.extend(str(path) for path in paths)
    result = subprocess.run(command, capture_output=True, text=True, timeout=45)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        if detail.startswith("ERROR="):
            detail = detail[6:]
        partial = re.match(r"PARTIAL_ATTACHED=(\d+);TOTAL=(\d+);ERROR=(.*)", detail, re.DOTALL)
        if partial:
            raise PartialPasteError(int(partial.group(1)), int(partial.group(2)), partial.group(3).strip())
        raise RuntimeError(detail or "无法把图片粘贴到 Codex 输入框")


def check_codex_bridge():
    helper = Path(__file__).with_name("paste_files")
    if not helper.is_file():
        raise RuntimeError("缺少 Codex 输入框粘贴组件")
    result = subprocess.run(
        [str(helper), "--check-accessibility"],
        capture_output=True,
        text=True,
        timeout=45,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        if detail.startswith("ERROR="):
            detail = detail[6:]
        raise RuntimeError(detail or "Codex 输入框粘贴组件不可用")


def generate_qr(content, output_path):
    helper = Path(__file__).with_name("paste_files")
    if not helper.is_file():
        raise RuntimeError("缺少二维码生成组件")
    result = subprocess.run(
        [str(helper), "--generate-qr", content, str(output_path)],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        if detail.startswith("ERROR="):
            detail = detail[6:]
        raise RuntimeError(detail or "无法生成上传二维码")


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def local_ipv4():
    candidates = []
    try:
        route = subprocess.run(
            ["/sbin/route", "-n", "get", "default"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        match = re.search(r"^\s*interface:\s*(\S+)", route.stdout, re.MULTILINE)
        if match:
            candidates.append(match.group(1))
    except (OSError, subprocess.TimeoutExpired):
        pass
    candidates.extend(["en0", "en1"])
    for interface in dict.fromkeys(candidates):
        try:
            result = subprocess.run(
                ["/usr/sbin/ipconfig", "getifaddr", interface],
                capture_output=True,
                text=True,
                timeout=3,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        address = result.stdout.strip()
        if re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}", address) and not address.startswith(("127.", "169.254.")):
            return address
    raise RuntimeError("找不到 Mac 的局域网 IPv4 地址，请确认已连接 Wi-Fi")


def safe_name(raw_name, index, extension):
    name = Path(raw_name or "image").name
    stem = Path(name).stem
    stem = unicodedata.normalize("NFKC", stem)
    stem = re.sub(r"[^\w\- ()\[\].]+", "-", stem, flags=re.UNICODE).strip(" .-")
    if not stem:
        stem = "image"
    stem = stem[:60]
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return f"{stamp}-{index:02d}-{stem}{extension}"


def sniff_extension(data, original_name):
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if data.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if data.startswith((b"GIF87a", b"GIF89a")):
        return ".gif"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return ".webp"
    if len(data) >= 12 and data[4:8] == b"ftyp":
        brand = data[8:12]
        if brand in {b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1"}:
            suffix = Path(original_name or "").suffix.lower()
            return suffix if suffix in {".heic", ".heif"} else ".heic"
    return None


def _legacy_upload_page(action_path, project_name, expires_at):
    action = html.escape(action_path, quote=True)
    project = html.escape(project_name)
    expires = html.escape(iso_utc(expires_at))
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <title>上传图片到 Codex 输入框</title>
  <style>
    :root {{ color-scheme: light; font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }}
    body {{ margin:0; background:#f5f7fb; color:#18212f; }}
    main {{ max-width:560px; margin:0 auto; padding:32px 18px 48px; }}
    .card {{ background:white; border-radius:20px; padding:24px; box-shadow:0 10px 35px rgba(26,40,70,.10); }}
    h1 {{ font-size:24px; margin:0 0 8px; }}
    p {{ color:#5a6473; line-height:1.6; }}
    .project {{ background:#eef4ff; border-radius:12px; padding:12px; overflow-wrap:anywhere; }}
    input {{ display:block; width:100%; box-sizing:border-box; margin:20px 0; padding:16px; border:2px dashed #9bb8ee; border-radius:14px; background:#f8fbff; }}
    button {{ width:100%; border:0; border-radius:14px; padding:15px; color:white; background:#1769e0; font-size:17px; font-weight:650; }}
    button:disabled {{ opacity:.55; }}
    #status {{ min-height:24px; margin-top:14px; color:#1769e0; }}
    small {{ display:block; color:#7b8492; line-height:1.5; margin-top:18px; }}
  </style>
</head>
<body>
<main><div class="card">
  <h1>上传图片</h1>
  <p>选择手机中的图片，上传完成后会直接出现在电脑上的 Codex 输入框中。</p>
  <div class="project">项目：{project}</div>
  <form id="form" action="{action}" method="post" enctype="multipart/form-data">
    <input id="images" name="images" type="file" accept="image/*,.heic,.heif" multiple required>
    <button id="submit" type="submit">上传到 Codex 输入框</button>
  </form>
  <div id="status"></div>
  <small>一次最多 {MAX_FILES} 张，每张不超过 {MAX_FILE_BYTES // (1024 * 1024)} MB。链接为一次性地址，将在 {expires} 失效。</small>
</div></main>
<script>
const form = document.getElementById('form');
const button = document.getElementById('submit');
const status = document.getElementById('status');
form.addEventListener('submit', async (event) => {{
  event.preventDefault();
  button.disabled = true;
  status.textContent = '正在上传，请不要关闭页面…';
  try {{
    const response = await fetch(form.action, {{ method:'POST', body:new FormData(form) }});
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || '上传失败');
    status.textContent = `上传成功：${{result.count}} 张图片已放入 Codex 输入框。现在可以关闭页面。`;
    form.style.display = 'none';
  }} catch (error) {{
    status.textContent = error.message || '上传失败，请重试。';
    button.disabled = false;
  }}
}});
</script>
</body></html>"""


def upload_page(action_path, project_name, expires_at, mode="local"):
    template_path = Path(__file__).resolve().parent.parent / "assets" / "mobile-upload.html"
    template = template_path.read_text(encoding="utf-8")
    replacements = {
        "__ACTION__": html.escape(action_path, quote=True),
        "__TARGET__": html.escape(project_name),
        "__EXPIRES__": html.escape(iso_utc(expires_at)),
        "__MAX_FILES__": str(MAX_FILES),
        "__MAX_FILE_BYTES__": str(MAX_FILE_BYTES),
        "__MAX_FILE_MB__": str(MAX_FILE_BYTES // (1024 * 1024)),
        "__MAX_TOTAL_BYTES__": str(MAX_REQUEST_BYTES),
        "__MAX_TOTAL_MB__": str(MAX_REQUEST_BYTES // (1024 * 1024)),
        "__LOCAL_MODE__": "true" if mode == "local" else "false",
    }
    for placeholder, value in replacements.items():
        template = template.replace(placeholder, value)
    return template


class UploadServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, config):
        super().__init__(address, handler)
        self.config = config
        self.completed = False
        self.upload_lock = threading.Lock()


class UploadHandler(BaseHTTPRequestHandler):
    server_version = "CodexPhoneUpload/0.4.2"

    def log_message(self, fmt, *args):
        message = "%s - %s\n" % (self.log_date_time_string(), fmt % args)
        with open(self.server.config["request_log"], "a", encoding="utf-8") as log:
            log.write(message)

    def send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def english(self):
        return not self.headers.get("Accept-Language", "").lower().startswith("zh")

    def message(self, chinese, english):
        return english if self.english() else chinese

    def valid_session(self):
        parsed = urlparse(self.path)
        expected = "/upload/" + self.server.config["token"]
        return parsed.path == expected and time.time() < self.server.config["expires_at"]

    def do_GET(self):
        if not self.valid_session() or self.server.completed:
            self.send_error(HTTPStatus.GONE, "Upload link expired")
            return
        body = upload_page(
            "/upload/" + self.server.config["token"],
            self.server.config["project_name"],
            self.server.config["expires_at"],
            self.server.config.get("mode", "local"),
        ).encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not self.valid_session() or self.server.completed:
            self.send_json(HTTPStatus.GONE, {"error": self.message("上传链接已失效", "The upload link has expired")})
            return
        if not self.server.upload_lock.acquire(blocking=False):
            self.send_json(HTTPStatus.CONFLICT, {
                "error": self.message("正在处理上一批图片，请稍后重试", "Another batch is being attached. Try again shortly")
            })
            return
        try:
            self.handle_upload()
        finally:
            self.server.upload_lock.release()

    def handle_upload(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": self.message("上传内容过大或为空", "The upload is empty or exceeds 100 MB")})
            return
        content_type = self.headers.get("Content-Type", "")
        if not content_type.startswith("multipart/form-data"):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": self.message("请求格式不正确", "The upload request is malformed")})
            return

        body = self.rfile.read(length)
        mime_message = BytesParser(policy=policy.default).parsebytes(
            (
                "Content-Type: " + content_type + "\r\n"
                "MIME-Version: 1.0\r\n\r\n"
            ).encode("utf-8") + body
        )
        if not mime_message.is_multipart():
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": self.message("请求格式不正确", "The upload request is malformed")})
            return
        items = [
            part for part in mime_message.iter_parts()
            if part.get_param("name", header="content-disposition") == "images"
        ]
        if not items or len(items) > MAX_FILES:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": self.message(f"请选择 1 到 {MAX_FILES} 张图片", f"Choose 1 to {MAX_FILES} images")})
            return

        save_dir = Path(self.server.config["save_dir"])
        try:
            save_dir.mkdir(parents=True, exist_ok=True)
            os.chmod(str(save_dir), 0o700)
        except OSError as error:
            self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(error)})
            return

        saved = []
        try:
            for index, item in enumerate(items, 1):
                data = item.get_payload(decode=True) or b""
                if not data:
                    raise ValueError(self.message("图片文件为空", "The image file is empty"))
                if len(data) > MAX_FILE_BYTES:
                    raise ValueError(self.message(
                        f"单张图片不能超过 {MAX_FILE_BYTES // (1024 * 1024)} MB",
                        f"Each image must be {MAX_FILE_BYTES // (1024 * 1024)} MB or smaller",
                    ))
                original_name = item.get_filename() or ""
                extension = sniff_extension(data[:64], original_name)
                if extension not in ALLOWED_EXTENSIONS:
                    raise ValueError(self.message(
                        "只支持 PNG、JPEG、GIF、WebP、HEIC 和 HEIF 图片",
                        "Only PNG, JPEG, GIF, WebP, HEIC, and HEIF images are supported",
                    ))
                filename = safe_name(original_name, index, extension)
                target = save_dir / filename
                counter = 1
                while target.exists():
                    target = target.with_name(f"{target.stem}-{counter}{target.suffix}")
                    counter += 1
                with target.open("xb") as output:
                    output.write(data)
                os.chmod(str(target), 0o600)
                saved.append(target)
        except (OSError, ValueError) as error:
            cleanup_staging_dir(save_dir)
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
            return

        try:
            try:
                paste_into_codex(saved)
            except PartialPasteError as error:
                state = dict(self.server.config["state"])
                state.update({
                    "status": "partial_attach_failed",
                    "failed_at": iso_utc(time.time()),
                    "attached": error.attached,
                    "attachment_count": error.total,
                })
                atomic_json(Path(self.server.config["state_path"]), state)
                self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {
                    "error": self.message("部分图片未能放入 Codex", "Some images could not be attached to Codex"),
                    "attached": error.attached,
                    "total": error.total,
                })
                return
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                state = dict(self.server.config["state"])
                state.update({
                    "status": "attach_failed",
                    "failed_at": iso_utc(time.time()),
                    "error": str(error),
                })
                atomic_json(Path(self.server.config["state_path"]), state)
                self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {
                    "error": self.message(
                        str(error),
                        "Could not attach the images. Keep the target Codex task open and try again.",
                    )
                })
                return

            self.server.completed = True
            state = dict(self.server.config["state"])
            state.update({
                "status": "completed",
                "completed_at": iso_utc(time.time()),
                "attachment_count": len(saved),
            })
            atomic_json(Path(self.server.config["state_path"]), state)
            self.send_json(HTTPStatus.OK, {"count": len(saved)})
            threading.Timer(SHUTDOWN_DELAY_SECONDS, self.server.shutdown).start()
        finally:
            cleanup_staging_dir(save_dir)


def run_server(args):
    project = Path(args.project).expanduser().resolve()
    state_path = Path(args.state).expanduser().resolve()
    save_dir = validated_staging_dir(args.save_dir)
    if save_dir is None:
        raise RuntimeError("拒绝使用临时目录根目录之外的上传目录")
    session_dir = state_path.parent
    clean_old_staging()
    save_dir.mkdir(parents=True, exist_ok=True)
    session_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(str(save_dir), 0o700)
    os.chmod(str(session_dir), 0o700)

    request_log = session_dir / "requests.log"
    tunnel_log = session_dir / "tunnel.log"
    expires_at = float(args.expires_at)
    initial_state = {
        "status": "starting",
        "pid": os.getpid(),
        "project": str(project),
        "save_dir": str(save_dir),
        "expires_at": iso_utc(expires_at),
        "port": args.port,
        "session_nonce": args.session_nonce,
    }
    atomic_json(state_path, initial_state)

    server = None
    tunnel = None
    timer = None
    try:
        bind_host = "0.0.0.0" if args.mode == "local" else "127.0.0.1"
        server = UploadServer((bind_host, args.port), UploadHandler, {})
        if args.mode == "local":
            public_base = f"http://{args.local_ip}:{args.port}"
        else:
            cloudflared = shutil.which("cloudflared")
            if not cloudflared:
                raise RuntimeError("cloudflared 未安装")
            with tunnel_log.open("w", encoding="utf-8") as log:
                tunnel = subprocess.Popen(
                    [cloudflared, "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{args.port}"],
                    stdout=log,
                    stderr=subprocess.STDOUT,
                )

            public_base = None
            deadline = time.time() + 12
            while time.time() < deadline and tunnel.poll() is None:
                try:
                    log_text = tunnel_log.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    log_text = ""
                match = URL_PATTERN.search(log_text)
                if match:
                    public_base = match.group(0)
                    break
                time.sleep(0.2)
            if not public_base:
                raise RuntimeError("无法创建 Cloudflare 临时公网地址；请改用同一 Wi-Fi 极速模式")

        public_url = public_base + "/upload/" + args.token
        qr_path = session_dir / "upload-qr.png"
        generate_qr(public_url, qr_path)
        os.chmod(str(qr_path), 0o600)
        ready_state = dict(initial_state)
        ready_state.update({
            "status": "ready",
            "mode": args.mode,
            "public_url": public_url,
            "qr_path": str(qr_path),
        })
        atomic_json(state_path, ready_state)

        server.config = {
            "token": args.token,
            "project_name": project.name,
            "save_dir": str(save_dir),
            "expires_at": expires_at,
            "state_path": str(state_path),
            "request_log": str(request_log),
            "state": ready_state,
            "mode": args.mode,
        }

        def expire():
            if not server.completed:
                state = dict(ready_state)
                state.update({"status": "expired", "expired_at": iso_utc(time.time())})
                atomic_json(state_path, state)
            server.shutdown()

        timer = threading.Timer(max(0.1, expires_at - time.time()), expire)
        timer.daemon = True
        timer.start()
        server.serve_forever(poll_interval=0.25)
    finally:
        if timer is not None:
            timer.cancel()
        if server is not None:
            server.server_close()
        terminate_process(tunnel)
        cleanup_staging_dir(save_dir)


def require_command(name, install_hint):
    if not shutil.which(name):
        raise RuntimeError(f"缺少 {name}。{install_hint}")


def start_session(args):
    if args.remote:
        require_command("cloudflared", "请先运行：brew install cloudflared")
    check_codex_bridge()
    project = Path(args.project).expanduser().resolve()
    if not project.is_dir():
        raise RuntimeError(f"项目目录不存在：{project}")
    if project == Path(project.anchor):
        raise RuntimeError("拒绝把文件保存到文件系统根目录")

    session_root = prepare_session_root(project)
    state_path = state_path_for_project(project)
    stop_state_process(state_path)
    stop_state_process(legacy_state_path_for_project(project))

    session_id = datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(3)
    save_dir = validated_staging_dir(STAGING_ROOT / session_id)
    if save_dir is None:
        raise RuntimeError("无法创建安全的临时上传目录")
    token = secrets.token_urlsafe(32)
    session_nonce = secrets.token_urlsafe(24)
    port = free_port()
    mode = "remote" if args.remote else "local"
    local_ip = "" if args.remote else local_ipv4()
    expires_at = time.time() + args.ttl
    daemon_log = session_root / "daemon.log"
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "serve",
        "--project", str(project),
        "--state", str(state_path),
        "--save-dir", str(save_dir),
        "--session-nonce", session_nonce,
        "--token", token,
        "--port", str(port),
        "--expires-at", str(expires_at),
        "--mode", mode,
        "--local-ip", local_ip,
    ]
    with daemon_log.open("w", encoding="utf-8") as log:
        daemon = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    atomic_json(state_path, {
        "status": "launching",
        "pid": daemon.pid,
        "project": str(project),
        "save_dir": str(save_dir),
        "expires_at": iso_utc(expires_at),
        "port": port,
        "mode": mode,
        "session_nonce": session_nonce,
    })

    deadline = time.time() + (20 if args.remote else 5)
    state = {}
    while time.time() < deadline:
        state = read_state(state_path)
        if state.get("status") == "ready":
            break
        pid = state.get("pid")
        if pid and not process_alive(pid):
            break
        time.sleep(0.25)
    if state.get("status") != "ready":
        detail = ""
        try:
            detail = daemon_log.read_text(encoding="utf-8", errors="replace")[-2000:].strip()
        except OSError:
            pass
        terminate_process(daemon)
        cleanup_staging_dir(save_dir)
        raise RuntimeError("扫码上传服务启动失败" + (f"：{detail}" if detail else ""))

    print(f"QR_PATH={state['qr_path']}")
    print(f"UPLOAD_URL={state['public_url']}")
    print(f"MODE={state['mode']}")
    print(f"EXPIRES_AT={state['expires_at']}")
    print(f"SESSION_PID={state['pid']}")


def stop_session(args):
    project = Path(args.project).expanduser().resolve()
    state_path = state_path_for_project(project)
    legacy_state_path = legacy_state_path_for_project(project)
    stopped = False
    state = {}
    for candidate in (state_path, legacy_state_path):
        candidate_state = read_state(candidate)
        if not candidate_state:
            continue
        stopped = stop_state_process(candidate) or stopped
        if candidate_state.get("save_dir"):
            cleanup_staging_dir(candidate_state["save_dir"])
        if candidate == state_path:
            state = candidate_state
    if state:
        state["status"] = "stopped"
        state["stopped_at"] = iso_utc(time.time())
        atomic_json(state_path, state)
    print("STOPPED=true" if stopped else "STOPPED=false")


def show_status(args):
    project = Path(args.project).expanduser().resolve()
    state_path = state_path_for_project(project)
    state = read_state(state_path)
    if not state:
        state = read_state(legacy_state_path_for_project(project))
    if not state:
        print("STATUS=none")
        return
    print(json.dumps(state, ensure_ascii=False, indent=2))


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    start = subparsers.add_parser("start", help="start a one-time upload session")
    start.add_argument("--project", required=True)
    start.add_argument("--ttl", type=int, default=DEFAULT_TTL_SECONDS)
    start.add_argument("--remote", action="store_true", help="use a public Cloudflare quick tunnel")
    start.set_defaults(func=start_session)

    serve = subparsers.add_parser("serve", help=argparse.SUPPRESS)
    serve.add_argument("--project", required=True)
    serve.add_argument("--state", required=True)
    serve.add_argument("--save-dir", required=True)
    serve.add_argument("--session-nonce", default="")
    serve.add_argument("--token", required=True)
    serve.add_argument("--port", required=True, type=int)
    serve.add_argument("--expires-at", required=True, type=float)
    serve.add_argument("--mode", choices=("local", "remote"), required=True)
    serve.add_argument("--local-ip", default="")
    serve.set_defaults(func=run_server)

    stop = subparsers.add_parser("stop", help="stop the current project upload session")
    stop.add_argument("--project", required=True)
    stop.set_defaults(func=stop_session)

    status = subparsers.add_parser("status", help="show the current project upload session")
    status.add_argument("--project", required=True)
    status.set_defaults(func=show_status)
    return parser.parse_args()


def main():
    args = parse_args()
    if getattr(args, "ttl", DEFAULT_TTL_SECONDS) < 60 or getattr(args, "ttl", DEFAULT_TTL_SECONDS) > 3600:
        raise RuntimeError("ttl 必须在 60 到 3600 秒之间")
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as error:
        print(f"ERROR={error}", file=sys.stderr)
        sys.exit(1)
