import EventKit
import Foundation

/// 캘린더와 미리 알림은 같은 EKEventStore 를 쓰지만 권한이 분리되어 있어
/// 프로바이더(=도메인 스위치)도 따로 둔다.
enum EventKitAccess {

    static let store = EKEventStore()

    static func ensureAuthorized(_ entity: EKEntityType, needsRead: Bool = true) throws {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .notDetermined:
            throw ToolError("\(label(entity)) 권한이 아직 요청되지 않았습니다. iPhone 에서 AssetBridge 앱을 열어 허용하세요.")
        case .denied, .restricted:
            throw ToolError("\(label(entity)) 접근이 거부되어 있습니다. 설정 > 개인정보 보호에서 허용하세요.")
        case .writeOnly where needsRead:
            throw ToolError("\(label(entity)) 이 쓰기 전용으로 허용되어 있어 읽을 수 없습니다. 전체 접근을 허용하세요.")
        default:
            return
        }
    }

    private static func label(_ entity: EKEntityType) -> String {
        entity == .event ? "캘린더" : "미리 알림"
    }

    @discardableResult
    static func requestEvents() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    @discardableResult
    static func requestReminders() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    static func calendars(_ entity: EKEntityType, ids: [String]?) -> [EKCalendar]? {
        let all = store.calendars(for: entity)
        guard let ids, !ids.isEmpty else { return nil }   // nil = 전체
        let filtered = all.filter { ids.contains($0.calendarIdentifier) }
        return filtered.isEmpty ? nil : filtered
    }

    static func describe(_ calendar: EKCalendar) -> [String: Any] {
        [
            "id": calendar.calendarIdentifier,
            "title": calendar.title,
            "source": calendar.source?.title ?? "알 수 없음",
            "editable": calendar.allowsContentModifications
        ]
    }
}

// MARK: - Calendar

final class CalendarProvider: ToolProvider {

    let domain = ToolDomain.calendar

    lazy var tools: [MCPTool] = [
        MCPTool(
            name: "calendar_list_calendars",
            title: "캘린더 목록",
            description: "기기에 등록된 캘린더와 각각의 ID.",
            domain: .calendar
        ),

        MCPTool(
            name: "calendar_list_events",
            title: "일정 조회",
            description: """
            기간 안의 일정을 가져온다. start_date 를 생략하면 오늘 0시, end_date 를 생략하면 7일 뒤까지 본다.
            EventKit 특성상 한 번에 조회할 수 있는 기간은 최대 4년이다.
            """,
            inputSchema: Schema.object([
                "start_date": Schema.date("조회 시작."),
                "end_date": Schema.date("조회 끝."),
                "calendar_ids": Schema.stringArray("특정 캘린더만 볼 때의 ID 목록."),
                "query": Schema.string("제목·장소·메모에 포함된 문자열로 추가 필터."),
                "limit": Schema.integer("최대 개수", minimum: 1, maximum: 500, defaultValue: 100)
            ]),
            domain: .calendar
        ),

        MCPTool(
            name: "calendar_create_event",
            title: "일정 추가",
            description: "새 일정을 만든다. all_day 가 아니면 start 와 end 가 모두 필요하다.",
            inputSchema: Schema.object([
                "title": Schema.string("일정 제목."),
                "start": Schema.date("시작 시각."),
                "end": Schema.date("종료 시각. 생략하면 시작 +1시간."),
                "all_day": Schema.boolean("종일 일정 여부", defaultValue: false),
                "location": Schema.string("장소."),
                "notes": Schema.string("메모."),
                "calendar_id": Schema.string("넣을 캘린더 ID. 생략하면 기본 캘린더.")
            ], required: ["title", "start"]),
            domain: .calendar,
            isWrite: true
        )
    ]

    func call(_ name: String, arguments: [String: Any]) async throws -> ToolOutput {
        switch name {
        case "calendar_list_calendars":
            try EventKitAccess.ensureAuthorized(.event)
            let calendars = EventKitAccess.store.calendars(for: .event)
            return .json(["count": calendars.count, "calendars": calendars.map { EventKitAccess.describe($0) }])

        case "calendar_list_events":
            try EventKitAccess.ensureAuthorized(.event)
            return try listEvents(arguments)

        case "calendar_create_event":
            try EventKitAccess.ensureAuthorized(.event, needsRead: false)
            return try createEvent(arguments)

        default:
            throw ToolError("알 수 없는 도구: \(name)")
        }
    }

