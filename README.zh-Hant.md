# MicaGo

[English](README.md) · [简体中文](README.zh-Hans.md) · **繁體中文**

**用你自己的 Android 手機，透過你自己的 Mac，使用你自己的 iMessage。沒有 MicaGo 雲端、沒有 MicaGo 帳號、沒有 MicaGo 中繼。**

MicaGo 是一個自架的 iMessage 橋接工具。一個小巧的 Go 伺服器執行在你的 Mac 上，
讀取本機的「訊息」資料庫；一個 macOS 選單列 **Companion（伴隨程式）** 負責管理該
伺服器；一個 **Flutter Android 應用程式** 透過你的 Wi‑Fi（或你自行掌控的選用公開
網址）與之配對，以收發訊息。你的資料始終只在 **你的** Mac 和 **你的** 裝置之間
傳輸。

> ⚠️ **專案狀態：** 可用、可自架，但仍相當年輕。它依賴 macOS「訊息」的內部機制，
> 並需要「完全取用磁碟」權限。在依賴它之前，請先閱讀
> [安全模型](#安全模型) 與 [限制](#限制)。與 Apple 無任何關聯。

---

## 目錄

- [運作原理](#運作原理)
- [功能特色](#功能特色)
- [儲存庫結構](#儲存庫結構)
- [環境需求](#環境需求)
- [快速開始](#快速開始)
- [分元件建置](#分元件建置)
- [選用功能](#選用功能)
- [安全模型](#安全模型)
- [限制](#限制)
- [文件](#文件)
- [參與貢獻](#參與貢獻)
- [授權](#授權)

## 運作原理

```
            ┌──────────────────────── 你的 Mac ────────────────────────┐
            │                                                            │
 訊息       │   chat.db ──► 同步迴圈 ──► relay.db ──► REST + WebSocket   │
 (iMessage) │      ▲                                        │           │
            │      │ AppleScript / 選用的 IMCore 輔助程式    │           │
            │   ┌──┴───────────────┐                         │           │
            │   │  Mac Companion   │  執行並管理伺服器                   │
            │   │  （選單列程式）  │                         │           │
            │   └──────────────────┘                         │           │
            └────────────────────────────────────────────────┼──────────┘
                                                              │
                       區域網路（同一 Wi‑Fi）  ──或──  選用公開網址（你的通道）
                                                              │
                                                   ┌──────────▼──────────┐
                                                   │     Android 用戶端  │
                                                   │   （Flutter 程式）  │
                                                   └─────────────────────┘
```

- **讀取路徑：** 伺服器將 `chat.db` 單向同步進自己的 `relay.db`，再提供一套小而
  穩定的 REST + WebSocket API。用戶端透過以游標為基礎的 **增量（delta）** 進行
  補齊，並透過 socket 取得即時事件。
- **傳送路徑：** 文字透過 AppleScript 經由「訊息」傳送；附件透過 multipart 上傳。
  編輯 / 收回 / 刪除 使用選用的內建
  [IMCore 輔助程式](#編輯--收回--刪除imcore-輔助程式)。
- **配對：** Companion 顯示包含區域網路/公開候選位址與一個 bearer 權杖的 QR code /
  連線 JSON；用戶端掃描或貼上它。

## 功能特色

- **自架。** 沒有 MicaGo 帳號或代管中繼；選用的推播與遠端存取使用你自己擁有/設定
  的服務。
- **對話與訊息。** 對話列表、訊息串、點按回應（Tapback）、引用回覆、傳送特效、
  貼圖，以及內嵌圖片/影片媒體與全螢幕檢視器。
- **傳送。** 透過 iMessage 傳送文字與附件；簡訊（SMS）傳送 **預設關閉**，並由
  伺服器設定控制。
- **即時 + 補齊。** WebSocket 事件用於即時更新，游標增量同步用於在程式關閉後補上
  遺漏。
- **區域網路優先的連線。** 會公告多個區域網路介面位址；用戶端自動選擇一條可達路由，
  並允許你手動釘選其一。選用的公開網址（你自己的通道）可在任何地方存取。
- **聯絡人比對。** 在本機進行聯絡人姓名比對（需選擇啟用；通訊錄絕不上傳）。
- **已配對裝置。** Companion 列出已連線裝置及其推播/背景狀態，並提供測試推播操作。
- **選用擴充**（全部預設關閉）：Firebase/FCM 推播、保活背景服務，以及編輯/收回/
  刪除的 IMCore 輔助程式。

## 儲存庫結構

| 路徑 | 說明 |
| --- | --- |
| `MicaGoServer/micago-server/` | Go 中繼伺服器（`micago` 執行檔）。 |
| `MicaGoServer/micago-mac-companion/` | macOS SwiftUI 選單列 Companion（執行/管理伺服器、配對介面）。 |
| `MicaGoFlutterClient/` | Flutter Android 用戶端。 |
| `docs/` | 使用者指南（快速上手、遠端存取、手動測試流程）。 |
| `MicaGoServer/docs/CHANGELOG.md` | 彙整的開發/版本歷史。 |

> `Ref/`（若本機存在）存放開發期間使用的第三方參考專案。它 **不屬於** MicaGo，
> 且已被 git 忽略。

## 環境需求

- **macOS**，且「訊息」應用程式已登入 iMessage，並已向 Companion / 終端機授予
  **完全取用磁碟** 權限（以便讀取 `chat.db`）。
- **Go 1.24+** 用於建置伺服器。
- **Xcode**（較新版本）用於建置 Companion。
- **Flutter**（stable，含 Android 工具鏈）用於建置用戶端。
- 一台與 Mac 處於同一 Wi‑Fi 的 Android 裝置（區域網路），或你自己的公開網址/通道
  以進行遠端存取。

## 快速開始

最簡單的方式是執行 **Companion**，它會為你建置並啟動內建的伺服器：

1. 在 Xcode 中開啟 `MicaGoServer/micago-mac-companion/MicaGoCompanion.xcodeproj`
   並執行（或建置 release 版本再啟動）。
2. 在提示時向 Companion 授予 **完全取用磁碟** 權限，然後 **啟動** 伺服器。它預設
   繫結 `0.0.0.0:3000`（區域網路可達）。
3. 在 Companion 的 **建立連線** 卡片上，顯示 QR code（或複製連線 JSON）。
4. 在 Android 程式中，**掃描 QR code** 或 **貼上連線 JSON** 進行配對。它會自動透過
   區域網路連線。

偏好命令列？參見 [分元件建置](#分元件建置)，用 `go run`/`go build` 直接執行
伺服器。

## 分元件建置

### 伺服器（`MicaGoServer/micago-server`）

```sh
cd MicaGoServer/micago-server
go build ./cmd/micago        # 產生 ./micago
./micago --version
go test ./...
```

直接執行（首次執行會產生帶 bearer 權杖的 `~/.micago/config.yaml`）：

```sh
go run ./cmd/micago
```

### Companion（`MicaGoServer/micago-mac-companion`）

開啟 Xcode 專案並建置 `MicaGoCompanion` scheme。建置階段會把內建的 `micago` 後端
**以及** `micago-imcore-helper` 編譯進程式的 `Resources/`。命令列建置：

```sh
cd MicaGoServer/micago-mac-companion
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion -configuration Debug build
```

### 用戶端（`MicaGoFlutterClient`）

```sh
cd MicaGoFlutterClient
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # 或：flutter run
```

## 選用功能

全部選用且 **預設關閉** —— 沒有它們 MicaGo 也能完整運作。

### Firebase / FCM 推播

背景推播使用 **你自己的** Firebase 專案（程式中 **不** 內建 `google-services.json`）。
把伺服器指向你的 `google-services.json`，它會在 `GET /api/fcm/client` 提供用戶端
設定；程式在執行時初始化 Firebase 並註冊權杖。推播只是一個輕量的 **喚醒** 訊號 ——
訊息內容會在喚醒後透過 WebSocket / 增量同步抵達。若什麼都不設定，程式就靠
WebSocket + 增量同步運作。參見 `docs/setup/firebase/`。

### 保活背景服務（Android）

一個進階、需選擇啟用的開關（「在背景保持 MicaGo 執行」）會啟動一個原生前景服務並
顯示一則極簡的常駐通知，在不依賴 Firebase 的情況下讓連線在背景保持存活。預設關閉；
廠商的電池管理仍可能限制或終止它。

### 編輯 / 收回 / 刪除（IMCore 輔助程式）

這些功能使用一個小巧的內建輔助程式（`micago-imcore-helper`），它呼叫 macOS 私有的
IMCore API。Companion 的 **安裝輔助程式** 按鈕會把它複製到 `~/.micago/bin`；後端
偵測到它後，用戶端僅在輔助程式回報可用時才顯示這些操作。如果你的 Mac 不授予 IMCore
存取，它會回報 *不支援* —— 絕不偽造成功。可用性取決於 macOS、「訊息」應用程式
狀態、權限，以及 Apple 私有 API 的行為。

### 遠端存取

要在 Wi‑Fi 之外存取，請在伺服器前自行架設反向代理 / 通道（例如 Cloudflare
Tunnel），並在 Companion 中設定 **公開網址（Public URL）**。MicaGo 不提供也不管理
通道。參見 [`docs/remote-access-cloudflare.md`](docs/remote-access-cloudflare.md)。

## 安全模型

- **Bearer 權杖。** 每個 API 呼叫都需要伺服器產生的 bearer 權杖（在
  `~/.micago/config.yaml` 中）。任何同時擁有你的網址 **和** 權杖的人都能存取你的
  Mac —— 請像對待密碼一樣對待該權杖；切勿把它貼進截圖、日誌或 issue。若外洩，
  請重新產生（並重新配對）。
- **本機優先。** 預設繫結到你的區域網路。公開暴露需你主動開啟，且由你自行負責；
  任何離開你網路的流量都應優先使用 HTTPS。
- **你的資料仍屬於你。** 沒有 MicaGo 雲端中繼。聯絡人在本機比對，絕不上傳。推播
  負載（若你啟用 FCM）只攜帶很小的喚醒/預覽資料，絕不包含你的訊息歷史或權杖。
- **私有 API。** 選用的 IMCore 輔助程式為編輯/收回/刪除使用 Apple 私有框架，並受
  能力偵測的限制。

## 限制

- **繫結 macOS。** 伺服器必須執行在已登入 iMessage 且已授予完全取用磁碟權限的 Mac
  上。它讀取即時的「訊息」資料庫。
- **編輯/收回/刪除** 取決於你的 Mac 是否授予私有 API（IMCore）存取；在不可用之處，
  這些操作會被隱藏。
- **可靠的「程式被終止」推播** 在 Android 上實際需要你自己的 `google-services.json`
  和/或保活服務；沒有它們時，推播會盡力涵蓋前景/背景的程式，其餘則由 socket +
  增量同步補足。
- 用戶端目前 **僅支援 Android**（API 在設計上與用戶端無關）。
- 與 Apple 無任何關聯，亦未獲其背書。使用風險自負。

## 文件

- [快速上手](docs/getting-started.zh-Hant.md)
- [Android 用戶端連線](docs/android-client-connection.md)
- [使用 Cloudflare Tunnel 遠端存取](docs/remote-access-cloudflare.md)
- [手動測試流程](docs/manual-test-flow.md)
- [CHANGELOG](MicaGoServer/docs/CHANGELOG.md) —— 完整的開發/版本歷史
- 各元件 README：[`server`](MicaGoServer/README.md)、
  [`Companion`](MicaGoServer/micago-mac-companion/README.md)、
  [`client`](MicaGoFlutterClient/README.md)

## 參與貢獻

歡迎提交 issue 與 pull request。提交 PR 前：

- **伺服器：** `go build ./... && go vet ./... && go test ./...`
- **用戶端：** `flutter analyze && flutter test`
- **Companion：** 在 Xcode 中建置 `MicaGoCompanion` scheme。

盡量保持改動輕量、少依賴；切勿記錄或提交 bearer 權杖或推播權杖。

## 授權

[MIT](LICENSE)。
