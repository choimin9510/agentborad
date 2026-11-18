[English](Distribution-Install-EN.md) · [한국어](Distribution-Install-KO.md) · [简体中文](Distribution-Install-ZH-CN.md)

# 安装 AgentBoard

需要 macOS 13 或更高版本及本地 Codex CLI 会话。通用包支持 Apple Silicon 和 Intel Mac。当前应用界面及安装程序提示为韩语。

## 安装

1. 在 Finder 中完整解压发行版 ZIP。
2. 双击 `Install.command`，安装完成后应用自动打开。
3. 如果 macOS 阻止了您信任的项目，请在“系统设置 → 隐私与安全性”中针对该项目选择“仍要打开”。参见 [Apple 官方说明](https://support.apple.com/en-us/102445)。

应用及 helper 采用临时签名，未经过 Apple 公证。请确认被阻止的是应用、helper 还是安装程序，不要关闭 macOS 安全功能。无法双击时，可在终端输入 `bash` 和一个空格，将 `Install.command` 拖入终端后按回车。

预编译包不需要 Xcode、Python 或 ripgrep。

- 应用：`~/Applications/AgentBoard.app`
- Helper：`~/.local/bin/agentboard`
- 安装清单：`~/.local/share/agentboard/install.json`

## 会话与进度报告

看板监控本地 `~/.codex` 和 `~/.codex-ds` 会话，不跨设备同步，也不发送消息或停止、恢复代理。

安装程序将报告指引添加到 `~/.codex/AGENTS.md` 和已存在的 `~/.codex-ds/AGENTS.md`，保留其他指令。新会话会读取指引，已有会话在收到新报告前可能没有计划。如果之后才创建独立的 DeepSeek 主目录，请重新运行安装程序。使用 `bash install.sh --prebuilt --yes --no-agents` 可跳过指引修改。

上下拖动卡片调整顺序，左右拖动隐藏。手动顺序保存在本机，可通过自动排序控件恢复自动排序。

## 卸载

退出 AgentBoard，在解压的包目录中运行：

```bash
bash uninstall.sh --yes
```

此操作删除属于 AgentBoard 的应用、helper 和报告指引块，保留 Codex 会话、认证信息、其他指令以及 AgentBoard 数据库。请保留完整的解压目录或 ZIP，卸载脚本还需要同目录中的 helper 和包标记文件。
