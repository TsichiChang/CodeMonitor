# CodeMonitor

一个 macOS 菜单栏应用，把这台机器上正在跑的编码 agent 会话摆到屏上，并能跳到承载它的
终端。用 Swift/SwiftUI 写，`swift/` 下是全部代码。

## 这个仓库怎么运作

**决策写在 `docs/adr/`，而 ADR 是规范。** 代码不能让任何一条 ADR 变成假的。反过来也
成立：**ADR 也会错**——它可能落后于代码，也可能描述一个从未实现过的机制。两边对不上
时，先判定是哪一边错，再动手。

**`--selftest` 的每一条断言都是一个上过屏的缺陷。** 修好一个就留一条。

**同一件事只表达一次。** 这个仓库为"两处各写一遍然后分头漂移"付过至少六次账。发现
第二处表达时合并它，不要加条件；能改成派生就派生。

完整流程（何时写 ADR、何时先 grill、提交与评审）见 `/adr-flow`。

## 硬性门槛

改动完成的定义，三条都要过：

```bash
cd swift && swift build                 # 必须零 warning
./.build/debug/CodeMonitor --selftest   # 必须全绿
```

**不在 `main` 上直接提交。** 先开分支，走 PR，评审后合并。远端是 GitHub
（`TsichiChang/CodeMonitor`），用 `gh`。

提交信息承载推理，不是变更清单；结尾带
`Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`。完整形式见 `/adr-flow`。

## 两个容易踩空的地方

**`--diagnose` 是另一个进程、自己重新扫一遍。** 它答不了关于运行中 app 的问题——只活
一秒的卡片、跨两轮扫描才成立的状态，它都看不到。那种问题要开 `snapshotLog`。

**这个 app 从不申请可以避开的权限**（ADR-0014）。写验证代码时同理：`screencapture` 和
`CGWindowListCopyWindowInfo` 需要屏幕录制权限，拿不到时**无声地返回空**而不是报错；
`NSWindow.isVisible` 和离屏渲染不需要。

## 手边的仪器

| 命令 | 用途 |
|---|---|
| `--diagnose` | 会话、证据、liveness、跳转路由 |
| `--focus-next --dry-run` | 快捷键的访问顺序 |
| `--hooks` / `--install-hooks` | 各工具的上报 hook |
| `CODEMONITOR_STATE_DIR=<dir>` | 用假的 hook state 构造场景 |
| `tools/dead-wait.py` | dead wait 基线，按类别分开 |
| `tools/band-probe.swift` | 光带独立运行，用于调参与测 CPU |
