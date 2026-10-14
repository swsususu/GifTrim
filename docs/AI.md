# GifTrim for AI agents / 让 AI 帮你做 GIF

English | [简体中文](#简体中文)

GifTrim ships a local **MCP server**, an **agent skill** and a **JSON-first CLI**. Any AI assistant
that can run tools on your Mac can turn videos and screen recordings into small, sharp GIFs for you.
Nothing is uploaded; all encoding happens locally with gifski.

> "Turn ~/Desktop/demo.mov into a 2 MB GIF for the README, skip the first 3 seconds, add the
> caption *Drag to reorder*."

The agent calls `get_media_info`, checks a frame with `preview_frame`, then `make_gif`, and replies
with the path and file size.

## 1. Get the binary

Installing GifTrim.app gives you `/Applications/GifTrim.app/Contents/Helpers/giftrim`. To use it
from a terminal, either:

- choose **GifTrim → 安装命令行工具 giftrim…** (Install Command Line Tool) in the menu bar, or
- install with Homebrew, which links `giftrim` automatically:
  `brew install --cask swsususu/tap/giftrim`

## 2. Connect your assistant (MCP)

The server is `giftrim mcp` and speaks MCP over stdio. **GifTrim → 为 AI 助手配置 MCP…**
(Configure MCP for AI) copies a ready-to-paste config.

**Claude Code**

```bash
claude mcp add giftrim -- /Applications/GifTrim.app/Contents/Helpers/giftrim mcp
```

**Claude Desktop**: `~/Library/Application Support/Claude/claude_desktop_config.json`
**Cursor**: `~/.cursor/mcp.json`
**Windsurf**: `~/.codeium/windsurf/mcp_config.json`

```json
{
  "mcpServers": {
    "giftrim": {
      "command": "/Applications/GifTrim.app/Contents/Helpers/giftrim",
      "args": ["mcp"]
    }
  }
}
```

**VS Code (Copilot agent mode)**: `.vscode/mcp.json`

```json
{
  "servers": {
    "giftrim": {
      "type": "stdio",
      "command": "/Applications/GifTrim.app/Contents/Helpers/giftrim",
      "args": ["mcp"]
    }
  }
}
```

**Codex CLI**: `~/.codex/config.toml`

```toml
[mcp_servers.giftrim]
command = "/Applications/GifTrim.app/Contents/Helpers/giftrim"
args = ["mcp"]
```

**Kilo / Cline / Roo / other MCP clients**: same command and args.

### Tools

| Tool | What it does |
|---|---|
| `get_media_info` | Size, duration, frame rate and kind of a file |
| `preview_frame` | Renders one frame with crop, effect and captions applied, and returns it as an image so the model can look at it |
| `estimate_gif` | Predicts dimensions, frame count and file size by encoding a short sample |
| `make_gif` | Trim, crop, resize, speed, reverse/bounce, captions, effects, target size, then encode. Reports progress |

Every tool takes the same parameters as the [JSON job](#4-json-jobs). Errors come back as
`isError` results with a readable message, for example `start must be in [0, 4.0) seconds`, so the
model can fix the call itself.

## 3. Agent skill (no MCP needed)

[`skills/giftrim/SKILL.md`](../skills/giftrim/SKILL.md) teaches an agent how to drive the CLI:
workflow, every option, and size recipes. Copy it into your agent's skills folder:

```bash
# Claude Code (personal)
mkdir -p ~/.claude/skills && cp -R skills/giftrim ~/.claude/skills/
# Codex / other agents that read ~/.agents/skills
mkdir -p ~/.agents/skills && cp -R skills/giftrim ~/.agents/skills/
```

## 4. JSON jobs

```bash
giftrim schema            # JSON Schema of a job
giftrim run job.json --json
echo '{"inputs":["/abs/in.mov"],"output":"/abs/out.gif","targetSizeKB":2048}' | giftrim run - --json
```

```json
{
  "inputs": ["/Users/me/Desktop/demo.mov"],
  "output": "/Users/me/Desktop/demo.gif",
  "start": 3, "end": 12,
  "width": 720, "fps": 12,
  "aspect": "16:9",
  "mode": "forward",
  "texts": [{ "text": "Drag to reorder", "position": "bottom", "size": 0.08 }],
  "lossy": 70
}
```

With `--json`, stdout holds exactly one JSON object and progress goes to stderr. Exit code is
`0` on success and `1` on error (`{"error": "..."}`). Every subcommand behaves this way: `info`,
`estimate`, `snapshot`, `run` and convert.

---

## 简体中文

GifTrim 带有本地 **MCP 服务**、**Agent Skill** 和**以 JSON 为主的命令行**。只要 AI 助手能在你的 Mac 上调用工具，
它就能把视频、录屏转成又小又清晰的 GIF。全部在本机用 gifski 编码，不上传任何文件。

> “把 ~/Desktop/demo.mov 做成 2MB 以内的 GIF 放 README，去掉前 3 秒，底部加字幕「拖动排序」。”

AI 会依次调用 `get_media_info`、`preview_frame`（先看效果）和 `make_gif`，最后告诉你文件路径和大小。

### 1. 获取命令

装好 GifTrim.app 后，命令位于 `/Applications/GifTrim.app/Contents/Helpers/giftrim`。想在终端里直接用，可以任选一种方式：

- 在菜单栏选择 **GifTrim → 安装命令行工具 giftrim…**。
- 用 Homebrew 安装，会自动链接 `giftrim`：`brew install --cask swsususu/tap/giftrim`。

### 2. 接入 AI 助手（MCP）

在菜单栏选择 **GifTrim → 为 AI 助手配置 MCP…**，会复制一份可直接粘贴的配置。各客户端的配置文件位置和格式见上面的英文部分：
Claude Code 只需一行 `claude mcp add`；Claude Desktop、Cursor、Windsurf 用 `mcpServers` 的 JSON；VS Code 用 `servers`；
Codex 用 TOML。

| 工具 | 作用 |
|---|---|
| `get_media_info` | 读取尺寸、时长、帧率和类型 |
| `preview_frame` | 渲染一帧应用了裁剪、滤镜和字幕的画面，以图片形式返回给 AI 看 |
| `estimate_gif` | 试编码一小段，预测尺寸、帧数和文件大小 |
| `make_gif` | 截取、裁剪、缩放、变速、倒放/来回、字幕、滤镜、目标大小，然后编码，过程中汇报进度 |

### 3. Agent Skill（不用 MCP 也行）

把 [`skills/giftrim`](../skills/giftrim/SKILL.md) 复制到 `~/.claude/skills/` 或 `~/.agents/skills/`。
AI 读了之后就知道怎么调用 `giftrim` 命令，也知道怎么把 GIF 压到指定大小。

### 4. JSON 任务

运行 `giftrim schema` 可以查看任务格式。`giftrim run job.json --json` 执行一个任务；也可以通过 stdin 传入。
加了 `--json` 时，stdout 只输出一个 JSON 对象，进度信息写到 stderr。出错时退出码为 1，并输出 `{"error": "..."}`。
