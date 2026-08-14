# AssetBridge — iPhone 을 MCP 서버로

iPhone 자체가 **MCP 서버**가 되어, Mac 의 Claude Code / Claude Desktop 이 기기에 저장된
사진·연락처·캘린더·위치·파일 등에 도구(tool) 호출로 직접 접근하게 해주는 iOS 앱입니다.

클라우드 동기화도, 중계 서버도 없습니다. 데이터는 iPhone 을 떠나지 않고 같은 Wi-Fi 안에서만 오갑니다.

```
┌──────────────────────┐        같은 Wi-Fi          ┌────────────────────────────┐
│  Mac                 │  HTTP + Bearer 토큰        │  iPhone (AssetBridge 앱)   │
│  ├ Claude Code       │ ─────────────────────────▶ │  ├ HTTP 서버 :8765         │
│  └ Claude Desktop    │   POST /mcp (JSON-RPC)     │  ├ MCP 디스패처            │
└──────────────────────┘ ◀───────────────────────── │  └ 10개 도메인 프로바이더  │
                            도구 결과 / 이미지       │     PhotoKit, Contacts,    │
                                                     │     EventKit, CoreLocation │
                                                     └────────────────────────────┘
```

---

## 노출되는 도구 (32개)

앱에서 도메인 단위로 켜고 끌 수 있고, `*` 표시된 쓰기 도구는 "쓰기 도구 허용" 스위치가 켜져 있을 때만
Claude 에게 보입니다. 꺼진 도구는 `tools/list` 에 아예 나타나지 않습니다.

### 사진 · 동영상 (12)
| 도구 | 하는 일 |
|---|---|
| `photos_search` | 앨범·기간·종류·즐겨찾기·GPS 유무로 검색. 메타데이터만 반환해 저렴함 |
| `photos_contact_sheet` | 여러 장을 **번호 붙은 격자 이미지 한 장**으로 합쳐 반환 (훑어보기용) |
| `photos_view` | 사진 최대 6장을 이미지로 반환 (크기·품질 지정) |
| `photos_read_text` | 기기 내장 Vision OCR 로 사진 속 글자 추출 (한국어 지원) |
| `photos_video_frame` | 동영상의 특정 시점 프레임 추출 |
| `photos_get_details` | 해상도, 촬영 시각, GPS, 원본 파일명 등 전체 메타데이터 |
| `photos_list_albums` | 사용자 앨범 + 스마트 앨범(스크린샷·셀피·즐겨찾기 등) 목록 |
| `photos_stats` | 라이브러리 규모 요약 (종류별 개수, 최초/최근 날짜) |
| `photos_export` | 원본 또는 축소 JPEG 을 파일로 내보내고 인증된 다운로드 URL 반환 |
| `photos_set_favorite` * | 즐겨찾기 토글 |
| `photos_create_album` * | 새 앨범 생성 |
| `photos_add_to_album` * | 기존 앨범에 사진 추가 |

### 나머지 도메인 (20)
| 도메인 | 도구 |
|---|---|
| 연락처 | `contacts_search`, `contacts_get`, `contacts_create` * |
| 캘린더 | `calendar_list_calendars`, `calendar_list_events`, `calendar_create_event` * |
| 미리 알림 | `reminders_list`, `reminders_create` * |
| 위치 | `location_current` (역지오코딩 포함) |
| 기기 정보 | `device_info` (배터리·저장공간·발열·네트워크·메모리) |
| 걸음 · 활동 | `motion_activity` (걸음 수·거리·층수, 일별 집계 가능) |
| 클립보드 | `clipboard_read`, `clipboard_write` * |
| 음악 보관함 | `music_search_library`, `music_playlists`, `music_now_playing` |
| 파일 | `files_list_roots`, `files_list`, `files_read`, `files_write` * |

### 컨텍스트 절약 설계
사진을 다루는 MCP 서버의 실패 지점은 대부분 "이미지를 너무 많이, 너무 크게 보내는 것"입니다.
그래서 이렇게 설계했습니다.

- `photos_search` 는 **이미지를 반환하지 않습니다.** 후보를 먼저 좁히게 만듭니다.
- 여러 장을 훑어야 할 땐 `photos_contact_sheet` 한 번으로 최대 30장을 격자 한 장에 담습니다.
  응답 텍스트에 `번호 → asset_id` 대응표가 들어 있어, Claude 가 원하는 것만 골라 확대할 수 있습니다.
- 개별 이미지는 base64 크기가 상한(약 900KB)을 넘지 않도록 품질을 자동으로 낮추고,
  그래도 크면 해상도를 단계적으로 줄입니다.
- 스크린샷의 글자만 필요하면 `photos_read_text` 가 이미지 전송 없이 텍스트만 돌려줍니다.
- `initialize` 응답의 `instructions` 필드로 이 사용 순서를 Claude 에게 직접 알려줍니다.

---

## 빌드

