import AppKit
import SwiftUI

// MARK: - Local data

struct TodoItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var plannedDay: String
    var createdAt: Date = Date()
    var completedAt: Date? = nil
}

struct SavedData: Codable {
    var tasks: [TodoItem] = []
    var notes: [String: String] = [:]
}

enum PanelTab: Hashable {
    case tasks, note, history
}

final class PetStore: ObservableObject {
    @Published private(set) var tasks: [TodoItem] = []
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var currentDay = PetStore.dayKey(Date())
    @Published var selectedTab: PanelTab = .tasks
    @Published var historyDate = Date()
    @Published private(set) var undoIDs: Set<UUID> = []
    @Published private(set) var feedingStatus: [UUID: String] = [:]
    @Published private(set) var saveError: String?
    @Published private(set) var departingIDs: Set<UUID> = []
    @Published private(set) var visibleFeedingIDs: Set<UUID> = []
    var rowBounds: [UUID: () -> NSRect?] = [:]

    var onFeed: ((FeedRequest) -> Void)?
    var onCancelFeed: ((UUID) -> Void)?
    private let fileURL: URL
    private var undoWork: [UUID: DispatchWorkItem] = [:]
    private var departureTokens: [UUID: UUID] = [:]

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabbyDesktopPet", isDirectory: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("data.json")
        load()
    }

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    var today: String { currentDay }

    func refreshDay() {
        let newDay = Self.dayKey(Date())
        if newDay != currentDay { currentDay = newDay }
    }
    var openTasks: [TodoItem] {
        tasks.filter { ($0.completedAt == nil || visibleFeedingIDs.contains($0.id)) && $0.plannedDay <= today }
            .sorted { $0.createdAt < $1.createdAt }
    }
    var completedToday: [TodoItem] {
        tasks.filter { item in
            guard let date = item.completedAt else { return false }
            return Self.dayKey(date) == today
        }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    func historyTasks(on date: Date) -> [TodoItem] {
        let day = Self.dayKey(date)
        return tasks.filter { $0.plannedDay == day || ($0.completedAt.map(Self.dayKey) == day) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func note(on date: Date) -> String { notes[Self.dayKey(date)] ?? "" }

    func setNote(_ text: String, on date: Date) {
        notes[Self.dayKey(date)] = text
        save()
    }

    func addTask(_ rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        tasks.append(TodoItem(title: String(title.prefix(200)), plannedDay: today))
        save()
    }

    func editTask(_ id: UUID, title rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].title = String(title.prefix(200))
        save()
    }

    func deleteTask(_ id: UUID) {
        onCancelFeed?(id)
        tasks.removeAll { $0.id == id }
        clearFeedStatus(id)
        save()
    }

    func completeTask(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].completedAt == nil else { return }
        let title = tasks[index].title
        tasks[index].completedAt = Date()
        // Persist first: exiting halfway through a performance must not lose a
        // completed task or replay it on launch. Never animate a failed save.
        guard save() else { tasks[index].completedAt = nil; return }
        undoIDs.insert(id)
        visibleFeedingIDs.insert(id)
        feedingStatus[id] = "排队等投喂"
        if let onFeed = onFeed {
            let event = NSApp?.currentEvent
            let origin = event?.type == .leftMouseUp || event?.type == .leftMouseDown
                ? NSEvent.mouseLocation : nil
            onFeed(FeedRequest(id: id, title: title, origin: origin, sourceRect: rowBounds[id]?()))
        } else {
            finishFeed(id)
        }
    }

    func feedStarted(_ id: UUID) {
        guard feedingStatus[id] != nil else { return }
        let token = UUID()
        departureTokens[id] = token
        departingIDs.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
            guard self?.departureTokens[id] == token else { return }
            self?.visibleFeedingIDs.remove(id)
            self?.departingIDs.remove(id)
            self?.departureTokens.removeValue(forKey: id)
        }
    }

    func feedProgress(_ id: UUID, state: PetAnimationState) {
        guard feedingStatus[id] != nil else { return }
        let labels: [PetAnimationState: String] = [.feedStart: "小纸条飘下来啦…", .rise: "起身准备…",
            .catchCard: "跳起来接住！", .settle: "落地坐稳…", .eat: "正在嚼小纸条…",
            .swallow: "咕噜，吃完啦", .wipeMouth: "抬爪擦擦嘴…", .standAfterWipe: "擦干净，站起来…",
            .turnBack: "转过身…",
            .poop: "正在拉粑粑…", .returnFront: "转回来啦", .proud: "眨眨眼，谢谢投喂"]
        if let label = labels[state], feedingStatus[id] != label { feedingStatus[id] = label }
    }

    func finishFeed(_ id: UUID) {
        guard undoIDs.contains(id) else { return }
        feedingStatus.removeValue(forKey: id)
        visibleFeedingIDs.remove(id)
        departingIDs.remove(id)
        undoWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.undoIDs.remove(id)
            self?.undoWork.removeValue(forKey: id)
        }
        undoWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func undoCompletion(_ id: UUID) {
        guard undoIDs.contains(id), let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let completedAt = tasks[index].completedAt
        tasks[index].completedAt = nil
        guard save() else { tasks[index].completedAt = completedAt; return }
        clearFeedStatus(id)
        onCancelFeed?(id)
    }

    private func clearFeedStatus(_ id: UUID) {
        departureTokens.removeValue(forKey: id)
        undoWork.removeValue(forKey: id)?.cancel()
        undoIDs.remove(id)
        feedingStatus.removeValue(forKey: id)
        visibleFeedingIDs.remove(id)
        departingIDs.remove(id)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(SavedData.self, from: data) else { return }
        tasks = saved.tasks
        notes = saved.notes
    }

    @discardableResult private func save() -> Bool {
        let data = SavedData(tasks: tasks, notes: notes)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: fileURL, options: .atomic)
            saveError = nil
            return true
        } catch {
            saveError = "保存失败，请检查磁盘空间或文件权限后重试。"
            NSLog("TabbyDesktopPet: save failed: %@", error.localizedDescription)
            return false
        }
    }
}

