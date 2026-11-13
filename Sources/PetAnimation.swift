import AppKit
import ImageIO

// Resource format accepts individual PNG frames and regions of a sprite sheet.
// Anchor coordinates are measured in source pixels from the top-left corner.
private struct AnimationManifest: Decodable {
    let canvas: [Int]
    let clips: [String: ClipDescription]
}

private struct ClipDescription: Decodable {
    let loop: Bool
    let provisional: Bool
    let blendFrames: Bool?
    let frames: [FrameDescription]
}

private struct FrameDescription: Decodable {
    let file: String
    let duration: Double
    let anchor: [Double]
    let sourceRect: [Double]?
    let mouth: [Double]?
    let displaySize: [Double]?
}

struct SpriteFrame {
    let image: NSImage
    let sourceRect: NSRect
    let anchor: NSPoint
    let duration: TimeInterval
    let mouth: NSPoint
    let displaySize: NSSize
}

struct SpriteClip {
    let name: String
    let frames: [SpriteFrame]
    let loop: Bool
    let provisional: Bool
    let blendFrames: Bool
    let duration: TimeInterval

    func sample(at elapsed: TimeInterval) -> (frame: SpriteFrame, next: SpriteFrame?, index: Int, progress: CGFloat, finished: Bool) {
        let finished = !loop && elapsed >= duration
        let position = loop ? elapsed.truncatingRemainder(dividingBy: duration) : min(elapsed, duration - 0.000001)
        var cursor: TimeInterval = 0
        for (index, frame) in frames.enumerated() {
            let end = cursor + frame.duration
            if position < end || index == frames.count - 1 {
                let nextIndex = index + 1
                let next = nextIndex < frames.count ? frames[nextIndex] : (loop ? frames.first : nil)
                return (frame, frames.count > 1 ? next : nil,
                        index, CGFloat((position - cursor) / frame.duration), finished)
            }
            cursor = end
        }
        return (frames[0], frames.count > 1 ? frames[1] : nil, 0, 0, finished)
    }
}

final class SpriteLibrary {
    let canvasSize: NSSize
    private(set) var clips: [String: SpriteClip] = [:]

    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "pet-animations", withExtension: "json") else {
            throw NSError(domain: "SpriteLibrary", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "缺少 pet-animations.json"])
        }
        let manifest = try JSONDecoder().decode(AnimationManifest.self, from: Data(contentsOf: url))
        guard manifest.canvas.count == 2, manifest.canvas.allSatisfy({ $0 > 0 }) else {
            throw NSError(domain: "SpriteLibrary", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "动画画布尺寸无效"])
        }
        canvasSize = NSSize(width: manifest.canvas[0], height: manifest.canvas[1])
        var imageCache: [String: NSImage] = [:]
        for (name, description) in manifest.clips {
            guard !description.frames.isEmpty else { throw NSError(domain: "SpriteLibrary", code: 3) }
            var frames: [SpriteFrame] = []
            for item in description.frames {
                guard item.duration > 0, item.anchor.count == 2,
                      item.anchor[0] >= 0, item.anchor[0] <= Double(manifest.canvas[0]),
                      item.anchor[1] >= 0, item.anchor[1] <= Double(manifest.canvas[1]) else {
                    throw NSError(domain: "SpriteLibrary", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "\(name) 的帧时长或锚点无效"])
                }
                let image: NSImage
                if let cached = imageCache[item.file] {
                    image = cached
                } else {
                    guard let resource = bundle.resourceURL?.appendingPathComponent(item.file),
                          let loaded = NSImage(contentsOf: resource) else {
                        throw NSError(domain: "SpriteLibrary", code: 5,
                                      userInfo: [NSLocalizedDescriptionKey: "缺少动画素材 \(item.file)"])
                    }
                    imageCache[item.file] = loaded
                    image = loaded
                }
                let source: NSRect
                if let rect = item.sourceRect {
                    guard rect.count == 4,
                          rect[2] > 0, rect[3] > 0,
                          rect[0] >= 0, rect[1] >= 0,
                          rect[0] + rect[2] <= image.size.width,
                          rect[1] + rect[3] <= image.size.height else {
                        throw NSError(domain: "SpriteLibrary", code: 6)
                    }
                    // Manifests use top-left atlas coordinates. NSImage's
                    // source rectangles use a bottom-left origin even when
                    // the destination view is flipped.
                    source = NSRect(x: rect[0], y: image.size.height - rect[1] - rect[3],
                                    width: rect[2], height: rect[3])
                } else {
                    guard Int(image.size.width) == manifest.canvas[0],
                          Int(image.size.height) == manifest.canvas[1] else {
                        throw NSError(domain: "SpriteLibrary", code: 7,
                                      userInfo: [NSLocalizedDescriptionKey: "\(item.file) 与统一画布尺寸不符"])
                    }
                    source = NSRect(origin: .zero, size: image.size)
                }
                let displaySize: NSSize
                if let size = item.displaySize {
                    guard size.count == 2, size.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                        throw NSError(domain: "SpriteLibrary", code: 8,
                            userInfo: [NSLocalizedDescriptionKey: "\(name) 的显示尺寸无效"])
                    }
                    displaySize = NSSize(width: size[0], height: size[1])
                } else { displaySize = canvasSize }
                frames.append(SpriteFrame(image: image, sourceRect: source,
                                          anchor: NSPoint(x: item.anchor[0], y: item.anchor[1]),
                                          duration: item.duration,
                                          mouth: NSPoint(x: item.mouth?.first ?? 523,
                                                         y: item.mouth?.last ?? 418),
                                          displaySize: displaySize))
            }
            clips[name] = SpriteClip(name: name, frames: frames, loop: description.loop,
                                     provisional: description.provisional,
                                     blendFrames: description.blendFrames ?? false,
                                     duration: frames.reduce(0) { $0 + $1.duration })
        }
    }

    func clip(_ name: String) -> SpriteClip? { clips[name] }
}