Mac + **Xcode 15 이상**, iOS 17 이상 기기가 필요합니다.
(시뮬레이터에서도 뜨지만 사진·센서 데이터가 비어 있습니다.)

```bash
brew install xcodegen          # 처음 한 번만
cd iphone-asset-mcp
xcodegen generate              # AssetBridge.xcodeproj 생성
open AssetBridge.xcodeproj
```

> **"future Xcode project file format" 오류가 나면**
> XcodeGen 이 설치된 Xcode 보다 새 포맷으로 프로젝트를 만든 경우입니다.
> `project.yml` 의 `options.projectFormat` 이 이를 막아주는데, 그 줄이 추가되기 전에
> 생성한 프로젝트가 남아 있으면 그대로 실패합니다. 지우고 다시 만드세요.
>
> ```bash
> rm -rf AssetBridge.xcodeproj && xcodegen generate
> ```
>
> XcodeGen 이 `projectFormat` 을 모른다고 하면 (2.43 미만) `brew upgrade xcodegen` 하거나,
> 생성된 파일의 포맷 버전을 직접 낮추세요.
>
> ```bash
> sed -i '' 's/objectVersion = [0-9]*;/objectVersion = 56;/' \
>   AssetBridge.xcodeproj/project.pbxproj
> ```

Xcode 에서:
1. `AssetBridge` 타겟 → **Signing & Capabilities** → 본인 팀 선택
2. `PRODUCT_BUNDLE_IDENTIFIER` 를 고유한 값으로 변경 (예: `com.내이름.assetbridge`)
3. iPhone 을 연결하고 실행

> 무료 Apple ID 로도 사이드로드할 수 있지만 프로비저닝 프로파일이 7일마다 만료되어 재설치해야 합니다.

XcodeGen 없이 하려면 Xcode 에서 iOS App 프로젝트를 새로 만들고 `Sources/` 를 통째로 끌어다 넣은 뒤,
`project.yml` 의 `info.properties` 에 적힌 Info.plist 키를 그대로 옮기면 됩니다.

---

## 연결

### 1. iPhone 에서
1. AssetBridge 앱 실행 → 우측 상단 **권한 요청** 을 눌러 필요한 권한을 모두 허용
   (사진 → 연락처 → 캘린더 → 미리 알림 → 위치 → 음악 → 동작 순으로 시트가 뜹니다)
2. 노출하고 싶은 도메인만 켜기
3. **시작** 버튼 → 상태가 "실행 중" 이 되고 `192.168.x.x:8765` 가 표시됨
4. 첫 실행 시 **로컬 네트워크 접근 허용** 프롬프트가 뜹니다. 반드시 허용해야 합니다.

### 2. Mac 에서 (Claude Code)
앱의 **Claude Code 명령 복사** 버튼을 누르면 아래 형태가 클립보드에 담깁니다.

```bash
claude mcp add --transport http iphone http://192.168.0.42:8765/mcp \
  --header "Authorization: Bearer <토큰>"
```

붙여넣고 실행한 뒤 `claude` 를 띄우고 `/mcp` 로 연결을 확인하세요.

### 3. Claude Desktop
**설정 JSON 복사** 버튼의 내용을 설정 파일에 넣습니다.

```json
{
  "mcpServers": {
    "iphone": {
      "type": "http",
      "url": "http://192.168.0.42:8765/mcp",
      "headers": { "Authorization": "Bearer <토큰>" }
    }
  }
}
```

### 연결 확인
```bash
curl -s http://192.168.0.42:8765/health | jq
curl -s http://192.168.0.42:8765/mcp \
  -H "Authorization: Bearer <토큰>" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools[].name'
```

브라우저로 `http://192.168.0.42:8765/` 를 열면 현재 노출 중인 도구 목록을 볼 수 있습니다.

---

## 집 밖에서 쓰기

LAN 밖에서 붙으려면 **Tailscale** 을 권합니다. iPhone 과 Mac 에 각각 설치하고 로그인한 뒤,
앱에 표시된 IP 대신 iPhone 의 Tailscale IP(`100.x.y.z`)를 쓰면 됩니다.
Tailscale 대역(CGNAT `100.64.0.0/10`)은 "사설망에서만 접속 허용" 필터를 그대로 통과하고,
WireGuard 로 암호화되므로 평문 HTTP 위험도 사라집니다.

ngrok/Cloudflare Tunnel 같은 공개 터널을 쓰려면 앱에서 "사설망에서만 접속 허용"을 꺼야 하는데,
이 경우 인터넷에 개인 데이터 엔드포인트가 노출되므로 권장하지 않습니다.

---

## 보안 모델

| 항목 | 내용 |
|---|---|
| 인증 | 32바이트 랜덤 Bearer 토큰. 키체인 보관, 상수시간 비교, 앱에서 즉시 재발급 가능 |
| 네트워크 | 기본값이 사설망 전용. 공인 IP 에서 온 요청은 403 |
| 전송 | 평문 HTTP (LAN 전제). 암호화가 필요하면 Tailscale 사용 |
| 범위 | 앱에서 끈 도메인의 도구는 목록에 나타나지도, 호출되지도 않음 |
| 쓰기 | 기본 허용이지만 스위치 하나로 전체 차단. 삭제 도구는 아예 만들지 않음 |
| 감사 | 모든 도구 호출이 앱 화면 로그에 도구명·소요시간과 함께 남음 |