// MARK: - Note panel

private let paper = Color(red: 0.99, green: 0.96, blue: 0.86)
private let ink = Color(red: 0.28, green: 0.20, blue: 0.15)
private let accent = Color(red: 0.51, green: 0.34, blue: 0.21)

private struct TaskRowOrigin: NSViewRepresentable {
    let id: UUID
    let store: PetStore
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        store.rowBounds[id] = { [weak view] in
            guard let view = view, let window = view.window else { return nil }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct TaskRow: View {
    let item: TodoItem
    @ObservedObject var store: PetStore
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isEditing {
                TextField("任务", text: $editText, onCommit: commitEdit)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("保存", action: commitEdit)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    if item.plannedDay < store.today {
                        Text("之前未完成").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button(item.completedAt == nil ? "喂给猫咪" : "等待投喂") { store.completeTask(item.id) }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(accent).cornerRadius(7)
                    .buttonStyle(PlainButtonStyle())
                    .disabled(item.completedAt != nil)
                if item.completedAt != nil {
                    Button("撤销") { store.undoCompletion(item.id) }
                } else {
                    Button("✎") { editText = item.title; isEditing = true }.help("编辑任务")
                    Button("×") { store.deleteTask(item.id) }.help("删除任务")
                }
            }
        }
        .foregroundColor(ink)
        .padding(9)
        .background(Color.white.opacity(0.65))
        .cornerRadius(9)
        .background(TaskRowOrigin(id: item.id, store: store))
        .opacity(store.departingIDs.contains(item.id) ? 0 : 1)
        .scaleEffect(store.departingIDs.contains(item.id) ? 0.96 : 1)
        .animation(.easeInOut(duration: 0.35), value: store.departingIDs.contains(item.id))
    }

    private func commitEdit() {
        store.editTask(item.id, title: editText)
        isEditing = false
    }
}

struct TaskPanelView: View {
    @ObservedObject var store: PetStore
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("🐾 今日小纸条")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Spacer()
                Text(Date(), style: .date).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Picker("", selection: $store.selectedTab) {
                Text("待办").tag(PanelTab.tasks)
                Text("便签").tag(PanelTab.note)
                Text("历史").tag(PanelTab.history)
            }
            .pickerStyle(SegmentedPickerStyle())
            .labelsHidden()

            Group {
                switch store.selectedTab {
                case .tasks: tasksPage
                case .note: notePage
                case .history: historyPage
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 390, height: 500)
        .background(paper)
        .foregroundColor(ink)
    }