enum PetAnimationState: String, CaseIterable {
    case idle = "Idle"
    case idleAccent = "IdleAccent"
    case hover = "Hover"
    case awaitInput = "AwaitInput"
    case enterAwait = "EnterAwait"
    case exitAwait = "ExitAwait"
    case roam = "Roam"
    case play = "Play"
    case playYarn = "PlayYarn"
    case playButterfly = "PlayButterfly"
    case feedStart = "FeedStart"
    case rise = "Rise"
    case catchCard = "CatchCard"
    case settle = "Settle"
    case eat = "Eat"
    case swallow = "Swallow"
    case wipeMouth = "WipeMouth"
    case standAfterWipe = "StandAfterWipe"
    case celebrate = "Celebrate"
    case turnBack = "TurnBack"
    case poop = "Poop"
    case returnFront = "ReturnFront"
    case proud = "Proud"

    static let feedingSequence: [PetAnimationState] = [
        .feedStart, .rise, .catchCard, .settle, .eat, .swallow,
        .wipeMouth, .standAfterWipe, .turnBack, .poop, .returnFront, .proud
    ]
}

struct SpritePlayback {
    let state: PetAnimationState
    let frame: SpriteFrame
    let nextFrame: SpriteFrame?
    let frameIndex: Int
    let frameCount: Int
    let frameProgress: CGFloat
    let clipProgress: CGFloat
    let clipFinished: Bool
    let provisional: Bool
    let blendFrames: Bool
}

final class PetAnimationPlayer {
    private let library: SpriteLibrary
    private(set) var state: PetAnimationState = .idle
    private var clipStart: TimeInterval

    init(library: SpriteLibrary, now: TimeInterval) {
        self.library = library
        clipStart = now
    }

    func play(_ next: PetAnimationState, at now: TimeInterval) {
        guard next != state, library.clip(next.rawValue) != nil else { return }
        state = next
        clipStart = now
    }

    func sample(at now: TimeInterval) -> SpritePlayback? {
        guard let clip = library.clip(state.rawValue) else { return nil }
        let current = clip.sample(at: max(0, now - clipStart))
        return SpritePlayback(state: state, frame: current.frame,
                              nextFrame: current.next,
                              frameIndex: current.index, frameCount: clip.frames.count,
                              frameProgress: current.progress,
                              clipProgress: min(1, CGFloat(max(0, now - clipStart) / clip.duration)),
                              clipFinished: current.finished,
                              provisional: clip.provisional,
                              blendFrames: clip.blendFrames)
    }
}

