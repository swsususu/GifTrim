import Foundation
import GifTrimCore

// giftrim — command-line front end for GifTrimCore, built for both humans and AI agents.
//
//   giftrim <input...> -o out.gif [options]        convert (default command)
//   giftrim info <file> [--json]                    inspect a source
//   giftrim estimate <input...> [options] [--json]  predict size without writing a GIF
//   giftrim snapshot <input...> -o frame.png [--at s] [options]   preview one edited frame
//   giftrim run <job.json | ->                      run a JSON JobSpec (from file or stdin)
//   giftrim schema                                  print the JobSpec JSON schema
//   giftrim make-test-video out.mp4 [--seconds n]

let version = "0.1.0"

func usage() -> Never {
    let text = """
    giftrim \(version) — high-quality GIFs from video, animated images or image sequences (gifski inside).

    USAGE
      giftrim <input...> -o out.gif [options]          Convert (inputs: video, GIF/APNG/WebP, or many images)
      giftrim info <file> [--json]                      Show size, duration, frame rate
      giftrim estimate <input...> [options] [--json]    Predict output size without encoding everything
      giftrim snapshot <input...> -o frame.png [--at <s>] [options]
                                                        Render one edited frame as PNG (check crop/text first)
      giftrim run <job.json | ->                        Run a JSON job (see `giftrim schema`), '-' reads stdin
      giftrim schema                                    Print the JSON schema of a job
      giftrim mcp                                       Start the MCP server (stdio) for AI agents

    OPTIONS
      -o, --output <path>      Output file (default: input name with .gif)
      --start <s> --end <s>    Trim range in seconds
      --width <px>             Output width (default 480, never upscales)
      --fps <n>                Frame rate (default 15, max 50)
      --quality <1-100>        Quality (default 90)
      --lossy <1-100>          Lossy compression quality (lower = smaller)
      --motion <1-100>         Motion quality (lower = smaller)
      --speed <x>              Playback speed (default 1)
      --mode <m>               forward | reverse | bounce
      --loop <n>               0 = forever (default), -1 = once, n = repeat n times
      --crop <x,y,w,h>         Crop in source pixels
      --aspect <w:h>           Center-crop to an aspect ratio, e.g. 1:1
      --text <str>             Caption (repeatable); --text-position top|center|bottom, --text-size 0.12
      --effect <name>          \(ColorEffect.allCases.map(\.rawValue).joined(separator: ", "))
      --target-size <KB>       Pick the largest width that fits this size
      --fast                   Faster encoding, slightly lower quality
      --json                   Print a machine-readable JSON result on stdout (progress stays on stderr)
      -q, --quiet              No progress output

    EXAMPLES
      giftrim demo.mov -o demo.gif --start 2 --end 6 --width 640
      giftrim screen.mov --target-size 2048 --fps 12 --json
      giftrim frames/*.png -o anim.gif --fps 8
      echo '{"inputs":["a.mov"],"output":"a.gif","texts":[{"text":"Hi"}]}' | giftrim run -
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") { usage() }
if args == ["--version"] || args == ["-v"] { print(version); exit(0) }

func take(_ names: String...) -> String? {
    for name in names {
        if let i = args.firstIndex(of: name), i + 1 < args.count {
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
    }
    return nil
}

func takeAll(_ name: String) -> [String] {
    var out: [String] = []
    while let v = take(name) { out.append(v) }
    return out
}

func flag(_ names: String...) -> Bool {
    var found = false
    for name in names {
        while let i = args.firstIndex(of: name) {
            args.remove(at: i)
            found = true
        }
    }
    return found
}

func number<T: LosslessStringConvertible>(_ name: String, _ type: T.Type) throws -> T? {
    guard let raw = take(name) else { return nil }
    guard let v = T(raw) else { throw JobError.invalid("\(name) expects a number, got \"\(raw)\"") }
    return v
}

let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return e
}()

func emit<T: Encodable>(_ value: T) {
    if let data = try? encoder.encode(value) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

func stderr(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

/// Parses the shared option flags into a JobSpec (remaining positional args are inputs).
func parseSpec() throws -> JobSpec {
    var spec = JobSpec(inputs: [])
    spec.output = take("-o", "--output")
    spec.start = try number("--start", Double.self)
    spec.end = try number("--end", Double.self)
    spec.width = try number("--width", Int.self)
    spec.fps = try number("--fps", Double.self)
    spec.quality = try number("--quality", Int.self)
    spec.lossy = try number("--lossy", Int.self)
    spec.motion = try number("--motion", Int.self)
    spec.speed = try number("--speed", Double.self)
    spec.mode = take("--mode")
    spec.loop = try number("--loop", Int.self) ?? number("--repeat", Int.self)
    if let c = take("--crop") {
        let v = c.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 4 else { throw JobError.invalid("--crop expects x,y,w,h in pixels") }
        // Values all <= 1 are treated as normalized fractions (backwards compatible).
        spec.crop = .init(x: v[0], y: v[1], width: v[2], height: v[3])
        if v.allSatisfy({ $0 <= 1 }) { spec.crop = nil; normalizedCrop = v }
    }
    spec.aspect = take("--aspect")
    spec.effect = take("--effect")
    spec.brightness = try number("--brightness", Double.self)
    spec.contrast = try number("--contrast", Double.self)
    spec.saturation = try number("--saturation", Double.self)
    let position = take("--text-position")
    let size = try number("--text-size", Double.self)
    let color = take("--text-color")
    let texts = takeAll("--text")
    if !texts.isEmpty {
        spec.texts = texts.map { t in
            var s = JobSpec.TextSpec(text: t)
            s.position = position
            s.size = size
            s.color = color
            return s
        }
    }
    spec.targetSizeKB = try number("--target-size", Int.self)
    spec.fast = flag("--fast") ? true : nil
    if let unknown = args.first(where: { $0.hasPrefix("--") }) {
        throw JobError.invalid("unknown option \(unknown) (see giftrim --help)")
    }
    spec.inputs = args
    return spec
}

var normalizedCrop: [Double]?

/// Applies a normalized crop (0..1) once the source size is known.
func resolveNormalizedCrop(_ spec: inout JobSpec) async throws {
    guard let v = normalizedCrop else { return }
    let source = try await JobRunner.open(spec)
    spec.crop = .init(x: v[0] * source.size.width, y: v[1] * source.size.height,
                      width: v[2] * source.size.width, height: v[3] * source.size.height)
}

struct ErrorOutput: Encodable { let error: String }

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
let json = flag("--json")
let quiet = flag("-q", "--quiet") || json

Task {
    defer { semaphore.signal() }
    do {
        let command = args.first
        switch command {
        case "make-test-video", "--make-test-video":
            args.removeFirst()
            let seconds = try number("--seconds", Double.self) ?? 3
            guard let out = args.first else { usage() }
            try await TestVideoGenerator.make(url: URL(fileURLWithPath: out), seconds: seconds)
            if json { emit(["output": out]) } else { print("wrote \(out)") }

        case "schema":
            print(JobSchema.json)

        case "mcp":
            await MCPServer().run()

        case "info":
            args.removeFirst()
            guard let path = args.first else { throw JobError.invalid("info needs a file") }
            let info = JobRunner.info(try await JobRunner.open(JobSpec(inputs: [path])))
            if json {
                emit(info)
            } else {
                print("\(info.path)")
                print("  kind      \(info.kind)")
                print("  size      \(info.width)x\(info.height)")
                print("  duration  \(String(format: "%.2f", info.duration)) s")
                print("  fps       \(String(format: "%.2f", info.frameRate))")
                if let n = info.frameCount { print("  frames    \(n)") }
                if let b = info.fileSizeBytes { print("  file      \(b / 1024) KB") }
            }

        case "estimate":
            args.removeFirst()
            var spec = try parseSpec()
            try await resolveNormalizedCrop(&spec)
            let e = try await JobRunner.estimate(spec)
            if json { emit(e) } else {
                print("\(e.width)x\(e.height)  \(e.frames) frames  \(String(format: "%.2f", e.duration)) s  ≈ \(e.estimatedBytes / 1024) KB")
            }

        case "snapshot":
            args.removeFirst()
            let at = try number("--at", Double.self)
            var spec = try parseSpec()
            try await resolveNormalizedCrop(&spec)
            let out = spec.output ?? "snapshot.png"
            let r = try await JobRunner.snapshot(spec, at: at, to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
            if json { emit(["output": out, "width": "\(r.width)", "height": "\(r.height)"]) } else { print("wrote \(out) (\(r.width)x\(r.height))") }

        case "run":
            args.removeFirst()
            guard let path = args.first else { throw JobError.invalid("run needs a job file or '-'") }
            let data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile()
                : try Data(contentsOf: URL(fileURLWithPath: path))
            let spec = try JSONDecoder().decode(JobSpec.self, from: data)
            try await convert(spec)

        default:
            if command == "convert" { args.removeFirst() }
            var spec = try parseSpec()
            guard !spec.inputs.isEmpty else { usage() }
            try await resolveNormalizedCrop(&spec)
            try await convert(spec)
        }
    } catch {
        let message = (error as? DecodingError).map { "invalid job JSON: \($0)" } ?? error.localizedDescription
        if json { emit(ErrorOutput(error: message)) }
        stderr("error: \(message)\n")
        exitCode = 1
    }
}

func convert(_ spec: JobSpec) async throws {
    let result = try await JobRunner.run(spec) { p in
        if !quiet { stderr("\r\(Int(p.fraction * 100))%  rendered \(p.rendered)/\(p.total)  encoded \(p.encoded)/\(p.total)   ") }
    }
    if !quiet { stderr("\n") }
    if json {
        emit(result)
    } else {
        print("\(result.output)")
        print("  \(result.width)x\(result.height)  \(result.frames) frames  \(String(format: "%.2f", result.duration)) s  \(result.sizeBytes / 1024) KB  in \(String(format: "%.1f", result.elapsedSeconds)) s")
    }
}

semaphore.wait()
exit(exitCode)
