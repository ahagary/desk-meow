import AppKit

struct FeedRequest {
    let id: UUID
    let title: String
    let origin: NSPoint?
    var sourceRect: NSRect? = nil
}

enum FeedMotion {
    static let catchFraction: CGFloat = 0.50
    static func scene(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.minX, y: bounds.maxY - 176, width: 220, height: 176)
    }

    static func lift(_ playback: SpritePlayback) -> CGFloat {
        guard playback.state == .catchCard else { return 0 }
        // Anticipation and landing stay on the floor. The airborne portion
        // follows an arc while the cel changes the actual limb articulation.
        // Airborne cels already contain the tucked-paw height. Add only the
        // small root arc, and finish it before the landing/compression cel.
        let flight = max(0, min(1, (playback.clipProgress - 0.25) / 0.48))
        return -14 * sin(flight * .pi)
    }

    static func mouth(_ playback: SpritePlayback) -> NSPoint {
        let scale: CGFloat = 220 / 1402
        let frame = playback.frame
        return NSPoint(x: 110 + (frame.mouth.x - frame.anchor.x) * scale,
                       y: 171 + (frame.mouth.y - frame.anchor.y) * scale + lift(playback))
    }

    static func interception(library: SpriteLibrary) -> NSPoint {
        guard let clip = library.clip(PetAnimationState.catchCard.rawValue) else {
            return NSPoint(x: 110, y: 38)
        }
        let sample = clip.sample(at: clip.duration * Double(catchFraction))
        let playback = SpritePlayback(state: .catchCard, frame: sample.frame,
            nextFrame: nil, frameIndex: sample.index, frameCount: clip.frames.count,
            frameProgress: sample.progress, clipProgress: catchFraction,
            clipFinished: false, provisional: clip.provisional, blendFrames: false)
        return mouth(playback)
    }

    static func drawCat(_ playback: SpritePlayback, canvas: NSSize, in bounds: NSRect,
                        backingScale: CGFloat = 1, mirrored: Bool = false) {
        let scene = self.scene(in: bounds)
        SpritePainter.draw(playback, canvas: canvas, in: scene,
                           groundY: scene.maxY - 5 + lift(playback),
                           backingScale: backingScale, mirrorHorizontally: mirrored)
    }
}

// IDs belong to tasks, so repeated clicks cannot create duplicate performances.
struct FeedQueue {
    private(set) var active: FeedRequest?
    private(set) var pending: [FeedRequest] = []

    mutating func enqueue(_ request: FeedRequest) {
        guard active?.id != request.id, !pending.contains(where: { $0.id == request.id }) else { return }
        pending.append(request)
    }

    mutating func startNext() -> FeedRequest? {
        guard active == nil, !pending.isEmpty else { return nil }
        active = pending.removeFirst()
        return active
    }

    mutating func finish() -> FeedRequest? {
        let finished = active
        active = nil
        return finished
    }

    @discardableResult mutating func cancel(_ id: UUID) -> Bool {
        pending.removeAll { $0.id == id }
        guard active?.id == id else { return false }
        active = nil
        return true
    }
}

// Props are drawn separately from the unchanged character PNGs. Coordinates use
// the pet's 220 × 176 point display, with a top-left origin and a fixed floor.
enum FeedingPainter {
    static let mouth = NSPoint(x: 82, y: 65)
    private static let paper = NSColor(calibratedRed: 1, green: 0.95, blue: 0.78, alpha: 1)
    private static let border = NSColor(calibratedRed: 0.40, green: 0.27, blue: 0.16, alpha: 1)

    static func ease(_ value: CGFloat) -> CGFloat {
        let t = max(0, min(1, value))
        return t * t * (3 - 2 * t)
    }

    static func draw(_ playback: SpritePlayback, title: String, in bounds: NSRect,
                     externalFlight: Bool = false, reducedMotion: Bool = false,
                     interception: NSPoint = NSPoint(x: 110, y: 38)) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.scaleBy(x: bounds.width / 220, y: bounds.height / 176)
        context.setShouldAntialias(false)
        let p = playback.clipProgress
        let mouth = FeedMotion.mouth(playback)

