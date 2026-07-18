---
name: phone-upload
description: Start a temporary QR-code upload page that lets a phone or WeChat user select images and paste them into the current Codex desktop composer as unsent attachments. Use fast same-Wi-Fi local transfer by default and public remote transfer only when explicitly requested. Use when the user asks to scan a QR code, upload phone screenshots or photos, or put phone images into the active Codex input box. This skill only transfers files; it must not send a Codex turn, inspect, analyze, summarize, or modify uploaded images.
---

# Phone Upload

1. Treat the current shell working directory as the active Codex project. Do not choose a different project unless the user explicitly provides one.
2. For the default fast same-Wi-Fi mode, run:

   ```bash
   python3 <skill-directory>/scripts/phone_upload.py start --project "$PWD"
   ```

   Replace `<skill-directory>` with the absolute directory containing this `SKILL.md`.
   Only when the user explicitly says the phone is not on the same Wi-Fi or asks for public/remote mode, append `--remote`.
3. Read `QR_PATH`, `UPLOAD_URL`, `MODE`, and `EXPIRES_AT` from the command output.
4. Display the local image at `QR_PATH` in the response so the user can scan it with WeChat. Also provide `UPLOAD_URL` as a clickable fallback. If `MODE=local`, say the phone and Mac must be on the same Wi-Fi.
5. State that a successful phone upload will place the images in the current Codex input box without sending them, and state when the link expires. Stop after that response.

Do not wait for uploads, open uploaded files, analyze their contents, send the composer, or start another Codex task. The phone page uses a private temporary local staging file only long enough to paste the selected images into the current Codex composer, then closes the one-time session after a successful batch. It must not save uploaded images into the project.

If startup fails because Codex desktop or macOS Accessibility permission is missing, report the exact dependency error. In remote mode, also report any `cloudflared` error and suggest the default same-Wi-Fi mode. Do not fall back to saving images in the project.
