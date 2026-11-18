[English](README.md) · [한국어](README.ko.md) · [简体中文](README.zh-CN.md)

# AgentBoard

用于查看本地 Codex 对话进度的 macOS 悬浮看板，支持 OpenAI 和 DeepSeek 会话。

## 功能

- 每段对话一张卡片，显示任务目的、最新请求、已报告的步骤和摘要。
- 全部、进行中、需要关注和已完成标签页。
- 未读完成标记、全部标为已读和完成提示音。
- 上下拖动卡片调整顺序，左右拖动隐藏；任务恢复时自动重新显示。
- 通过省略号菜单重命名，可同时展开多张卡片。
- 移动及调整看板大小、吸附其他窗口边缘、收起到屏幕边缘。

**文档提供英语、韩语和简体中文版本。当前应用界面为韩语。**

## 在另一台 Mac 上安装

需要 **macOS 13 或更高版本**、Apple Silicon 或 Intel Mac，以及本地 Codex CLI 会话记录。

1. 从 [Releases](https://github.com/choimin9510/agentborad/releases) 下载通用 ZIP 包。
2. 解压整个文件夹，双击 `Install.command`。
3. 安装完成后应用自动打开。预编译包无需开发工具。

应用及 helper 采用临时签名，**未经过 Apple 公证**。如果 macOS 阻止了您信任的文件，请针对该项目使用系统的“仍要打开”操作。安装路径、安全提示及卸载方法见[安装指南](Resources/Distribution-Install-ZH-CN.md)。

每台 Mac 只读取本机记录，不在设备之间同步对话。

## 工作原理

AgentBoard 读取 `~/.codex/sessions`、`~/.codex-ds/sessions` 以及自定义 `CODEX_HOME` 中的 JSONL 会话日志。通过文件事件和每五秒的检查读取新增记录。可用于 cmux、Herdr 等终端中的会话，无需读取终端画面。

代理正常结束回复后，卡片显示为已完成。**这不代表构建、测试或用户要求的任务成功。** 子代理线程和不支持的提供商会话不会显示。

任务步骤来自代理通过已安装的 `agentboard` helper 提交的结构化报告。应用不会从普通回复中推断计划。没有报告时显示“계획 미등록”（尚未登记计划）。安装程序会向支持的 Codex 主目录的 `AGENTS.md` 添加报告指引，新启动的会话才会读取。仅重启看板不会为旧对话生成计划。

默认显示最近 30 天的已完成卡片；没有进度报告的未完成卡片显示最近 7 天；有报告的未完成任务不受显示时间限制。“全部历史”可扩大已有记录的查看范围，隐藏卡片单独管理。

## 隐私与限制

- 仅在本地监控，不发送提示词、不停止或恢复代理、不调用模型 API。
- 整理后的任务信息及偏好存储在 `~/Library/Application Support/AgentBoard/agentboard.sqlite3`。完整原始对话和凭据不会复制到此数据库。
- Codex 日志格式变更、事件缺失或延迟可能影响状态准确性。
- 完成通知依据记录中的回复结束事件，不会独立验证实际工作结果。
- 卸载会保留本地数据库、Codex 会话和认证信息。

## 构建与验证

需要安装 Xcode Command Line Tools 和 Swift 编译器的 Mac。脚本构建 SwiftUI/AppKit 应用、SQLite 核心和 CLI helper；打包时包含 arm64 与 x86_64。

```bash
git clone https://github.com/choimin9510/agentborad.git
cd agentborad
./scripts/build.sh
./scripts/test.sh
./scripts/integration.sh
./scripts/test-install.sh
./scripts/package.sh
./scripts/test-package.sh
```

`build/`、`.build/` 和 `dist/` 为生成目录，不提交至 Git。测试使用虚构会话数据。`./scripts/install.sh` 默认仅预览，添加 `--yes` 才执行安装；`--no-agents` 可跳过报告指引。

## 项目结构

- `Sources/AgentBoardApp`：悬浮看板、卡片交互与窗口行为。
- `Sources/AgentBoardCore`：会话收集、验证、状态处理与 SQLite 存储。
- `Sources/agentboard`：结构化进度报告 helper。
- `Tests`、`fixtures`：回归检查及虚构会话。
- `scripts`、`Resources`：构建、安装与分发资源。

## 当前验证状态

首个版本为预览版。核心测试 395 项中有 393 项通过，正常回复结束后的未读标记有两项检查失败。`scripts/test.sh` 会在此停止，该次运行不覆盖后续测试。包验证结果请参阅发行说明。
