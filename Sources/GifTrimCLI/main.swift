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

/// Prints usage and exits: `help` → stdout, exit 0; otherwise a usage error (exit 2),
/// reported as a single `{"error": ...}` JSON object on stdout when `--json` is set.
func usage(_ error: String? = nil, help: Bool = false) -> Never {
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
      --loop, --repeat <n>     0 = forever (default), -1 = once, n = repeat n times
      --crop <x,y,w,h>         Crop in source pixels
      --aspect <w:h>           Center-crop to an aspect ratio, e.g. 1:1
      --text <str>             Caption (repeatable); --text-position top|center|bottom, --text-size 0.12
      --effect <name>          \(ColorEffect.allCases.map(\.rawValue).joined(separator: ", "))
      --brightness <-1..1>     Brightness (default 0)
      --contrast <0.25..4>     Contrast (default 1)
      --saturation <0..3>      Saturation (default 1, 0 = grayscale)
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
    if help {
        print(text)
        exit(0)
    }
    if json {
        emit(ErrorOutput(error: error ?? "missing input (see giftrim --help)"))
    } else {
        if let error { FileHandle.standardError.write(Data("error: \(error)\n\n".utf8)) }
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())

/// True for `-x` / `--xyz`, false for values such as `-1`, `-0.5` or a lone `-`.
func isFlagLike(_ s: String) -> Bool {
    s.count > 1 && s.hasPrefix("-") && Double(s) == nil && !(s.dropFirst().first?.isWhitespace ?? false)
}

/// Removes every `name value` pair from `args` and returns the values.
func takeValues(_ names: [String]) throws -> [String] {
    var out: [String] = []
    while let i = args.firstIndex(where: { names.contains($0) }) {
        guard i + 1 < args.count, !isFlagLike(args[i + 1]) else {
            throw JobError.invalid("\(args[i]) requires a value")
        }
        out.append(args[i + 1])
        args.removeSubrange(i...(i + 1))
    }
    return out
}

func take(_ names: String...) throws -> String? {
    let values = try takeValues(names)
    guard values.count <= 1 else { throw JobError.invalid("\(names[0]) specified more than once") }
    return values.first
}

func takeAll(_ name: String) throws -> [String] { try takeValues([name]) }

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
    guard let raw = try take(name) else { return nil }
    guard let v = T(raw) else { throw JobError.invalid("\(name) expects a number, got \"\(raw)\"") }
    return v
}

let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return e
}()

func emit<T: Encodable>(_ value: T) {
    guard let data = try? encoder.encode(value) else {
        FileHandle.standardOutput.write(Data("{\"error\":\"encode failed\"}\n".utf8))
        exit(1)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func stderr(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

struct ErrorOutput: Encodable { let error: String }

// --json is parsed first so that usage errors can honor it.
let json = flag("--json")
let quiet = flag("-q", "--quiet") || json

/// Flags that consume the next argument; used to tell `--help` apart from a flag value (`--text --help`).
let valueFlags: Set<String> = [
    "-o", "--output", "--start", "--end", "--width", "--fps", "--quality", "--lossy", "--motion", "--speed",
    "--mode", "--loop", "--repeat", "--crop", "--aspect", "--effect", "--brightness", "--contrast",
    "--saturation", "--text", "--text-position", "--text-size", "--text-color", "--target-size", "--at", "--seconds",
]

/// True when one of `names` appears as a standalone argument in flag position.
func hasStandalone(_ names: Set<String>) -> Bool {
    var i = 0
    while i < args.count {
        if names.contains(args[i]) { return true }
        i += valueFlags.contains(args[i]) ? 2 : 1
    }
    return false
}

if hasStandalone(["-h", "--help"]) { usage(help: true) }
if hasStandalone(["--version", "-v"]) {
    if json { emit(["version": version]) } else { print(version) }
    exit(0)
}
if args.isEmpty { usage() }

/// Throws for any leftover `-x` / `--xyz` argument.
func rejectUnknownOptions() throws {
    if let unknown = args.first(where: isFlagLike) {
        throw JobError.invalid("unknown option \(unknown) (see giftrim --help)")
    }
}

/// Parses the shared option flags into a JobSpec (remaining positional args are inputs).
func parseSpec() throws -> JobSpec {
    var spec = JobSpec(inputs: [])
    spec.output = try take("-o", "--output")
    spec.start = try number("--start", Double.self)
    spec.end = try number("--end", Double.self)
    spec.width = try number("--width", Int.self)
    spec.fps = try number("--fps", Double.self)
    spec.quality = try number("--quality", Int.self)
    spec.lossy = try number("--lossy", Int.self)
    spec.motion = try number("--motion", Int.self)
    spec.speed = try number("--speed", Double.self)
    spec.mode = try take("--mode")
    spec.loop = try number("--loop", Int.self) ?? number("--repeat", Int.self)
    if let c = try take("--crop") {
        let v = c.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 4 else { throw JobError.invalid("--crop expects x,y,w,h in pixels") }
        // Values all <= 1 are treated as normalized fractions (backwards compatible).
        spec.crop = .init(x: v[0], y: v[1], width: v[2], height: v[3])
        if v.allSatisfy({ $0 <= 1 }) { spec.crop = nil; normalizedCrop = v }
    }
    spec.aspect = try take("--aspect")
    spec.effect = try take("--effect")
    spec.brightness = try number("--brightness", Double.self)
    spec.contrast = try number("--contrast", Double.self)
    spec.saturation = try number("--saturation", Double.self)
    let position = try take("--text-position")
    let size = try number("--text-size", Double.self)
    let color = try take("--text-color")
    let texts = try takeAll("--text")
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
    try rejectUnknownOptions()
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

struct SnapshotOutput: Encodable { let output: String; let width: Int; let height: Int }

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    defer { semaphore.signal() }
    do {
        let command = args.first
        switch command {
        case "make-test-video", "--make-test-video":
            args.removeFirst()
            let seconds = try number("--seconds", Double.self) ?? 3
            try rejectUnknownOptions()
            guard let out = args.first else { usage("make-test-video needs an output path") }
            try await TestVideoGenerator.make(url: URL(fileURLWithPath: out), seconds: seconds)
            if json { emit(["output": out]) } else { print("wrote \(out)") }

        case "schema":
            print(JobSchema.json)

        case "mcp":
            await MCPServer().run()

        case "info":
            args.removeFirst()
            try rejectUnknownOptions()
            guard let path = args.first else { usage("info needs a file") }
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
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            let r = try await JobRunner.snapshot(spec, at: at, to: url)
            if json { emit(SnapshotOutput(output: url.standardizedFileURL.path, width: r.width, height: r.height)) } else { print("wrote \(out) (\(r.width)x\(r.height))") }

        case "run":
            args.removeFirst()
            guard let path = args.first else { usage("run needs a job file or '-'") }
            let data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile()
                : try Data(contentsOf: URL(fileURLWithPath: path))
            let spec = try JSONDecoder().decode(JobSpec.self, from: data)
            try JobSchema.rejectUnknownFields(in: data)
            try await convert(spec)

        default:
            if command == "convert" { args.removeFirst() }
            var spec = try parseSpec()
            guard !spec.inputs.isEmpty else { usage("no input files") }
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