        switch playback.state {
        case .feedStart, .rise, .catchCard:
            if !externalFlight {
                let tip: NSPoint
                if playback.state == .feedStart {
                    tip = NSPoint(x: interception.x - 17, y: interception.y - 21 + ease(p) * 5)
                } else if playback.state == .rise {
                    let t = ease(p)
                    tip = NSPoint(x: interception.x - 17 + 17 * t,
                                  y: interception.y - 16 - 12 * t)
                } else {
                    let t = ease(p / FeedMotion.catchFraction)
                    tip = p >= FeedMotion.catchFraction ? mouth :
                        NSPoint(x: interception.x, y: interception.y - 28 + 28 * t)
                }
                drawCard(title: title, tip: tip, width: 54, height: 28,
                         angle: -0.25 + (playback.state == .catchCard ? 0 : sin(p * .pi * 2) * 0.08))
            }
        case .settle:
            // The card remains held at the mouth while all four paws land and
            // the hindquarters settle; consumption starts only once seated.
            drawCard(title: title, tip: mouth, width: 54, height: 28, angle: -0.25)
        case .eat:
            // Three bites with pauses between them; paper is consumed at the
            // mouth edge instead of fading the entire card or shaking the cat.
            let bites = [CGFloat(0.10), 0.39, 0.68]
            let swallowed = bites.reduce(CGFloat(0)) { $0 + ease((p - $1) / 0.17) / 3 }
            if swallowed < 0.995 {
                drawCard(title: title, tip: mouth, width: max(1, 54 * (1 - swallowed)),
                         height: 28 - swallowed * 14, angle: -0.25)
            }
            if !reducedMotion {
                for (index, bite) in bites.enumerated() {
                    let t = (p - bite - 0.10) / 0.23
                    if t > 0 && t < 1 {
                        paper.withAlphaComponent(1 - t).setFill()
                        for j in 0..<3 {
                            let x = mouth.x - 6 - CGFloat(j * 5 + index) * t
                            let y = mouth.y + 5 + 23 * t * t + CGFloat(j * 3)
                            NSRect(x: x.rounded(), y: y.rounded(), width: 2, height: 2).fill()
                        }
                    }
                }
            }
        case .celebrate:
            for index in 0..<3 {
                let x = CGFloat(30 + index * 55)
                star(at: NSPoint(x: x, y: 37 - 12 * sin(p * .pi)),
                     opacity: sin(p * .pi))
            }
        case .poop:
            guard p > 0.20 else { return }
            let fall = max(0, min(1, (p - 0.34) / 0.44))
            let drop = reducedMotion ? CGFloat(1) : fall * fall
            let bounce = !reducedMotion && fall == 1 ? sin((p - 0.78) / 0.22 * .pi) * 3 : 0
            drawPoop(base: NSPoint(x: 139 + 12 * drop, y: 125 + 44 * drop - bounce),
                     dissolve: 0, size: reducedMotion ? 1 : ease((p - 0.20) / 0.16))
        case .returnFront, .proud:
            let dissolve = playback.state == .proud ? ease((p - 0.55) / 0.45) : 0
            drawPoop(base: NSPoint(x: 151, y: 169), dissolve: dissolve)
            if playback.state == .proud && p > 0.55 {
                star(at: NSPoint(x: 151, y: 140 - (p - 0.55) * 20), opacity: (1 - p) * 2)
            }
        default: break
        }
    }

    static func drawCard(title: String, tip: NSPoint, width: CGFloat, height: CGFloat,
                         angle: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: tip.x.rounded(), y: tip.y.rounded())
        context.rotate(by: angle)
        context.setShouldAntialias(false)
        let rect = NSRect(x: -width, y: -height / 2, width: width, height: height)
        border.setFill()
        rect.fill()
        paper.setFill()
        rect.insetBy(dx: 1.5, dy: 1.5).fill()
        guard width > 18 else { return }
        NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.32, alpha: 1).setFill()
        NSRect(x: -width + 5, y: -height / 2 + 6, width: 5, height: 5).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        context.setShouldAntialias(true)
        (title as NSString).draw(in: NSRect(x: -width + 13, y: -height / 2 + 4,
                                          width: width - 18, height: max(10, height - 8)),
            withAttributes: [.font: NSFont.systemFont(ofSize: width > 80 ? 11 : 8),
                             .foregroundColor: border, .paragraphStyle: paragraph])
        context.setShouldAntialias(false)
        if height > 22 {
            border.withAlphaComponent(0.3).setFill()
            NSRect(x: -width + 13, y: height / 2 - 7, width: max(2, width - 22), height: 1).fill()
        }
    }

    static func drawFlight(title: String, source: NSRect, target: NSPoint,
                           state: PetAnimationState, progress: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let startTip = NSPoint(x: source.midX + 27, y: source.midY + 10)
        let above = NSPoint(x: target.x, y: target.y - 28)
        if state == .feedStart {
            let t = ease(progress / 0.65)
            let width = source.width + (54 - source.width) * t
            let height = source.height + (28 - source.height) * t
            let tip = NSPoint(x: source.maxX + (startTip.x - source.maxX) * t,
                              y: source.midY + 10 * t)
            NSGraphicsContext.current?.cgContext.setAlpha(ease(progress / 0.25))
            drawCard(title: title, tip: tip, width: width, height: height, angle: -0.25 * t)
        } else if state == .rise {
            let t = ease(progress)
            let tip = NSPoint(x: startTip.x + (above.x - startTip.x) * t,
                              y: startTip.y + (above.y - startTip.y) * t - sin(t * .pi) * 18)
            drawCard(title: title, tip: tip, width: 54, height: 28,
                     angle: -0.25 + sin(t * .pi * 2) * 0.12)
        } else {
            let t = ease(progress / FeedMotion.catchFraction)
            let tip = NSPoint(x: above.x, y: above.y + (target.y - above.y) * t)
            drawCard(title: title, tip: tip, width: 54, height: 28, angle: -0.25)
        }
    }

    private static func drawPoop(base: NSPoint, dissolve: CGFloat, size: CGFloat = 1) {
        guard size > 0.01, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: base.x, y: base.y)
        context.scaleBy(x: size, y: size)
        let pixels = [
            "      oo      ", "     ohho     ", "     ohlo     ",
            "    ohhhlo    ", "   ohhhhllo   ", "   ollllllo   ",
            "  ohhhhhlllo  ", " ohhhhhlllllo ", " ollllllllllo ",
            "ohhhhhhhlllllo", "ohhhlllllllllo", " ollllllllllo ",
            "  oooooooooo  "
        ]
        let colors: [Character: NSColor] = [
            "o": NSColor(calibratedRed: 0.30, green: 0.18, blue: 0.11, alpha: 1),
            "h": NSColor(calibratedRed: 0.64, green: 0.43, blue: 0.24, alpha: 1),
            "l": NSColor(calibratedRed: 0.48, green: 0.29, blue: 0.15, alpha: 1)
        ]
        for (y, row) in pixels.enumerated() {
            for (x, pixel) in row.enumerated() {
                guard let color = colors[pixel] else { continue }
                let threshold = CGFloat((x * 7 + y * 11) % 17 + 1) / 18
                guard dissolve < threshold else { continue }
                color.setFill()
                NSRect(x: -14 + CGFloat(x * 2), y: -26 + CGFloat(y * 2), width: 2, height: 2).fill()
            }
        }
    }

    private static func star(at point: NSPoint, opacity: CGFloat) {
        NSColor(calibratedRed: 0.96, green: 0.74, blue: 0.28,
                alpha: max(0, min(1, opacity))).setFill()
        NSRect(x: point.x.rounded() - 1, y: point.y.rounded() - 5, width: 2, height: 10).fill()
        NSRect(x: point.x.rounded() - 5, y: point.y.rounded() - 1, width: 10, height: 2).fill()
    }
}

