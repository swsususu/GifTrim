---
name: giftrim
description: Make high-quality, small GIFs on macOS from videos, screen recordings, animated images (GIF/APNG/WebP) or image sequences — trim, crop, resize, speed up, reverse/bounce, add captions and color effects, or hit a target file size. Use when the user asks to create, convert, shrink, caption or optimize a GIF, turn a video/screen recording into a GIF for a README, PR, issue, doc, chat or social post.
---

# GifTrim

`giftrim` is a local macOS command-line tool (bundled with GifTrim.app) that converts media into
optimized GIFs with the gifski encoder. Everything runs offline on the user's Mac.

## Setup check

```bash
command -v giftrim || ls /Applications/GifTrim.app/Contents/Helpers/giftrim
```

If neither exists, ask the user to install GifTrim (`brew install --cask swsususu/tap/giftrim`) or
download it from https://github.com/swsususu/GifTrim/releases. When only the app path exists, call
`/Applications/GifTrim.app/Contents/Helpers/giftrim` directly.

## Workflow

1. **Inspect** the source to learn its size and duration:
   `giftrim info input.mov --json`
2. **(Optional) check the look** of one edited frame before encoding — open the PNG to verify
   crop and captions:
   `giftrim snapshot input.mov -o /tmp/check.png --aspect 1:1 --text "Hello" --at 3`
3. **(Optional) predict size** when the user has a size limit:
   `giftrim estimate input.mov --width 640 --fps 15 --json`
4. **Convert**, always with `--json` so the result is machine-readable:
   `giftrim input.mov -o out.gif --start 2 --end 8 --width 640 --json`
5. Report the output path, dimensions, duration and size to the user.

Progress goes to stderr; with `--json`, stdout carries exactly one JSON object (or `{"error": "..."}`
with exit code 1).

## Options

| Option | Meaning |
|---|---|
| `-o <path>` | Output GIF (default: input name with `.gif`) |
| `--start <s>` / `--end <s>` | Trim range, seconds |
| `--width <px>` | Output width (default 480, never upscales) |
| `--fps <n>` | Frame rate, 1–50 (default 15). GIF/APNG inputs keep their own timing |
| `--speed <x>` | Playback speed (2 = twice as fast) |
| `--mode forward\|reverse\|bounce` | `bounce` = ping-pong seamless loop |
| `--loop <n>` | 0 forever (default), -1 once, n times |
| `--crop x,y,w,h` | Crop in source pixels, top-left origin |
| `--aspect 1:1` | Center-crop to an aspect ratio |
| `--text "…"` | Caption (repeatable); `--text-position top\|center\|bottom`, `--text-size 0.12`, `--text-color "#FFCC00"` |
| `--effect <name>` | none, mono, noir, tonal, sepia, chrome, fade, instant, process, transfer, invert, posterize, comic |
| `--brightness`, `--contrast`, `--saturation` | Color adjustments (0 / 1 / 1 neutral) |
| `--quality <1-100>` | Default 90 |
| `--lossy <1-100>`, `--motion <1-100>` | Lower = smaller files |
| `--target-size <KB>` | Auto-pick the largest width under this size |
| `--fast` | Faster, slightly lower quality |

Complex jobs can be sent as JSON (`giftrim schema` prints the schema):

```bash
echo '{"inputs":["/abs/in.mov"],"output":"/abs/out.gif","width":600,
       "texts":[{"text":"Before","end":2},{"text":"After","start":2}]}' | giftrim run - --json
```

## Recipes

- **README / PR demo from a screen recording**: `--width 800 --fps 12 --lossy 70` keeps text crisp and files small.
- **Chat / social size limits**: `--target-size 2048` (≈2 MB); for stickers `--width 240 --aspect 1:1`.
- **Seamless loop**: `--mode bounce`.
- **Image sequence**: pass many files (`frames/*.png`); they are sorted by filename, 0.5 s each unless `--fps` is given.
- **Too big?** In order: lower `--fps` (10–12), lower `--width`, add `--lossy 60`, shorten the range.

## Notes

- Paths with spaces must be quoted. Output directories are created automatically.
- Never overwrite the user's source file; the tool refuses `output == input`.
- macOS 14 or later.
