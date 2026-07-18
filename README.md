# Codex Phone Upload

用微信扫描 Mac 上的一次性二维码，把手机截图或照片直接放进当前 Codex 桌面应用的输入框。

- 不自动发送消息
- 不读取或分析图片内容
- 不把图片保存到项目目录
- 一次最多 12 张，每张不超过 25 MB

仓库同时提供两种入口：

1. **macOS 小工具**：适合日常使用。需要时打开应用即生成二维码，不需要先发起 Codex 对话。
2. **Codex Skill**：适合在当前任务中用 `$phone-upload` 临时唤起，也保留可选的公网模式。

## macOS 小工具

### 工作方式

小工具会在 Mac 的局域网地址上启动一个短期 HTTP 服务，生成随机的一次性地址。手机与 Mac 在同一 Wi-Fi 时，微信扫码即可多选图片。上传成功后，工具会激活 Codex、聚焦当前输入框并逐张粘贴，只有检测到附件出现在输入框后才向手机报告成功，随后约 3 秒自动退出。

二维码 10 分钟过期，成功上传一批图片后立即失效。应用只在需要时打开，不设菜单栏常驻、固定手机网址、云端中转、开机自启或全局快捷键。

### 系统要求

- macOS 14 或更高版本
- Codex 桌面应用
- 手机与 Mac 连接同一 Wi-Fi
- 首次使用时授予“辅助功能”权限
- Xcode Command Line Tools（仅源码构建需要）

### 构建、验证和安装

```bash
cd menubar
swift run --jobs 1 CodexPhoneUploadSelfTests
./script/build_and_run.sh --verify
./script/build_and_run.sh --install
```

安装目标默认为 `~/Applications/CodexPhoneUpload.app`。以后从“应用程序”或 Spotlight 按需启动即可。

## Codex Skill

Skill 位于 [`skills/phone-upload`](skills/phone-upload)。默认使用同一 Wi-Fi 的局域网直传；只有用户明确要求时才使用 `--remote` 和 Cloudflare 临时隧道。

手动安装到个人 Codex：

```bash
mkdir -p ~/.codex/skills
ln -s "$(pwd)/skills/phone-upload" ~/.codex/skills/phone-upload
```

重新打开 Codex 后，可以输入：

```text
$phone-upload 生成二维码，把手机图片放进当前输入框，不要发送，也不要分析。
```

Skill 的局域网模式还需要：

```bash
brew install qrencode
```

仓库自带 Apple Silicon 和 Intel 通用的粘贴辅助程序。修改 `paste_files.swift` 后可重新构建：

```bash
./skills/phone-upload/scripts/build_helper.sh
```

公网模式是可选能力，需要额外安装 `cloudflared`。macOS 小工具刻意只提供更快、更简单的同一 Wi-Fi 模式。

## 隐私与安全

- 上传 URL 含 64 位十六进制随机令牌，不使用固定入口。
- 服务只存在于当前 Mac；局域网模式不经过第三方服务器。
- 页面设置 10 分钟有效期，成功一批后停止监听。
- 临时图片只在粘贴期间进入系统临时目录（Skill）或内存（菜单栏工具），不会进入当前项目。
- 工具通过 macOS 辅助功能 API 定位 Codex 输入框，因此首次使用必须获得用户授权。

## 开发

目录结构：

```text
.codex-plugin/          Codex 插件元数据
skills/phone-upload/    Codex Skill 与 Python/Swift 辅助程序
menubar/                SwiftUI macOS 小工具（目录名沿用早期原型）
```

项目使用 MIT License。
