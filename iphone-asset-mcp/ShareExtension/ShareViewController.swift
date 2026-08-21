import UIKit
import UniformTypeIdentifiers

/// 공유 시트에서 받은 항목을 AssetBridge 앱에 넘긴다.
///
/// 무료 Apple 계정은 App Group 을 쓸 수 없다. 익스텐션과 앱이 컨테이너를 공유할
/// 방법이 없다는 뜻이라, 파일로 주고받는 흔한 방식은 여기서 성립하지 않는다.
/// 대신 앱이 이미 열어 둔 로컬 서버로 보낸다 — 127.0.0.1 이므로 기기 밖으로
/// 나가지 않고, 로컬 네트워크 권한도 필요 없다.
///
/// 대가는 하나다. 앱이 살아 있어야 한다. '백그라운드 유지'가 켜져 있으면 대개
/// 살아 있고, 아니면 사용자에게 앱을 한 번 열라고 말해 준다.
final class ShareViewController: UIViewController {

    /// 앱이 어느 포트를 쓰는지 알아낼 방법이 없다(컨테이너 공유 불가).
    /// 기본값을 먼저 보고, 사용자가 스테퍼로 옮겼을 만한 범위를 조금 더 훑는다.
    private static let candidatePorts = Array(8765...8775)

    /// 사용자가 적는 지시. 이게 없으면 받는 쪽은 이 항목으로 무엇을 해야 하는지
    /// 알 수 없다 — 요약인지, 캘린더에 넣으라는 건지, 그냥 보관인지.
    private let noteField = UITextField()
    private let preview = UILabel()
    private let status = UILabel()
    private let sendButton = UIButton(type: .system)

    private var payloads: [Payload] = []

