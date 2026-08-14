import Contacts
import Foundation

final class ContactsProvider: ToolProvider {

    let domain = ToolDomain.contacts
    private let store = CNContactStore()

    private static let keys: [CNKeyDescriptor] = [
        CNContactIdentifierKey,
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactMiddleNameKey,
        CNContactNicknameKey,
        CNContactOrganizationNameKey,
        CNContactJobTitleKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey,
        CNContactPostalAddressesKey,
        CNContactUrlAddressesKey,
        CNContactBirthdayKey
    ].map { $0 as CNKeyDescriptor }

    lazy var tools: [MCPTool] = [
        MCPTool(
            name: "contacts_search",
            title: "연락처 검색",
            description: """
            이름·전화번호·이메일로 연락처를 찾는다. query 를 비우면 전체를 이름순으로 훑는다.
            개인정보이므로 필요한 항목만 사용자에게 보여주고 전체를 나열하지 마라.
            """,
            inputSchema: Schema.object([
                "query": Schema.string("이름 일부, 전화번호, 또는 이메일 주소."),
                "limit": Schema.integer("최대 개수", minimum: 1, maximum: 200, defaultValue: 25)
            ]),
            domain: .contacts
        ),

        MCPTool(
            name: "contacts_get",
            title: "연락처 상세",
            description: "식별자로 연락처 한 건의 모든 필드를 가져온다.",
            inputSchema: Schema.object([
                "contact_id": Schema.string("contacts_search 가 돌려준 식별자.")
            ], required: ["contact_id"]),
            domain: .contacts
        ),

        MCPTool(
            name: "contacts_create",
            title: "연락처 추가",
            description: "새 연락처를 만든다.",
            inputSchema: Schema.object([
                "given_name": Schema.string("이름."),
                "family_name": Schema.string("성."),
                "organization": Schema.string("소속."),
                "phone": Schema.string("전화번호."),
                "email": Schema.string("이메일 주소.")
            ]),
            domain: .contacts,
            isWrite: true
        )
    ]

    // MARK: - Authorization

    private func ensureAuthorized() throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            throw ToolError("연락처 권한이 아직 요청되지 않았습니다. iPhone 에서 AssetBridge 앱을 열어 허용하세요.")
        case .denied, .restricted:
            throw ToolError("연락처 접근이 거부되어 있습니다. 설정 > 개인정보 보호 > 연락처에서 허용하세요.")
        default:
            // .authorized 및 iOS 18 의 .limited 를 포함한다.
            return
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in continuation.resume(returning: granted) }
        }
    }

    // MARK: - Dispatch

    func call(_ name: String, arguments: [String: Any]) async throws -> ToolOutput {
        try ensureAuthorized()

        switch name {
        case "contacts_search": return try search(arguments)
        case "contacts_get": return try get(arguments)
        case "contacts_create": return try create(arguments)
        default: throw ToolError("알 수 없는 도구: \(name)")
        }
    }

    // MARK: - Tools

    private func search(_ arguments: [String: Any]) throws -> ToolOutput {
        let limit = arguments.clampedInt("limit", default: 25, min: 1, max: 200)
        let rawQuery = arguments.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines)

        var matches: [CNContact] = []

        if let rawQuery, !rawQuery.isEmpty {
            var predicates: [NSPredicate] = [CNContact.predicateForContacts(matchingName: rawQuery)]
            if rawQuery.contains("@") {
                predicates.append(CNContact.predicateForContacts(matchingEmailAddress: rawQuery))
            }
            let digits = rawQuery.filter { $0.isNumber || $0 == "+" }
            if digits.count >= 4 {
                predicates.append(CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: digits)))
            }

            var seen = Set<String>()
            for predicate in predicates {
                let found = (try? store.unifiedContacts(matching: predicate, keysToFetch: Self.keys)) ?? []
                for contact in found where !seen.contains(contact.identifier) {
                    seen.insert(contact.identifier)
                    matches.append(contact)
                }
                if matches.count >= limit { break }
            }
        } else {
            let request = CNContactFetchRequest(keysToFetch: Self.keys)
            request.sortOrder = .givenName
            try store.enumerateContacts(with: request) { contact, stop in
                matches.append(contact)
                if matches.count >= limit { stop.pointee = true }
            }
        }

        let trimmed = Array(matches.prefix(limit))
        return .json([
            "count": trimmed.count,
            "truncated": matches.count >= limit,
            "contacts": trimmed.map { Self.summary($0) }
        ])
    }

    private func get(_ arguments: [String: Any]) throws -> ToolOutput {
        guard let identifier = arguments.string("contact_id") else { throw ToolError("contact_id 가 필요합니다.") }
        let predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
        guard let contact = (try? store.unifiedContacts(matching: predicate, keysToFetch: Self.keys))?.first else {
            throw ToolError("연락처를 찾을 수 없습니다: \(identifier)")
        }
        return .json(Self.details(contact))
    }

    private func create(_ arguments: [String: Any]) throws -> ToolOutput {
        let contact = CNMutableContact()
        contact.givenName = arguments.string("given_name") ?? ""
        contact.familyName = arguments.string("family_name") ?? ""
        contact.organizationName = arguments.string("organization") ?? ""

        guard !(contact.givenName.isEmpty && contact.familyName.isEmpty && contact.organizationName.isEmpty) else {
            throw ToolError("given_name, family_name, organization 중 최소 하나는 필요합니다.")
        }

        if let phone = arguments.string("phone"), !phone.isEmpty {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile,
                                                   value: CNPhoneNumber(stringValue: phone))]
        }
        if let email = arguments.string("email"), !email.isEmpty {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        }

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
        } catch {
            throw ToolError("연락처 저장 실패: \(error.localizedDescription)")
        }

        return .json(["ok": true, "contact_id": contact.identifier])
    }

    // MARK: - Serialization

    private static func summary(_ contact: CNContact) -> [String: Any] {
        var payload: [String: Any] = ["id": contact.identifier]

        let name = CNContactFormatter.string(from: contact, style: .fullName)
            ?? [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        payload["name"] = name.isEmpty ? contact.organizationName : name

        if !contact.organizationName.isEmpty { payload["organization"] = contact.organizationName }
        if !contact.phoneNumbers.isEmpty {
            payload["phones"] = contact.phoneNumbers.map { $0.value.stringValue }
        }
        if !contact.emailAddresses.isEmpty {
            payload["emails"] = contact.emailAddresses.map { $0.value as String }
        }
        return payload
    }

    private static func details(_ contact: CNContact) -> [String: Any] {
        var payload = summary(contact)
        if !contact.nickname.isEmpty { payload["nickname"] = contact.nickname }
        if !contact.jobTitle.isEmpty { payload["job_title"] = contact.jobTitle }

        if !contact.postalAddresses.isEmpty {
            payload["addresses"] = contact.postalAddresses.map { entry -> [String: Any] in
                [
                    "label": entry.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "",
                    "value": CNPostalAddressFormatter.string(from: entry.value, style: .mailingAddress)
                ]
            }
        }
        if !contact.urlAddresses.isEmpty {
            payload["urls"] = contact.urlAddresses.map { $0.value as String }
        }
        if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
            payload["birthday"] = birthday.year.map { String(format: "%04d-%02d-%02d", $0, month, day) }
                ?? String(format: "--%02d-%02d", month, day)
        }
        return payload
    }
}
