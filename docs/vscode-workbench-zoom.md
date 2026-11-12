# VS Code 整体缩放调查与 vsux 实现

调查日期：2026-11-11。需求：文字、图标、工具栏、侧栏、编辑器及终端一起缩放。

## 证据与边界

目标是本机已安装的 VS Code **1.145.1**，不是网上其他版本的源码：
`/Applications/Visual Studio Code.app/Contents/Resources/app`。

从发布包 `out/vs/workbench/workbench.desktop.main.js` 提取三个连续片段，用 REA 6.8.0 `analyze_javascript_application` 分析，再用 `trace_javascript_semantics` 查询 `setZoomLevel`。原文件 SHA-256：
`f34c3c421f30a0a159f25daec3fea1e0b073a6a514b38a2547cfeec05ba915e6`。

| 片段 | 原文件 UTF-8 字节范围（左闭右开） | 内容 |
| --- | --- | --- |
| factor.js | 2244219–2244251 | `_Ee(s=0)` 返回 `1.2 ** s` |
| apply.js | 20383128–20383602 | 上下限、目标窗口选择、`webFrame.setZoomLevel` |
| actions.js | 20588629–20590058 | 放大、缩小、重置命令和配置更新 |

前两个片段字节不变；第三个仅将片段末尾的逗号换成分号，使其能单独解析。片段不是完整应用，不用于证明整包调用可达性。提取清单和复现脚本保存在 `.build/vscode-zoom-evidence/provenance.json` 与 `extract.py`；REA 可导入证据位于 `.build/vscode-zoom-evidence-bundle.json`，这些临时文件不进入版本库。

- 静态分析父证据：`ev_20cc599d6ade7f4c2b56f01711a628c65f71131e5429cb45e2ebe95c79a702e1`。
- 分析摘要：`ev_d4784d1d41a8da605f439a74223562df3a66ea1bc66c28183e3c24b4580675c7`。
- 属性追踪：`ev_cf0d01a1ccb2a520418f38666c3c809166f34f85ca7a78bc9007458ca5302bc1`。

REA 成功解析三个片段、566 个 AST 节点，无解析失败。属性追踪定位了 `webFrame.setZoomLevel` 的语法访问；其对象身份和继承调用存在动态依赖，追踪标记为 ambiguous/partial，不能当作运行时调用证明。本次未启动或操作 VS Code，以下是发布包的静态观察及基于它的行为推断。

## 行为整理

| 问题 | 发布包中的观察 | 对行为的推断 |
| --- | --- | --- |
| 缩放对象 | `yB` 调用目标窗口 `webFrame.setZoomLevel(s)`，并更新窗口缩放状态 | 整个工作台按同一倍率绘制，文字、图标和几何布局一起变化 |
| 比例 | `_Ee(s=0)` 返回 `1.2 ** s` | 0=100%，1=120%，2=144%，−1≈83% |
| 边界 | `c4t=8,l4t=-8`；应用时 clamp，命令拒绝超界 | 级别 −8…8，约 23%…430% |
| 放大/缩小 | `workbench.action.zoomIn/zoomOut` 调用当前级别 ±1；设置函数 `Math.round` | 快捷操作以整数级别递进 |
| 重置 | `zoomReset` 传入非数值标记；共享模式选 0，单窗模式读取配置基准 | 重置回默认/配置的基准值 |
| 作用域与持久化 | `window.zoomPerWindow !== false` 选择当前窗口；为 false 时写 `window.zoomLevel` 并更新全部窗口 | VS Code 支持单窗缩放和全局配置缩放两种语义 |
| 默认配置（补充直接字节检查） | 同一 bundle 的 `window.zoomLevel` 声明 default=0，`window.zoomPerWindow` default=true | 该版本默认允许每窗单独缩放 |
| 启动恢复（补充直接字节检查） | `out/mainImpl.js` 的窗口初始化使用 `zoomFactor:nk(n.zoomLevel??l?.zoomLevel)`，主进程保存 `customZoomLevel` | 有窗口级状态传递路径；完整跨退出恢复及多窗口生命周期未动态验证 |

原生 macOS 菜单和系统窗口装饰不属于 Electron 页面缩放目标。快捷键注册存在于动作片段，平台按键映射未通过 VS Code 运行时核对；vsux 保留自己的既有 Control 快捷键。

## 当前项目的实现选择

