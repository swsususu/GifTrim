# 第三方组件声明 / Third-Party Notices

GifTrim 以 GPL-3.0-or-later 发布（见 `LICENSE`）。分发的二进制中静态链接了以下组件。

GifTrim is distributed under GPL-3.0-or-later (see `LICENSE`). The distributed binary statically links the components below.

## gifski 1.34.0 — AGPL-3.0-or-later

- 作者 / Author: Kornel Lesiński
- 源码 / Source: https://github.com/ImageOptim/gifski （本仓库 `Vendor/gifski` 子模块 / git submodule）
- 许可 / License: GNU Affero General Public License v3.0 or later. 全文见 https://www.gnu.org/licenses/agpl-3.0.txt

GPLv3 第 13 条与 AGPLv3 第 13 条允许二者组合成一个作品；组合作品中的 gifski 部分仍受 AGPLv3 约束。GifTrim 的完整源码（包括 gifski）公开在本仓库。

GPLv3 §13 and AGPLv3 §13 permit combining the two into one work. The gifski part of the combined work remains under AGPLv3. Complete corresponding source (including gifski) is in this repository.

## libimagequant 4.4.1 — GPL-3.0-or-later

- 作者 / Author: Kornel Lesiński
- 源码 / Source: https://github.com/ImageOptim/libimagequant

## gifsicle 压缩代码（gifski 内含 / bundled in gifski `src/gifsicle.rs`）

- 源自 gifsicle (Eddie Kohler)，GPL-2.0-or-later，按 gifski 的许可整体发布。

## Rust crates — MIT / Apache-2.0 / Zlib / CC0

arrayvec, bytemuck, cfg-if, crossbeam-channel, crossbeam-deque, crossbeam-epoch, crossbeam-utils, either,
gif, gif-dispose, imgref, loop9, num-traits, once_cell, ordered-channel, quick-error, rayon, rayon-core,
resize, rgb, thread_local, weezl.

这些 crate 均采用宽松许可（MIT、Apache-2.0、Zlib 或 CC0，可任选其一），与 GPL-3.0 兼容。完整清单可运行：

These crates use permissive licenses (MIT, Apache-2.0, Zlib or CC0, at your option), compatible with GPL-3.0. Full list:

```sh
cargo tree --manifest-path Vendor/gifski/Cargo.toml --no-default-features --features gifsicle -e normal -f "{p} {l}"
```

## Apple 系统框架 / Apple system frameworks

SwiftUI、AppKit、AVFoundation、Core Image、ScreenCaptureKit 等为 macOS 系统库，属于 GPLv3 所述“系统库”，不随本程序分发。

SwiftUI, AppKit, AVFoundation, Core Image, ScreenCaptureKit etc. are macOS System Libraries (as defined by GPLv3) and are not distributed with GifTrim.
