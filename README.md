# Codex Phone Upload

Scan a one-time QR code on your Mac with WeChat, then place screenshots or photos from your phone directly into the current Codex desktop composer.

- Does not send the message automatically
- Does not inspect or analyze image contents
- Does not save images to the project directory
- Supports up to 12 images per batch, with a 25 MB limit per image

This repository provides two ways to use the tool:

1. **macOS app**: Best for everyday use. Open the app whenever you need it and a QR code appears immediately—no Codex conversation needs to be started first.
2. **Codex Skill**: Invoke `$phone-upload` from the current task when needed. An optional remote mode is also available.

## macOS App

### How It Works

The app starts a short-lived HTTP server on your Mac's local network address and generates a randomized, one-time URL. When your phone and Mac are on the same Wi-Fi network, scan the QR code with WeChat and select multiple images. After the upload finishes, the app activates Codex, focuses the current composer, and pastes each image. It reports success to the phone only after confirming that the attachments appeared in the composer, then quits automatically after about three seconds.

The QR code expires after 10 minutes and becomes invalid immediately after one successful batch. The app runs only when opened. It has no persistent menu bar item, fixed phone URL, cloud relay, launch-at-login behavior, or global keyboard shortcut.

### Requirements

- macOS 14 or later
- Codex desktop app
- Phone and Mac connected to the same Wi-Fi network
- Accessibility permission on first use
- Xcode Command Line Tools (only required when building from source)

### Build, Verify, and Install

```bash
cd menubar
swift run --jobs 1 CodexPhoneUploadSelfTests
./script/build_and_run.sh --verify
./script/build_and_run.sh --install
```

The default installation path is `~/Applications/CodexPhoneUpload.app`. After installation, open it on demand from Applications or Spotlight.

## Codex Skill

The Skill is located at [`skills/phone-upload`](skills/phone-upload). It uses direct same-Wi-Fi transfer by default. The Cloudflare temporary tunnel is used only when the user explicitly requests `--remote` mode.

To install the Skill manually for your personal Codex setup:

```bash
mkdir -p ~/.codex/skills
ln -s "$(pwd)/skills/phone-upload" ~/.codex/skills/phone-upload
```

Restart Codex, then enter:

```text
$phone-upload Generate a QR code and place images from my phone into the current composer. Do not send or analyze them.
```

Local mode also requires `qrencode`:

```bash
brew install qrencode
```

The repository includes a universal Apple Silicon and Intel build of the paste helper. Rebuild it after changing `paste_files.swift`:

```bash
./skills/phone-upload/scripts/build_helper.sh
```

Remote mode is optional and requires `cloudflared`. The macOS app intentionally supports only the faster and simpler same-Wi-Fi mode.

## Privacy and Security

- Upload URLs contain a random 64-character hexadecimal token and never use a fixed endpoint.
- The service runs only on the current Mac; local mode does not pass through a third-party server.
- Each page expires after 10 minutes, and the listener stops after one successful batch.
- Temporary images exist only in the system temporary directory while the Skill is pasting them, or in memory when using the macOS app. They are never written to the current project.
- The tool uses the macOS Accessibility API to locate the Codex composer, so explicit permission is required on first use.

## Development

Repository layout:

```text
.codex-plugin/          Codex plugin metadata
skills/phone-upload/    Codex Skill plus Python and Swift helpers
menubar/                SwiftUI macOS app (directory name retained from the early prototype)
```

Licensed under the MIT License.
