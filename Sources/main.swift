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

struct HistoryDay: Identifiable {
    let id: String
    var tasks: [TodoItem] = []
    var note = ""

    var recordCount: Int { tasks.count + (note.isEmpty ? 0 : 1) }
}

final class PetStore: ObservableObject {
    @Published private(set) var tasks: [TodoItem] = []
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var currentDay = PetStore.dayKey(Date())
    @Published var selectedTab: PanelTab = .tasks
    @Published private(set) var historyStartDate = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @Published private(set) var historyEndDate = Date()
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

    func setHistoryStart(_ date: Date) {
        historyStartDate = date
        if Self.dayKey(date) > Self.dayKey(historyEndDate) { historyEndDate = date }
    }

    func setHistoryEnd(_ date: Date) {
        historyEndDate = date
        if Self.dayKey(date) < Self.dayKey(historyStartDate) { historyStartDate = date }
    }

    func showRecentHistory(days: Int?) {
        historyEndDate = Date()
        if let days = days {
            historyStartDate = Calendar.current.date(byAdding: .day, value: -(max(1, days) - 1), to: historyEndDate) ?? historyEndDate
        } else {
            let day = (tasks.map(\.plannedDay) + tasks.compactMap { $0.completedAt.map(Self.dayKey) }
                + notes.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.key))
                .min() ?? Self.dayKey(historyEndDate)
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            historyStartDate = min(formatter.date(from: day) ?? historyEndDate, historyEndDate)
        }
    }

    func historyDays(from start: Date, through end: Date) -> [HistoryDay] {
        let first = Self.dayKey(start), last = Self.dayKey(end)
        guard first <= last else { return [] }
        var days: [String: HistoryDay] = [:]
        for item in tasks.sorted(by: { $0.createdAt < $1.createdAt }) {
            // Keep both the original day's task and a later completion record.
            // A task completed on its planned day appears only once that day.
            let taskDays = Set([item.plannedDay] + [item.completedAt.map(Self.dayKey)].compactMap { $0 })
            for day in taskDays where day >= first && day <= last {
                days[day, default: HistoryDay(id: day)].tasks.append(item)
            }
        }
        for (day, note) in notes where day >= first && day <= last &&
            !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            days[day, default: HistoryDay(id: day)].note = note
        }
        return days.values.sorted { $0.id > $1.id }
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

private let ink = Color(red: 0.28, green: 0.20, blue: 0.15)
private let accent = Color(red: 0.51, green: 0.34, blue: 0.21)

private enum PaperTheme: String, CaseIterable, Identifiable {
    case cream, peach, rose, mint, sky, lavender
    var id: String { rawValue }
    var name: String {
        switch self {
        case .cream: return "奶油黄"
        case .peach: return "蜜桃橙"
        case .rose: return "樱花粉"
        case .mint: return "薄荷绿"
        case .sky: return "晴空蓝"
        case .lavender: return "浅藤紫"
        }
    }
    var color: Color {
        switch self {
        case .cream: return Color(red: 0.99, green: 0.96, blue: 0.86)
        case .peach: return Color(red: 1.00, green: 0.91, blue: 0.83)
        case .rose: return Color(red: 0.99, green: 0.90, blue: 0.92)
        case .mint: return Color(red: 0.89, green: 0.95, blue: 0.88)
        case .sky: return Color(red: 0.88, green: 0.94, blue: 0.99)
        case .lavender: return Color(red: 0.94, green: 0.90, blue: 0.98)
        }
    }
}

