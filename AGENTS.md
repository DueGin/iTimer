# iTimer · Agent 工作约定

所有在这个仓库里干活的 agent（Claude Code、Codex 等）都按这份约定来。`CLAUDE.md` 引用的就是这个文件。

iTimer 是一个 macOS 菜单栏计时器，用 SwiftUI 写，Swift Package 管理，最低支持 macOS 14。`Sources/ITimerCore` 放核心逻辑（可测试），`Sources/ITimer` 放界面，`Tests/ITimerCoreTests` 是核心逻辑的测试。

## 文档分工

| 文件 | 内容 | 主要读者 |
|---|---|---|
| `README.md` | 产品定位、核心概念、完整用法 | 用户 |
| `docs/FEATURES.md` | 现有功能清单：一行一个功能，写明首发版本和代码位置 | 维护者、agent |
| `CHANGELOG.md` | 每个版本改了什么 | 所有人 |

动手改功能之前先读 `docs/FEATURES.md`，弄清楚现在有什么、代码在哪。

## 功能清单和 CHANGELOG 必须跟着代码一起改

只要改动了用户能感知的行为，包括新增、修改、移除功能，或者修了用户碰得到的问题，就在**同一个提交**里更新这些文件：

1. **`CHANGELOG.md`**：在 `## [未发布]` 下面按「新增 / 变更 / 修复 / 移除」归类加一条。对应的小节还没有就新建，小节顺序和已有版本保持一致。
2. **`docs/FEATURES.md`**：
   - 新功能：加到对应模块的表格里，版本列写「未发布」。没有合适的模块就新建一节，写上「代码：」一行。
   - 行为变了：改说明。变化大的，在版本列末尾用括号注明，例如「1.6.0（未发布起改为……）」。
   - 功能去掉了：从表格里删掉，移到文末的「已移除」，写上加入版本、移除版本（还没发版就写「未发布」）和原因或替代方案。
   - 代码挪了文件或新增了文件：同步那一节的「代码：」一行。
3. **`README.md`**：README 里写到了这个行为，就一起改。

不用记的：纯重构、测试、注释、SelfTest、构建脚本，前提是用户看不出任何变化。拿不准的就记。

提交前自查：`git diff --cached --stat` 里有 `Sources/` 的改动，却没有 `CHANGELOG.md`，确认一下是不是漏了。

### 写法

- 用简体中文，写用户看得到的行为和结果，不写类名、函数名这些实现细节（`docs/FEATURES.md` 的「代码：」一行除外）。
- 语气和 README 一致：平实、具体，不夸张。
- CHANGELOG 一条只写一件事，单独拿出来也能看懂；快捷键、数字照实写。
- `docs/FEATURES.md` 只写现在的样子；怎么变过来的写进 CHANGELOG。

## 发版

版本号规则：加了新功能升次版本号（1.7.0 → 1.8.0），只有修复和小调整升修订号（1.7.0 → 1.7.1）。

1. `Support/Info.plist`：`CFBundleShortVersionString` 改成新版本号，`CFBundleVersion` 加 1。
2. `CHANGELOG.md`：把 `## [未发布]` 改成 `## [x.y.z] - YYYY-MM-DD`，在它上面再加一个空的 `## [未发布]`；更新文末的比较链接。
3. `docs/FEATURES.md`：把所有「未发布」换成 `x.y.z`，更新顶部的当前版本、build 号和日期。
4. 提交信息写成 `iTimer x.y.z: 一句话摘要`，打标签 `vx.y.z`。

## 构建与测试

```bash
./scripts/build-app.sh release   # 输出 dist/iTimer.app
swift test                       # 核心逻辑测试
```

界面自测在 `Sources/ITimer/SelfTest.swift`。`goal`、`workflow` 两个场景支持 background 模式：不激活 App，事件直接发给窗口，不占用前台和鼠标。
