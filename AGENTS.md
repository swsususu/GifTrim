# AGENTS.md

Guidance for AI coding agents working on this repository.

## Layout

- `Sources/GifTrimCore`: UI-free pipeline. `MediaSource` (decode) → `FramePlanner` (frame list) →
  `Compositor` (crop, scale, filters, text/image overlays) → `GifskiEncoder` (libgifski C API).
  `Exporter` orchestrates the steps. `JobSpec`/`JobRunner` is the JSON-facing API that the CLI and MCP share.
- `Sources/GifTrimCLI`: the `giftrim` tool (`main.swift`), `MCPServer.swift` (stdio JSON-RPC) and
  `JobSchema.swift`. The SwiftPM product is `giftrim-cli`, renamed to `giftrim` when packaged. Paths
  are case-insensitive on macOS, so `giftrim` would clash with the `GifTrim` app.
- `Sources/GifTrim`: SwiftUI + AppKit app (editor, timeline, inspector, export, screen/camera recording).
- `Vendor/gifski`: git submodule. `scripts/build-gifski.sh` builds `Vendor/lib/libgifski.a`.

## Commands

```bash
make gifski   # once (needs Rust)
make test     # swift-testing suite
make cli      # debug CLI at .build/.../giftrim-cli
make app      # build/GifTrim.app (+ build/giftrim)
make dmg
```

Use `make`, not bare `swift build`. It picks a compatible SDK (`scripts/sdk.sh`) and loads the
swift-testing macro plugin when only Command Line Tools are installed.

## Conventions

- Normalized geometry uses a top-left origin (`NormalizedRect`, `NormalizedPoint`). Core Image and
  CoreGraphics are bottom-left, so convert only inside `Compositor`.
- Overlay times are source times. Text size is a fraction of output height.
- Frames must be added to gifski in order from one thread; see `Exporter`.
- With `--json`, the CLI's stdout carries exactly one JSON object; the MCP server's stdout carries
  protocol messages only. Send logs to stderr.
- Swift 5 language mode; macOS 14 deployment target. App strings are Chinese-first.
- Add a test in `Tests/GifTrimCoreTests` for pipeline changes. Orientation and text placement are
  checked by sampling pixels.
