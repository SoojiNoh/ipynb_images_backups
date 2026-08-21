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
cd iphone-asset-mcp
./go.sh
```

이게 전부입니다. 최신 코드를 받고, Xcode 를 점검하고, 키체인에서 팀 ID 를 찾아 서명을
채우고, 빌드해서 실행까지 합니다. iPhone 이 연결돼 있으면 iPhone 에, 아니면 시뮬레이터에
올립니다. 몇 번을 다시 돌려도 안전합니다.

**`AssetBridge.xcodeproj` 는 저장소에 들어 있습니다.** XcodeGen 같은 도구를 설치할 필요가 없고,
따라서 "future Xcode project file format" 오류도 나지 않습니다
(프로젝트 포맷을 Xcode 14 세대인 `objectVersion 56` 으로 고정해 뒀습니다).

### 실행

Xcode 의 실행 대상(destination) UI 를 거치지 않고 명령줄에서 바로 돌릴 수 있습니다.

```bash
./run-simulator.sh              # 시뮬레이터. 서명 불필요
./run-simulator.sh "iPhone 15"  # 기기 지정
./run-device.sh                 # 연결된 실제 iPhone
```

각각 빌드 → 설치 → 실행까지 합니다. 실패하면 컴파일 에러만 추려 보여주고
전체 로그를 클립보드에 복사하므로, 붙여넣기만 하면 됩니다.

시뮬레이터는 빌드와 MCP 연결 확인용입니다. 사진·연락처가 비어 있어서
실제 데이터를 다루려면 진짜 iPhone 이 필요합니다.
(Finder 에서 이미지를 시뮬레이터 창에 끌어다 놓으면 사진 앱에 들어갑니다.)

### 사람이 직접 해야 하는 것

기계가 대신할 수 없는 부분만 남습니다.

1. **실기기에 설치하려면 Apple ID 로그인** — Xcode > Settings (⌘,) > Accounts > `+`
   그다음 `./go.sh` 를 다시 돌리면 팀 ID 를 키체인에서 읽어 알아서 채웁니다.
   (Apple ID 가 없으면 go.sh 가 시뮬레이터로 넘어가므로 막히지는 않습니다.)
2. 무료 Apple ID 라면 iPhone 에서 한 번 신뢰:
   설정 → 일반 → VPN 및 기기 관리 → 본인 계정 → 신뢰
3. 앱에서 **권한 요청** → 시스템 시트 허용 → **시작**

> `setup.sh` 가 키체인에서 인증서를 못 찾으면 (Xcode 에 Apple ID 를 아직 로그인하지 않은 경우)
> 안내만 남기고 넘어갑니다. Xcode > Settings > Accounts 에서 로그인한 뒤 다시 실행하세요.
>
> 무료 Apple ID 로도 사이드로드할 수 있지만 프로비저닝 프로파일이 7일마다 만료되어
> 재설치해야 합니다. 연간 $99 개발자 계정이면 1년입니다.

### 소스 파일을 추가했다면

프로젝트 파일은 소스 목록을 담고 있으므로 다시 생성해야 합니다.

```bash
python3 tools/generate_xcodeproj.py
```

`Sources/` 를 훑어 `.xcodeproj` 를 다시 만들고, 끊어진 참조가 없는지 스스로 검증합니다.
ID 는 경로 해시로 결정되므로 재생성해도 불필요한 diff 가 생기지 않습니다.

### 서명 값을 바꾸려면

`Config/Local.xcconfig` (setup.sh 가 생성, git 에 올라가지 않음) 를 고치면 됩니다.

```
ASSETBRIDGE_BUNDLE_ID = com.내이름.assetbridge
ASSETBRIDGE_TEAM_ID = ABCDE12345
```

Apple 계정을 바꾸면 이 번들 ID 를 새 팀이 못 쓰는 경우가 있습니다 — 무료 계정에서
한 번 등록한 App ID 는 그 팀의 것이 되기 때문입니다. 누가 그 이름을 가졌는지는
이 Mac 에 내려와 있는 프로비저닝 프로파일에 적혀 있으므로(`application-identifier`),
`run-device.sh` 가 **빌드 전에** 확인해서 필요하면 팀 ID 를 붙인 이름으로 바꿉니다.
팀마다 고정된 이름이라 다시 돌려도 같은 값이고, 무료 계정의 App ID 주당 10개 한도를
헛되이 태우지 않습니다.

```bash
python3 tools/bundle_id.py com.내이름.assetbridge ABCDE12345   # 무슨 이름을 고를지 미리 보기
```

다른 Mac 에서 등록한 App ID 는 여기 프로파일에 없어서 미리 알 수 없습니다. 그때는
빌드가 한 번 실패하고, 그 실패를 보고 이름을 바꿔 자동으로 다시 빌드합니다.

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
claude mcp add-json iphone '{"type":"http","url":"http://192.168.0.42:8765/mcp","headers":{"Authorization":"Bearer VW71"}}'
```

