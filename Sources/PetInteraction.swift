import AppKit

enum PetLayout {
    static let baseSize = NSSize(width: 220, height: 176)

    static func clampedScale(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0.5), 2) : 1
    }

    static func size(scale: CGFloat, feeding: Bool) -> NSSize {
        let scale = clampedScale(scale)
        return NSSize(width: baseSize.width * scale, height: (feeding ? 232 : baseSize.height) * scale)
    }

    static func resizedFrame(_ frame: NSRect, scale: CGFloat, feeding: Bool, visible: NSRect) -> NSRect {
        let size = size(scale: scale, feeding: feeding)
        // Keep the feet and horizontal centre in place, except at screen edges.
        let origin = NSPoint(
            x: min(max(frame.midX - size.width / 2, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - size.height)))
        return NSRect(origin: origin, size: size)
    }
}

// Sample only visible cat pixels. Atlas crops, crossfades, jumps, mirroring and
// display scaling use the same placement as SpritePainter; props cannot open notes.
final class SpriteHitTester {
    private var bitmaps: [ObjectIdentifier: NSBitmapImageRep] = [:]

    func contains(_ point: NSPoint, playback: SpritePlayback, canvas: NSSize,
                  bounds: NSRect, backingScale: CGFloat = 1, mirrored: Bool = false) -> Bool {
        guard bounds.contains(point) else { return false }
        let scene = FeedMotion.scene(in: bounds)
        let scale = scene.width / PetLayout.baseSize.width
        let groundY = scene.maxY - 5 * scale + FeedMotion.lift(playback) * scale
        let blend = SpritePainter.frameBlend(playback)
        let point = NSPoint(x: mirrored ? scene.minX + scene.maxX - point.x : point.x, y: point.y)
        // A two-point allowance makes the outline easy to click without making
        // the surrounding transparent rectangle interactive again.
        for dy in [-CGFloat(2), 0, 2] {
            for dx in [-CGFloat(2), 0, 2] {
                let sample = NSPoint(x: point.x + dx, y: point.y + dy)
                let current = alpha(at: sample, frame: playback.frame, canvas: canvas,
                                    scene: scene, groundY: groundY, backingScale: backingScale) * (1 - blend)
                let next = playback.nextFrame.map {
                    alpha(at: sample, frame: $0, canvas: canvas, scene: scene,
                          groundY: groundY, backingScale: backingScale) * blend
                } ?? 0
                if current + next * (1 - current) >= 0.12 { return true }
            }
        }
        return false
    }

    private func alpha(at point: NSPoint, frame: SpriteFrame, canvas: NSSize,
                       scene: NSRect, groundY: CGFloat, backingScale: CGFloat) -> CGFloat {
        let rect = SpritePainter.destinationRect(frame, canvas: canvas, in: scene,
                                                 groundY: groundY, backingScale: backingScale)
        guard rect.contains(point), rect.width > 0, rect.height > 0 else { return 0 }
        let key = ObjectIdentifier(frame.image)
        let bitmap: NSBitmapImageRep
        if let cached = bitmaps[key] {
            bitmap = cached
        } else {
            guard let image = frame.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
            bitmap = NSBitmapImageRep(cgImage: image)
            bitmaps[key] = bitmap
        }
        // NSImage source rectangles start at bottom-left; bitmap pixels at top-left.
        let sourceX = frame.sourceRect.minX + (point.x - rect.minX) / rect.width * frame.sourceRect.width
        let sourceY = frame.image.size.height - frame.sourceRect.maxY +
            (point.y - rect.minY) / rect.height * frame.sourceRect.height
        let x = Int(floor(sourceX / frame.image.size.width * CGFloat(bitmap.pixelsWide)))
        let y = Int(floor(sourceY / frame.image.size.height * CGFloat(bitmap.pixelsHigh)))
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return 0 }
        return bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }
}

// Hover changes the silhouette it was entered through. Keep that entry pose
// and the hover clip's full motion envelope until the pointer leaves them.
// Clicks still use SpriteHitTester on the currently visible frame alone.
final class SpriteHoverTracker {
    private var entryPlayback: SpritePlayback?
    private var entryMirrored = false
    private let hoverPoses: [SpritePlayback]

    init(clip: SpriteClip?) {
        hoverPoses = (clip?.frames ?? []).enumerated().map { index, frame in
            SpritePlayback(state: .hover, frame: frame, nextFrame: nil,
                frameIndex: index, frameCount: clip?.frames.count ?? 0,
                frameProgress: 0, clipProgress: 0, clipFinished: false,
                provisional: clip?.provisional ?? false, blendFrames: false)
        }
    }

    func update(at point: NSPoint, playback: SpritePlayback, canvas: NSSize,
                bounds: NSRect, backingScale: CGFloat = 1, mirrored: Bool = false,
                hitTester: SpriteHitTester) -> (hovered: Bool, visible: Bool) {
        func hits(_ pose: SpritePlayback, mirrored: Bool) -> Bool {
            hitTester.contains(point, playback: pose, canvas: canvas, bounds: bounds,
                               backingScale: backingScale, mirrored: mirrored)
        }
        let visible = hits(playback, mirrored: mirrored)
        if visible {
            // Only an actual visible pixel can start a hover. Refresh the
            // entry pose during other actions; never retain a past feeding pose.
            if playback.state != .hover || entryPlayback == nil {
                entryPlayback = playback
                entryMirrored = mirrored
            }
            return (true, true)
        }
        if playback.state == .hover, let entry = entryPlayback {
            let retained = hits(entry, mirrored: entryMirrored) || hoverPoses.contains {
                hits($0, mirrored: false) || hits($0, mirrored: true)
            }
            if retained { return (true, false) }
        }
        entryPlayback = nil
        return (false, false)
    }
}
