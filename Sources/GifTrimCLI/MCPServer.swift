import Foundation
import GifTrimCore

/// Minimal Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// Exposes GifTrim to AI agents (Claude Desktop/Code, Cursor, VS Code, Codex, Kilo…).
/// stdout carries protocol messages only; diagnostics go to stderr.
final class MCPServer: @unchecked Sendable {
    private let writeLock = NSLock()
    private let tasksLock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Keys of in-flight requests that were cancelled: they keep running until they stop, but get no response.
    private var cancelled: Set<String> = []
    private static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    func run() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                while let line = readLine(strippingNewline: true) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    self.handle(line: trimmed)
                }
                // stdin closed: let in-flight calls finish, then exit.
                while self.tasksLock.withLock({ !self.tasks.isEmpty }) { Thread.sleep(forTimeInterval: 0.05) }
                done.resume()
            }
        }
    }

    // MARK: - Transport

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        writeLock.lock()
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        writeLock.unlock()
    }

    private func reply(_ id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func replyError(_ id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// Type-aware so that string "1" and number 1 are different requests.
    private func key(_ id: Any) -> String { id is String ? "s:\(id)" : "n:\(id)" }

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        guard let message = parsed as? [String: Any] else {
            replyError(NSNull(), code: -32600, message: "Invalid Request: expected a JSON-RPC request object")
            return
        }
        let method = message["method"] as? String
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        if id is NSNull {
            replyError(NSNull(), code: -32600, message: "Invalid Request: id must not be null")
            return
        }
        if let id, !(id is String), !(id is NSNumber) || CFGetTypeID(id as CFTypeRef) == CFBooleanGetTypeID() {
            replyError(NSNull(), code: -32600, message: "Invalid Request: id must be a string or number")
            return
        }
        guard let method else {
            // Responses to our own requests (none expected) are ignored; anything else with an id is invalid.
            if let id, message["result"] == nil, message["error"] == nil {
                replyError(id, code: -32600, message: "Invalid Request: missing method")
            }
            return
        }
        guard let id else {
            // Notifications.
            if method == "notifications/cancelled", let rid = params["requestId"] {
                let k = key(rid)
                tasksLock.withLock {
                    if let task = tasks[k] {
                        cancelled.insert(k)
                        task.cancel()
                    }
                }
            }
            return
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? Self.supportedVersions[0]
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            reply(id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "giftrim", "title": "GifTrim", "version": version_],
                "instructions": Self.instructions,
            ])
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard Self.tools.contains(where: { $0["name"] as? String == name }) else {
                replyError(id, code: -32602, message: "Unknown tool: \(name)")
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let progressToken = (params["_meta"] as? [String: Any])?["progressToken"]
            // Register before starting so a fast tool can't finish before it is tracked.
            let k = key(id)
            tasksLock.withLock {
                tasks[k] = Task { [self] in
                    let result = await callTool(name: name, arguments: arguments, progressToken: progressToken)
                    // Cancelled requests must not get a response.
                    if finish(k) { reply(id, result: result) }
                }
            }
        default:
            replyError(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Removes a finished request; false if it was cancelled meanwhile (no response must be sent).
    private func finish(_ k: String) -> Bool {
        tasksLock.withLock {
            tasks.removeValue(forKey: k)
            return cancelled.remove(k) == nil
        }
    }

    // MARK: - Tools

    private var version_: String { version }

    static let instructions = """
    GifTrim turns videos, animated images (GIF/APNG/WebP) and image sequences into high-quality, small GIFs \
    using the gifski encoder. Typical flow: get_media_info → (optional) preview_frame to check crop/captions → \
    estimate_gif when the user cares about file size → make_gif. All paths must be absolute local paths. \
    Times are in seconds of the source. Crop is in source pixels with a top-left origin.
    """

    static var tools: [[String: Any]] {
        let edits = JobSchema.editProperties
        func schema(_ extra: [String: Any], required: [String]) -> [String: Any] {
            ["type": "object", "properties": edits.merging(extra) { $1 }, "required": required]
        }
        let inputs: [String: Any] = ["type": "array", "items": ["type": "string"], "minItems": 1,
                                     "description": "Absolute paths: one video, one animated image, or several still images (frames, sorted by filename)."]
        return [
            [
                "name": "get_media_info",
                "title": "Inspect media",
                "description": "Read size, duration, frame rate and kind (video / animatedImage / imageSequence) of a local file. Call this first to plan trim ranges and crops.",
                "inputSchema": ["type": "object", "required": ["path"],
                                "properties": ["path": ["type": "string", "description": "Absolute path to a video, GIF/APNG/WebP or image."]]],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
            [
                "name": "make_gif",
                "title": "Make GIF",
                "description": "Convert a video, animated image or image sequence into an optimized GIF with optional trim, crop, resize, speed, reverse/bounce, color effects and text captions. Returns the output path, dimensions, frame count, duration and file size.",
                "inputSchema": schema(["inputs": inputs,
                                       "output": ["type": "string", "description": "Absolute output path ending in .gif. Default: next to the first input."]],
                                      required: ["inputs"]),
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
            ],
            [
                "name": "estimate_gif",
                "title": "Estimate GIF size",
                "description": "Predict the output dimensions, frame count and file size for the given settings by encoding a short sample. Much faster than make_gif; use it to choose width/fps/lossy before converting.",
                "inputSchema": schema(["inputs": inputs], required: ["inputs"]),
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
            [
                "name": "preview_frame",
                "title": "Preview a frame",
                "description": "Render one frame with all edits applied (crop, effect, captions) and return it as an image, so you can visually check the result before encoding.",
                "inputSchema": schema(["inputs": inputs,
                                       "at": ["type": "number", "description": "Source time in seconds (default: middle of the trim range)."]],
                                      required: ["inputs"]),
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
        ]
    }

    private func callTool(name: String, arguments: [String: Any], progressToken: Any?) async -> [String: Any] {
        do {
            switch name {
            case "get_media_info":
                guard let path = arguments["path"] as? String else { throw JobError.invalid("path is required") }
                let info = JobRunner.info(try await JobRunner.open(JobSpec(inputs: [path])))
                return success(info)
            case "estimate_gif":
                return success(try await JobRunner.estimate(try decodeSpec(arguments)))
            case "make_gif":
                let spec = try decodeSpec(arguments)
                let result = try await JobRunner.run(spec) { [self] p in
                    guard let progressToken else { return }
                    send(["jsonrpc": "2.0", "method": "notifications/progress",
                          "params": ["progressToken": progressToken, "progress": p.rendered + p.encoded,
                                     "total": p.total * 2, "message": "encoded \(p.encoded)/\(p.total) frames"]])
                }
                return success(result)
            case "preview_frame":
                let spec = try decodeSpec(arguments, allowing: ["at"])
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("giftrim-preview-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: tmp) }
                var small = spec
                // Keep previews light for the model's context window.
                small.width = min(spec.width ?? 480, 640)
                let size = try await JobRunner.snapshot(small, at: arguments["at"] as? Double, to: tmp)
                let png = try Data(contentsOf: tmp)
                return ["content": [
                    ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                    ["type": "text", "text": "Preview \(size.width)x\(size.height) (output will be \(spec.width ?? 480)px wide)."],
                ]]
            default:
                return failure("Unknown tool: \(name)")
            }
        } catch {
            if Task.isCancelled { return failure("cancelled") }
            return failure(error.localizedDescription)
        }
    }

    private func decodeSpec(_ arguments: [String: Any], allowing extra: Set<String> = []) throws -> JobSpec {
        try JobSchema.rejectUnknownFields(in: arguments, allowing: extra)
        var args = arguments
        args.removeValue(forKey: "at")
        let data = try JSONSerialization.data(withJSONObject: args)
        do {
            return try JSONDecoder().decode(JobSpec.self, from: data)
        } catch let DecodingError.typeMismatch(_, ctx), let DecodingError.valueNotFound(_, ctx) {
            throw JobError.invalid("invalid argument \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)")
        } catch let DecodingError.keyNotFound(key, _) {
            throw JobError.invalid("missing argument \(key.stringValue)")
        }
    }

    private func success<T: Encodable>(_ value: T) -> [String: Any] {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? enc.encode(value)) ?? Data("{}".utf8)
        let object = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
                "structuredContent": object]
    }

    private func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": "Error: \(message)"]], "isError": true]
    }
}
