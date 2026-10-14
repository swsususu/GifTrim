import AppKit

/// Installs the bundled `giftrim` CLI / MCP server and helps users wire it into AI agents.
@MainActor
enum CLIInstaller {
    static var bundledTool: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/giftrim")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Prefer a user-writable bin directory already on PATH; fall back to /usr/local/bin via admin prompt.
    static func install() {
        guard let tool = bundledTool else {
            alert("找不到内置命令行工具", "请使用发布版 GifTrim.app（Contents/Helpers/giftrim）。")
            return
        }
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        let fm = FileManager.default
        for dir in candidates where fm.isWritableFile(atPath: dir) {
            let link = URL(fileURLWithPath: dir).appendingPathComponent("giftrim")
            do {
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(at: link, withDestinationURL: tool)
                done(link.path)
                return
            } catch { continue }
        }
        // Needs admin rights: run `ln -sf` through AppleScript's authorization prompt.
        let cmd = "mkdir -p /usr/local/bin && ln -sf '\(tool.path)' /usr/local/bin/giftrim"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error == nil {
            done("/usr/local/bin/giftrim")
        } else {
            alert("安装失败", "可以在终端手动执行：\nsudo ln -sf '\(tool.path)' /usr/local/bin/giftrim")
        }
    }

    private static func done(_ path: String) {
        alert("已安装命令行工具", "现在可以在终端使用 `giftrim`（\(path)）。\n\n试试：giftrim --help\nAI 助手接入：giftrim mcp")
    }

    /// Copies an MCP config snippet that works in Claude Desktop, Cursor, VS Code, Kilo, etc.
    static func copyMCPConfig() {
        let command = bundledTool?.path ?? "/Applications/GifTrim.app/Contents/Helpers/giftrim"
        let snippet = """
        {
          "mcpServers": {
            "giftrim": {
              "command": "\(command)",
              "args": ["mcp"]
            }
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        alert("已复制 MCP 配置", """
        粘贴到 AI 客户端的 MCP 配置文件中即可让 AI 制作 GIF：
        • Claude Desktop：~/Library/Application Support/Claude/claude_desktop_config.json
        • Cursor：~/.cursor/mcp.json
        • Claude Code：claude mcp add giftrim -- "\(command)" mcp

        \(snippet)
        """)
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
