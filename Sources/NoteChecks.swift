import Foundation

enum NoteChecks {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "NoteChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tabby-notes-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data.json")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2025, month: 1, day: day, hour: hour,
                                              minute: minute, second: second))!
        }

        let early = TodoItem(title: "范围前", plannedDay: "2025-01-01", createdAt: date(1))
        let carried = TodoItem(title: "跨天完成", plannedDay: "2025-01-02", createdAt: date(2, 9), completedAt: date(4, 23, 59, 59))
        let sameDay = TodoItem(title: "当日完成", plannedDay: "2025-01-04", createdAt: date(4, 10), completedAt: date(4, 12))
        let open = TodoItem(title: "未完成", plannedDay: "2025-01-02", createdAt: date(2, 8))
        let late = TodoItem(title: "范围后", plannedDay: "2025-01-05", createdAt: date(5))
        let saved = SavedData(tasks: [late, carried, early, sameDay, open], notes: [
            "2025-01-01": "开始日期前的便签", "2025-01-03": "只有便签的一天\n第二行", "2025-01-04": "结束日期便签",
            "2025-01-05": "结束日期后的便签", "2024-12-01": " \n "
        ])
        try JSONEncoder().encode(saved).write(to: url)
        let store = PetStore(fileURL: url)
        // Date pickers retain a time component; filtering must still include the
        // whole start/end days, including a completion at 23:59:59 on the end day.
        let days = store.historyDays(from: date(2, 18), through: date(4))
        try require(days.map(\.id) == ["2025-01-04", "2025-01-03", "2025-01-02"], "范围边界、日期倒序或仅便签日期不正确")
        try require(days[0].tasks.map(\.id) == [carried.id, sameDay.id], "跨天完成未归档或同日任务重复")
        try require(days[2].tasks.map(\.id) == [open.id, carried.id], "原日期记录丢失或日内顺序错误")
        try require(days[1].note == saved.notes["2025-01-03"] && days[0].note == saved.notes["2025-01-04"], "便签未完整保留")
        try require(days.reduce(0) { $0 + $1.recordCount } == 6, "记录数量不正确")
        try require(store.historyDays(from: date(4), through: date(4)).first?.tasks.count == 2, "单日筛选丢失记录")
        try require(store.historyDays(from: date(6), through: date(7)).isEmpty, "空范围仍有记录")
        try require(store.historyDays(from: date(4), through: date(2)).isEmpty, "倒置范围未安全处理")

        store.setHistoryEnd(date(2))
        store.setHistoryStart(date(4))
        try require(PetStore.dayKey(store.historyEndDate) == "2025-01-04", "开始日期超过结束日期时未同步结束日期")
        store.setHistoryEnd(date(1))
        try require(PetStore.dayKey(store.historyStartDate) == "2025-01-01", "结束日期早于开始日期时未同步开始日期")
        store.showRecentHistory(days: 7)
        try require(calendar.dateComponents([.day], from: calendar.startOfDay(for: store.historyStartDate),
                                             to: calendar.startOfDay(for: store.historyEndDate)).day == 6,
                    "近七天不是含今天的七个自然日")
        store.showRecentHistory(days: nil)
        try require(PetStore.dayKey(store.historyStartDate) == "2025-01-01", "全部范围未从最早有效记录开始")
        try require(store.tasks == saved.tasks && store.notes == saved.notes, "筛选修改了原始记录")

        // Sparse and long histories should include every record without a day
        // cap. The view renders these groups lazily in its scrolling viewport.
        let many = (1...120).map { offset -> TodoItem in
            let created = calendar.date(byAdding: .day, value: -offset, to: Date())!
            return TodoItem(title: "历史记录 \(offset)", plannedDay: PetStore.dayKey(created), createdAt: created)
        }
        try JSONEncoder().encode(SavedData(tasks: many)).write(to: url)
        let longHistory = PetStore(fileURL: url)
        longHistory.showRecentHistory(days: nil)
        try require(longHistory.historyDays(from: longHistory.historyStartDate, through: longHistory.historyEndDate).count == 120,
                    "长时间段记录被截断")
        print("note checks passed: inclusive dates, cross-day completion, same-day deduplication, notes, sorting, empty ranges, range correction, presets, unchanged data, 120-day history")
    }
}