final class PetAnimationStateMachine {
    private let player: PetAnimationPlayer
    private let standingFeedPreparation: SpriteClip?
    private let supportsAutonomousClips: Bool
    private var nextIdleAccent: TimeInterval
    private var idleAccentEnd: TimeInterval = 0
    private var nextAutonomousAction: TimeInterval
    private var lastAutonomousAction: PetAnimationState?
    private let fullFeedSequence = PetAnimationState.feedingSequence
    private var activeFeedSequence: [PetAnimationState] = []
    private var feedIndex: Int?
    private var feedStartPlayback: SpritePlayback?
    private var needsToRise = true
    var isFeeding: Bool { feedIndex != nil }
    var state: PetAnimationState { player.state }
    // A queued card waits for the current sit/stand transition to finish.
    // Starting halfway through it would jump back to a different base pose.
    var canBeginFeed: Bool {
        !isFeeding && player.state != .enterAwait && player.state != .exitAwait
    }

    init(library: SpriteLibrary, now: TimeInterval) {
        player = PetAnimationPlayer(library: library, now: now)
        standingFeedPreparation = library.clip("FaceCard")
        supportsAutonomousClips = false
        nextIdleAccent = now + Double.random(in: 5...11)
        nextAutonomousAction = supportsAutonomousClips
            ? now + Double.random(in: 4...8) : .infinity
    }

    func beginFeed(at now: TimeInterval, reducedMotion: Bool = false) {
        guard feedIndex == nil else { return }
        feedStartPlayback = player.sample(at: now)
        needsToRise = [.awaitInput, .enterAwait, .proud].contains(player.state)
        activeFeedSequence = reducedMotion ? [.swallow, .proud] : fullFeedSequence
        feedIndex = 0
        player.play(activeFeedSequence[0], at: now)
    }

    func cancelFeed(at now: TimeInterval) {
        feedIndex = nil
        activeFeedSequence = []
        player.play(.idle, at: now)
    }

    func update(at now: TimeInterval, hovered: Bool, awaitingInput: Bool,
                canRoam _: Bool = true,
                preview: PetAnimationState? = nil) -> SpritePlayback? {
        if let preview = preview, feedIndex == nil {
            player.play(preview, at: now)
            return player.sample(at: now)
        }

        if let index = feedIndex {
            if player.sample(at: now)?.clipFinished == true {
                if index + 1 < activeFeedSequence.count {
                    feedIndex = index + 1
                    player.play(activeFeedSequence[index + 1], at: now)
                } else {
                    feedIndex = nil
                    nextIdleAccent = now + Double.random(in: 5...11)
                    nextAutonomousAction = supportsAutonomousClips
                        ? now + Double.random(in: 4...8) : .infinity
                    player.play(awaitingInput ? .awaitInput : .exitAwait, at: now)
                }
            }
            guard let playback = player.sample(at: now) else { return nil }
            if playback.state == .rise && !needsToRise,
               let preparation = standingFeedPreparation {
                let sample = preparation.sample(at: Double(playback.clipProgress) * preparation.duration)
                return SpritePlayback(state: .rise, frame: sample.frame, nextFrame: sample.next,
                    frameIndex: sample.index, frameCount: preparation.frames.count,
                    frameProgress: sample.progress, clipProgress: playback.clipProgress,
                    clipFinished: playback.clipFinished, provisional: preparation.provisional,
                    blendFrames: false)
            }
            if playback.state == .feedStart || (playback.state == .rise && !needsToRise),
               let held = feedStartPlayback {
                return SpritePlayback(state: playback.state, frame: held.frame, nextFrame: nil,
                    frameIndex: 0, frameCount: 1, frameProgress: playback.frameProgress,
                    clipProgress: playback.clipProgress, clipFinished: playback.clipFinished,
                    provisional: held.provisional, blendFrames: false)
            }
            return playback
        }

        let requested: PetAnimationState =
            awaitingInput ? .awaitInput : hovered ? .hover : .idle

        // Finish a physical transition even if the panel is quickly closed or
        // reopened. Reversing to its first cel mid-motion caused a visible pop.
        if player.state == .enterAwait {
            if player.sample(at: now)?.clipFinished != true { return player.sample(at: now) }
            player.play(awaitingInput ? .awaitInput : .exitAwait, at: now)
            return player.sample(at: now)
        }
        if player.state == .exitAwait {
            if player.sample(at: now)?.clipFinished != true { return player.sample(at: now) }
            nextIdleAccent = now + Double.random(in: 5...11)
            player.play(awaitingInput ? .enterAwait : requested, at: now)
            return player.sample(at: now)
        }

        if requested == .awaitInput {
            idleAccentEnd = 0
            if player.state != .awaitInput {
                player.play(.enterAwait, at: now)
            }
            return player.sample(at: now)
        }

        if player.state == .awaitInput {
            player.play(.exitAwait, at: now)
            return player.sample(at: now)
        }
        if requested == .hover {
            idleAccentEnd = 0
            nextIdleAccent = max(nextIdleAccent, now + 3)
            nextAutonomousAction = max(nextAutonomousAction, now + 2)
            player.play(.hover, at: now)
        } else {
            if player.state == .play || player.state == .playYarn ||
                player.state == .playButterfly || player.state == .roam {
                if player.sample(at: now)?.clipFinished != true {
                    return player.sample(at: now)
                }
                nextAutonomousAction = now + Double.random(in: 5...10)
            }
            if now >= nextAutonomousAction {
                let allChoices: [PetAnimationState] = [.play, .playYarn, .playButterfly]
                let choices = allChoices.filter { $0 != lastAutonomousAction }
                let action = choices.randomElement() ?? .play
                lastAutonomousAction = action
                player.play(action, at: now)
                return player.sample(at: now)
            }
            if now >= nextIdleAccent && now >= idleAccentEnd {
                idleAccentEnd = now + 0.55
                nextIdleAccent = now + Double.random(in: 7...15)
            }
            player.play(now < idleAccentEnd ? .idleAccent : .idle, at: now)
        }
        return player.sample(at: now)
    }
}

