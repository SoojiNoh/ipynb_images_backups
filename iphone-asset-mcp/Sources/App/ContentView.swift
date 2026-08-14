import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase

    @State private var showToken = false
    @State private var showQR = false
    @State private var showFolderPicker = false
    @State private var copiedLabel: String?

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                connectionSection
                domainSection
                filesSection
                settingsSection
                logSection
            }
            .navigationTitle("AssetBridge")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await state.requestAllPermissions() }
                    } label: {
                        Label("권한 요청", systemImage: "hand.raised")
                    }
                }
            }
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    state.addFileRoot(url)
                }
            }
            .sheet(isPresented: $showQR) { QRSheet(payload: state.pairingPayload) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    state.refreshPermissions()
                    state.refreshAddresses()
                }
            }
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(state.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.statusMessage).font(.headline)
                    Text("도구 \(state.toolCount)개 노출 중")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(state.isRunning ? "정지" : "시작") { state.toggleServer() }
                    .buttonStyle(.borderedProminent)
                    .tint(state.isRunning ? .red : .accentColor)
            }
            .padding(.vertical, 4)

            if state.isRunning {
                ForEach(state.addresses, id: \.ip) { interface in
                    LabeledContent(interface.isWiFi ? "Wi-Fi" : interface.name) {
                        Text("\(interface.ip):\(state.port)").font(.system(.footnote, design: .monospaced))
                    }
                }
            }
        } header: {
            Text("서버")
        } footer: {
            Text("서버는 앱이 화면에 떠 있는 동안만 확실히 동작합니다. 잠금 화면에서도 유지하려면 아래 '백그라운드 유지'를 켜세요.")
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            LabeledContent("엔드포인트") {
                Text(state.endpointURL)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            HStack {
                Text("토큰")
                Spacer()
                Text(showToken ? state.token : String(repeating: "•", count: 16))
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button {
                    showToken.toggle()
                } label: {
                    Image(systemName: showToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            copyRow("Claude Code 명령 복사", value: state.claudeCodeCommand, symbol: "terminal")
            copyRow("설정 JSON 복사", value: state.mcpJSONConfig, symbol: "curlybraces")
            copyRow("토큰만 복사", value: state.token, symbol: "key")

            Button {
                showQR = true
            } label: {
                Label("QR 코드로 보기", systemImage: "qrcode")
            }

            Button(role: .destructive) {
                state.rotateToken()
            } label: {
                Label("토큰 재발급", systemImage: "arrow.triangle.2.circlepath")
            }
        } header: {
            Text("연결")
        } footer: {
            if let copiedLabel {
                Text("복사됨: \(copiedLabel)").foregroundStyle(.green)
            } else {
                Text("Mac 터미널에 명령을 붙여넣으면 Claude Code 가 이 iPhone 에 연결됩니다. 같은 Wi-Fi 여야 합니다.")
            }
        }
    }

    private func copyRow(_ title: String, value: String, symbol: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copiedLabel = title
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if copiedLabel == title { copiedLabel = nil }
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    // MARK: - Domains

    private var domainSection: some View {
        Section {
            ForEach(ToolDomain.allCases) { domain in
                HStack {
                    Image(systemName: domain.symbol)
                        .frame(width: 26)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(domain.title)
                        Text(state.permissionSummary[domain] ?? "확인 중")
                            .font(.caption2)
                            .foregroundStyle(statusColor(state.permissionSummary[domain]))
                    }
                    Spacer()
                    Toggle("", isOn: binding(for: domain)).labelsHidden()
                }
                .contentShape(Rectangle())
                .onTapGesture { Task { await state.requestPermission(for: domain) } }
            }
        } header: {
            Text("노출할 데이터")
        } footer: {
            Text("행을 탭하면 해당 권한을 요청합니다. 끈 도메인의 도구는 Claude 에게 아예 보이지 않습니다.")
        }
    }

    private func binding(for domain: ToolDomain) -> Binding<Bool> {
        Binding(
            get: { state.enabledDomains.contains(domain.rawValue) },
            set: { isOn in
                var updated = state.enabledDomains
                if isOn { updated.insert(domain.rawValue) } else { updated.remove(domain.rawValue) }
                state.enabledDomains = updated
            }
        )
    }

    private func statusColor(_ summary: String?) -> Color {
        switch summary {
        case "허용됨", "항상 허용", "앱 사용 중 허용": return .green
        case "거부됨", "제한됨": return .red
        case .some(let text) where text.contains("만"): return .orange
        default: return .secondary
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        Section {
            Button {
                showFolderPicker = true
            } label: {
                Label("폴더 추가", systemImage: "folder.badge.plus")
            }

            ForEach(state.fileRoots, id: \.self) { name in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(name)
                    Spacer()
                    Button(role: .destructive) {
                        state.removeFileRoot(name)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("파일 접근")
        } footer: {
            Text("iOS 샌드박스 때문에 앱 자신의 폴더와 여기서 직접 고른 폴더만 읽고 쓸 수 있습니다.")
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Section("설정") {
            Stepper(value: $state.port, in: 1024...65535, step: 1) {
                LabeledContent("포트") { Text("\(state.port)").monospaced() }
            }
            .disabled(state.isRunning)

            Toggle("쓰기 도구 허용", isOn: $state.allowWrites)
            Toggle("사설망에서만 접속 허용", isOn: $state.lanOnly)
            Toggle("화면 꺼짐 방지", isOn: $state.keepAwake)
            Toggle("백그라운드 유지 (무음 오디오)", isOn: $state.backgroundAudio)
        }
    }

    // MARK: - Log

    private var logSection: some View {
        Section {
            if state.logs.isEmpty {
                Text("아직 요청이 없습니다.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            } else {
                ForEach(state.logs.prefix(40)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.caption)
                            .foregroundStyle(color(for: entry.level))
                    }
                }
            }
        } header: {
            HStack {
                Text("활동 로그")
                Spacer()
                if !state.logs.isEmpty {
                    Button("지우기") { state.clearLogs() }.font(.caption)
                }
            }
        }
    }

    private func color(for level: MCPServer.LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}

// MARK: - QR

private struct QRSheet: View {

    let payload: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = Self.qrImage(from: payload) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .padding()
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    Text("QR 코드를 만들지 못했습니다.")
                }
                Text("접속 주소와 토큰이 들어 있습니다. 신뢰하는 기기에서만 스캔하세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .navigationTitle("연결 정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }

    private static func qrImage(from text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
