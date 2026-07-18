# Codex Phone Upload

Scan a QR code with WeChat and place phone screenshots or photos directly into the current Codex desktop composer.

- Chinese and English interfaces, following the Mac or phone language by default
- A multi-image upload queue with thumbnails, file sizes, removal, and progress
- Up to 12 images per batch, 25 MB per image, and 100 MB total
- Locks the active Codex composer when the QR code is created
- If a batch stops partway through, retry only the remaining images
- Does not send the Codex message
- Does not inspect or analyze images
- Does not save images to the project directory

## Install in One Command

Requirements: macOS 14 or later, the Codex desktop app, and Xcode Command Line Tools.

Paste this command into Terminal:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dingaiminGIT/codex-phone-upload/main/install.sh)"
```

The installer automatically:

1. Downloads or updates the source at `~/.local/share/codex-phone-upload`.
2. Builds and installs `~/Applications/CodexPhoneUpload.app`.
3. Installs the `$phone-upload` Skill at `~/.codex/skills/phone-upload`.
4. Opens the macOS app when installation finishes.

No Homebrew package is required for same-Wi-Fi uploads. You can [review the installer](install.sh) before running it.

If Xcode Command Line Tools are missing, macOS will open its installer. Finish that installation, then run the same command again.

## First-Time Setup

The app needs Accessibility permission to focus the Codex composer and paste attachments.

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Enable **CodexPhoneUpload**.
3. Close and reopen the app.
4. Restart Codex once so it discovers the installed Skill.

This permission is normally required only once. macOS may request it again after the app is rebuilt or upgraded.

If macOS asks whether the app may accept incoming network connections, click **Allow**. This lets the phone reach the temporary upload page over Wi-Fi.

## Everyday Use: Open the App

This is the simplest workflow.

1. Open Codex and select the task that should receive the images.
2. Keep that task and its composer visible.
3. Open **CodexPhoneUpload** from Spotlight or Applications.
4. Scan the QR code with WeChat.
5. Select up to 12 images on the phone and upload them.
6. Wait for the phone page to report success.
7. Return to Codex. The images are attached to the composer but are **not sent**.
8. Add your instructions and send the message manually when ready.

The same QR-code page accepts multiple batches until its 10-minute link expires. After each successful batch, the phone queue clears so you can choose more images. The app does not stay in the menu bar or start at login; close it when you finish.

The Mac app and phone page automatically use Simplified Chinese when the system or browser language starts with Chinese; otherwise they use English. Use the language menu to switch between **中文** and **English** manually.

Before uploading, the phone page shows each selected image, its file size, and a remove action. It rejects batches over 12 images, individual images over 25 MB, or a combined size over 100 MB before transfer begins.

## Alternative Use: Trigger the Skill in Codex

The one-command installer also installs the Skill. In the target Codex task, enter:

```text
$phone-upload Generate a QR code and place images from my phone into the current composer. Do not send or analyze them.
```

Codex displays a QR code and a fallback link. Scan the code, select the images, upload them, and wait for the success message. The images appear as unsent composer attachments.

## Same-Wi-Fi and Remote Modes

The macOS app and the Skill use direct same-Wi-Fi transfer by default. This is the fastest and most reliable option, and images do not pass through a third-party server.

Only the Skill supports optional remote mode. Install `cloudflared` first:

```bash
brew install cloudflared
```

Then enter:

```text
$phone-upload Use remote mode. Generate a QR code and place images from my phone into the current composer. Do not send or analyze them.
```

Remote mode creates a temporary Cloudflare tunnel and can be slower or less reliable than same-Wi-Fi mode.

## Update

Run the same installation command again:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dingaiminGIT/codex-phone-upload/main/install.sh)"
```

The installer pulls the latest source, rebuilds the app, and refreshes the Skill link. Restart Codex if the Skill changed. A rebuilt app may need Accessibility permission again.

## Troubleshooting

### The phone cannot open the QR-code page

- Confirm that the phone and Mac are on the same Wi-Fi network.
- Temporarily disable VPNs on the phone and Mac.
- Avoid guest Wi-Fi networks that isolate connected devices.
- Allow incoming connections in the macOS firewall prompt.
- Reopen the app if the QR code is more than 10 minutes old.

### The phone reports success, but Codex has no attachment

- Keep the intended Codex task open and its composer visible.
- Confirm that **CodexPhoneUpload** is enabled under **System Settings → Privacy & Security → Accessibility**.
- Run the one-command installer again to update the app.
- Reopen the app and retry with a new QR code.

### Codex does not recognize `$phone-upload`

Confirm the installed link:

```bash
ls -ld ~/.codex/skills/phone-upload
```

Then restart Codex. The macOS app can still be used independently of the Skill.

### The Accessibility prompt appears again

This can happen after rebuilding, replacing, moving, or upgrading the app. Enable the current app again in **System Settings → Privacy & Security → Accessibility**.

## Manual Installation

Use these steps only if you do not want to run the one-command installer.

```bash
git clone https://github.com/dingaiminGIT/codex-phone-upload.git
cd codex-phone-upload

# Build and install the app
cd menubar
./script/build_and_run.sh --install
cd ..

# Install the Skill
mkdir -p ~/.codex/skills
ln -s "$(pwd)/skills/phone-upload" ~/.codex/skills/phone-upload
```

Restart Codex after installing the Skill.

## Uninstall

```bash
rm -rf ~/Applications/CodexPhoneUpload.app
rm ~/.codex/skills/phone-upload
rm -rf ~/.local/share/codex-phone-upload
```

## Privacy and Security

- Upload URLs contain a random 64-character hexadecimal token and never use a fixed endpoint.
- Local app sessions expire after 10 minutes and can accept multiple batches during that window. Skill sessions still stop after one successful batch.
- The app locks the active Codex composer when it creates the QR code instead of silently choosing a different task later.
- The Skill keeps temporary images only long enough to paste them; the app keeps uploads in memory.
- Uploaded images are never written to the current project.
- The tool uses the macOS Accessibility API only to focus the Codex composer and paste attachments.
- The tool does not send the Codex message and does not analyze uploaded images.

## Development

Run the parser self-tests and verify the app build:

```bash
cd menubar
swift run --jobs 1 CodexPhoneUploadSelfTests
./script/build_and_run.sh --verify
```

Rebuild the universal Apple Silicon and Intel helper after changing `paste_files.swift`:

```bash
./skills/phone-upload/scripts/build_helper.sh
```

For mobile layout checks, append `?preview=queue` to an active upload URL. This shows a disabled six-image fixture and never uploads it.

Repository layout:

```text
.codex-plugin/          Codex plugin metadata
skills/phone-upload/    Codex Skill plus Python and Swift helpers
menubar/                SwiftUI macOS app
install.sh              One-command installer for the app and Skill
```

Licensed under the MIT License.