enum SpritePainter {
    static func frameBlend(_ playback: SpritePlayback) -> CGFloat {
        guard playback.blendFrames, playback.nextFrame != nil else { return 0 }
        let blend = max(0, min(1, (playback.frameProgress - 0.72) / 0.28))
        return blend * blend * (3 - 2 * blend)
    }

    static func draw(_ playback: SpritePlayback, canvas: NSSize, in bounds: NSRect,
                     groundY: CGFloat, backingScale: CGFloat = 1,
                     mirrorHorizontally: Bool = false) {
        guard let graphics = NSGraphicsContext.current else { return }
        graphics.saveGraphicsState()
        defer { graphics.restoreGraphicsState() }
        graphics.imageInterpolation = .none
        if mirrorHorizontally {
            graphics.cgContext.translateBy(x: bounds.minX + bounds.maxX, y: 0)
            graphics.cgContext.scaleBy(x: -1, y: 1)
        }
        let frameBlend = self.frameBlend(playback)
        draw(playback.frame, canvas: canvas, in: bounds, groundY: groundY,
             backingScale: backingScale,
             opacity: 1 - frameBlend)
        if let next = playback.nextFrame {
            draw(next, canvas: canvas, in: bounds, groundY: groundY,
                 backingScale: backingScale, opacity: frameBlend)
        }
    }

    static func destinationRect(_ frame: SpriteFrame, canvas: NSSize, in bounds: NSRect,
                                groundY: CGFloat, backingScale: CGFloat) -> NSRect {
        let scale = bounds.width / canvas.width
        func snap(_ value: CGFloat) -> CGFloat {
            (value * backingScale).rounded() / backingScale
        }
        return NSRect(x: snap(bounds.midX - frame.anchor.x * scale),
                      y: snap(groundY - frame.anchor.y * scale),
                      width: snap(frame.displaySize.width * scale),
                      height: snap(frame.displaySize.height * scale))
    }

    private static func draw(_ frame: SpriteFrame, canvas: NSSize, in bounds: NSRect,
                             groundY: CGFloat, backingScale: CGFloat, opacity: CGFloat) {
        guard opacity > 0.005 else { return }
        let rect = destinationRect(frame, canvas: canvas, in: bounds,
                                   groundY: groundY, backingScale: backingScale)
        frame.image.draw(in: rect, from: frame.sourceRect,
                         operation: .sourceOver, fraction: opacity,
                         respectFlipped: true, hints: nil)
    }
}