    private func listEvents(_ arguments: [String: Any]) throws -> ToolOutput {
        let start = DateParse.date(from: arguments.string("start_date"))
            ?? Calendar.current.startOfDay(for: Date())
        let end = DateParse.endDate(from: arguments.string("end_date"))
            ?? Calendar.current.date(byAdding: .day, value: 7, to: start)
            ?? start.addingTimeInterval(7 * 86_400)

        guard end > start else { throw ToolError("end_date 는 start_date 보다 뒤여야 합니다.") }
        // EventKit 은 4년을 넘는 조회 구간을 조용히 잘라낸다.
        let cappedEnd = min(end, start.addingTimeInterval(4 * 365 * 86_400))

        let calendars = EventKitAccess.calendars(.event, ids: arguments.stringArray("calendar_ids"))
        let predicate = EventKitAccess.store.predicateForEvents(withStart: start, end: cappedEnd, calendars: calendars)
        var events = EventKitAccess.store.events(matching: predicate)

        if let needle = arguments.string("query")?.lowercased(), !needle.isEmpty {
            events = events.filter { event in
                [event.title, event.location, event.notes]
                    .compactMap { $0?.lowercased() }
                    .contains { $0.contains(needle) }
            }
        }

        events.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        let limit = arguments.clampedInt("limit", default: 100, min: 1, max: 500)
        let trimmed = Array(events.prefix(limit))

        return .json([
            "range": ["start": JSONUtil.value(DateParse.iso8601(start)),
                      "end": JSONUtil.value(DateParse.iso8601(cappedEnd))],
            "count": trimmed.count,
            "truncated": events.count > trimmed.count,
            "events": trimmed.map { Self.describe($0) }
        ])
    }

    private func createEvent(_ arguments: [String: Any]) throws -> ToolOutput {
        guard let title = arguments.string("title"), !title.isEmpty else { throw ToolError("title 이 필요합니다.") }
        guard let start = DateParse.date(from: arguments.string("start")) else {
            throw ToolError("start 를 해석하지 못했습니다. ISO 8601 또는 YYYY-MM-DD HH:mm 형식을 쓰세요.")
        }

        let event = EKEvent(eventStore: EventKitAccess.store)
        event.title = title
        event.startDate = start
        event.isAllDay = arguments.bool("all_day") ?? false
        event.endDate = DateParse.date(from: arguments.string("end")) ?? start.addingTimeInterval(3600)
        event.location = arguments.string("location")
        event.notes = arguments.string("notes")

        if let calendarID = arguments.string("calendar_id"),
           let calendar = EventKitAccess.store.calendar(withIdentifier: calendarID) {
            event.calendar = calendar
        } else {
            event.calendar = EventKitAccess.store.defaultCalendarForNewEvents
        }
        guard event.calendar != nil else { throw ToolError("일정을 넣을 캘린더를 찾지 못했습니다.") }

        do {
            try EventKitAccess.store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw ToolError("일정 저장 실패: \(error.localizedDescription)")
        }
        return .json(["ok": true, "event": Self.describe(event)])
    }

    private static func describe(_ event: EKEvent) -> [String: Any] {
        var payload: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "(제목 없음)",
            "start": JSONUtil.value(DateParse.iso8601(event.startDate)),
            "end": JSONUtil.value(DateParse.iso8601(event.endDate)),
            "all_day": event.isAllDay,
            "calendar": event.calendar?.title ?? ""
        ]
        if let location = event.location, !location.isEmpty { payload["location"] = location }
        if let notes = event.notes, !notes.isEmpty { payload["notes"] = notes }
        if event.hasAttendees, let attendees = event.attendees {
            payload["attendees"] = attendees.compactMap { $0.name }
        }
        if let url = event.url { payload["url"] = url.absoluteString }
        return payload
    }
}

// MARK: - Reminders

final class RemindersProvider: ToolProvider {

    let domain = ToolDomain.reminders