    private var tasksPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                TextField("写下今天要做的事", text: $draft, onCommit: addDraft)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("添加", action: addDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("待完成 \(store.openTasks.filter { $0.completedAt == nil }.count) 项  ·  今天完成 \(store.completedToday.count) 项")
                .font(.system(size: 11)).foregroundColor(.secondary)
            if let error = store.saveError {
                Text(error).font(.system(size: 11)).foregroundColor(.red)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if store.openTasks.isEmpty {
                        Text("今天的小纸条还是空的，先记下一件事吧。")
                            .font(.system(size: 12)).foregroundColor(.secondary).padding(.vertical, 18)
                    }
                    ForEach(store.openTasks) { item in TaskRow(item: item, store: store) }
                    if !store.completedToday.isEmpty {
                        Divider().padding(.vertical, 5)
                        Text("今天已完成")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(accent)
                        ForEach(store.completedToday.filter { !store.visibleFeedingIDs.contains($0.id) }) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("✓  " + item.title).lineLimit(2)
                                    if let status = store.feedingStatus[item.id] {
                                        Text(status).foregroundColor(accent)
                                    } else if let date = item.completedAt {
                                        Text(date, style: .time).font(.system(size: 10))
                                    }
                                }
                                Spacer()
                                if store.undoIDs.contains(item.id) {
                                    Button("撤销") { store.undoCompletion(item.id) }
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(7)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var notePage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("随手记下今天的想法").font(.system(size: 12)).foregroundColor(.secondary)
            TextEditor(text: Binding(
                get: { store.note(on: Date()) },
                set: { store.setNote($0, on: Date()) }
            ))
            .font(.system(size: 14))
            .padding(8)
            .background(Color.white.opacity(0.72))
            .cornerRadius(9)
            Text("自动保存在这台 Mac 上").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("查看日期", selection: $store.historyDate, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(CompactDatePickerStyle())
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let items = store.historyTasks(on: store.historyDate)
                    if items.isEmpty && store.note(on: store.historyDate).isEmpty {
                        Text("这一天没有记录。")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    ForEach(items) { item in
                        HStack(alignment: .top) {
                            Text(item.completedAt == nil ? "○" : "✓")
                            Text(item.title).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                    }
                    if !store.note(on: store.historyDate).isEmpty {
                        Divider()
                        Text("便签").font(.system(size: 12, weight: .semibold))
                        Text(store.note(on: store.historyDate))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func addDraft() {
        store.addTask(draft)
        draft = ""
    }
}

// MARK: - Transparent pet window and animation

final class PetSpriteView: NSView {
    let library: SpriteLibrary
    private let animationMachine: PetAnimationStateMachine
    var onClick: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onRoamStep: ((CGFloat) -> Void)?
    var onPlayback: ((SpritePlayback) -> Void)?
    var onFeedStarted: ((FeedRequest) -> Void)?
    var onFeedFinished: ((UUID) -> Void)?
    var onFeedCancelled: (() -> Void)?
    var onFeedProgress: ((UUID, SpritePlayback) -> Void)?
    var isWriting: (() -> Bool)?
    var previewState: PetAnimationState?
    var allowsDragging = true
    var reducedMotion = false
    var usesExternalCardFlight = false
    private var feedQueue = FeedQueue()
    private var currentPlayback: SpritePlayback?
    private var tickTimer: Timer?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var hoverMirrored = false
    private var mouseStart: NSPoint?
    private var originStart: NSPoint?
    private var didDrag = false
    private var lastRoamFrame = -1
    private var roamDirection: CGFloat = 1
    override var isFlipped: Bool { true }

    init(frame: NSRect, library: SpriteLibrary) {
        self.library = library
        self.animationMachine = PetAnimationStateMachine(library: library,
            now: ProcessInfo.processInfo.systemUptime)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { tickTimer?.invalidate() }

    private func tick() {
        if let window = window {
            let cursor = NSEvent.mouseLocation
            isHovered = window.frame.contains(cursor)
            if isHovered {
                updateHoverDirection(cursorX: cursor.x - window.frame.minX)
            }
        }
        advanceAnimation(at: ProcessInfo.processInfo.systemUptime)
        needsDisplay = true
    }

    private func updateHoverDirection(cursorX: CGFloat) {
        // The dead zone keeps the sprite from flipping repeatedly when the cursor
        // crosses the cat's nose. The source nuzzle faces screen-left.
        if cursorX < bounds.width * 0.42 {
            hoverMirrored = false
        } else if cursorX > bounds.width * 0.58 {
            hoverMirrored = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                      owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        mouseMoved(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoverDirection(cursorX: point.x)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    func feed(_ request: FeedRequest) {
        feedQueue.enqueue(request)
        advanceAnimation(at: ProcessInfo.processInfo.systemUptime)
        needsDisplay = true
    }

    func cancelFeed(_ id: UUID) {
        if feedQueue.cancel(id) {
            animationMachine.cancelFeed(at: ProcessInfo.processInfo.systemUptime)
            onFeedCancelled?()
        }
        advanceAnimation(at: ProcessInfo.processInfo.systemUptime)
        needsDisplay = true
    }

    private func advanceAnimation(at now: TimeInterval) {
        if animationMachine.canBeginFeed, let request = feedQueue.startNext() {
            animationMachine.beginFeed(at: now, reducedMotion: reducedMotion)
            onFeedStarted?(request)
        }
        if let playback = animationMachine.update(at: now, hovered: isHovered,
            awaitingInput: isWriting?() == true,
            canRoam: !UserDefaults.standard.bool(forKey: "pauseRoaming"),
            preview: previewState) {
            currentPlayback = playback
            onPlayback?(playback)
            if let request = feedQueue.active, animationMachine.isFeeding {
                onFeedProgress?(request.id, playback)
            }
            if previewState == nil && playback.state == .roam {
                if lastRoamFrame == -1 { roamDirection = Bool.random() ? 1 : -1 }
                if playback.frameIndex != lastRoamFrame {
                    lastRoamFrame = playback.frameIndex
                    let direction = roamDirection
                    DispatchQueue.main.async { [weak self] in self?.onRoamStep?(direction * 3) }
                }
            } else {
                lastRoamFrame = -1
            }
        }
        if !animationMachine.isFeeding, let finished = feedQueue.finish() {
            onFeedFinished?(finished.id)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        guard let playback = currentPlayback else { return }
        FeedMotion.drawCat(playback, canvas: library.canvasSize, in: bounds,
            backingScale: window?.backingScaleFactor ?? 1,
            mirrored: playback.state == .hover && hoverMirrored)
        let externalFlight = usesExternalCardFlight && previewState == nil &&
            (playback.state == .feedStart || playback.state == .rise ||
             (playback.state == .catchCard && playback.clipProgress < FeedMotion.catchFraction))
        FeedingPainter.draw(playback, title: feedQueue.active?.title ?? "完成今天的一件事",
            in: FeedMotion.scene(in: bounds), externalFlight: externalFlight,
            reducedMotion: reducedMotion, interception: FeedMotion.interception(library: library))
    }

    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation
        originStart = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard allowsDragging else { return }
        guard let start = mouseStart, let origin = originStart, let window = window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - start.x
        let dy = current.y - start.y
        if abs(dx) + abs(dy) > 4 { didDrag = true }
        guard didDrag else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(current) }) ?? window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = min(max(origin.x + dx, visible.minX), visible.maxX - window.frame.width)
        let y = min(max(origin.y + dy, visible.minY), visible.maxY - window.frame.height)
        window.setFrameOrigin(NSPoint(x: x, y: y))
        onMove?(window.frame.origin)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onClick?() }
        mouseStart = nil
        originStart = nil
    }
}

final class NotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

// MARK: - Application

final class PetAppDelegate: NSObject, NSApplicationDelegate {
    // Optional file override keeps UI verification isolated from personal tasks.
    private let store = PetStore(fileURL: {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--data-file"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }())
    private var spriteLibrary: SpriteLibrary!
    private var petWindow: NSPanel!
    private var notePanel: NotePanel!
    private var spriteView: PetSpriteView!
    private var previewWindow: NSWindow?
    private var previewSprite: PetSpriteView?
    private var previewLabel: NSTextField?
    private var statusItem: NSStatusItem!
    private var roamingTimer: Timer?
    private var globalClickMonitor: Any?
    private let feedingFlight = FeedingFlight()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let library = try? SpriteLibrary() else {
            NSAlert(error: NSError(domain: "TabbyDesktopPet", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "找不到猫咪动画资源或清单"])).runModal()
            NSApp.terminate(nil)
            return
        }
        spriteLibrary = library
        NSApp.applicationIconImage = library.clip("Idle")?.frames.first?.image
        setupPet(library: library)
        setupNotePanel()
        spriteView.isWriting = { [weak self] in self?.notePanel.isVisible ?? false }
        setupMenu()
        if CommandLine.arguments.contains("--preview") { openPreview() }
        store.onFeed = { [weak self] request in
            self?.spriteView.feed(request)
        }
        store.onCancelFeed = { [weak self] id in self?.spriteView.cancelFeed(id) }
        spriteView.usesExternalCardFlight = true
        spriteView.onFeedStarted = { [weak self] request in
            guard let self = self else { return }
            var request = request
            request.sourceRect = self.store.rowBounds[request.id]?() ?? request.sourceRect
            if CommandLine.arguments.contains("--data-file") {
                NSLog("feed source row: %@", NSStringFromRect(request.sourceRect ?? .zero))
            }
            self.store.feedStarted(request.id)
            self.setFeedingHeadroom(true)
            self.petWindow.orderFrontRegardless()
            self.feedingFlight.begin(request)
            if UserDefaults.standard.bool(forKey: "soundEnabled") {
                NSSound(named: NSSound.Name("Pop"))?.play()
            }
        }
        spriteView.onFeedProgress = { [weak self] id, playback in
            guard let self = self else { return }
            self.store.feedProgress(id, state: playback.state)
            if playback.state == .feedStart || playback.state == .rise ||
                (playback.state == .catchCard && playback.clipProgress < FeedMotion.catchFraction) {
                // Fixed interception point at the top of the jump. On contact,
                // the pet renderer takes over and the card follows its mouth.
                let scene = FeedMotion.scene(in: self.spriteView.bounds)
                let localPoint = FeedMotion.interception(library: library)
                let point = NSPoint(x: self.petWindow.frame.minX + localPoint.x,
                                    y: self.petWindow.frame.maxY - scene.minY - localPoint.y)
                self.feedingFlight.update(playback: playback, target: point)
            } else {
                self.feedingFlight.hide()
            }
        }
        spriteView.onFeedFinished = { [weak self] id in
            self?.feedingFlight.hide()
            self?.store.finishFeed(id)
            self?.setFeedingHeadroom(false)
        }
        spriteView.onFeedCancelled = { [weak self] in
            self?.feedingFlight.hide()
            self?.setFeedingHeadroom(false)
        }
        if CommandLine.arguments.contains("--demo-feed") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.demoFeed() }
        }
        if CommandLine.arguments.contains("--open-notes") { openNotes() }
        roamingTimer = Timer.scheduledTimer(withTimeInterval: 18, repeats: true) { [weak self] _ in
            self?.store.refreshDay()
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.notePanel.isVisible else { return }
                let point = NSEvent.mouseLocation
                if !self.notePanel.frame.contains(point) && !self.petWindow.frame.contains(point) {
                    self.notePanel.orderOut(nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor) }
        roamingTimer?.invalidate()
    }

    private func setupPet(library: SpriteLibrary) {
        let size = NSSize(width: 220, height: 176)
        let primary = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1000, height: 700)
        let defaults = UserDefaults.standard
        let savedX: CGFloat? = defaults.object(forKey: "petX") == nil ? nil : CGFloat(defaults.double(forKey: "petX"))
        let savedY: CGFloat? = defaults.object(forKey: "petY") == nil ? nil : CGFloat(defaults.double(forKey: "petY"))
        let proposed = NSPoint(x: savedX ?? primary.maxX - size.width - 24,
                               y: savedY ?? primary.minY + 90)
        let selectedScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(proposed) }) ?? NSScreen.main
        let visible = selectedScreen?.visibleFrame ?? primary
        let origin = NSPoint(x: min(max(proposed.x, visible.minX), visible.maxX - size.width),
                             y: min(max(proposed.y, visible.minY), visible.maxY - size.height))
        petWindow = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        petWindow.isOpaque = false
        petWindow.backgroundColor = .clear
        petWindow.hasShadow = false
        petWindow.level = .floating
        petWindow.collectionBehavior = [.canJoinAllSpaces]
        petWindow.ignoresMouseEvents = false
        spriteView = PetSpriteView(frame: NSRect(origin: .zero, size: size),
                                   library: library)
        spriteView.reducedMotion = UserDefaults.standard.bool(forKey: "reducedMotion")
        spriteView.onClick = { [weak self] in self?.toggleNotePanel() }
        spriteView.onMove = { point in
            UserDefaults.standard.set(Double(point.x), forKey: "petX")
            UserDefaults.standard.set(Double(point.y), forKey: "petY")
        }
        spriteView.onRoamStep = { [weak self] delta in self?.movePetDuringRoam(delta) }
        petWindow.contentView = spriteView
        petWindow.orderFrontRegardless()
    }

    private func setFeedingHeadroom(_ enabled: Bool) {
        var frame = petWindow.frame
        frame.size.height = enabled ? 232 : 176
        petWindow.setFrame(frame, display: true)
        spriteView.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func setupNotePanel() {
        notePanel = NotePanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        notePanel.title = "今日小纸条"
        notePanel.isReleasedWhenClosed = false
        notePanel.level = .floating
        notePanel.collectionBehavior = [.canJoinAllSpaces]
        notePanel.contentView = NSHostingView(rootView: TaskPanelView(store: store))
    }

    private func toggleNotePanel() {
        if notePanel.isVisible { notePanel.orderOut(nil); return }
        store.selectedTab = .tasks
        let pet = petWindow.frame
        let screen = petWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? pet
        let width = notePanel.frame.width
        let height = notePanel.frame.height
        let right = pet.maxX + 8
        let x = right + width <= screen.maxX ? right : max(screen.minX, pet.minX - width - 8)
        let y = min(max(pet.midY - height / 2, screen.minY), screen.maxY - height)
        notePanel.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        notePanel.makeKeyAndOrderFront(nil)
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐈"
        let menu = NSMenu()
        addMenuItem("显示猫咪", action: #selector(showPet), to: menu)
        addMenuItem("打开今日小纸条", action: #selector(openNotes), to: menu)
        addMenuItem("试喂一张卡片", action: #selector(demoFeed), to: menu)
        addMenuItem("动作预览…", action: #selector(openPreview), to: menu)
        menu.addItem(.separator())
        addMenuItem("暂停闲逛", action: #selector(toggleRoaming), to: menu)
        addMenuItem("减少动态效果", action: #selector(toggleReducedMotion), to: menu)
        addMenuItem("播放音效", action: #selector(toggleSound), to: menu)
        menu.addItem(.separator())
        addMenuItem("退出", action: #selector(quit), to: menu)
        statusItem.menu = menu
        refreshMenu()
    }

    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.item(withTitle: "暂停闲逛")?.state = UserDefaults.standard.bool(forKey: "pauseRoaming") ? .on : .off
        menu.item(withTitle: "减少动态效果")?.state = UserDefaults.standard.bool(forKey: "reducedMotion") ? .on : .off
        menu.item(withTitle: "播放音效")?.state = UserDefaults.standard.bool(forKey: "soundEnabled") ? .on : .off
    }

    private func movePetDuringRoam(_ delta: CGFloat) {
        guard !UserDefaults.standard.bool(forKey: "pauseRoaming"), !notePanel.isVisible else { return }
        let frame = petWindow.frame
        guard let visible = petWindow.screen?.visibleFrame else { return }
        let x = min(max(frame.origin.x + delta, visible.minX), visible.maxX - frame.width)
        petWindow.setFrameOrigin(NSPoint(x: x, y: frame.origin.y))
        UserDefaults.standard.set(Double(x), forKey: "petX")
    }

    @objc private func openPreview() {
        if previewWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "猫咪动作预览 · 关键姿态"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces]
            window.center()
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor

            let selector = NSPopUpButton(frame: NSRect(x: 24, y: 255, width: 312, height: 28),
                                         pullsDown: false)
            selector.addItems(withTitles: PetAnimationState.allCases.map { $0.rawValue })
            selector.target = self
            selector.action = #selector(selectPreviewState(_:))
            content.addSubview(selector)

            let sprite = PetSpriteView(frame: NSRect(x: 70, y: 24, width: 220, height: 232),
                                       library: spriteLibrary)
            sprite.previewState = .idle
            sprite.allowsDragging = false
            content.addSubview(sprite)

            let label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: 24, y: 28, width: 312, height: 22)
            label.alignment = .center
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            content.addSubview(label)
            previewLabel = label
            sprite.onPlayback = { [weak self] playback in
                let message = "\(playback.state.rawValue) · 帧 \(playback.frameIndex + 1)/\(playback.frameCount) · \(playback.provisional ? "素材待补" : "正式素材")"
                if self?.previewLabel?.stringValue != message {
                    self?.previewLabel?.stringValue = message
                }
            }
            window.contentView = content
            previewSprite = sprite
            previewWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        previewWindow?.makeKeyAndOrderFront(nil)
        previewWindow?.orderFrontRegardless()
    }

    @objc private func selectPreviewState(_ sender: NSPopUpButton) {
        let states = PetAnimationState.allCases
        let index = sender.indexOfSelectedItem
        guard states.indices.contains(index) else { return }
        previewSprite?.previewState = states[index]
        previewSprite?.needsDisplay = true
    }

    @objc private func showPet() { petWindow.orderFrontRegardless() }
    @objc private func demoFeed() {
        spriteView.feed(FeedRequest(id: UUID(), title: "完成今天的一件事", origin: nil))
    }
    @objc private func openNotes() {
        if !notePanel.isVisible { toggleNotePanel() }
        else { NSApp.activate(ignoringOtherApps: true); notePanel.makeKeyAndOrderFront(nil) }
    }
    @objc private func toggleRoaming() {
        let value = !UserDefaults.standard.bool(forKey: "pauseRoaming")
        UserDefaults.standard.set(value, forKey: "pauseRoaming")
        refreshMenu()
    }
    @objc private func toggleReducedMotion() {
        let value = !UserDefaults.standard.bool(forKey: "reducedMotion")
        UserDefaults.standard.set(value, forKey: "reducedMotion")
        spriteView.reducedMotion = value
        refreshMenu()
    }
    @objc private func toggleSound() {
        let value = !UserDefaults.standard.bool(forKey: "soundEnabled")
        UserDefaults.standard.set(value, forKey: "soundEnabled")
        refreshMenu()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--validate-resources") {
    do {
        let library = try SpriteLibrary()
        print("animation resources valid: \(library.clips.count) clips")
    } catch {
        fputs("animation resources invalid: \(error)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.contains("--check-feeding") {
    do {
        try FeedingChecks.run(library: SpriteLibrary())
    } catch {
        fputs("feeding checks failed: \(error)\n", stderr)
        exit(1)
    }
} else if let index = CommandLine.arguments.firstIndex(of: "--export-feed"),
          CommandLine.arguments.indices.contains(index + 1) {
    do {
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        try SpritePreviewExporter.exportFeeding(library: SpriteLibrary(), to: directory)
        print(directory.appendingPathComponent("feed.gif").path)
    } catch {
        fputs("feeding preview failed: \(error)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.contains("--check-animation-flow") {
    do {
        let library = try SpriteLibrary()
        let machine = PetAnimationStateMachine(library: library, now: 0)
        machine.beginFeed(at: 0)
        var visited: [PetAnimationState] = []
        for tick in 0...600 {
            let time = Double(tick) / 30
            if let playback = machine.update(at: time, hovered: true,
                                             awaitingInput: true) {
                if visited.last != playback.state { visited.append(playback.state) }
            }
            if !machine.isFeeding { break }
        }
        let expected: [PetAnimationState] = [.feedStart, .rise, .catchCard, .settle,
            .eat, .swallow, .wipeMouth, .standAfterWipe,
            .turnBack, .poop, .returnFront, .proud, .awaitInput]
        guard visited == expected else {
            throw NSError(domain: "TabbyDesktopPet", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "喂食状态顺序错误: \(visited)"])
        }
        print("animation flow valid: \(visited.map(\.rawValue).joined(separator: " → "))")
    } catch {
        fputs("animation flow invalid: \(error)\n", stderr)
        exit(1)
    }
} else if let index = CommandLine.arguments.firstIndex(of: "--export-preview"),
          CommandLine.arguments.indices.contains(index + 1) {
    do {
        let library = try SpriteLibrary()
        let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        let files = try SpritePreviewExporter.export(library: library, to: destination)
        files.forEach { print($0.path) }
    } catch {
        fputs("preview export failed: \(error)\n", stderr)
        exit(1)
    }
} else {
    let application = NSApplication.shared
    let delegate = PetAppDelegate()
    application.delegate = delegate
    application.run()
}