// A click-through overlay lets the card travel across the gap between the Todo
// panel and the pet without blocking either window or taking keyboard focus.
final class FeedingFlight {
    private var panel: NSPanel?
    private var view: FlightView?
    private var request: FeedRequest?
    private var sourceRect: NSRect?

    func begin(_ request: FeedRequest) {
        self.request = request
        sourceRect = request.sourceRect
    }

    func update(playback: SpritePlayback, target: NSPoint) {
        guard let request = request else { return }
        let origin = request.origin ?? NSPoint(x: target.x - 100, y: target.y + 45)
        let row = sourceRect ?? NSRect(x: origin.x - 120, y: origin.y - 20, width: 240, height: 40)
        if panel == nil {
            let created = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = false
            created.ignoresMouseEvents = true
            created.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            created.collectionBehavior = [.canJoinAllSpaces]
            let content = FlightView(frame: .zero)
            created.contentView = content
            panel = created
            view = content
        }
        let frame = row.union(NSRect(x: target.x - 80, y: target.y - 50, width: 160, height: 130)).insetBy(dx: -30, dy: -40)
        panel?.setFrame(frame, display: false)
        view?.title = request.title
        view?.source = NSRect(x: row.minX - frame.minX, y: frame.maxY - row.maxY,
                             width: row.width, height: row.height)
        view?.target = NSPoint(x: target.x - frame.minX, y: frame.maxY - target.y)
        view?.progress = playback.clipProgress
        view?.state = playback.state
        view?.needsDisplay = true
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        request = nil
        sourceRect = nil
    }
}

private final class FlightView: NSView {
    var title = ""
    var source = NSRect.zero
    var target = NSPoint.zero
    var progress: CGFloat = 0
    var state: PetAnimationState = .feedStart
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        FeedingPainter.drawFlight(title: title, source: source, target: target,
                                  state: state, progress: progress)
    }
}