    private static let presets = ["요약해줘", "캘린더에 넣어줘", "할 일로 추가해줘", "번역해줘"]

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        Task {
            payloads = await collect()
            showPreview()
        }
    }

    private func buildUI() {
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "AssetBridge 로 보내기"
        title.font = .preferredFont(forTextStyle: .headline)

        preview.font = .preferredFont(forTextStyle: .footnote)
        preview.textColor = .secondaryLabel
        preview.numberOfLines = 3
        preview.text = "내용을 읽는 중…"

        noteField.placeholder = "무엇을 해드릴까요? (비워도 됩니다)"
        noteField.borderStyle = .roundedRect
        noteField.font = .preferredFont(forTextStyle: .body)
        noteField.returnKeyType = .send
        noteField.delegate = self
        noteField.clearButtonMode = .whileEditing

        // 자주 쓰는 것은 눌러서 채우고, 그대로 두거나 고쳐 쓸 수 있게 한다.
        let chips = UIStackView()
        chips.axis = .horizontal
        chips.spacing = 8
        chips.distribution = .fillProportionally
        for (index, preset) in Self.presets.enumerated() {
            let chip = UIButton(type: .system)
            chip.setTitle(preset, for: .normal)
            chip.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
            chip.titleLabel?.adjustsFontSizeToFitWidth = true
            chip.backgroundColor = .secondarySystemBackground
            chip.layer.cornerRadius = 8
            chip.tag = index
            chip.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            chips.addArrangedSubview(chip)
        }

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("취소", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        sendButton.setTitle("보내기", for: .normal)
        sendButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.isEnabled = false

        let buttons = UIStackView(arrangedSubviews: [cancelButton, UIView(), sendButton])
        buttons.axis = .horizontal

        status.font = .preferredFont(forTextStyle: .footnote)
        status.textAlignment = .center
        status.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, preview, chips, noteField, buttons, status])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            chips.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    private func showPreview() {
        guard !payloads.isEmpty else {
            preview.text = "보낼 수 있는 내용이 없습니다."
            preview.textColor = .systemRed
            return
        }

        let first = payloads[0]
        let body = first.text ?? first.name ?? first.kind
        let extra = payloads.count > 1 ? "  · 외 \(payloads.count - 1)개" : ""
        preview.text = body.trimmingCharacters(in: .whitespacesAndNewlines) + extra
        sendButton.isEnabled = true
    }

    @objc private func chipTapped(_ sender: UIButton) {
        guard Self.presets.indices.contains(sender.tag) else { return }
        noteField.text = Self.presets[sender.tag]
    }

    @objc private func cancelTapped() {
        extensionContext?.cancelRequest(withError: NSError(domain: "AssetBridge", code: 0))
    }

    @objc private func sendTapped() {
        guard sendButton.isEnabled else { return }
        sendButton.isEnabled = false
        noteField.resignFirstResponder()
        Task { await run(note: noteField.text ?? "") }
    }

    // MARK: - 흐름

    private func run(note: String) async {
        guard !payloads.isEmpty else {
            await finish("보낼 수 있는 내용이 없습니다.", success: false)
            return
        }

        status.text = "보내는 중…"
        status.textColor = .secondaryLabel

        guard let port = await findPort() else {
            await finish("AssetBridge 가 응답하지 않습니다.\n앱을 한 번 열어 두고 다시 공유해 주세요.",
                         success: false)
            return
        }

        var sent = 0
        var lastFailure = ""

        for payload in payloads {
            let result = await post(payload, port: port, note: note)
            if result.ok {
                sent += 1
            } else {
                lastFailure = result.detail
            }
        }

        if sent == payloads.count {
            await finish("보냈습니다 · \(sent)개", success: true)
        } else if sent > 0 {
            await finish("일부만 보냈습니다 · \(sent)/\(payloads.count)\n\(lastFailure)", success: false)
        } else {
            // 이유를 같이 보여 준다. "보내지 못했습니다" 한 줄로는 앱을 열어
            // 로그를 뒤지기 전까지 아무것도 알 수 없다.
            await finish("보내지 못했습니다.\n\(lastFailure)", success: false)
        }
    }

    @MainActor
    private func finish(_ message: String, success: Bool) async {
        status.text = message
        status.textColor = success ? .systemGreen : .systemRed
        if !success { sendButton.isEnabled = true }

        // 성공은 빨리 사라지는 편이 낫고, 실패는 읽을 시간이 필요하다.
        guard success else { return }
        try? await Task.sleep(nanoseconds: 700_000_000)
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - 입력 수집

    private struct Payload {
        let kind: String
        var text: String?
        var name: String?
        var mimeType: String?
        var data: Data?
    }

    private func collect() async -> [Payload] {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var payloads: [Payload] = []

        for item in items {
            // 공유 시트에 사용자가 덧붙인 메모. 본문과 별개로 온다.
            if let text = item.attributedContentText?.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                payloads.append(Payload(kind: "text", text: text))
            }

            for provider in item.attachments ?? [] {
                if let payload = await load(from: provider) {
                    payloads.append(payload)
                }
            }
        }

        // 같은 내용이 텍스트로도 첨부로도 오는 경우가 있다. 중복은 한 번만 보낸다.
        var seen = Set<String>()
        return payloads.filter { payload in
            let key = payload.text ?? payload.name ?? "\(payload.kind):\(payload.data?.count ?? 0)"
            return seen.insert(key).inserted
        }
    }

    private func load(from provider: NSItemProvider) async -> Payload? {
        // 이미지가 먼저다. 이미지에는 URL 표현도 같이 딸려 오는 경우가 많은데,
        // 그때 URL 쪽을 집으면 정작 그림을 잃는다.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let data = await loadData(provider, type: UTType.image.identifier) {
                return Payload(kind: "image",
                               name: provider.suggestedName ?? "image",
                               mimeType: "image/jpeg",
                               data: data)
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let value = await loadItem(provider, type: UTType.url.identifier) {
                if let url = value as? URL, !url.isFileURL {
                    return Payload(kind: "url", text: url.absoluteString)
                }
                if let url = value as? URL, url.isFileURL,
                   let data = try? Data(contentsOf: url) {
                    return Payload(kind: "file",
                                   name: url.lastPathComponent,
                                   mimeType: "application/octet-stream",
                                   data: data)
                }
            }
        }

        for type in [UTType.plainText.identifier, UTType.text.identifier] {
            guard provider.hasItemConformingToTypeIdentifier(type) else { continue }
            if let value = await loadItem(provider, type: type) {
                if let text = value as? String { return Payload(kind: "text", text: text) }
                if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
                    return Payload(kind: "text", text: text)
                }
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            if let data = await loadData(provider, type: UTType.data.identifier) {
                return Payload(kind: "file",
                               name: provider.suggestedName ?? "file",
                               mimeType: "application/octet-stream",
                               data: data)
            }
        }

        return nil
    }

    private func loadItem(_ provider: NSItemProvider, type: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    private func loadData(_ provider: NSItemProvider, type: String) async -> Data? {
        let value = await loadItem(provider, type: type)
        if let data = value as? Data { return data }
        if let url = value as? URL { return try? Data(contentsOf: url) }
        if let image = value as? UIImage { return image.jpegData(compressionQuality: 0.9) }
        return nil
    }

    // MARK: - 전송

    private func findPort() async -> Int? {
        for port in Self.candidatePorts where await isAlive(port) {
            return port
        }
        return nil
    }

    private func isAlive(_ port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// 성공 여부와, 실패했을 때 사람이 읽을 수 있는 이유.
    private struct PostResult {
        let ok: Bool
        let detail: String
    }

    private func post(_ payload: Payload, port: Int, note: String) async -> PostResult {
        guard let url = URL(string: "http://127.0.0.1:\(port)/share") else {
            return PostResult(ok: false, detail: "주소를 만들지 못했습니다.")
        }

        var body: [String: Any] = ["kind": payload.kind]
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["note"] = trimmed }
        if let text = payload.text { body["text"] = text }
        if let name = payload.name { body["name"] = name }
        if let mimeType = payload.mimeType { body["mimeType"] = mimeType }
        if let data = payload.data { body["data"] = data.base64EncodedString() }

        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else {
            return PostResult(ok: false, detail: "내용을 JSON 으로 만들지 못했습니다.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return PostResult(ok: false, detail: error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 { return PostResult(ok: true, detail: "") }

        // 서버가 이유를 본문에 담아 준다. 상태 코드만 보여 주면 또 추측하게 된다.
        var reason = ""
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            reason = (object["error"] as? [String: Any])?["message"] as? String
                ?? object["message"] as? String ?? ""
        }
        if reason.isEmpty { reason = String(data: data.prefix(120), encoding: .utf8) ?? "" }

        return PostResult(ok: false, detail: "HTTP \(status)\(reason.isEmpty ? "" : " · \(reason)")")
    }
}

// 키보드 리턴으로도 보낼 수 있게 한다. 보내기 버튼까지 손을 옮길 이유가 없다.
extension ShareViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendTapped()
        return true
    }
}
