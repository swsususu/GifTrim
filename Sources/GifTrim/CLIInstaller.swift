import AppKit

/// Installs the bundled `giftrim` CLI / MCP server and helps users wire it into AI agents.
@MainActor
enum CLIInstaller {
    static var bundledTool: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/giftrim")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// POSIX single-quote escaping for sh.
    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Prefer a user-writable bin directory already on PATH; fall back to /usr/local/bin via admin prompt.
    static func install() {
        guard let tool = bundledTool else {
            alert("找不到内置命令行工具", "请使用发布版 GifTrim.app（Contents/Helpers/giftrim）。")
            return
        }
        // A translocated or disk-image copy disappears later and would leave a dangling link.
        let appPath = Bundle.main.bundleURL.path
        if appPath.contains("/AppTranslocation/") || appPath.hasPrefix("/Volumes/") {
            alert("请先移动应用", "GifTrim 正在从临时位置或磁盘映像运行。请先把它拖到“应用程序”(/Applications) 文件夹，再重新打开并安装命令行工具。")
            return
        }
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        let fm = FileManager.default
        for dir in candidates where fm.isWritableFile(atPath: dir) {
            let link = URL(fileURLWithPath: dir).appendingPathComponent("giftrim")
            do {
                // Only replace an existing symlink; never clobber a real file.
                if let attrs = try? fm.attributesOfItem(atPath: link.path) {
                    guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else {
                        alert("无法安装", "\(link.path) 已存在且不是符号链接，未做修改。请先手动处理该文件。")
                        return
                    }
                    try fm.removeItem(at: link)
                }
                try fm.createSymbolicLink(at: link, withDestinationURL: tool)
                done(link.path)
                return
            } catch {
                alert("安装失败", "\(link.path)：\(error.localizedDescription)")
                return
            }
        }
        // Needs admin rights: run `ln -sf` through AppleScript's authorization prompt.
        // Skip if a real file is in the way (only symlinks are replaced).
        let dest = "/usr/local/bin/giftrim"
        if let attrs = try? fm.attributesOfItem(atPath: dest), attrs[.type] as? FileAttributeType != .typeSymbolicLink {
            alert("无法安装", "\(dest) 已存在且不是符号链接，未做修改。请先手动处理该文件。")
            return
        }
        let cmd = "mkdir -p /usr/local/bin && ln -sf \(shQuote(tool.path)) \(dest)"
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error == nil {
            done(dest)
        } else {
            alert("安装失败", "可以在终端手动执行：\nsudo ln -sf \(shQuote(tool.path)) \(dest)")
        }
    }

    private static func done(_ path: String) {
        alert("已安装命令行工具", "现在可以在终端使用 `giftrim`（\(path)）。\n\n试试：giftrim --help\nAI 助手接入：giftrim mcp")
    }

    /// Copies an MCP config snippet that works in Claude Desktop, Cursor, VS Code, Kilo, etc.
    static func copyMCPConfig() {
        let command = bundledTool?.path ?? "/Applications/GifTrim.app/Contents/Helpers/giftrim"
        func jsonString(_ v: Any) -> String {
            let d = try? JSONSerialization.data(withJSONObject: [v], options: [.withoutEscapingSlashes])
            let arr = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(arr.dropFirst().dropLast())   // strip the wrapping [ ]
        }
        let snippet = """
        {
          "mcpServers": {
            "giftrim": {
              "command": \(jsonString(command)),
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
        • Claude Code：claude mcp add giftrim -- \(shQuote(command)) mcp

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
