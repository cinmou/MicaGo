# MicaGo

[English](README.md) · **简体中文** · [繁體中文](README.zh-Hant.md)

**用你自己的安卓手机，通过你自己的 Mac，使用你自己的 iMessage。没有 MicaGo 云、没有 MicaGo 账号、没有 MicaGo 中继。**

MicaGo 是一个自托管的 iMessage 桥接工具。一个小巧的 Go 服务器运行在你的 Mac 上，
读取本机的「信息」数据库；一个 macOS 菜单栏 **Companion（伴侣应用）** 负责管理该
服务器；一个 **Flutter 安卓应用** 通过你的 Wi‑Fi（或你自行控制的可选公网地址）
与之配对，以收发消息。你的数据始终只在 **你的** Mac 和 **你的** 设备之间传输。

> ⚠️ **项目状态：** 可用、可自托管，但仍较为年轻。它依赖 macOS「信息」的内部机制，
> 并需要「完全磁盘访问权限」。在依赖它之前，请先阅读
> [安全模型](#安全模型) 与 [局限性](#局限性)。与 Apple 无任何关联。

---

## 目录

- [工作原理](#工作原理)
- [功能特性](#功能特性)
- [仓库结构](#仓库结构)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [分组件构建](#分组件构建)
- [可选功能](#可选功能)
- [安全模型](#安全模型)
- [局限性](#局限性)
- [文档](#文档)
- [参与贡献](#参与贡献)
- [许可证](#许可证)

## 工作原理

```
            ┌──────────────────────── 你的 Mac ────────────────────────┐
            │                                                            │
 信息       │   chat.db ──► 同步循环 ──► relay.db ──► REST + WebSocket   │
 (iMessage) │      ▲                                        │           │
            │      │ AppleScript / 可选的 IMCore 助手        │           │
            │   ┌──┴───────────────┐                         │           │
            │   │  Mac Companion   │  运行并管理服务器                   │
            │   │  （菜单栏应用）  │                         │           │
            │   └──────────────────┘                         │           │
            └────────────────────────────────────────────────┼──────────┘
                                                              │
                       局域网（同一 Wi‑Fi）  ──或──  可选公网地址（你的隧道）
                                                              │
                                                   ┌──────────▼──────────┐
                                                   │      安卓客户端     │
                                                   │   （Flutter 应用）  │
                                                   └─────────────────────┘
```

- **读取路径：** 服务器将 `chat.db` 单向同步进自己的 `relay.db`，再提供一套小而
  稳定的 REST + WebSocket API。客户端通过基于游标的 **增量（delta）** 进行补齐，
  并通过 socket 获取实时事件。
- **发送路径：** 文本通过 AppleScript 经由「信息」发送；附件通过 multipart 上传。
  编辑 / 撤回 / 删除 使用可选的内置
  [IMCore 助手](#编辑--撤回--删除imcore-助手)。
- **配对：** Companion 显示包含局域网/公网候选地址与一个 bearer 令牌的二维码 /
  连接 JSON；客户端扫描或粘贴它。

## 功能特性

- **自托管。** 没有 MicaGo 账号或托管中继；可选的推送与远程访问使用你自己拥有/
  配置的服务。
- **会话与消息。** 会话列表、消息线程、回应（tapback）、引用回复、发送特效、
  贴纸，以及内嵌图片/视频媒体与全屏查看器。
- **发送。** 通过 iMessage 发送文本与附件；短信（SMS）发送 **默认关闭**，并由
  服务器设置控制。
- **实时 + 补齐。** WebSocket 事件用于实时更新，游标增量同步用于在应用关闭后填补
  遗漏。
- **局域网优先的连接。** 会公布多个局域网网卡地址；客户端自动选择一个可达路由，
  并允许你手动固定其一。可选的公网地址（你自己的隧道）可随处访问。
- **联系人匹配。** 在本机进行联系人姓名匹配（需选择启用；通讯录绝不上传）。
- **已配对设备。** Companion 列出已连接设备及其推送/后台状态，并提供测试推送操作。
- **可选扩展**（全部默认关闭）：Firebase/FCM 推送、保活后台服务，以及编辑/撤回/
  删除的 IMCore 助手。

## 仓库结构

| 路径 | 说明 |
| --- | --- |
| `MicaGoServer/micago-server/` | Go 中继服务器（`micago` 可执行文件）。 |
| `MicaGoServer/micago-mac-companion/` | macOS SwiftUI 菜单栏 Companion（运行/管理服务器、配对界面）。 |
| `MicaGoFlutterClient/` | Flutter 安卓客户端。 |
| `docs/` | 用户指南（快速上手、远程访问、手动测试流程）。 |
| `MicaGoServer/docs/CHANGELOG.md` | 汇总的开发/版本历史。 |

> `Ref/`（若本地存在）存放开发期间使用的第三方参考项目。它 **不属于** MicaGo，
> 且已被 git 忽略。

## 环境要求

- **macOS**，且「信息」应用已登录 iMessage，并已向 Companion / 终端授予
  **完全磁盘访问权限**（以便读取 `chat.db`）。
- **Go 1.24+** 用于构建服务器。
- **Xcode**（较新版本）用于构建 Companion。
- **Flutter**（stable，含安卓工具链）用于构建客户端。
- 一台与 Mac 处于同一 Wi‑Fi 的安卓设备（局域网），或你自己的公网地址/隧道以进行
  远程访问。

## 快速开始

最简单的方式是运行 **Companion**，它会为你构建并启动内置的服务器：

1. 在 Xcode 中打开 `MicaGoServer/micago-mac-companion/MicaGoCompanion.xcodeproj`
   并运行（或构建 release 版本再启动）。
2. 在提示时向 Companion 授予 **完全磁盘访问权限**，然后 **启动** 服务器。它默认
   绑定 `0.0.0.0:3000`（局域网可达）。
3. 在 Companion 的 **创建连接** 卡片上，显示二维码（或复制连接 JSON）。
4. 在安卓应用中，**扫描二维码** 或 **粘贴连接 JSON** 进行配对。它会自动通过局域网
   连接。

更喜欢命令行？参见 [分组件构建](#分组件构建)，用 `go run`/`go build` 直接运行
服务器。

## 分组件构建

### 服务器（`MicaGoServer/micago-server`）

```sh
cd MicaGoServer/micago-server
go build ./cmd/micago        # 生成 ./micago
./micago --version
go test ./...
```

直接运行（首次运行会生成带 bearer 令牌的 `~/.micago/config.yaml`）：

```sh
go run ./cmd/micago
```

### Companion（`MicaGoServer/micago-mac-companion`）

打开 Xcode 工程并构建 `MicaGoCompanion` scheme。构建阶段会把内置的 `micago` 后端
**以及** `micago-imcore-helper` 编译进应用的 `Resources/`。命令行构建：

```sh
cd MicaGoServer/micago-mac-companion
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion -configuration Debug build
```

### 客户端（`MicaGoFlutterClient`）

```sh
cd MicaGoFlutterClient
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # 或：flutter run
```

## 可选功能

全部可选且 **默认关闭** —— 没有它们 MicaGo 也能完整工作。

### Firebase / FCM 推送

后台推送使用 **你自己的** Firebase 项目（应用中 **不** 内置 `google-services.json`）。
把服务器指向你的 `google-services.json`，它会在 `GET /api/fcm/client` 提供客户端
配置；应用在运行时初始化 Firebase 并注册令牌。推送只是一个轻量的 **唤醒** 信号 ——
消息内容会在唤醒后通过 WebSocket / 增量同步到达。若什么都不配置，应用就靠
WebSocket + 增量同步运行。参见 `docs/setup/firebase/`。

### 保活后台服务（安卓）

一个进阶、需选择启用的开关（「在后台保持 MicaGo 运行」）会启动一个原生前台服务并
显示一条极简的常驻通知，在不依赖 Firebase 的情况下让连接在后台保持存活。默认关闭；
厂商的电池管理仍可能限制或杀死它。

### 编辑 / 撤回 / 删除（IMCore 助手）

这些功能使用一个小巧的内置助手（`micago-imcore-helper`），它调用 macOS 私有的
IMCore API。Companion 的 **安装助手** 按钮会把它复制到 `~/.micago/bin`；后端检测到
它后，客户端仅在助手报告可用时才显示这些操作。如果你的 Mac 不授予 IMCore 访问，
它会报告 *不支持* —— 绝不伪造成功。可用性取决于 macOS、「信息」应用状态、权限，
以及 Apple 私有 API 的行为。

### 远程访问

要在 Wi‑Fi 之外访问，请在服务器前自行架设反向代理 / 隧道（例如 Cloudflare
Tunnel），并在 Companion 中设置 **公网地址（Public URL）**。MicaGo 不提供也不管理
隧道。参见 [`docs/remote-access-cloudflare.md`](docs/remote-access-cloudflare.md)。

## 安全模型

- **Bearer 令牌。** 每个 API 调用都需要服务器生成的 bearer 令牌（在
  `~/.micago/config.yaml` 中）。任何同时拥有你的地址 **和** 令牌的人都能访问你的
  Mac —— 请像对待密码一样对待该令牌；切勿把它贴进截图、日志或 issue。若泄露，
  请重新生成（并重新配对）。
- **本地优先。** 默认绑定到你的局域网。公网暴露需你主动开启，且由你自行负责；
  任何离开你网络的流量都应优先使用 HTTPS。
- **你的数据仍属于你。** 没有 MicaGo 云中继。联系人在本机匹配，绝不上传。推送负载
  （若你启用 FCM）只携带很小的唤醒/预览数据，绝不包含你的消息历史或令牌。
- **私有 API。** 可选的 IMCore 助手为编辑/撤回/删除使用 Apple 私有框架，并受能力
  检测的限制。

## 局限性

- **绑定 macOS。** 服务器必须运行在已登录 iMessage 且已授予完全磁盘访问权限的 Mac
  上。它读取实时的「信息」数据库。
- **编辑/撤回/删除** 取决于你的 Mac 是否授予私有 API（IMCore）访问；在不可用之处，
  这些操作会被隐藏。
- **可靠的「应用被杀」推送** 在安卓上实际需要你自己的 `google-services.json` 和/或
  保活服务；没有它们时，推送会尽力覆盖前台/后台的应用，其余则由 socket + 增量同步
  兜底。
- 客户端目前 **仅支持安卓**（API 在设计上与客户端无关）。
- 与 Apple 无任何关联，亦未获其认可。使用风险自负。

## 文档

- [快速上手](docs/getting-started.zh-Hans.md)
- [安卓客户端连接](docs/android-client-connection.md)
- [使用 Cloudflare Tunnel 远程访问](docs/remote-access-cloudflare.md)
- [手动测试流程](docs/manual-test-flow.md)
- [CHANGELOG](MicaGoServer/docs/CHANGELOG.md) —— 完整的开发/版本历史
- 各组件 README：[`server`](MicaGoServer/README.md)、
  [`Companion`](MicaGoServer/micago-mac-companion/README.md)、
  [`client`](MicaGoFlutterClient/README.md)

## 参与贡献

欢迎提交 issue 与 pull request。提交 PR 前：

- **服务器：** `go build ./... && go vet ./... && go test ./...`
- **客户端：** `flutter analyze && flutter test`
- **Companion：** 在 Xcode 中构建 `MicaGoCompanion` scheme。

尽量保持改动轻量、少依赖；切勿记录或提交 bearer 令牌或推送令牌。

## 许可证

[MIT](LICENSE)。