- `interfaceZoomLevel` 独立于 `terminal.fontSize`；采用相同的 `1.2^level` 与 −8…8 范围。
- 使用应用级 UserDefaults 持久化，所有打开窗口和新窗口共享同一缩放值；这是本项目的产品选择，相当于 VS Code 的全局模式，而非复制其默认单窗模式。
- `WorkbenchHostingView` 保留同一个 SwiftUI hosting view，宿主维持窗口的实际尺寸；在 SwiftUI 内按倍率提供逻辑视口，再用 `scaleEffect` 同步缩放绘制与手势坐标。工具栏、侧栏、状态栏、图标、编辑器、网页预览和命中区域随之一起缩放。
- Ghostty 的渲染尺寸、内容倍率、IOSurface 图层 `contentsScale` 同步到实际 backing 像素；否则图层和网格密度不一致会出现二次放大。
- 设置增加“界面缩放”，将原字号明确标为“终端与编辑器字号”。设置及应用自有的命令、服务、日志、分支选择等面板按相同倍率缩放，超过显示器可用区域时可以滚动。
- 保留已有快捷键标识与用户自定义绑定：`Ctrl +`（含 `Ctrl =`、`Ctrl Shift =` 和数字键盘别名）放大，`Ctrl -` 缩小；新增可自定义的 `Ctrl 0` 重置到 100%。已有 `Ctrl 0` 自定义绑定优先保留，避免升级后丢失快捷键存档。
- macOS 系统菜单、窗口标题栏与系统文件选择器保持系统尺寸。独立业务 sheet 共用同一个缩放容器。

## 验证

### 放大后按钮无法点击的回归修复

初版只缩放 AppKit 祖先视图的 bounds：界面绘制变大，但 SwiftUI 的手势命中图未同步变换。实际 NSWindow 鼠标事件测试在 100% 可以启动右侧服务，在 144% 无法启动，命中落到 NSClipView。将变换移入 SwiftUI 的视图图后，同一测试通过，且宿主、编辑器和终端会话无需重建。

新增三组回归测试均发送真实的 mouseDown/mouseUp，并断言业务状态发生变化：

- 右侧服务启动、停止、重启：83%、100%、120%、144%、173%，低高度窗口中滚动后点击；启动验证实际子进程与文件输出，重启验证进程更换，停止验证进程移除。
- Markdown 工具栏的拆分编辑、大纲、关闭预览：相同倍率范围，并调整窗口宽度，验证文档预览状态。
- 顶部终端 / 编辑器切换：相同倍率范围，验证当前内容模式。

### 日志弹窗右侧裁切的回归修复（2026-11-12）

实际 sheet 测试复现了日志画布为 720×480、弹窗却保留默认 610×700 的情况：100% 时“完成”按钮右边界为 700，超出弹窗宽度 610；放大后两者差距同步扩大。原先跨视图传递的尺寸 preference 在日志的 ScrollViewReader 场景中未更新缩放容器。

测量视图现在直接在出现及尺寸变化时更新容器状态，避免依赖外层 preference 观察。回归测试在 83%、100%、120%、144%、173% 检查实际弹窗宽高、右边缘和底部按钮的可见范围，并发送真实鼠标事件验证“完成”关闭弹窗。

`WorkbenchZoomTests` 使用实际 NSWindow、SwiftUI、Ghostty 和 WKWebView：

- 设置持久化、边界、100% 重置，且独立内容字号保持不变。
- 图标转换后的尺寸符合 1.2 倍，原生按钮在缩放后仍能点击。
- 原窗口尺寸、终端 surface 和前台进程保持不变；网格随视口重排，IOSurface 和 Ghostty 的像素密度一致。
- 编辑器与预览使用相同倍率；文本、脏状态、选区和焦点保持不变。
- 设置在 100%、120% 和最大倍率下不超出屏幕高度。
- 生成 `.build/workbench-zoom-{0,1,2,-1}.png` 及 `.build/workbench-zoom-settings.png` 供视觉复核。

最终验证（2026-11-12）：`swift test` 共 206 项测试全部通过（0 failures）；`python3 Scripts/check-localizations.py` 通过（588 条双语文案）；`git diff --check` 通过。`VERSION=0.1.3 Scripts/build.sh release` 构建并签名 `dist/vsux.app`。现有运行实例不重启，避免中断用户正在运行的服务；新代码由 XCTest 创建的独立原生窗口验证。