**이 앱은 켜 두는 동안 내 개인 데이터 전체를 AI 에게 열어줍니다.** 필요한 도메인만 켜고,
쓰지 않을 때는 서버를 정지하는 것을 권합니다.

---

## iOS 때문에 생기는 제약

**백그라운드** — iOS 는 앱이 백그라운드로 가면 네트워크 리스너를 곧 정지시킵니다.
- 기본 대응: "화면 꺼짐 방지"(기본 켜짐)로 앱을 앞에 띄워 두면 계속 동작합니다.
- 잠금 화면에서도 유지하려면 "백그라운드 유지 (무음 오디오)"를 켜세요. 무음을 재생해 세션을 유지하는
  방식이라 배터리를 더 쓰고 App Store 심사에서는 거부될 수 있습니다. 개인 사이드로드 전용입니다.

**파일 접근** — 샌드박스 때문에 임의 경로를 읽을 수 없습니다. 접근 가능한 것은
앱 자신의 Documents 폴더(파일 앱의 "나의 iPhone > AssetBridge")와, 앱에서 **폴더 추가** 로
직접 고른 폴더뿐입니다.

**아예 불가능한 것** — 공개 API 가 없어 이 앱으로는 접근할 수 없습니다:
문자·iMessage, 통화 기록, Safari 방문 기록, 다른 앱의 데이터, 화면 캡처, 알림 내용.
HealthKit(건강 데이터)은 기술적으로 가능하지만 별도 entitlement 가 필요해 넣지 않았습니다.

**사진 제한 접근** — 사진 권한을 "선택한 사진"으로 주면 고른 항목만 보입니다.
이 경우 도구 응답에 그 사실이 `note` 로 함께 표시됩니다.

**전화번호가 필요한 도구** — `location_current` 는 앱이 화면에 떠 있어야 동작합니다
(위치 권한이 "앱 사용 중"이므로).

---

## 구조

```
Sources/
├── App/            AssetBridgeApp, AppState, ContentView, AudioKeepAlive
├── Server/         HTTPServer / HTTPConnection / HTTPTypes  (Network.framework, 의존성 0)
├── MCP/            MCPServer (JSON-RPC 디스패치), MCPTool (도구·스키마 정의)
├── Photos/         PhotoLibraryService (PhotoKit), ImageEncoding (축소·격자 합성)
├── Providers/      도메인별 도구 구현 10종
└── Support/        JSON, 키체인, 설정, 네트워크 정보, 내보내기 저장소
```

새 도메인을 붙이려면 `ToolProvider` 를 구현하고 `ToolDomain` 에 케이스를 추가한 뒤
`AppState.init` 의 프로바이더 배열에 넣으면 됩니다.

### MCP 프로토콜 구현 범위
- 트랜스포트: Streamable HTTP (`POST /mcp` → `application/json` 응답)
- 프로토콜 버전 협상: `2025-06-18` / `2025-03-26` / `2024-11-05`
- 상태 없는 서버라 `Mcp-Session-Id` 를 발급하지 않고, SSE 를 제공하지 않으므로 `GET /mcp` 는 405
  — 둘 다 스펙이 허용하는 축약 구현입니다
- 알림(notification)에는 본문 없이 `202`, 구버전 클라이언트의 JSON-RPC 배치도 처리

---

## 문제 해결

| 증상 | 원인 / 해결 |
|---|---|
| Mac 에서 연결 실패 | 두 기기가 같은 Wi-Fi 인지 확인. 게스트 네트워크나 AP 격리(client isolation)면 통신이 막힙니다 |
| 앱은 실행 중인데 접속 불가 | 첫 실행 시 뜬 "로컬 네트워크" 권한을 거부했을 수 있습니다. 설정 > AssetBridge > 로컬 네트워크 |
| 잠깐 쓰다가 끊김 | 앱이 백그라운드로 내려간 상태. 화면 꺼짐 방지 또는 백그라운드 유지를 켜세요 |
| 401 Unauthorized | 토큰 재발급 후 클라이언트 설정을 갱신하지 않은 경우 |
| 403 Forbidden | 사설망 밖에서 접속. Tailscale 을 쓰거나 LAN 전용 스위치를 끄세요 |
| 사진이 안 나옴 | iCloud 원본이 기기에 없어 다운로드 중일 수 있습니다. 잠시 후 재시도 |
| 도구가 목록에 없음 | 해당 도메인 스위치가 꺼져 있거나, 쓰기 도구인데 쓰기 허용이 꺼져 있음 |
| 포트를 못 엶 | 서버를 정지한 상태에서만 포트를 바꿀 수 있습니다. 1024 미만은 사용 불가 |
