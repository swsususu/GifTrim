import Foundation

/// One frame of the output GIF.
public struct PlannedFrame: Hashable, Sendable {
    /// Source time (seconds) whose image is shown.
    public var sourceTime: Double
    /// How long this frame stays on screen (seconds).
    public var delay: Double
}

public enum FramePlanner {
    /// GIF delays are stored in 1/100 s units; this is the minimum that browsers respect.
    public static let minDelay = 0.02

    /// Computes the ordered list of output frames for a project.
    public static func plan(project: Project, source: MediaSource) -> [PlannedFrame] {
        if let custom = project.customFrames {
            return custom.map { PlannedFrame(sourceTime: $0.sourceTime, delay: max(minDelay, $0.delay)) }
        }
        let start = max(0, min(project.trimStart, source.duration))
        let end = max(start, min(project.trimEnd, source.duration))
        let speed = max(0.05, project.settings.speed)
        var frames: [PlannedFrame]

        if source.isDiscrete, project.settings.useSourceTiming, let times = source.nativeFrameTimes {
            frames = []
            for (i, t) in times.enumerated() {
                let frameEnd = i + 1 < times.count ? times[i + 1] : source.duration
                // Keep frames that overlap the trim range.
                guard frameEnd > start + 1e-6, t < end - 1e-6 || (start == end && i == 0) else { continue }
                let visibleStart = max(t, start)
                let visibleEnd = min(frameEnd, end)
                let d = (visibleEnd - visibleStart) / speed
                frames.append(PlannedFrame(sourceTime: visibleStart, delay: max(minDelay, d)))
            }
        } else {
            let fps = min(ExportSettings.maxFPS, max(1, project.settings.fps))
            let step = 1.0 / fps
            let length = end - start
            // Number of output frames covering the trimmed duration (in output time).
            let outputDuration = length / speed
            let count = max(1, Int((outputDuration * fps).rounded(.toNearestOrAwayFromZero)))
            frames = (0..<count).map { i in
                let sourceTime = start + Double(i) * step * speed
                return PlannedFrame(sourceTime: min(sourceTime, max(start, end - 1e-3)), delay: step)
            }
        }

        switch project.settings.playbackMode {
        case .forward:
            break
        case .reverse:
            frames.reverse()
        case .bounce:
            if frames.count > 2 {
                let back = frames.dropFirst().dropLast().reversed()
                frames.append(contentsOf: back)
            }
        }
        return quantizeDelays(frames)
    }

    /// GIF stores delays in centiseconds. Distribute rounding error so total duration stays accurate.
    static func quantizeDelays(_ frames: [PlannedFrame]) -> [PlannedFrame] {
        var result = frames
        var accumulatedExact = 0.0
        var accumulatedRounded = 0.0
        for i in result.indices {
            accumulatedExact += result[i].delay
            let target = (accumulatedExact * 100).rounded() / 100
            var d = target - accumulatedRounded
            if d < minDelay - 1e-9 { d = minDelay }
            result[i].delay = d
            accumulatedRounded += d
        }
        return result
    }

    /// Presentation timestamps for the planned frames. gifski takes a first PTS > 0 as the delay of the
    /// last frame (and shifts the whole animation back), so every PTS is offset by the last frame's delay.
    public static func presentationTimes(_ frames: [PlannedFrame]) -> [Double] {
        var pts: [Double] = []
        pts.reserveCapacity(frames.count)
        var t = frames.last?.delay ?? 0
        for f in frames {
            pts.append(t)
            t += f.delay
        }
        return pts
    }

    public static func totalDuration(_ frames: [PlannedFrame]) -> Double {
        frames.reduce(0) { $0 + $1.delay }
    }
}
