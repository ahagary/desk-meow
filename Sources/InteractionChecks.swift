import AppKit

enum InteractionChecks {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "InteractionChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func run(library: SpriteLibrary) throws {
        // Two deliberately asymmetric atlas cells expose vertical crop and
        // mirroring mistakes. The first cell includes a transparent interior hole.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 220, pixelsHigh: 352,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<352 {
            for x in 0..<220 {
                let top = (40..<100).contains(x) && (30..<120).contains(y) &&
                    !((60..<80).contains(x) && (60..<80).contains(y))
                let bottom = (140..<180).contains(x) && (226..<316).contains(y)
                let offset = y * bitmap.bytesPerRow + x * 4
                let value: UInt8 = top || bottom ? 255 : 0
                for channel in 0..<4 { bitmap.bitmapData![offset + channel] = value }
            }
        }
        let image = NSImage(size: NSSize(width: 220, height: 352))
        image.addRepresentation(bitmap)
        func frame(top: Bool) -> SpriteFrame {
            SpriteFrame(image: image, sourceRect: NSRect(x: 0, y: top ? 176 : 0, width: 220, height: 176),
                anchor: NSPoint(x: 110, y: 171), duration: 1, mouth: .zero, displaySize: PetLayout.baseSize)
        }
        func playback(top: Bool = true, blend: CGFloat = 0, jump: Bool = false,
                      state: PetAnimationState = .idle) -> SpritePlayback {
            SpritePlayback(state: jump ? .catchCard : state, frame: frame(top: top),
                nextFrame: frame(top: !top), frameIndex: 0, frameCount: 2,
                frameProgress: blend, clipProgress: jump ? 0.49 : 0,
                clipFinished: false, provisional: false, blendFrames: blend > 0)
        }
        let tester = SpriteHitTester()
        let percentages: [CGFloat] = [50, 63.5, 75, 100, 112.3, 150, 177.7, 200]
        for percentage in percentages {
            let scale = CGFloat(percentage) / 100
            for feeding in [false, true] {
                let bounds = NSRect(origin: .zero, size: PetLayout.size(scale: scale, feeding: feeding))
                func hit(_ x: CGFloat, _ y: CGFloat, top: Bool = true,
                         mirrored: Bool = false, blend: CGFloat = 0, jump: Bool = false) -> Bool {
                    tester.contains(NSPoint(x: x * scale, y: (y + (feeding ? 56 : 0)) * scale),
                        playback: playback(top: top, blend: blend, jump: jump), canvas: PetLayout.baseSize,
                        bounds: bounds, backingScale: 2, mirrored: mirrored)
                }
                try require(hit(50, 40), "\(percentage)% 无法点击猫咪实体")
                try require(!hit(20, 40) && !hit(70, 70), "透明外侧或内部空洞触发了便签")
                try require(!hit(160, 80) && hit(160, 80, top: false), "图集上下裁切方向错误")
                try require(hit(170, 40, mirrored: true) && !hit(50, 40, mirrored: true), "镜像点击范围错误")
                try require(hit(50, 40, blend: 0.86) && hit(160, 80, blend: 0.86), "淡入淡出中的可见帧不可点击")
                try require(!hit(50, 40, blend: 1) && hit(160, 80, blend: 1), "淡出的旧轮廓仍可点击")
                try require(hit(50, 20, jump: true) && !hit(50, 118, jump: true), "跳跃时点击范围没有跟随")
                if feeding { try require(!hit(50, -20), "投喂预留空白触发了便签") }
            }
        }
        let bounds = NSRect(origin: .zero, size: PetLayout.baseSize)
        try require(tester.contains(NSPoint(x: 39, y: 40), playback: playback(), canvas: PetLayout.baseSize,
                                    bounds: bounds), "轮廓边缘没有保留点击容差")
        try require(!tester.contains(NSPoint(x: 36, y: 40), playback: playback(), canvas: PetLayout.baseSize,
                                     bounds: bounds), "点击容差超出约 2pt")

        let hoverClip = SpriteClip(name: "Hover", frames: [frame(top: false), frame(top: true)],
            loop: true, provisional: false, blendFrames: false, duration: 2)
        for percentage in percentages {
            let scale = percentage / 100
            let hoverBounds = NSRect(origin: .zero, size: PetLayout.size(scale: scale, feeding: false))
            let tracker = SpriteHoverTracker(clip: hoverClip)
            func update(_ x: CGFloat, _ y: CGFloat, top: Bool, state: PetAnimationState,
                        mirrored: Bool = false) -> (hovered: Bool, visible: Bool) {
                tracker.update(at: NSPoint(x: x * scale, y: y * scale),
                    playback: playback(top: top, state: state), canvas: PetLayout.baseSize,
                    bounds: hoverBounds, backingScale: 2, mirrored: mirrored, hitTester: tester)
            }
            try require(!update(50, 40, top: false, state: .hover).hovered,
                        "透明的悬停预留范围不应启动动作")
            try require(update(50, 40, top: true, state: .idle).hovered,
                        "实体轮廓没有启动悬停")
            for _ in 0..<120 {
                let held = update(50, 40, top: false, state: .hover)
                try require(held.hovered && !held.visible,
                            "轮廓变化取消了悬停，或悬停保持范围吞掉透明点击")
            }
            try require(update(160, 80, top: false, state: .hover).hovered &&
                        update(160, 80, top: true, state: .hover).hovered,
                        "移入悬停动作新轮廓后，后续帧又丢失悬停")
            try require(update(170, 40, top: true, state: .hover, mirrored: true).hovered &&
                        update(170, 40, top: true, state: .hover).hovered,
                        "左右转向导致悬停抖动")
            try require(!update(10, 10, top: true, state: .hover).hovered &&
                        !update(160, 80, top: true, state: .hover).hovered,
                        "离开猫咪后悬停保持范围没有清除")
            _ = update(50, 40, top: true, state: .idle)
            try require(!update(50, 40, top: false, state: .awaitInput).hovered &&
                        !update(50, 40, top: false, state: .hover).hovered,
                        "其他动作继承了已经过期的悬停轮廓")
        }

        try checkStationaryForehead(library: library)

        let visible = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let original = NSRect(x: -900, y: 150, width: 220, height: 176)
        for percentage in percentages {
            for feeding in [false, true] {
                let resized = PetLayout.resizedFrame(original, scale: CGFloat(percentage) / 100,
                                                     feeding: feeding, visible: visible)
                try require(resized.midX == original.midX && resized.minY == original.minY,
                            "缩放改变了猫咪中心或脚底位置")
                let edge = PetLayout.resizedFrame(NSRect(x: -60, y: 860, width: 110, height: 88),
                    scale: CGFloat(percentage) / 100, feeding: feeding, visible: visible)
                try require(visible.contains(edge), "缩放后猫咪超出屏幕")
            }
        }
        try require(PetLayout.clampedScale(.nan) == 1 && PetLayout.clampedScale(.infinity) == 1 &&
                    PetLayout.clampedScale(0) == 0.5 && PetLayout.clampedScale(3) == 2,
                    "无效或超出范围的缩放设置未修正")
        print("interaction checks passed: alpha silhouette, transparent holes, atlas crops, mirroring, crossfade, jump, 50–200% scale, headroom, screen edges, stable hover and click-through")
    }

    private static func checkStationaryForehead(library: SpriteLibrary) throws {
        let tester = SpriteHitTester()
        let hoverClip = library.clip(PetAnimationState.hover.rawValue)!
        let player = PetAnimationPlayer(library: library, now: 0)
        let idle = player.sample(at: 0)!
        player.play(.hover, at: 0)
        let firstHover = player.sample(at: 0)!
        for scale: CGFloat in [0.5, 0.877, 1, 2] {
            let bounds = NSRect(origin: .zero, size: PetLayout.size(scale: scale, feeding: false))
            // Real art at the forehead between the ears. Find an entry pixel
            // that the first hover pose moves away from, exposing the old loop.
            let candidates = (12...65).flatMap { y in
                (85...135).map { x in NSPoint(x: CGFloat(x) * scale, y: CGFloat(y) * scale) }
            }
            guard let point = candidates.first(where: {
                tester.contains($0, playback: idle, canvas: library.canvasSize, bounds: bounds, backingScale: 2) &&
                !tester.contains($0, playback: firstHover, canvas: library.canvasSize, bounds: bounds, backingScale: 2)
            }) else { continue } // Art with identical silhouettes cannot reproduce this bug.
            let machine = PetAnimationStateMachine(library: library, now: 0)
            let tracker = SpriteHoverTracker(clip: hoverClip)
            var current = machine.update(at: 0, hovered: false, awaitingInput: false)!
            var transitions = 0
            for tick in 1...300 {
                let hit = tracker.update(at: point, playback: current, canvas: library.canvasSize,
                    bounds: bounds, backingScale: 2, hitTester: tester)
                let next = machine.update(at: Double(tick) / 60, hovered: hit.hovered, awaitingInput: false)!
                if next.state != current.state { transitions += 1 }
                try require(next.state == .hover, "鼠标停在额头时反复离开悬停动作")
                current = next
            }
            try require(transitions == 1, "静止指针仍在反复切换 Idle/Hover")
            let outside = tracker.update(at: NSPoint(x: -10, y: -10), playback: current,
                canvas: library.canvasSize, bounds: bounds, backingScale: 2, hitTester: tester)
            try require(!outside.hovered &&
                machine.update(at: 5.1, hovered: outside.hovered, awaitingInput: false)?.state == .idle,
                "移开鼠标后没有恢复待机")
            print("stationary forehead at \(Int((scale * 100).rounded()))%: 1 hover entry in 300 ticks; exit works")
        }
    }
}
