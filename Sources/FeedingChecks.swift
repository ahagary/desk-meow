import AppKit

enum FeedingChecks {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "FeedingChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func run(library: SpriteLibrary) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tabby-feed-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data.json")
        let store = PetStore(fileURL: url)
        var received: [FeedRequest] = []
        var cancelled: [UUID] = []
        store.onFeed = { received.append($0) }
        store.onCancelFeed = { cancelled.append($0) }
        store.addTask("吃掉测试卡片")
        store.addTask(String(repeating: "长标题", count: 100))
        let first = store.tasks[0].id
        let second = store.tasks[1].id
        store.completeTask(first)
        store.completeTask(first)
        store.completeTask(second)
        try require(received.count == 2, "同一任务重复投喂")
        try require(received[1].title.count == 200, "长标题未截断")
        let reloaded = PetStore(fileURL: url)
        try require(reloaded.completedToday.count == 2, "动画中退出会丢失完成记录")
        try require(reloaded.feedingStatus.isEmpty, "重启应保留记录但不重播动画")

        var queue = FeedQueue()
        queue.enqueue(received[0])
        queue.enqueue(received[0])
        queue.enqueue(received[1])
        try require(queue.pending.count == 2, "队列没有去重")
        try require(queue.startNext()?.id == first, "没有按请求顺序播放")
        try require(queue.startNext() == nil, "两个表演同时播放")
        store.undoCompletion(second)
        queue.cancel(second)
        try require(cancelled == [second] && queue.pending.isEmpty, "撤销未取消排队卡片")
        try require(queue.finish()?.id == first && queue.active == nil, "首个表演没有结束")
        store.finishFeed(first)
        try require(store.feedingStatus[first] == nil && store.undoIDs.contains(first), "表演后没有保留撤销窗口")
        store.undoCompletion(first)
        try require(PetStore(fileURL: url).openTasks.count == 2, "撤销结果未保存")
        store.completeTask(first)
        queue.enqueue(received.last!)
        _ = queue.startNext()
        try require(queue.cancel(first) && queue.active == nil, "撤销未停止当前表演")

        let full: [PetAnimationState] = [.feedStart, .rise, .catchCard, .settle,
            .eat, .swallow, .wipeMouth, .standAfterWipe, .turnBack, .poop, .returnFront, .proud]
        let joins = [("EnterAwait","AwaitInput"),("AwaitInput","Rise"),
                     ("Rise","CatchCard"),("CatchCard","Settle"),("Settle","Eat"),
                     ("Eat","Swallow"),("Swallow","WipeMouth"),("WipeMouth","StandAfterWipe"),
                     ("StandAfterWipe","TurnBack"),("TurnBack","Poop"),("Poop","ReturnFront"),
                     ("ReturnFront","Proud"),("Proud","AwaitInput"),("Proud","ExitAwait"),("ExitAwait","Idle")]
        for (from, to) in joins {
            let a = library.clip(from)!.frames.last!, b = library.clip(to)!.frames.first!
            try require(a.image === b.image && a.sourceRect == b.sourceRect &&
                        a.anchor == b.anchor && a.displaySize == b.displaySize,
                        "\(from) → \(to) 没有复用同一落稳姿态，可能突然换体型")
        }
        let wipe = library.clip("WipeMouth")!
        try require(wipe.frames.count >= 8 && !wipe.blendFrames,
                    "擦嘴必须使用完整姿态，不能交叉淡入造成重复前爪")
        try require(wipe.frames[0].sourceRect.minY > wipe.frames[4].sourceRect.minY,
                    "图集上下两排的读取方向错误")
        for frame in wipe.frames {
            try require(abs(frame.anchor.y - wipe.frames[0].anchor.y) < 0.01,
                        "擦嘴支撑脚的基线漂移")
            try require(abs(frame.displaySize.width / frame.sourceRect.width -
                            frame.displaySize.height / frame.sourceRect.height) < 0.001,
                        "擦嘴图像被非等比拉伸")
        }
        let catchClip = library.clip("CatchCard")!
        let sitClip = library.clip("Settle")!
        func point(_ frame: SpriteFrame) -> NSPoint {
            NSPoint(x: (frame.mouth.x - frame.anchor.x) * 220 / 1402,
                    y: (frame.mouth.y - frame.anchor.y) * 220 / 1402)
        }
        let landingMouth = point(catchClip.frames.last!), sittingStart = point(sitClip.frames.first!)
        try require(hypot(landingMouth.x - sittingStart.x, landingMouth.y - sittingStart.y) < 6,
                    "落地接坐下时卡片脱离嘴部")
        for reduced in [false, true] {
            let machine = PetAnimationStateMachine(library: library, now: 0)
            machine.beginFeed(at: 0, reducedMotion: reduced)
            var visited: [PetAnimationState] = []
            for tick in 0...600 {
                // Hover, typing, and a preview request must not interrupt a feed.
                let playback = machine.update(at: Double(tick) / 30, hovered: true,
                                              awaitingInput: true, preview: .hover)
                if let state = playback?.state, visited.last != state { visited.append(state) }
                if !machine.isFeeding { break }
            }
            let expected = (reduced ? [.swallow, .proud] : full) + [.awaitInput]
            try require(visited == expected, "喂食顺序不正确（减少动态：\(reduced)）：\(visited)")
            try require(!machine.isFeeding, "喂食表演没有退出")
            machine.beginFeed(at: 7)
            machine.cancelFeed(at: 7.1)
            try require(!machine.isFeeding && machine.state == .idle, "当前动画无法撤销")
        }
        // Rapid panel toggles must finish the physical sit/stand in progress.
        let toggles = PetAnimationStateMachine(library: library, now: 0)
        _ = toggles.update(at: 0, hovered: false, awaitingInput: true)
        try require(!toggles.canBeginFeed, "坐下过程中不应开始投喂")
        _ = toggles.update(at: 0.06, hovered: false, awaitingInput: false)
        try require(toggles.state == .enterAwait, "快速关闭便签打断了坐下动作")
        let seatedAt = library.clip("EnterAwait")!.duration + 0.01
        _ = toggles.update(at: seatedAt, hovered: false, awaitingInput: false)
        try require(toggles.state == .exitAwait, "坐下后没有自然起身")
        _ = toggles.update(at: seatedAt + 0.06, hovered: false, awaitingInput: true)
        try require(toggles.state == .exitAwait && !toggles.canBeginFeed,
                    "重新打开便签造成起身动作跳回第一帧")
        let stoodAt = seatedAt + library.clip("ExitAwait")!.duration + 0.01
        _ = toggles.update(at: stoodAt, hovered: false, awaitingInput: false)
        try require(toggles.state == .idle && toggles.canBeginFeed, "起身完成后未恢复已有待机")

        let closedPanel = PetAnimationStateMachine(library: library, now: 0)
        closedPanel.beginFeed(at: 0)
        var sawExit = false
        for tick in 0...720 {
            _ = closedPanel.update(at: Double(tick)/30, hovered: false, awaitingInput: false)
            if closedPanel.state == .exitAwait { sawExit = true }
            if sawExit && closedPanel.state == .idle { break }
        }
        try require(sawExit && closedPanel.state == .idle, "关闭便签后的投喂没有完成起身并回到待机")
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let failingStore = PetStore(fileURL: blocked.appendingPathComponent("data.json"))
        failingStore.addTask("保存失败测试")
        var failedFeedStarted = false
        failingStore.onFeed = { _ in failedFeedStarted = true }
        failingStore.completeTask(failingStore.tasks[0].id)
        try require(!failedFeedStarted && failingStore.tasks[0].completedAt == nil,
                    "保存失败时仍播放并移除了任务")
        print("feeding checks passed: shared boundary poses, rapid panel toggles, return to existing idle, persistence, duplicate clicks, FIFO, undo, cancellation, reduced motion, save failure")
    }
}