붙여넣고 실행한 뒤 `claude` 를 띄우고 `/mcp` 로 연결을 확인하세요.

`--transport` 대신 `add-json` 을 쓰는 이유는 전자가 비교적 최근 claude CLI 에만
있어서 조금 옛 버전에서 `unknown option '--transport'` 로 실패하기 때문입니다.
`add-json` 조차 없는 버전이라면 앱의 **.mcp.json 만들기** 버튼을 쓰세요 —
CLI 하위 명령을 전혀 쓰지 않고 설정 파일을 직접 만듭니다.

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
| 인증 | 4자 Bearer 토큰(Crockford Base32). 키체인 보관, 상수시간 비교, 앱에서 즉시 재발급 |
| 대입 차단 | IP당 5회 실패 → 15분 차단. IP 갈아타기까지 막는 전역 상한 시간당 15회 |
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

**앱이 화면에 떠 있어야 하는 도구** — `location_current` 는 위치 권한이
"앱 사용 중"이라 앱이 포그라운드일 때만 좌표를 돌려줍니다.

---

## 구조

```
├── setup.sh                    한 번에 빌드 준비 (Xcode 확인 → 서명 → 열기)
├── AssetBridge.xcodeproj/      커밋된 프로젝트 파일 (objectVersion 56)
├── AssetBridge-Info.plist      권한 문구와 번들 설정
├── Config/Base.xcconfig        서명 값의 기본값 + Local.xcconfig 선택 include
├── tools/
│   ├── generate_xcodeproj.py   소스 추가 시 프로젝트 재생성 (자체 검증 포함)
│   ├── bundle_id.py            이 팀으로 쓸 수 있는 번들 ID 를 빌드 전에 결정
│   ├── inbox_watcher.py        공유 수신함을 보고 지시를 수행 (launchd 가 30초마다)
│   ├── ask_channel.py          폰으로 묻고 답을 기다린다 (텔레그램)
│   └── ask_mcp.py              그 되묻기를 claude 에게 도구로 물려주는 작은 MCP 서버
└── Sources/
    ├── App/        AssetBridgeApp, AppState, ContentView, AudioKeepAlive
    ├── Server/     HTTPServer / HTTPConnection / HTTPTypes (Network.framework, 의존성 0)
    ├── MCP/        MCPServer (JSON-RPC 디스패치), MCPTool (도구·스키마 정의)
    ├── Photos/     PhotoLibraryService (PhotoKit), ImageEncoding (축소·격자 합성)
    ├── Providers/  도메인별 도구 구현 10종
    └── Support/    JSON, 키체인, 설정, 네트워크 정보, 내보내기 저장소
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

## Mac 에 예약 걸기

```bash
bash tools/install_schedule.sh            # 걸기 (다시 실행해도 안전)
bash tools/install_schedule.sh --remove   # 지우기
```

두 가지가 걸립니다.

**갱신 (6일마다)** — 무료 Apple 계정 서명은 7일 뒤 만료됩니다. Mac 이 하루 전에
다시 설치합니다. 자고 있었으면 깨어난 직후에 밀린 작업이 돕니다.

**감시 (30초마다)** — 공유 수신함에 지시가 붙은 새 항목이 오면 `claude -p` 로
바로 수행합니다. 즉 **공유만 하면 끝**이고, Mac 에서 따로 물어볼 필요가 없습니다.
한 항목은 한 번만 처리하고(같은 일정을 두 번 넣지 않습니다), 3회 실패하면
포기하고 알림을 띄웁니다.

로그는 `~/Library/Logs/AssetBridge/`.

무인 실행이라 claude 가 도구 승인을 물으면 멈춥니다. 어떤 도구를 미리 허용할지는
`.claude/settings.json` 의 permissions 에서 정하세요 — 캘린더에 쓰는 것과 파일을
지우는 것은 다른 얘기라, 기본값으로 열어 두지 않았습니다.

한 번 처리가 30초를 넘겨도 겹쳐 돌지 않습니다. 감시자는 시작할 때 `flock` 으로
잠금을 쥐고, 이미 돌고 있으면 조용히 물러납니다.

## 애매하면 폰으로 물어보기

공유한 글에 "3시" 라고만 적혀 있으면 오늘인지 내일인지 알 수 없습니다. 지금까지는
둘 중 하나였습니다 — 찍어서 넣거나, 포기하거나. 텔레그램 봇을 하나 붙여 두면
**폰으로 물어보고 답을 기다립니다.**

```bash
bash tools/setup_telegram.sh            # 한 번만 (봇 토큰을 붙여넣으면 나머지는 자동)
bash tools/setup_telegram.sh --check    # 상태 확인
bash tools/setup_telegram.sh --remove   # 다시 안 묻게 하기
```

설정하고 나면 감시자가 `claude -p` 를 부를 때 되묻기 도구 두 개를 붙여 줍니다.

| 도구 | 하는 일 |
|---|---|
| `ask_user(question, choices?)` | 폰에 질문을 보내고 답을 기다립니다. `choices` 를 주면 버튼으로 뜹니다 |
| `tell_user(message)` | 답이 필요 없는 소식만 보냅니다 |

기본 4분까지 기다리고, 답이 없으면 **되돌릴 수 있는 쪽으로** 진행한 뒤 무엇을
가정했는지 폰으로 알립니다. 처리 결과 알림도 Mac 알림과 함께 폰으로 갑니다 —
이 기능을 쓰는 상황이 곧 Mac 앞에 없는 상황이라서입니다.

**왜 텔레그램인가.** 슬랙은 워크스페이스와 앱 등록에 Socket Mode 나 공개 이벤트
URL 이 필요하고, 디스코드는 웹훅이 보내기 전용이라 답장을 읽으려면 봇과 게이트웨이
웹소켓이 필요합니다. 텔레그램은 `getUpdates` 롱폴링이라 NAT 안쪽 Mac 에서 공개 주소
없이 그냥 되고, 봇 만들기가 2분입니다. 받는 쪽 경험(폰 알림 → 거기서 답장)은 셋 다
같습니다.

토큰은 `~/Library/Application Support/AssetBridge/telegram.json` 에 권한 600 으로
저장합니다. 질문을 보내기 직전에 밀린 메시지를 모두 읽은 것으로 넘겨서, 어제 보낸
"ㅇㅇ" 이 오늘 질문의 답으로 둔갑하지 않습니다. 설정된 대화에서 온 메시지만 답으로
받습니다 — 봇에게는 누구나 말을 걸 수 있습니다.

터미널에서 직접 써 볼 수도 있습니다.

```bash
python3 tools/ask_channel.py --ask "지금 나갈까요?" --choice 네 --choice 조금뒤
```

## 어디서나 붙기

`tools/link_device.sh` 는 오래 가는 주소부터 차례로 실제로 찔러 보고, 응답하는
첫 번째를 등록합니다.

| 순서 | 주소 | 어디까지 되나 |
|---|---|---|
| 1 | `ASSETBRIDGE_HOST` | 직접 지정한 주소 |
| 2 | **Tailscale** (`100.x.x.x`) | **다른 Wi-Fi·LTE·어디서나** |
| 3 | `<기기이름>.local` | 같은 Wi-Fi. IP 가 바뀌어도 유지 |
| 4 | LAN IP | 지금 이 순간만 |

**다른 네트워크에서도 쓰려면 Tailscale** 을 Mac·아이폰 양쪽에 깔고 같은 계정으로
로그인한 뒤 `link_device.sh` 를 다시 돌리면 됩니다. 개인 사용은 무료입니다.
앱은 CGNAT(100.64/10) 대역을 사설망으로 인정하므로 '사설망에서만 접속 허용'을
켜 둔 채로도 통합니다.

단, **앱 재설치(7일 갱신)는 여전히 같은 Wi-Fi 나 케이블이 필요합니다.** Xcode 의
기기 설치는 Bonjour 로 기기를 찾는 CoreDevice 로컬 터널을 쓰는데, Tailscale 은
그걸 실어 나르지 않습니다.

## 문제 해결

무엇이 잘못됐는지 모를 때는 먼저 이것부터. 아무것도 바꾸지 않고 읽기만 하며,
앱·서버·설정 세 곳의 토큰을 대조한 뒤 결과를 클립보드에 넣습니다.

```bash
bash tools/doctor.sh
```

실기기 서명이 막힐 때는 무엇이 등록돼 있는지부터 봅니다. 무료 Apple ID 는
등록 기기를 볼 수 있는 웹 포털이 없어서, 프로비저닝 프로파일 안을 들여다봅니다.

```bash
python3 tools/list_devices.py
```

| 증상 | 원인 / 해결 |
|---|---|
| Mac 에서 연결 실패 | 두 기기가 같은 Wi-Fi 인지 확인. 게스트 네트워크나 AP 격리(client isolation)면 통신이 막힙니다 |
| 앱은 실행 중인데 접속 불가 | 첫 실행 시 뜬 "로컬 네트워크" 권한을 거부했을 수 있습니다. 설정 > AssetBridge > 로컬 네트워크 |
| 잠깐 쓰다가 끊김 | 앱이 백그라운드로 내려간 상태. 화면 꺼짐 방지 또는 백그라운드 유지를 켜세요 |
| 401 Unauthorized | 설정에 남은 옛 토큰. `./go.sh` 가 등록 전에 토큰을 검증하므로 다시 돌리면 맞춰집니다 |
| 빌드가 `Device is busy` / `no DDI` | iPhone 개발자 모드가 꺼져 있거나 준비가 안 끝났습니다. 설정 > 개인정보 보호 및 보안 > 개발자 모드 > 켬 → 재시동. `run-device.sh` 가 준비를 최대 5분 기다립니다 |
| `No Account for Team` / `No profiles for` | Xcode 에 Apple ID 계정이 없습니다. 키체인 인증서만으로는 프로파일을 만들 수 없습니다. Xcode > Settings > Accounts > '+' > Apple ID |
| `maximum number of registered ... devices` | 무료 Apple 계정의 기기 등록 한도(3대)입니다. 지워서 늘릴 수 없고 1년 주기로만 초기화됩니다. 무엇이 차지하고 있는지는 `python3 tools/list_devices.py` 로 봅니다. 해결하려면 새 Apple 계정([account.apple.com/account](https://account.apple.com/account) — 끝의 `/account` 가 있어야 생성 폼입니다)을 만들어 Xcode > Settings > Accounts 에 추가하세요. Xcode 로그인 창에서는 계정을 만들 수 없습니다 |
| 계정 생성 시 `해당 이메일 주소를 사용할 수 없습니다` | 그 주소가 이미 Apple 계정입니다(예전 로그인, 또는 다른 계정의 복구용 이메일). 만들지 말고 그 주소로 **로그인**하세요. 삭제된 Apple 계정의 주소는 영구히 재사용할 수 없으니, 그 경우 새 이메일을 만드세요 |
| 403 Forbidden | 사설망 밖에서 접속. Tailscale 을 쓰거나 LAN 전용 스위치를 끄세요 |
| 사진이 안 나옴 | iCloud 원본이 기기에 없어 다운로드 중일 수 있습니다. 잠시 후 재시도 |
| 도구가 목록에 없음 | 해당 도메인 스위치가 꺼져 있거나, 쓰기 도구인데 쓰기 허용이 꺼져 있음 |
| 포트를 못 엶 | 서버를 정지한 상태에서만 포트를 바꿀 수 있습니다. 1024 미만은 사용 불가 |
