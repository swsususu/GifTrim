<p align="center">
  <img src="docs/images/icon.png" width="128" alt="GifTrim icon">
</p>

<h1 align="center">GifTrim</h1>

<p align="center">
  <b>Make beautiful, tiny GIFs on your Mac, or let your AI assistant make them for you.</b><br>
  Video → GIF · screen &amp; iPhone recording · captions · crop · target size · CLI · MCP server
</p>

<p align="center">
  <a href="https://github.com/swsususu/GifTrim/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/swsususu/GifTrim?color=ec4899"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Universal" src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-6366f1">
  <a href="docs/AI.md"><img alt="MCP" src="https://img.shields.io/badge/MCP-ready-8b5cf6"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/swsususu/GifTrim"></a>
  <a href="https://github.com/swsususu/GifTrim/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/swsususu/GifTrim?style=social"></a>
</p>

<p align="center">
  English | <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/images/demo.gif" width="720" alt="GifTrim demo (this GIF was made with GifTrim)">
  <br><sub>This GIF was recorded and encoded with GifTrim itself.</sub>
</p>

GifTrim is a free, open-source replacement for GIF Brewery. Drop in a video, screen recording,
animated GIF/APNG/WebP or a folder of images. Trim it, crop it, caption it, and export a GIF
that is **sharp and small**. Encoding uses [gifski](https://gif.ski), which builds a
cross-frame palette with pngquant, so you get thousands of colors per frame instead of the
usual 256-color mush.

It is also **built for AI**. A local MCP server and an agent skill let Claude, Cursor, VS Code
Copilot, Codex and other assistants make GIFs for you:

> *"Turn the last screen recording on my Desktop into a GIF under 2 MB for the README and add
> the caption 'Drag to reorder'."*

## Why GifTrim

| | GifTrim | Typical online converter |
|---|---|---|
| Quality | gifski, thousands of colors per frame | 256-color dither |
| Privacy | 100% local, nothing uploaded | Uploads your video |
| Size control | Live size estimate, **target size** (e.g. ≤ 2 MB) | Guess and retry |
| Recording | Screen region, camera, **iPhone over USB** | — |
| Automation | CLI with `--json`, JSON jobs, **MCP server**, agent skill | — |
| Price | Free, GPL-3.0 | Ads, watermarks, subscriptions |

## Features

<table>
<tr>
<td width="50%"><img src="docs/images/editor.png" alt="Editor"></td>
<td width="50%"><img src="docs/images/crop.png" alt="Crop"></td>
</tr>
<tr>
<td align="center"><sub>Timeline trim, draggable captions, live size estimate</sub></td>
<td align="center"><sub>Crop with locked ratios (1:1, 16:9, 9:16…)</sub></td>
</tr>
<tr>
<td width="50%"><img src="docs/images/export.png" alt="Export preview"></td>
<td width="50%"><img src="docs/images/welcome.png" alt="Welcome"></td>
</tr>
<tr>
<td align="center"><sub>The preview <i>is</i> the real GIF, with its real file size</sub></td>
<td align="center"><sub>Drop a file, record the screen, or use a camera / iPhone</sub></td>
</tr>
</table>

- **Inputs**: MOV / MP4 / M4V, GIF / APNG / WebP, or many images (sorted by name into a sequence)
- **Record**: a screen region or the whole screen (ScreenCaptureKit, GifTrim's own windows
  excluded), a webcam or Continuity Camera, or an **iPhone/iPad screen over USB**
- **Trim**: thumbnail timeline with handles. Keys: `I` / `O` set in/out, `Space` plays,
  `←` / `→` step one frame
- **Crop**: drag on the canvas, lock aspect ratios, or enter exact pixels
- **Captions**: multiple text layers you drag into place, with font, size, color, outline, shadow
  and alignment. Each can show only for part of the clip
- **Stickers and watermarks**: PNG or logo overlays with size, opacity and timing
- **Look**: 13 effects (noir, sepia, comic…), plus brightness, contrast, saturation, sharpen and
  vignette
- **Output**:
  - width, fps up to 50, speed from 0.25× to 4×
  - forward, reverse, or **bounce** for a seamless loop
  - loop count, quality, lossy and motion controls, fast mode
  - presets, and **auto-fit to a target size**
- **Frame editor**: delete, duplicate, reorder, or retime individual frames
- **Copy and paste**: copy the GIF and paste it straight into Slack, WeChat, GitHub or Notion

## 🤖 For AI agents

GifTrim gives AI three ways to drive it. All of them run on your Mac.

**1. MCP server.** Claude Desktop / Code, Cursor, VS Code, Windsurf, Codex, Kilo…

```bash
claude mcp add giftrim -- /Applications/GifTrim.app/Contents/Helpers/giftrim mcp
```

```json
{ "mcpServers": { "giftrim": { "command": "/Applications/GifTrim.app/Contents/Helpers/giftrim", "args": ["mcp"] } } }
```

| Tool | |
|---|---|
| `get_media_info` | Duration, size, fps of any file |
| `preview_frame` | Returns an **image** of one edited frame, so the model can check crop and captions before encoding |
| `estimate_gif` | Predicts file size in about a second |
| `make_gif` | Does the full job and reports progress |

**2. Agent skill.** Copy [`skills/giftrim`](skills/giftrim/SKILL.md) to `~/.claude/skills/` or
`~/.agents/skills/`.

**3. JSON-first CLI.** Every command takes `--json`, and you can pipe in a whole job:

```bash
giftrim info demo.mov --json
giftrim demo.mov -o demo.gif --start 3 --end 12 --width 720 --text "Drag to reorder" --target-size 2048 --json
echo '{"inputs":["/abs/demo.mov"],"aspect":"1:1","mode":"bounce"}' | giftrim run - --json
```

Full guide, including VS Code, Codex and Cursor configs: **[docs/AI.md](docs/AI.md)** ·
[llms.txt](llms.txt)

## Install

**Homebrew** (also links the `giftrim` command):

```bash
brew install --cask swsususu/tap/giftrim
```

**DMG**: download `GifTrim_x.y.z_universal.dmg` from
[Releases](https://github.com/swsususu/GifTrim/releases/latest) and drag GifTrim to Applications.

GifTrim is ad-hoc signed and **not notarised** yet, so macOS blocks it the first time you open
it. Right-click the app and choose **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/GifTrim.app
```

Permissions:

- Screen recording is granted in **System Settings → Privacy & Security → Screen & System
  Audio Recording**. Relaunch GifTrim afterwards.
- Camera access is requested the first time you use it.

## Usage

1. **Open**: drop a file on the window or Dock icon, press `⌘O`, record the screen (`⇧⌘R`), or
   use a camera or iPhone (`⇧⌘C`).
2. **Trim**: drag the yellow handles, or press `I` / `O` at the playhead.
3. **Edit** in the inspector tabs: Output, Crop, Text, Image, Filter, Frames.
   The toolbar keeps showing the estimated file size.
4. **Export** (`⌘E`): GifTrim encodes the real GIF and plays it. Then choose **Save…** or **Copy**.

Tips:

- **README or PR demos**: width 800, 12 fps, lossy 70.
- **Chat size limits**: Output → Target size.
- **Seamless loops**: Output → Bounce.
- **Files too big?** Lower fps first, then width, then turn on lossy.

## Command line

```text
giftrim <input...> -o out.gif [options]    convert
giftrim info <file>                        inspect
giftrim estimate <input...> [options]      predict size
giftrim snapshot <input...> -o f.png       preview one edited frame
giftrim run <job.json | ->                 JSON job (giftrim schema)
giftrim mcp                                MCP server
```

Run `giftrim --help` for every option.

## Build from source

You need Xcode or the Command Line Tools (Swift 6), and Rust (`rustup`) for gifski.

```bash
git clone --recursive https://github.com/swsususu/GifTrim.git
cd GifTrim
make gifski   # universal libgifski.a
make test     # unit tests
make app      # build/GifTrim.app (universal, hardened runtime)
make dmg      # build/GifTrim_0.1.2_universal.dmg
```

`APP_ARCHS=arm64 make app` builds only for Apple Silicon. `CODESIGN_IDENTITY="Developer ID…"`
signs with your own certificate. If you only have the Command Line Tools, `scripts/sdk.sh` picks an
SDK whose SwiftUI builds without Xcode's macro plugins.

```text
Sources/GifTrimCore   UI-free pipeline: decode → plan → composite → gifski. JobSpec API
Sources/GifTrimCLI    giftrim CLI + MCP server
Sources/GifTrim       SwiftUI / AppKit app, recording
Tests/                swift-testing (orientation, captions, timing, bounce, JSON jobs…)
Vendor/gifski         gifski 1.34.0 (submodule)
```

## Roadmap

- [ ] Developer ID signing and notarisation
- [x] In-app update check (GifTrim → Check for Updates…)
- [ ] English UI (the app is Chinese-first today; the CLI and MCP are in English)
- [ ] Save and restore projects
- [ ] Export MP4 / WebP / APNG
- [ ] Click highlights while recording the screen

Ideas and PRs are welcome. If GifTrim saves you time, **a ⭐ helps others find it.**

## Credits and license

GifTrim is [GPL-3.0-or-later](LICENSE). It statically links
[gifski](https://github.com/ImageOptim/gifski) by Kornel Lesiński (AGPL-3.0-or-later), combined
under §13 of GPLv3 and AGPLv3. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