    lazy var tools: [MCPTool] = [
        MCPTool(
            name: "reminders_list",
            title: "미리 알림 조회",
            description: "미리 알림을 가져온다. 기본값은 미완료 항목만.",
            inputSchema: Schema.object([
                "include_completed": Schema.boolean("완료된 항목도 포함", defaultValue: false),
                "due_before": Schema.date("이 시각 이전 마감인 것만."),
                "due_after": Schema.date("이 시각 이후 마감인 것만."),
                "list_ids": Schema.stringArray("특정 목록만 볼 때의 ID."),
                "limit": Schema.integer("최대 개수", minimum: 1, maximum: 500, defaultValue: 100)
            ]),
            domain: .reminders
        ),

        MCPTool(
            name: "reminders_create",
            title: "미리 알림 추가",
            description: "새 미리 알림을 만든다.",
            inputSchema: Schema.object([
                "title": Schema.string("할 일 제목."),
                "due": Schema.date("마감 시각(선택)."),
                "notes": Schema.string("메모."),
                "priority": Schema.integer("우선순위 0(없음)~9(낮음). 1이 가장 높음.", minimum: 0, maximum: 9, defaultValue: 0),
                "list_id": Schema.string("넣을 목록 ID. 생략하면 기본 목록.")
            ], required: ["title"]),
            domain: .reminders,
            isWrite: true
        )
    ]

    func call(_ name: String, arguments: [String: Any]) async throws -> ToolOutput {
        try EventKitAccess.ensureAuthorized(.reminder)

        switch name {
        case "reminders_list": return try await list(arguments)
        case "reminders_create": return try create(arguments)
        default: throw ToolError("알 수 없는 도구: \(name)")
        }
    }

    private func list(_ arguments: [String: Any]) async throws -> ToolOutput {
        let calendars = EventKitAccess.calendars(.reminder, ids: arguments.stringArray("list_ids"))
        let includeCompleted = arguments.bool("include_completed") ?? false

        let predicate = includeCompleted
            ? EventKitAccess.store.predicateForReminders(in: calendars)
            : EventKitAccess.store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                                   ending: nil,
                                                                   calendars: calendars)

        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            EventKitAccess.store.fetchReminders(matching: predicate) { result in
                continuation.resume(returning: result ?? [])
            }
        }

        let dueBefore = DateParse.endDate(from: arguments.string("due_before"))
        let dueAfter = DateParse.date(from: arguments.string("due_after"))

        var filtered = reminders.filter { reminder in
            guard dueBefore != nil || dueAfter != nil else { return true }
            guard let due = reminder.dueDateComponents?.date else { return false }
            if let dueBefore, due > dueBefore { return false }
            if let dueAfter, due < dueAfter { return false }
            return true
        }

        filtered.sort { lhs, rhs in
            let left = lhs.dueDateComponents?.date ?? .distantFuture
            let right = rhs.dueDateComponents?.date ?? .distantFuture
            return left < right
        }

        let limit = arguments.clampedInt("limit", default: 100, min: 1, max: 500)
        let trimmed = Array(filtered.prefix(limit))

        return .json([
            "count": trimmed.count,
            "truncated": filtered.count > trimmed.count,
            "reminders": trimmed.map { Self.describe($0) }
        ])
    }

    private func create(_ arguments: [String: Any]) throws -> ToolOutput {
        guard let title = arguments.string("title"), !title.isEmpty else { throw ToolError("title 이 필요합니다.") }

        let reminder = EKReminder(eventStore: EventKitAccess.store)
        reminder.title = title
        reminder.notes = arguments.string("notes")
        reminder.priority = arguments.clampedInt("priority", default: 0, min: 0, max: 9)

        if let due = DateParse.date(from: arguments.string("due")) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
        }

        if let listID = arguments.string("list_id"),
           let calendar = EventKitAccess.store.calendar(withIdentifier: listID) {
            reminder.calendar = calendar
        } else {
            reminder.calendar = EventKitAccess.store.defaultCalendarForNewReminders()
        }
        guard reminder.calendar != nil else { throw ToolError("미리 알림을 넣을 목록을 찾지 못했습니다.") }

        do {
            try EventKitAccess.store.save(reminder, commit: true)
        } catch {
            throw ToolError("미리 알림 저장 실패: \(error.localizedDescription)")
        }
        return .json(["ok": true, "reminder": Self.describe(reminder)])
    }

    private static func describe(_ reminder: EKReminder) -> [String: Any] {
        var payload: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "(제목 없음)",
            "completed": reminder.isCompleted,
            "list": reminder.calendar?.title ?? ""
        ]
        if let due = reminder.dueDateComponents?.date {
            payload["due"] = JSONUtil.value(DateParse.iso8601(due))
        }
        if reminder.priority != 0 { payload["priority"] = reminder.priority }
        if let notes = reminder.notes, !notes.isEmpty { payload["notes"] = notes }
        if let completedAt = reminder.completionDate {
            payload["completed_at"] = JSONUtil.value(DateParse.iso8601(completedAt))
        }
        return payload
    }
}