enum SpritePreviewExporter {
    private static let previewSize = NSSize(width: 220, height: 232)

    private static func render(_ frame: SpriteFrame, state: PetAnimationState,
                               count: Int, index: Int, library: SpriteLibrary) throws -> CGImage {
        let playback = SpritePlayback(state: state, frame: frame,
            nextFrame: nil, frameIndex: index, frameCount: count,
            frameProgress: 0, clipProgress: 0, clipFinished: false,
            provisional: true, blendFrames: false)
        return try render(playback, library: library)
    }

    private static func render(_ playback: SpritePlayback, library: SpriteLibrary,
                               opaque: Bool = false, interaction: Bool = false,
                               notesVisible: Bool = true, taskCompleted: Bool = true) throws -> CGImage {
        let size = interaction ? NSSize(width: 620, height: 300) : previewSize
        let bounds = interaction ? NSRect(x: 360, y: 60, width: 220, height: 232) : NSRect(origin: .zero, size: size)
        let scene = FeedMotion.scene(in: bounds)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        (opaque ? NSColor(calibratedWhite: 0.95, alpha: 1) : NSColor.clear).setFill()
        NSRect(origin: .zero, size: size).fill()
        FeedMotion.drawCat(playback, canvas: library.canvasSize, in: bounds)
        let flying = interaction && (playback.state == .feedStart || playback.state == .rise ||
            (playback.state == .catchCard && playback.clipProgress < FeedMotion.catchFraction))
        FeedingPainter.draw(playback, title: "完成今天的一件事",
                            in: scene, externalFlight: flying,
                            interception: FeedMotion.interception(library: library))
        if interaction && !notesVisible {
            ("猫咪陪你待在桌面上" as NSString).draw(at: NSPoint(x: 24, y: 30),
                withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                                 .foregroundColor: NSColor.darkGray])
        }
        if interaction && notesVisible {
            let source = NSRect(x: 24, y: 66, width: 290, height: 44)
            ("今日小纸条" as NSString).draw(at: NSPoint(x: 24, y: 30),
                withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                                 .foregroundColor: NSColor.darkGray])
            if playback.state == .feedStart {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setAlpha(1 - FeedingPainter.ease(playback.clipProgress / 0.65))
                NSColor.white.setFill()
                NSBezierPath(roundedRect: source, xRadius: 9, yRadius: 9).fill()
                ("完成今天的一件事" as NSString).draw(at: NSPoint(x: 36, y: 80),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray])
                NSGraphicsContext.restoreGraphicsState()
            } else if taskCompleted {
                ("✓  完成今天的一件事" as NSString).draw(at: NSPoint(x: 36, y: 80),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.gray])
            } else {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: source, xRadius: 9, yRadius: 9).fill()
                ("完成今天的一件事" as NSString).draw(at: NSPoint(x: 36, y: 80),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray])
                ("喂给猫咪" as NSString).draw(at: NSPoint(x: 236, y: 80),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.brown])
            }
            if flying {
                let target = FeedMotion.interception(library: library)
                FeedingPainter.drawFlight(title: "完成今天的一件事", source: source,
                    target: NSPoint(x: scene.minX + target.x, y: scene.minY + target.y),
                    state: playback.state, progress: playback.clipProgress)
            }
        }
        image.unlockFocus()
        guard let result = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "SpritePreviewExporter", code: 1)
        }
        return result
    }

    private static func sample(_ clip: SpriteClip, state: PetAnimationState,
                               elapsed: TimeInterval) -> SpritePlayback {
        let value = clip.sample(at: elapsed)
        return SpritePlayback(state: state, frame: value.frame, nextFrame: value.next,
            frameIndex: value.index, frameCount: clip.frames.count, frameProgress: value.progress,
            clipProgress: min(1, CGFloat(elapsed / clip.duration)), clipFinished: value.finished,
            provisional: clip.provisional, blendFrames: clip.blendFrames)
    }

    static func exportAnimation(library: SpriteLibrary, to url: URL,
                                states: [PetAnimationState], interaction: Bool = false,
                                timelineDirectory: URL? = nil) throws {
        let frames = try states.flatMap { state -> [(CGImage, Double, String)] in
            guard let clip = library.clip(state.rawValue) else { return [] }
            let count = Int(ceil(clip.duration * 30))
            return try (0..<count).map { index in
                let elapsed = Double(index) * clip.duration / Double(count)
                let playback = sample(clip, state: state, elapsed: elapsed)
                return (try render(playback, library: library, opaque: true, interaction: interaction),
                        clip.duration / Double(count), state.rawValue)
            }
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "com.compuserve.gif" as CFString, frames.count, nil) else {
            throw NSError(domain: "SpritePreviewExporter", code: 2)
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        if let directory = timelineDirectory {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("frames"),
                                                    withIntermediateDirectories: true)
        }
        var timeline: [[String: Any]] = []
        for (index, item) in frames.enumerated() {
            let (image, duration, state) = item
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: duration]] as CFDictionary)
            if let directory = timelineDirectory {
                let file = String(format: "frames/%04d.png", index)
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "SpritePreviewExporter", code: 5)
                }
                try png.write(to: directory.appendingPathComponent(file), options: .atomic)
                timeline.append(["file": file, "duration": duration, "state": state])
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "SpritePreviewExporter", code: 3)
        }
        if let directory = timelineDirectory {
            let manifest: [String: Any] = ["frames": timeline, "duration": frames.reduce(0) { $0 + $1.1 },
                                           "renderer": "native-SpritePainter-and-FeedingPainter"]
            let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: directory.appendingPathComponent("timeline.json"), options: .atomic)
        }
    }

    static func exportFeeding(library: SpriteLibrary, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try exportAnimation(library: library, to: directory.appendingPathComponent("feed.gif"),
                            states: PetAnimationState.feedingSequence,
                            interaction: true, timelineDirectory: directory)
        let steps: [(PetAnimationState, Double)] = [(.feedStart, 0.1), (.rise, 0.4),
            (.catchCard, 0.30), (.catchCard, 0.52), (.catchCard, 0.90), (.settle, 0.5),
            (.eat, 0.47), (.swallow, 0.5), (.wipeMouth, 0.22), (.wipeMouth, 0.5),
            (.wipeMouth, 0.87), (.standAfterWipe, 0.5), (.turnBack, 0.5), (.poop, 0.65),
            (.returnFront, 0.5), (.proud, 0.75)]
        let sheet = NSImage(size: NSSize(width: 880, height: 1040))
        sheet.lockFocusFlipped(true)
        NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 880, height: 1040).fill()
        for (index, step) in steps.enumerated() {
            guard let clip = library.clip(step.0.rawValue) else { continue }
            let x = CGFloat(index % 4) * 220
            let y = CGFloat(index / 4) * 260
            let bounds = NSRect(x: x, y: y, width: 220, height: 232)
            let playback = sample(clip, state: step.0, elapsed: step.1 * clip.duration)
            FeedMotion.drawCat(playback, canvas: library.canvasSize, in: bounds)
            FeedingPainter.draw(playback, title: "完成今天的一件事", in: FeedMotion.scene(in: bounds),
                                interception: FeedMotion.interception(library: library))
            ("\(index + 1). \(step.0.rawValue) \(Int(step.1 * 100))%" as NSString).draw(
                at: NSPoint(x: x + 10, y: y + 238),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray])
        }
        sheet.unlockFocus()
        guard let image = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SpritePreviewExporter", code: 4)
        }
        try png.write(to: directory.appendingPathComponent("feed-steps.png"), options: .atomic)
        try exportJourney(library: library, to: directory)
    }

    // Exercise the real state machine across opening, feeding, remaining seated,
    // and closing the notes. A concatenation of feeding clips hid these joins.
    private static func exportJourney(library: SpriteLibrary, to directory: URL) throws {
        let machine = PetAnimationStateMachine(library: library, now: 0)
        let openAt = 0.8
        let feedAt = openAt + (library.clip("EnterAwait")?.duration ?? 1) + 1
        var fed = false
        var closeAt: Double?
        var stopAt = 30.0
        var samples: [(SpritePlayback, Bool, Bool, String)] = []
        for tick in 0...900 {
            let now = Double(tick) / 30
            if now >= stopAt { break }
            let notesVisible = now >= openAt && now < (closeAt ?? .infinity)
            if !fed && now >= feedAt && machine.canBeginFeed {
                machine.beginFeed(at: now)
                fed = true
            }
            guard let playback = machine.update(at: now, hovered: false, awaitingInput: notesVisible) else { continue }
            if fed && !machine.isFeeding && closeAt == nil {
                closeAt = now + 1
                stopAt = now + 1 + (library.clip("ExitAwait")?.duration ?? 1) + 1.2
            }
            var section = playback.state.rawValue
            if playback.state == .idle { section = fed ? "IdleAfter" : "IdleBefore" }
            if playback.state == .awaitInput { section = fed ? "AwaitAfter" : "AwaitBefore" }
            samples.append((playback, notesVisible, fed, section))
        }
        let url = directory.appendingPathComponent("journey.gif")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
            "com.compuserve.gif" as CFString, samples.count, nil) else {
            throw NSError(domain: "SpritePreviewExporter", code: 6)
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var timeline: [[String: Any]] = []
        for (index, item) in samples.enumerated() {
            try autoreleasepool {
                let (playback, visible, completed, section) = item
                let image = try render(playback, library: library, opaque: true, interaction: true,
                                       notesVisible: visible, taskCompleted: completed)
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary:
                    [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
                let file = String(format: "frames/%04d.png", index)
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "SpritePreviewExporter", code: 7)
                }
                try png.write(to: directory.appendingPathComponent(file), options: .atomic)
                timeline.append(["file":file,"duration":1.0/30,"state":playback.state.rawValue,
                                 "section":section,"cel":playback.frameIndex])
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "SpritePreviewExporter", code: 8) }
        let result: [String: Any] = ["frames":timeline,"duration":Double(samples.count)/30,
            "renderer":"native-state-machine-SpritePainter-and-FeedingPainter",
            "scope":"existing idle → open notes → feed → remain seated → close notes → existing idle"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("timeline.json"), options: .atomic)
    }

    static func export(library: SpriteLibrary, to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var saved: [URL] = []
        for state in PetAnimationState.allCases {
            guard let clip = library.clip(state.rawValue) else { continue }
            for (index, frame) in clip.frames.enumerated() {
                let image = try render(frame, state: state, count: clip.frames.count,
                                       index: index, library: library)
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "SpritePreviewExporter", code: 1)
                }
                let url = directory.appendingPathComponent("\(state.rawValue)-\(index + 1).png")
                try png.write(to: url, options: .atomic)
                saved.append(url)
            }
        }
        try exportAnimation(library: library,
            to: directory.appendingPathComponent("pet-animation-demo.gif"),
            states: [.idle, .hover, .enterAwait, .awaitInput, .exitAwait,
                     .play, .playYarn, .playButterfly, .roam,
                     .feedStart, .rise, .catchCard, .settle, .eat, .swallow, .wipeMouth,
                     .standAfterWipe, .turnBack, .poop, .returnFront, .proud])
        try exportAnimation(library: library,
            to: directory.appendingPathComponent("idle-head-motion.gif"),
            states: [.idle, .idleAccent])
        try exportAnimation(library: library,
            to: directory.appendingPathComponent("hover.gif"), states: [.hover])
        try exportAnimation(library: library,
            to: directory.appendingPathComponent("waiting-head-motion.gif"),
            states: [.enterAwait, .awaitInput, .exitAwait])
        try exportAnimation(library: library,
            to: directory.appendingPathComponent("play.gif"),
            states: [.play, .playYarn, .playButterfly])
        try exportAnimation(library: library,
            to: directory.appendingPathComponent("play-ball.gif"), states: [.play])
        try exportAnimation(library: library,
            to: directory.appendingPathComponent("play-yarn.gif"), states: [.playYarn])
        try exportAnimation(library: library,
            to: directory.appendingPathComponent("play-butterfly.gif"), states: [.playButterfly])
        try exportAnimation(library: library,
            to: directory.appendingPathComponent("feed.gif"),
            states: PetAnimationState.feedingSequence)
        return saved
    }
}
