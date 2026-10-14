import Foundation

/// JSON Schema for `JobSpec`, shared by `giftrim schema` and the MCP tool definitions.
enum JobSchema {
    static let effects = ["none", "mono", "noir", "tonal", "sepia", "chrome", "fade", "instant",
                          "process", "transfer", "invert", "posterize", "comic"]

    static let textItem: [String: Any] = [
        "type": "object",
        "required": ["text"],
        "properties": [
            "text": ["type": "string", "description": "Caption text. Use \\n for multiple lines."],
            "position": ["type": "string", "enum": ["top", "center", "bottom"], "description": "Default bottom."],
            "size": ["type": "number", "description": "Font size as a fraction of output height (default 0.12)."],
            "color": ["type": "string", "description": "Name (white, black, yellow, red, green, blue) or hex #RRGGBB. Default white."],
            "strokeColor": ["type": "string", "description": "Outline color. Default black."],
            "font": ["type": "string", "description": "PostScript font name, e.g. Impact, HelveticaNeue-Bold, PingFangSC-Semibold."],
            "start": ["type": "number", "description": "Show from this source time (seconds)."],
            "end": ["type": "number", "description": "Hide after this source time (seconds)."],
        ],
    ]

    /// Properties describing the edits (everything except inputs/output).
    static let editProperties: [String: Any] = [
        "start": ["type": "number", "description": "Trim start in seconds (default 0)."],
        "end": ["type": "number", "description": "Trim end in seconds (default: end of source)."],
        "width": ["type": "integer", "description": "Output width in pixels (default 480; never upscales beyond the crop)."],
        "fps": ["type": "number", "description": "Frames per second, 1-50 (default 15). Ignored for GIF/APNG inputs, which keep their own timing."],
        "quality": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Overall quality (default 90)."],
        "lossy": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Lossy LZW quality; lower = smaller file, more noise."],
        "motion": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Motion quality; lower = smaller file, more smearing in moving areas."],
        "speed": ["type": "number", "description": "Playback speed multiplier (default 1; 2 = twice as fast)."],
        "mode": ["type": "string", "enum": ["forward", "reverse", "bounce"], "description": "bounce plays forward then backward (seamless loop)."],
        "loop": ["type": "integer", "description": "0 = loop forever (default), -1 = play once, n = repeat n times."],
        "crop": [
            "type": "object", "description": "Crop rectangle in source pixels, origin top-left.",
            "required": ["x", "y", "width", "height"],
            "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
        ],
        "aspect": ["type": "string", "description": "Center-crop to an aspect ratio such as \"1:1\", \"16:9\", \"9:16\". Ignored if crop is set."],
        "effect": ["type": "string", "enum": effects, "description": "Color effect."],
        "brightness": ["type": "number", "description": "-1..1, default 0."],
        "contrast": ["type": "number", "description": "0.25..4, default 1."],
        "saturation": ["type": "number", "description": "0..3, default 1 (0 = grayscale)."],
        "texts": ["type": "array", "items": textItem, "description": "Text captions burned into the GIF."],
        "targetSizeKB": ["type": "integer", "description": "Target file size in KB; automatically picks the largest width that fits."],
        "fast": ["type": "boolean", "description": "Faster encoding with slightly lower quality."],
    ]

    static var jobSchema: [String: Any] {
        var props = editProperties
        props["inputs"] = ["type": "array", "items": ["type": "string"], "minItems": 1,
                           "description": "Absolute paths. One video (mov/mp4/m4v…), one animated image (gif/apng/webp), or several still images that become frames in filename order."]
        props["output"] = ["type": "string", "description": "Absolute path of the GIF to write (default: next to the input, .gif extension)."]
        return ["type": "object", "required": ["inputs"], "properties": props, "additionalProperties": false]
    }

    static var json: String {
        var schema = jobSchema
        schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        schema["title"] = "GifTrim job"
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