private func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct CopyTextButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            copyText(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .frame(width: 15, height: 16)
        }
        .buttonStyle(.borderless)
        .help(copied ? "已复制" : "复制全文")
        .accessibilityLabel(copied ? "已复制" : "复制全文")
    }
}

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
                        .textSelection(.enabled)
                    if item.plannedDay < store.today {
                        Text("之前未完成").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
                CopyTextButton(text: item.title)
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
        .contextMenu {
            Button { copyText(item.title) } label: { Label("复制全文", systemImage: "doc.on.doc") }
        }
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
    @State private var showingPaperColors = false
    @AppStorage("notePaperTheme") private var paperTheme = PaperTheme.cream.rawValue

    private var selectedPaper: PaperTheme { PaperTheme(rawValue: paperTheme) ?? .cream }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("🐾 今日小纸条")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Spacer()
                Text(Date(), style: .date).font(.system(size: 11)).foregroundColor(.secondary)
                Button { showingPaperColors.toggle() } label: {
                    Image(systemName: "paintpalette").font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help("纸张颜色")
                .accessibilityLabel("纸张颜色")
                .popover(isPresented: $showingPaperColors, arrowEdge: .bottom) { paperColors }
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
        .background(selectedPaper.color)
        .foregroundColor(ink)
        .preferredColorScheme(.light)
    }

    private var paperColors: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("纸张颜色").font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(66)), count: 3), spacing: 12) {
                ForEach(PaperTheme.allCases) { theme in
                    Button {
                        paperTheme = theme.rawValue
                    } label: {
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.color)
                                .frame(width: 54, height: 34)
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(selectedPaper == theme ? accent : ink.opacity(0.15),
                                            lineWidth: selectedPaper == theme ? 2 : 1))
                                .overlay {
                                    if selectedPaper == theme { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)) }
                                }
                            Text(theme.name).font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.name)
                    .accessibilityValue(selectedPaper == theme ? "已选中" : "未选中")
                }
            }
            Text("自动记住你喜欢的颜色").font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(16)
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
                                    Text("✓  " + item.title)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                    if let status = store.feedingStatus[item.id] {
                                        Text(status).foregroundColor(accent)
                                    } else if let date = item.completedAt {
                                        Text(date, style: .time).font(.system(size: 10))
                                    }
                                }
                                Spacer()
                                CopyTextButton(text: item.title)
                                if store.undoIDs.contains(item.id) {
                                    Button("撤销") { store.undoCompletion(item.id) }
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(7)
                            .contextMenu {
                                Button { copyText(item.title) } label: { Label("复制全文", systemImage: "doc.on.doc") }
                            }
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
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color.white.opacity(0.72))
            .cornerRadius(9)
            Text("自动保存在这台 Mac 上").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private var historyPage: some View {
        let days = store.historyDays(from: store.historyStartDate, through: store.historyEndDate)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 6) {
                DatePicker("开始日期", selection: Binding(get: { store.historyStartDate }, set: store.setHistoryStart),
                           in: ...Date(), displayedComponents: .date)
                DatePicker("结束日期", selection: Binding(get: { store.historyEndDate }, set: store.setHistoryEnd),
                           in: ...Date(), displayedComponents: .date)
            }
            .datePickerStyle(.compact)
            HStack(spacing: 8) {
                Button("今天") { store.showRecentHistory(days: 1) }
                Button("近 7 天") { store.showRecentHistory(days: 7) }
                Button("近 30 天") { store.showRecentHistory(days: 30) }
                Button("全部") { store.showRecentHistory(days: nil) }
            }
            .font(.system(size: 11))
            Text("新记录在前 · \(days.count) 天 · \(days.reduce(0) { $0 + $1.recordCount }) 条记录")
                .font(.system(size: 11)).foregroundColor(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if days.isEmpty {
                        Text("这个时间段没有记录，试试其他日期。")
                            .font(.system(size: 12)).foregroundColor(.secondary).padding(.vertical, 18)
                    }
                    ForEach(days) { day in historySection(day) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(PetStore.dayKey(store.historyStartDate) + PetStore.dayKey(store.historyEndDate))
        }
    }

    private func historySection(_ day: HistoryDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day.id.replacingOccurrences(of: "-", with: "/"))
                .font(.system(size: 12, weight: .semibold)).foregroundColor(accent)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(day.tasks) { item in
                    HStack(alignment: .top, spacing: 7) {
                        let completedOnDay = item.completedAt.map(PetStore.dayKey) == day.id
                        Text(completedOnDay ? "✓" : "○").foregroundColor(accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            if let date = item.completedAt {
                                if completedOnDay {
                                    (Text("完成于 ") + Text(date, style: .time))
                                        .font(.system(size: 10)).foregroundColor(.secondary)
                                } else {
                                    Text("当日待办 · 已于 \(PetStore.dayKey(date).replacingOccurrences(of: "-", with: "/")) 完成")
                                        .font(.system(size: 10)).foregroundColor(.secondary)
                                }
                            } else {
                                Text("待办 · 未完成").font(.system(size: 10)).foregroundColor(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        CopyTextButton(text: item.title)
                    }
                }
                if !day.note.isEmpty {
                    if !day.tasks.isEmpty { Divider() }
                    HStack {
                        Text("便签").font(.system(size: 11, weight: .semibold)).foregroundColor(accent)
                        Spacer()
                        CopyTextButton(text: day.note)
                    }
                    Text(day.note).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .font(.system(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.60))
            .cornerRadius(9)
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
    var onScaleGesture: ((CGFloat) -> Void)?
    var onOpenSizeControls: (() -> Void)?
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
    var passesThroughTransparentPixels = false
    var reducedMotion = false
    var usesExternalCardFlight = false
    private var feedQueue = FeedQueue()
    private var currentPlayback: SpritePlayback?
    private let hitTester = SpriteHitTester()
    private let hoverTracker: SpriteHoverTracker
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
        self.hoverTracker = SpriteHoverTracker(clip: library.clip(PetAnimationState.hover.rawValue))
        self.animationMachine = PetAnimationStateMachine(library: library,
            now: ProcessInfo.processInfo.systemUptime)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("猫咪，点击打开今日小纸条")
        setAccessibilityHelp("拖动移动猫咪，右键调整大小；按住 Command 滚动或双指捏合可连续缩放。")
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "调整猫咪大小") { [weak self] in
            self?.onOpenSizeControls?()
            return true
        }])
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { tickTimer?.invalidate() }

    private func tick() {
        refreshPointerInteraction()
        advanceAnimation(at: ProcessInfo.processInfo.systemUptime)
        needsDisplay = true
    }

    func containsPet(at point: NSPoint) -> Bool {
        guard let playback = currentPlayback else { return false }
        return hitTester.contains(point, playback: playback, canvas: library.canvasSize,
            bounds: bounds, backingScale: window?.backingScaleFactor ?? 1,
            mirrored: playback.state == .hover && hoverMirrored)
    }

    func containsPet(atScreenPoint point: NSPoint) -> Bool {
        guard let window = window else { return false }
        return containsPet(at: convert(window.convertPoint(fromScreen: point), from: nil))
    }

    func refreshPointerInteraction() {
        guard let window = window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        refreshPointerInteraction(at: point)
    }

    private func refreshPointerInteraction(at point: NSPoint) {
        guard let window = window, let playback = currentPlayback else { return }
        let wasMirrored = hoverMirrored
        let interaction = hoverTracker.update(at: point, playback: playback,
            canvas: library.canvasSize, bounds: bounds, backingScale: window.backingScaleFactor,
            mirrored: playback.state == .hover && hoverMirrored, hitTester: hitTester)
        isHovered = interaction.hovered
        if isHovered { updateHoverDirection(cursorX: point.x) }
        if passesThroughTransparentPixels {
            // Continue receiving drag/up events after leaving the silhouette.
            // The hover retention envelope must not swallow transparent clicks.
            // Polling still tracks the pointer while this window is click-through.
            let visible = wasMirrored == hoverMirrored ? interaction.visible : containsPet(at: point)
            window.ignoresMouseEvents = mouseStart == nil && !visible
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard containsPet(at: localPoint) else { return nil }
        return super.hitTest(point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard containsPet(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return super.menu(for: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick = onClick else { return false }
        onClick()
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command),
              containsPet(at: convert(event.locationInWindow, from: nil)) else {
            super.scrollWheel(with: event)
            return
        }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.05
        onScaleGesture?(exp(event.scrollingDeltaY * sensitivity))
    }

    override func magnify(with event: NSEvent) {
        guard containsPet(at: convert(event.locationInWindow, from: nil)) else { return }
        onScaleGesture?(max(0.1, 1 + event.magnification))
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
        mouseMoved(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        refreshPointerInteraction(at: point)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        // Click-through changes can emit an exit even with a stationary pointer.
        // Use the same retained silhouette as the timer instead of cancelling it.
        refreshPointerInteraction()
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
        guard containsPet(at: convert(event.locationInWindow, from: nil)) else { return }
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
        if mouseStart != nil, !didDrag,
           containsPet(at: convert(event.locationInWindow, from: nil)) { onClick?() }
        mouseStart = nil
        originStart = nil
        refreshPointerInteraction()
    }
}

final class NotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class PetPanel: NSPanel {
    override func accessibilityPerformRaise() -> Bool {
        orderFrontRegardless()
        return true
    }
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
    private var petSettingsMenu: NSMenu?
    private let appUpdater = AppUpdater()
    private var updateMenuItem: NSMenuItem?
    private var roamingTimer: Timer?
    private var globalClickMonitor: Any?
    private let feedingFlight = FeedingFlight()
    private var petScale: CGFloat = 1
    private var feedingHeadroom = false
    private var sizePanel: NSPanel?
    private var sizeSlider: NSSlider?
    private var sizeLabel: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupEditingMenu()
        guard let library = try? SpriteLibrary() else {
            NSAlert(error: NSError(domain: "TabbyDesktopPet", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "找不到猫咪动画资源或清单"])).runModal()
            NSApp.terminate(nil)
            return
        }
        spriteLibrary = library
        setupPet(library: library)
        setupNotePanel()
        spriteView.isWriting = { [weak self] in self?.notePanel.isVisible ?? false }
        setupMenu()
        appUpdater.onStateChanged = { [weak self] in self?.refreshMenu() }
        appUpdater.start()
        if CommandLine.arguments.contains("--check-for-updates") {
            DispatchQueue.main.async { [weak self] in self?.appUpdater.checkForUpdates(nil) }
        }
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
                let scale = scene.width / PetLayout.baseSize.width
                let point = NSPoint(x: self.petWindow.frame.minX + scene.minX + localPoint.x * scale,
                                    y: self.petWindow.frame.maxY - scene.minY - localPoint.y * scale)
                self.feedingFlight.update(playback: playback, target: point, scale: scale)
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
                if !self.notePanel.frame.contains(point) && !self.spriteView.containsPet(atScreenPoint: point) {
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
        let defaults = UserDefaults.standard
        petScale = PetLayout.clampedScale(defaults.object(forKey: "petScale") == nil ? 1 :
                                         CGFloat(defaults.double(forKey: "petScale")))
        let size = PetLayout.size(scale: petScale, feeding: false)
        let primary = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1000, height: 700)
        let savedX: CGFloat? = defaults.object(forKey: "petX") == nil ? nil : CGFloat(defaults.double(forKey: "petX"))
        let savedY: CGFloat? = defaults.object(forKey: "petY") == nil ? nil : CGFloat(defaults.double(forKey: "petY"))
        let proposed = NSPoint(x: savedX ?? primary.maxX - size.width - 24,
                               y: savedY ?? primary.minY + 90)
        let selectedScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(proposed) }) ?? NSScreen.main
        let visible = selectedScreen?.visibleFrame ?? primary
        let origin = NSPoint(x: min(max(proposed.x, visible.minX), visible.maxX - size.width),
                             y: min(max(proposed.y, visible.minY), visible.maxY - size.height))
        petWindow = PetPanel(contentRect: NSRect(origin: origin, size: size),
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
        spriteView.passesThroughTransparentPixels = true
        spriteView.reducedMotion = UserDefaults.standard.bool(forKey: "reducedMotion")
        spriteView.onClick = { [weak self] in self?.toggleNotePanel() }
        spriteView.onScaleGesture = { [weak self] factor in
            guard let self = self else { return }
            self.setPetScale(self.petScale * factor)
        }
        spriteView.onOpenSizeControls = { [weak self] in self?.openSizeControls() }
        spriteView.onMove = { point in
            UserDefaults.standard.set(Double(point.x), forKey: "petX")
            UserDefaults.standard.set(Double(point.y), forKey: "petY")
        }
        spriteView.onRoamStep = { [weak self] delta in self?.movePetDuringRoam(delta) }
        petWindow.contentView = spriteView
        petWindow.orderFrontRegardless()
    }

    private func setFeedingHeadroom(_ enabled: Bool) {
        feedingHeadroom = enabled
        resizePet()
    }

    private func resizePet(repositionNotes: Bool = false) {
        let visible = petWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? petWindow.frame
        let frame = PetLayout.resizedFrame(petWindow.frame, scale: petScale,
                                          feeding: feedingHeadroom, visible: visible)
        petWindow.setFrame(frame, display: true)
        spriteView.frame = NSRect(origin: .zero, size: frame.size)
        spriteView.needsDisplay = true
        spriteView.refreshPointerInteraction()
        spriteView.onMove?(frame.origin)
        if repositionNotes, notePanel?.isVisible == true { positionNotePanel() }
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
        positionNotePanel()
        NSApp.activate(ignoringOtherApps: true)
        notePanel.makeKeyAndOrderFront(nil)
    }

    private func positionNotePanel() {
        let pet = petWindow.frame
        let screen = petWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? pet
        let width = notePanel.frame.width
        let height = notePanel.frame.height
        let right = pet.maxX + 8
        let x = right + width <= screen.maxX ? right : max(screen.minX, pet.minX - width - 8)
        let y = min(max(pet.midY - height / 2, screen.minY), screen.maxY - height)
        notePanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func setupEditingMenu() {
        // Accessory apps do not receive SwiftUI's standard app menu. Keep the
        // native responder-chain shortcuts available to selectable text/editors.
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let aboutItem = applicationMenu.addItem(withTitle: "关于桌咪…", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        let updateItem = applicationMenu.addItem(withTitle: "检查更新…", action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = appUpdater
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出桌咪", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let editingItem = NSMenuItem()
        let editingMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
                                      ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                      ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editingMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editingItem.submenu = editingMenu
        menu.addItem(editingItem)
        NSApp.mainMenu = menu
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menuIcon = NSImage(systemSymbolName: "cat", accessibilityDescription: "桌咪")
            ?? NSImage(systemSymbolName: "pawprint", accessibilityDescription: "桌咪")
        menuIcon?.isTemplate = true
        statusItem.button?.image = menuIcon
        statusItem.button?.toolTip = "桌咪"
        let menu = NSMenu()
        addMenuItem("桌咪 \(appUpdater.currentVersion)", action: #selector(showAbout), to: menu)
        menu.addItem(.separator())
        addMenuItem("显示猫咪", action: #selector(showPet), to: menu)
        addMenuItem("打开今日小纸条", action: #selector(openNotes), to: menu)
        let settings = NSMenu(title: "猫咪设置")
        addMenuItem("调整猫咪大小…", action: #selector(openSizeControls), to: settings)
        settings.addItem(.separator())
        addMenuItem("暂停闲逛", action: #selector(toggleRoaming), to: settings)
        addMenuItem("减少动态效果", action: #selector(toggleReducedMotion), to: settings)
        addMenuItem("播放音效", action: #selector(toggleSound), to: settings)
        settings.addItem(.separator())
        let automaticItem = settings.addItem(withTitle: "自动检查更新", action: #selector(AppUpdater.toggleAutomaticChecks(_:)), keyEquivalent: "")
        automaticItem.target = appUpdater
        let settingsItem = NSMenuItem(title: "猫咪设置", action: nil, keyEquivalent: "")
        settingsItem.submenu = settings
        menu.addItem(settingsItem)
        petSettingsMenu = settings
        menu.addItem(.separator())
        let updateItem = menu.addItem(withTitle: "检查更新…", action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = appUpdater
        updateMenuItem = updateItem
        addMenuItem("退出", action: #selector(quit), to: menu)
        statusItem.menu = menu
        let contextMenu = NSMenu()
        addMenuItem("打开今日小纸条", action: #selector(openNotes), to: contextMenu)
        addMenuItem("调整猫咪大小…", action: #selector(openSizeControls), to: contextMenu)
        contextMenu.addItem(.separator())
        addMenuItem("退出", action: #selector(quit), to: contextMenu)
        spriteView.menu = contextMenu
        refreshMenu()
    }

    @objc private func openSizeControls() {
        if sizePanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 144),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "猫咪大小"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces]
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 144))
            let label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: 20, y: 108, width: 240, height: 22)
            label.alignment = .center
            label.font = .systemFont(ofSize: 14, weight: .medium)
            content.addSubview(label)
            let slider = NSSlider(value: Double(petScale) * 100, minValue: 50, maxValue: 200,
                                  target: self, action: #selector(changePetSize(_:)))
            slider.frame = NSRect(x: 20, y: 72, width: 240, height: 24)
            slider.isContinuous = true
            slider.setAccessibilityLabel("猫咪大小")
            content.addSubview(slider)
            let hint = NSTextField(labelWithString: "⌘ + 滚轮 / 双指捏合也可缩放")
            hint.frame = NSRect(x: 10, y: 48, width: 260, height: 16)
            hint.alignment = .center
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            content.addSubview(hint)
            let reset = NSButton(title: "恢复默认大小", target: self, action: #selector(resetPetSize))
            reset.frame = NSRect(x: 80, y: 10, width: 120, height: 28)
            reset.bezelStyle = .rounded
            content.addSubview(reset)
            panel.contentView = content
            panel.center()
            sizePanel = panel
            sizeSlider = slider
            sizeLabel = label
        }
        refreshSizeControls()
        NSApp.activate(ignoringOtherApps: true)
        sizePanel?.makeKeyAndOrderFront(nil)
    }

    @objc private func changePetSize(_ sender: NSSlider) {
        setPetScale(CGFloat(sender.doubleValue / 100))
    }

    @objc private func resetPetSize() { setPetScale(1) }

    private func setPetScale(_ value: CGFloat) {
        petScale = PetLayout.clampedScale(value)
        UserDefaults.standard.set(Double(petScale), forKey: "petScale")
        resizePet(repositionNotes: true)
        refreshSizeControls()
    }

    private func refreshSizeControls() {
        sizeSlider?.doubleValue = Double(petScale) * 100
        sizeLabel?.stringValue = "大小 \(Int((petScale * 100).rounded()))%"
    }

    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func refreshMenu() {
        guard let menu = petSettingsMenu else { return }
        menu.item(withTitle: "暂停闲逛")?.state = UserDefaults.standard.bool(forKey: "pauseRoaming") ? .on : .off
        menu.item(withTitle: "减少动态效果")?.state = UserDefaults.standard.bool(forKey: "reducedMotion") ? .on : .off
        menu.item(withTitle: "播放音效")?.state = UserDefaults.standard.bool(forKey: "soundEnabled") ? .on : .off
        menu.item(withTitle: "自动检查更新")?.state = appUpdater.automaticallyChecks ? .on : .off
        updateMenuItem?.title = appUpdater.menuTitle
        statusItem.button?.title = appUpdater.availableVersion == nil ? "" : "•"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "桌咪 \(appUpdater.currentVersion)" + (appUpdater.availableVersion.map { " · 发现新版 \($0)" } ?? "")
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "桌咪", .applicationVersion: appUpdater.currentVersion, .version: "",
            .credits: NSAttributedString(string: "桌面上的小猫与小纸条。")
        ])
    }

    private func movePetDuringRoam(_ delta: CGFloat) {
        guard !UserDefaults.standard.bool(forKey: "pauseRoaming"), !notePanel.isVisible else { return }
        let frame = petWindow.frame
        guard let visible = petWindow.screen?.visibleFrame else { return }
        let x = min(max(frame.origin.x + delta * petScale, visible.minX), visible.maxX - frame.width)
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
} else if CommandLine.arguments.contains("--check-notes") {
    do {
        try NoteChecks.run()
    } catch {
        fputs("note checks failed: \(error)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.contains("--check-interaction") {
    do {
        try InteractionChecks.run(library: SpriteLibrary())
    } catch {
        fputs("interaction checks failed: \(error)\n", stderr)
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
