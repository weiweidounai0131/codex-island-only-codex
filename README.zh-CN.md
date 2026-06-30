# CodexIsland oc

## 原作者仓库：[ericjypark/codex-island](https://github.com/ericjypark/codex-island)

[English](README.md) | [简体中文](README.zh-CN.md)

<p align="center">
  <img src="Assets/codexisland-logo.png" width="150" alt="CodexIsland oc logo">
</p>

> 让 Codex 的用量、成本和 token 活动安静地住进 Mac 刘海里。

CodexIsland oc 是
[CodexIsland](https://github.com/ericjypark/codex-island) 的 Codex-only 改版。
原项目是一个原生 macOS 悬浮层，可以把 MacBook 刘海变成类似 Dynamic Island
的实时用量状态，并同时支持 Claude Code 与 Codex。因为我日常只使用 Codex，
当关闭 Claude Code 显示后，原来的双服务布局会留下明显空白，视觉上不够平衡。
因此这个仓库在原项目基础上改成只围绕 Codex 展示，并重新调整了刘海常驻态、
展开面板、成本页和设置页，让单一 Codex 场景更紧凑、更美观。

### 预览

<p align="center">
  <img src="docs/images/island-compact.png" width="420" alt="CodexIsland oc 常驻刘海">
  <img src="docs/images/island-compact-usage.png" width="420" alt="CodexIsland oc 常驻用量">
</p>

<p align="center">
  <img src="docs/images/island-expanded-usage.png" width="280" alt="CodexIsland oc 用量页">
  <img src="docs/images/island-expanded-cost.png" width="280" alt="CodexIsland oc 成本页">
  <img src="docs/images/island-expanded-overview.png" width="280" alt="CodexIsland oc 概览页">
</p>

<p align="center">
  <img src="docs/images/settings-general.png" width="420" alt="CodexIsland oc 通用设置">
  <img src="docs/images/settings-display.png" width="420" alt="CodexIsland oc 显示设置">
</p>

应用免费、开源、未签名，并且以本地优先为原则。它读取 Codex 已经写入本机的认证状态，
拉取 Codex 用量，并从本地 Codex 会话日志估算成本和 token 吞吐量。

## 功能

- **只展示 Codex。** 常驻刘海和展开面板都围绕单一 Codex 服务重新设计，不再为
  Claude 预留空列。
- **贴合刘海的悬浮层。** 紧凑状态是一个对齐物理刘海的黑色胶囊；没有刘海的 Mac
  会退回到紧凑菜单栏胶囊。
- **常驻用量显示。** Codex 图标和用量数字可以在不悬停时保持显示。
- **点击展开。** 点击岛可打开完整 Usage / Cost / Overview 面板。
- **滑动切换页面。** 在展开面板里左右拖动，或点击底部圆点，可在 Usage、Cost、
  Overview 之间切换。
- **成本页面。** Cost 页面会从本地 Codex 日志估算今日、本月至今成本、token 总量、
  价值和趋势。
- **Token 统计口径。** 支持统计所有 token，或只统计输入 + 输出。
- **多种图表样式。** Codex 用量仍支持 Ring、Bar、Stepped、Numeric、Sparkline。
- **手动刷新。** 点击面板里的同步状态即可立即重新拉取数据。
- **低功耗模式。** 可以隐藏常驻辉光，只在刷新、悬停或接近限额提醒时显示。
- **无 Dock 图标设置窗口。** 通过展开面板里的齿轮打开自定义设置窗口，可配置登录启动、
  刷新频率、显示样式、目标屏幕、语言、token 统计和退出。
- **通用二进制。** `build.sh` 会编译 arm64 和 x86_64 两个切片，并用 `lipo`
  合并，目标为 macOS 13+。
- **不绑定上游更新渠道。** 本改版已移除 Sparkle 自动更新和原作者 Homebrew tap
  发布流程，避免和原项目发布渠道混用。
- **原生隐私边界。** 没有应用遥测、崩溃上报、第三方分析或代理服务。

## 安装

### 直接下载

从本仓库 [Releases](../../releases) 下载 `CodexIsland-oc-X.Y.Z.dmg`，
把 `CodexIsland oc.app` 拖进 `/Applications`，然后运行：

```sh
xattr -dr com.apple.quarantine "/Applications/CodexIsland oc.app"
```

<details>
<summary>为什么需要移除 quarantine？</summary>

CodexIsland oc 未签名。上面的命令会移除 macOS Gatekeeper quarantine 属性，
避免 “Apple 无法检查是否包含恶意软件” 的拦截。源码就在这个仓库里，可以自行审计。
</details>

<details>
<summary>不想用终端怎么办？</summary>

1. 把 `CodexIsland oc.app` 拖进 `/Applications`。
2. 尝试打开一次，macOS 会因为未签名而拦截。
3. 打开 **系统设置 -> 隐私与安全性**。
4. 在底部找到被拦截的 CodexIsland oc 提示。
5. 点击 **仍要打开**，再重新启动应用。
</details>

## 首次运行

CodexIsland oc 不会询问密码或 API key。它只读取你已经登录过的 Codex / ChatGPT
CLI 认证状态。

Codex：

- 先登录 Codex / ChatGPT CLI。
- CodexIsland oc 读取 `~/.codex/auth.json`。
- 如果文件或 access token 缺失，面板会显示 `no codex auth`。

应用启动后会立即进行第一次拉取，所以你第一次悬停时通常已经能看到数据。打开设置也会触发一次刷新。

## 使用

- 悬停刘海，预览当前 Codex 用量。
- 点击岛，展开完整面板。
- 在展开面板里左右拖动，或点击底部圆点，在 **Usage**、**Cost**、**Overview**
  之间切换。
- 移开鼠标，面板会收起。
- 点击同步状态可立即刷新。
- 点击展开面板左下角的齿轮打开设置。
- 在设置里可以开启登录启动、选择刷新间隔、切换低功耗模式、选择用量显示方式、
  选择图表和成本视图、切换 token 统计口径、选择目标屏幕、打开 GitHub / License，
  或退出应用。

## 设置

设置窗口是自定义 `NSWindow`，不是系统 Settings scene。应用仍以无 Dock 图标、
无菜单栏的 accessory app 方式运行。

主要偏好：

| 设置 | 存储 | UserDefaults key | 值 |
| --- | --- | --- | --- |
| 图表样式 | `StylePref` | `MacIsland.chartStyle` | `ring`, `bar`, `stepped`, `numeric`, `spark` |
| 成本样式 | `CostStylePref` | `MacIsland.costStyle` | `dollar`, `multi`, `tokens`, `spark` |
| Token 统计 | `TokenCountModeStore` | `MacIsland.tokenCountMode` | `all`, `billable` |
| 用量显示 | `UsageDisplayModeStore` | `MacIsland.usageDisplayMode` | `used`, `remaining` |
| 刷新间隔 | `RefreshIntervalStore` | `MacIsland.refreshInterval` | `300`, `900`, `1800` |
| 常驻显示用量 | `AlwaysShowUsageStore` | `MacIsland.alwaysShowUsage` | Boolean |
| 低功耗模式 | `LowPowerModeStore` | `MacIsland.lowPowerMode` | Boolean |
| 登录启动 | `LaunchAtLoginStore` | 由 `SMAppService.mainApp` 管理 | 系统登录项状态 |

刷新间隔会立即生效。`UsageStore` 会重置当前计时器，并用新的间隔重新安排下一次拉取。

## 从源码构建

需要 macOS 13+ 和来自 Xcode / Command Line Tools 的 Swift 工具链。

```sh
git clone https://github.com/weiweidounai0131/codex-island-only-codex
cd codex-island-only-codex
./build.sh
open "build/CodexIsland oc.app"
```

这个项目没有 Xcode project，也没有 SwiftPM package。`build.sh` 会直接用 `swiftc`
编译 `Sources/**/*.swift`，分别构建 arm64 和 x86_64，再合并为通用二进制，复制资源并写入
`Info.plist`。

原生 app 冒烟测试：

```sh
./scripts/verify.sh
```

脚本会构建应用，启动二进制 1 秒，如果它仍在运行就结束进程。

## 发布

打包 DMG：

```sh
npm install --global create-dmg
./release.sh
```

`release.sh` 会运行原生构建，把 `.app` 复制到 `dist/`，应用 ad-hoc codesign，
创建 `dist/CodexIsland-oc-X.Y.Z.dmg`，并输出文件大小和 SHA-256。

推送 `v*` tag 会触发 `.github/workflows/release.yml`，在 `macos-15` 上构建 DMG、
计算 checksum，并发布 GitHub Release。

## 项目结构

```text
.
├── Sources/
│   ├── App.swift
│   ├── Cost/                # 本地 Codex 日志成本与 token 聚合
│   ├── Model/
│   ├── Theme/
│   ├── Usage/
│   ├── Views/
│   └── Window/
├── Resources/              # 应用内 logo、图标、本地化
├── Assets/                 # README logo
├── docs/images/            # README 截图
├── scripts/verify.sh       # 原生冒烟测试
├── build.sh                # 通用 .app 构建
├── release.sh              # DMG 打包
└── VERSION
```

## 隐私

原生应用行为：

- 没有应用遥测。
- 没有应用分析。
- 没有崩溃上报。
- 没有代理服务器。
- CodexIsland oc 不存储凭据。
- Codex token 只从本机 `~/.codex/auth.json` 读取。
- Cost 页面只读取本机 Codex 会话日志。
- 网络请求直接发往 Codex/OpenAI 用量相关接口。

## 常见问题

**下载后无法打开。**

运行：

```sh
xattr -dr com.apple.quarantine "/Applications/CodexIsland oc.app"
```

**Codex 显示没有认证。**

先登录 Codex / ChatGPT CLI，然后重启 CodexIsland oc。

**岛显示在错误的屏幕上。**

打开设置选择目标屏幕，或保持 Auto，让应用优先选择带刘海的屏幕。

## 致谢

本项目是 [ericjypark/codex-island](https://github.com/ericjypark/codex-island)
的 Codex-only 改版。原项目创意、原生 macOS 架构和 MIT 许可均来自 Eric Park 的工作。

## 许可证

MIT。见 [LICENSE](LICENSE)。
