<div align="center">

# MicaGo

[English](README.md) · **简体中文** · [繁體中文](README.zh-Hant.md)

**你的 iMessage、你的 Mac、你的手机 —— 中间什么都没有。**
*一个自托管的 iMessage 桥接工具。没有 MicaGo 云、没有账号、没有中继。*

[文档](docs/index.zh-Hans.md) · [快速上手](docs/getting-started.zh-Hans.md) · [安全模型](#-安全模型) · [远程访问](docs/remote-access-cloudflare.md) · [CHANGELOG](MicaGoServer/docs/CHANGELOG.md)

</div>

---

## 概览

MicaGo 让你 **自己的** 安卓手机,通过你 **自己的** Mac,收发你的 iMessage。Mac 上的
一个小巧 Go 服务器读取本机「信息」数据库,提供一套私密、受令牌保护的 API;一个 macOS
菜单栏 **Companion(伴侣应用)** 负责运行并管理它;一个 **Flutter 安卓应用** 通过你的
Wi‑Fi(或你自行控制的可选公网地址)与之配对。你的数据始终只在 **你的** Mac 和 **你的**
设备之间传输。

> ⚠️ **项目状态:** 可用、可自托管,但仍较年轻。它读取 macOS「信息」的内部机制,并需要
> 「完全磁盘访问权限」。在依赖它之前,请先阅读 [安全模型](#-安全模型) 与
> [局限性](#-局限性)。与 Apple 无任何关联。

---

## ✨ 你能得到什么

- 🔐 **自托管。** 没有 MicaGo 账号或托管中继。可选的推送与远程访问使用 **你** 自己拥有
  并配置的服务。
- 💬 **会话与消息。** 会话列表、消息线程、回应(tapback)、引用回复、发送特效、贴纸、
  **位置 / 手写 / Digital Touch**,以及内嵌图片/视频与全屏查看器。
- 📤 **发送。** 通过 iMessage 发送文本与附件、**语音消息**,以及在你开启后发送短信
  (默认关闭,由服务器设置控制)。
- ⚡ **实时 + 补齐。** WebSocket 事件用于实时更新,再加上基于游标的 **增量(delta)**
  同步,在应用关闭后填补遗漏 —— 不会丢消息。
- 🌐 **局域网优先。** 会公布多条局域网路由;客户端自动选择可达的一条并允许你固定。可选
  的公网地址(你自己的隧道)可随处访问。
- 👤 **联系人匹配。** 在本机做姓名匹配,需选择启用 —— 通讯录绝不上传。
- 🔔 **通知(可选)。** 通过 **你自己的** Firebase 实现原生 Android MessagingStyle 推送,
  或完全不用 Firebase 的保活本地通知路径。

---

## 🧩 工作原理

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

- **读取路径** —— 服务器将 `chat.db` 单向同步进自己的 `relay.db`,再提供一套小而稳定的
  REST + WebSocket API。客户端通过基于游标的 **增量** 补齐,并通过 socket 获取实时事件。
- **发送路径** —— 文本通过 AppleScript 经由「信息」发送;附件通过 multipart 上传。编辑 /
  撤回 / 删除 使用可选的内置 [IMCore 助手](#-可选功能)。
- **配对** —— Companion 显示包含局域网/公网候选地址与一个 bearer 令牌的二维码 / 连接
  JSON;客户端扫描或粘贴它。

---

## 🔐 安全模型

MicaGo 是 **本地优先** 的,设计上让你的数据始终属于你。

| 关注点 | MicaGo 如何处理 |
| --- | --- |
| **鉴权** | 每个 API 调用都需要服务器生成的 **bearer 令牌**(`~/.micago/config.yaml`)。任何同时拥有你的地址 **和** 令牌的人都能访问你的 Mac —— 请像密码一样对待它。 |
| **网络** | 默认绑定到你的 **局域网**。公网暴露需你主动开启,且由你负责;任何离开你网络的流量都应优先用 HTTPS。 |
| **你的数据** | **没有 MicaGo 云中继。** 联系人在本机匹配,绝不上传。 |
| **推送** | 若你启用 FCM,负载只携带很小的唤醒/预览 —— 绝不包含你的消息历史或令牌。 |
| **私有 API** | 可选的 IMCore 助手(编辑/撤回/删除)受能力检测限制;绝不伪造成功。 |

> **MicaGo 做的** —— 把 *你的* iMessage 桥接到 *你的* 设备,走 *你* 掌控的连接。
> **MicaGo **不** 做的** —— 运行云、持有账号、把你的消息存到你 Mac 以外的任何地方,或上传你的通讯录。

---

## 🚀 快速开始

最简单的方式是运行 **Companion**,它会为你构建并启动内置的服务器:

1. 在 Xcode 中打开 `MicaGoServer/micago-mac-companion/MicaGoCompanion.xcodeproj` 并运行
   (或构建 release 版本再启动)。
2. 在提示时授予 **完全磁盘访问权限**,然后 **启动** 服务器。它默认绑定 `0.0.0.0:3000`
   (局域网可达)。
3. 在 Companion 的 **创建连接** 卡片上,显示二维码(或复制连接 JSON)。
4. 在安卓应用中,**扫描二维码** 或 **粘贴连接 JSON** 进行配对 —— 它会自动通过局域网连接。

更喜欢命令行?参见 [分组件构建](#-分组件构建)。

---

## 🛠 分组件构建

**服务器**(`MicaGoServer/micago-server`)

```sh
cd MicaGoServer/micago-server
go build ./cmd/micago        # 生成 ./micago
./micago --version
go test ./...
go run ./cmd/micago          # 首次运行会生成 ~/.micago/config.yaml 和一个令牌
```

**Companion**(`MicaGoServer/micago-mac-companion`)

```sh
cd MicaGoServer/micago-mac-companion
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion -configuration Debug build
```

> Xcode 构建阶段会把内置的 `micago` 后端 **以及** `micago-imcore-helper` 编译进应用的
> `Resources/`。

**客户端**(`MicaGoFlutterClient`)

```sh
cd MicaGoFlutterClient
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # 或：flutter run
```

---

## 🧰 可选功能

全部可选且 **默认关闭** —— 没有它们 MicaGo 也能完整工作。

- 🔔 **Firebase / FCM 推送。** 使用 **你自己的** Firebase 项目实现后台推送(不内置
  `google-services.json`)。它只是一个轻量 *唤醒* 信号;消息数据通过 WebSocket / 增量到达。
  参见 [`docs/setup/firebase/`](docs/setup/firebase/README.md)。
- 🔋 **保活服务(安卓)。** 一个前台服务,用极简通知保持连接打开 —— **无需** 配置推送也能
  收到提醒。默认关闭;厂商电池策略仍可能限制它。
- ✍️ **编辑 / 撤回 / 删除(IMCore 助手)。** 一个小巧的内置助手,调用 macOS 私有 IMCore API。
  - *用途* —— 从手机端编辑/撤回/删除一条已发的 iMessage。
  - *它 **不** 做* —— 伪造成功。如果你的 Mac 不授予 IMCore 访问,它会报告 *不支持*,这些操作就隐藏。
- 🌍 **远程访问。** 在服务器前自行架设反向代理 / 隧道(例如 Cloudflare Tunnel),并在
  Companion 中设置 **公网地址**。MicaGo 不提供也不管理隧道。参见
  [`docs/remote-access-cloudflare.md`](docs/remote-access-cloudflare.md)。

---

## 🗂 仓库结构

```
MicaGo/
├── MicaGoServer/
│   ├── micago-server/          # Go 中继服务器（`micago` 可执行文件）
│   ├── micago-mac-companion/   # macOS SwiftUI 菜单栏 Companion
│   └── docs/                   # 软件/设计文档 + CHANGELOG
├── MicaGoFlutterClient/        # Flutter 安卓客户端
├── docs/                       # 用户指南（快速上手、远程访问……）
└── README.md
```

> `Ref/`（若本地存在）存放开发期间使用的第三方参考项目。它 **不属于** MicaGo,且已被
> git 忽略。

---

## 🌐 本地化

安卓客户端内置 **English / 简体中文 / 繁體中文**(在设置中选择,或跟随系统语言)。Companion
的菜单/侧边栏与这些文档也已本地化;本 README 提供 [简体中文](README.zh-Hans.md) 与
[繁體中文](README.zh-Hant.md) 版本。

---

## ⚠️ 局限性

- **绑定 macOS。** 服务器必须运行在已登录 iMessage 且已授予完全磁盘访问权限的 Mac 上。它
  读取实时的「信息」数据库。
- **编辑/撤回/删除** 取决于你的 Mac 是否授予私有 API(IMCore)访问;不可用之处会隐藏这些操作。
- **可靠的「应用被杀」推送** 在安卓上实际需要你自己的 `google-services.json` 和/或保活;
  否则推送只能尽力而为,其余由 socket + 增量同步兜底。
- 客户端目前 **仅支持安卓**(API 在设计上与客户端无关)。
- 与 Apple 无任何关联,亦未获其认可。使用风险自负。

---

## 🤝 参与贡献

欢迎提交 issue 与 pull request。提交 PR 前:

- **服务器:** `go build ./... && go vet ./... && go test ./...`
- **客户端:** `flutter analyze && flutter test`
- **Companion:** 在 Xcode 中构建 `MicaGoCompanion` scheme。

尽量保持改动轻量、少依赖;切勿记录或提交 bearer 令牌或推送令牌。

---

<div align="center">

**[MIT](LICENSE)** · 为更愿意自己托管的人而做。

[开始使用 →](docs/getting-started.zh-Hans.md)

</div>
