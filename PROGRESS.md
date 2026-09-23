# Inputscape 交接文档

> macOS 14+ 本地输入习惯分析器 · 唯一交接主文档，随开发推进更新
> 设计契约：`INPUTSCAPE_DESIGN_PLAN.md`（用户 authored，改动需谨慎）
> 触控板扩展方案（待拍板）：`TOUCHPAD_PROPOSAL.md`
> 最近更新：2026-09-23（夜览模式、无标题栏顶栏、自定义区间弹层与滚动语义）
> 本文件只保留**最终状态与决策**；完整迭代历史见 git log

---

## 一、项目概况

- **定位**：本地输入习惯分析工具。仅保存本地聚合统计，不记录文字内容、按键序列、应用名称、屏幕坐标或原始事件，无云同步。
- **首版范围**：内置键盘（Apple Wireless Keyboard 实测布局，78 键基准）+ 内置触控板；ISO/JIS/Magic Keyboard 为后续模板。
- **技术栈**：Swift 5.9 tools / Swift 6.3 编译器（CommandLineTools，Xcode 许可未接受）、SwiftUI + Swift Charts、CGEventTap（公开 API）、JSON 按日存储。
- **版本管理**：git 仓库（本目录），提交身份 Bintao / zfr45682@icloud.com；构建产物与 `.workbuddy/` 已 gitignore。

## 二、当前状态

**首版功能完成。48/48 测试通过，`build-release.sh` 一键构建/签名/启动。**

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| 键盘主图规范 | ✅ 完成 | 78 键唯一真值；物理布局对齐 `apple-wireless-keyboard.json`（功能行 1.0357u、command 1.25u、space 5u、四方向键半高、右修饰键右对齐、fn 地球左下+字母右下、Touch ID 矩形键帽+居中指纹圆环、caps LED 点），三页共用同一渲染视图；F3 = `rectangle.3.group` |
| 键帽样式 | ✅ 完成 | 修饰键图标用标准 Unicode（⌘⌥⇧⌃⇪⌫⏎⇥），F1–F12 用 SF Symbols 描边图标；左侧修饰键图标上/单词下左对齐、右侧 command/option 右对齐；数字/标点双层居中；键帽小圆角（0.09u）、画布四周 0.1u 留白 |
| 聚合引擎 | ✅ 完成 | 60s 输入段 / 5 分钟桶 / 跨天 / 预设周期与自定义起止快照（含同日区间）/ 组合键计数 |
| 本地存储 | ✅ 完成 | 按日 JSON + 白名单 schema（date/keyCounts/comboCounts/trackpadCounts/buckets/hourlyByOp/activeSeconds），隐私测试守护 |
| 监听层 | ✅ 完成（待真机授权验证） | keyDown/keyUp + flagsChanged（修饰键含释放）+ systemDefined（F 行媒体键含释放）+ 特殊键码；只输出键位 ID / 操作类别 / 组合和弦 |
| 组合键统计 | ✅ 完成 | 修饰键按住 + 普通键按下 → 和弦（⌘C / ⇧⌘3 / 三键）；150ms 去抖；实时页 + 键盘分布 Top5 + 总览摘要 |
| 自定义统计区间 | ✅ 完成 | 三段状态机（开始 → 结束不早于开始，**允许同一天** → 点击重置）；开始/结束输入框一行排布，支持键入 `YYYY-MM-DD` / 缺前导零 / `20260913` 八位无分隔符（补零、超月收敛、非法回退）；日历跟手 pager 翻页（拖拽/双指横扫/箭头，方向性滑动过渡）；端点带「开始/结束」标记；标题按区间显示中文日期（跨年补年份） |
| 实时反馈 | ✅ 完成 | 三类键释放闭环，按下点亮缩放、松开即灭、无残留 |
| 七页面 UI | ✅ 完成 | 总览 / 键盘分布 / 触控板操作 / 使用趋势 / 实时观察 / 设置 + 三步引导；侧栏每项带 SF Symbol 图标；ⓘ 说明为 AppKit 原生 Tooltip |
| 夜览模式 | ✅ 完成 | 设置页三档显示模式（开启夜览 / 关闭夜览 / 跟随系统），UserDefaults 持久化、重启保持；`Theme` 全量语义色动态化（明暗双套色板），切换即时生效无需重启 |
| XCTest 测试 | ✅ 48/48 | 布局规范 14（含 JSON 等价性、方向键底对齐、高度归一）、聚合 11、存储 5、隐私 5、键码映射 8、显示模式 5 |

## 三、代码结构

```
monitor-dev/
├── Package.swift                    # SwiftPM：InputscapeKit + InputscapeApp + Tests
├── build-release.sh                 # ★ 一键：构建(exit 校验)→稳定签名→重启
├── run-tests.sh                     # ★ 一键测试（CLT 编 Kit + Xcode XCTest.framework 链接）
├── apple-wireless-keyboard.json     # ★ 键盘物理布局数据源（Apple Wireless Keyboard 实测，KLE 格式）
├── keyboard-preview.png             # 键盘布局离屏渲染预览图
├── Sources/InputscapeKit/           # 核心库（无 UI 依赖，可独立测试）
│   ├── KeyboardLayoutSpec.swift     # ★ 78 键主键盘图唯一真值（几何源自 JSON + KeyGlyph/KeycapStyle 逐键定义）
│   ├── AppearanceMode.swift         # 显示模式三档枚举 + UserDefaults 持久化（可测）
│   ├── KeyCodeMapper.swift          # kVK 键码→键位 ID + 媒体键/fn 改写键码映射 + ComboKeyBuilder
│   ├── AggregationEngine.swift      # 聚合：60s 输入段 / 288 桶 / 跨天 / 两种快照
│   ├── AggregateStore.swift         # 按日 JSON 存储（原子写、白名单 schema）
│   ├── EventMonitor.swift           # CGEventTap（主 run loop）+ 三类键事件分类 + 权限中心
│   └── Models.swift                 # DailyRecord / TimeBucket / LiveState / 快照等
├── Sources/InputscapeApp/           # SwiftUI 应用
│   ├── KeyboardHeatmapView.swift    # ★ 唯一键盘渲染视图（三页共用，键帽样式渲染 + 画布外边距）
│   ├── AppearanceManager.swift      # 夜览切换核心：NSApp.appearance 应用 + 系统深浅色监听
│   ├── WindowChrome.swift           # 无标题栏窗口的拖拽补回（isMovableByWindowBackground）
│   ├── AppModel.swift               # 主模型（状态/快照/持久化；高频事件不经此失效全树）
│   ├── LiveModel.swift              # 实时状态（pressedKeys/heldChips，按键只失效实时页）
│   ├── AppKitTooltip.swift          # ⓘ 原生 Tooltip 桥接（NSView.toolTip）
│   ├── CustomRangePicker.swift      # ★ 自定义区间弹层（三段状态机 + 键盘输入 + 跟手 pager）
│   ├── RootView.swift               # HStack 分栏（侧栏 | 分割线 | 内容）+ 状态栏 + 诊断钩子
│   ├── Theme.swift                  # ★ 全量语义色（NSColor dynamicProvider 明暗双套色板）
│   ├── Components.swift             # 卡片 / 周期切换 / 状态横幅 / 空状态 / Tooltip 标记
│   ├── OverviewAndKeyboardViews.swift   # 总览 + 键盘分布
│   ├── TrackpadAndTrendsViews.swift     # 触控板操作 + 使用趋势
│   └── LiveSettingsOnboardingViews.swift # 实时观察 + 设置 + 首次引导
└── Tests/InputscapeKitTests/        # 48 个 XCTest 用例（6 个文件）
```

## 四、构建 / 测试 / 运行

```bash
./build-release.sh   # 一键：release 构建（exit 校验）→ 稳定签名 → 重启
./run-tests.sh       # 48 个测试（CLT 编 Kit + Xcode XCTest.framework 链接 + xctest 运行器）
```

- 签名用钥匙串中的 **Apple Development 证书**（TeamID Y99GV96XD6）——签名身份稳定，**TCC 授权跨构建保留**；ad-hoc 签名（`-s -`）会每次重置授权，已弃用。证书约 1 年有效期，续订后需再授权一次。
- 签名/codesign 访问钥匙串，沙箱内会被拦，需非沙箱执行。
- 运行前置：系统设置 › 隐私与安全性 › 输入监听 + 辅助功能（启动时未授权会自动弹申请）。

## 五、本机工具链备注

- `xcode-select` 指向 Xcode.app 但许可未接受（接受需 sudo）→ 所有 swift 命令用 `DEVELOPER_DIR=/Library/Developer/CommandLineTools`。
- SwiftPM 沙箱在本机起不来 → 必须 `--disable-sandbox`。
- **新版 CLT 不带 XCTest / Swift Testing** → `run-tests.sh` 用 CLT 编 Kit（`-enable-testing`），链接 Xcode 的 XCTest.framework 出 .xctest bundle，再用 Xcode 的 `xctest` 运行器执行（非许可门禁工具，绝对路径）。
- ⚠️ 测试只编 Kit——**测试绿 ≠ 应用 target 编译绿**，交付前必须跑 `build-release.sh` 并确认 "Build complete"。
- ⚠️ **构建/测试命令禁止接管道看 tail**——管道会掩盖退出码（曾致编译失败被吞、连续三轮验证跑旧二进制）。用 `set -o pipefail` 或不接管道看全量输出。

## 六、关键技术决策（最终态）

1. **键盘唯一真值**：所有键盘页面从 `KeyboardLayoutSpec` 派生（KeyGlyph/KeycapStyle 逐键定义），禁止硬编码键位数组。物理布局源自 `apple-wireless-keyboard.json`，几何等价性由 JSON 比对测试守护（容差 0.002）。
2. **键帽样式**：修饰键图标用标准 Unicode 字符，F1–F12 用 SF Symbols 描边图标（F3 = `rectangle.3.group`）；左修饰键左对齐、右 command/option 右对齐；键帽小圆角、画布四周 0.1u 外边距（`canvasAspectRatio` 暴露给调用方）。
3. **方向键**：四键全半高（↑ 顶对齐、←/↓/→ 底对齐），箭头字形随半高缩小；对齐关系有测试断言。
4. **三类键释放路径闭环**：普通键 keyUp / 修饰键 flagsChanged 标志位移除（CapsLock 用事件交替判定）/ 媒体键 0xB 帧——实时"按下中"状态与统计都依赖这三条路径完整。
5. **fn 按住会改写键码**（官方 Events.h）：fn+方向键 → Home/End/PageUp/PageDown，fn+delete → ForwardDelete；映射回物理键位，保证组合可识别。
6. **媒体键解析**：systemDefined(14) + subtype 8 + data1 位域（0xA 按下 / 0xB 释放），按下计数并点亮、释放熄灭。
7. **CGEventTap source 必须挂主 run loop**：挂后台线程时 HIToolbox 的 caps 长按 timer 会 SIGTRAP 崩溃。
8. **组合键 = 和弦快照**：Apple 菜单顺序 ⌃⌥⇧⌘ 编码；只存和弦构成不存时间序列；150ms 去抖。
9. **ⓘ 提示用平台原生 `NSView.toolTip`**：自研悬浮窗已验证不稳定，平台机制是唯一稳定实现。
10. **性能**：高频事件（每次按键）只更新 LiveModel 与引擎计数，不触发主模型 `objectWillChange`；空闲秒数用 TimelineView 局部刷新。
11. **交付纪律**：`build-release.sh` 固化构建流程（构建退出码显式校验、失败输出日志并中止、稳定签名、重启冒烟）；**构建/测试命令禁止接管道后链式执行**——管道掩盖退出码，曾致连续三轮验证跑旧二进制。
12. **夜览（深色）模式走 AppKit 原生外观机制**：`Theme` 全部语义色为 `NSColor(name:dynamicProvider:)` 动态颜色（明暗两套配对值），应用侧只改 `NSApp.appearance`（开启=darkAqua / 关闭=aqua / 跟随=nil）——外观变化由系统传播到所有窗口并触发动态颜色重解析，即时生效、无需重启，也不需要逐视图订阅 colorScheme。持久化在 UserDefaults（`Inputscape.AppearanceMode`），Kit 层枚举 + 存储可测。**新增颜色必须走 `Theme.dynamicColor(浅, 深)`，禁止引入静态色。**
13. **顶部品牌区 = 无标题栏窗口 + 纯 HStack 分栏**：`.windowStyle(.hiddenTitleBar)`，根布局 `HStack { sidebar | 1pt hairline | detail }` 而非 NavigationSplitView——后者会安装隐式 NSToolbar，即使 hiddenTitleBar 也保留 ~52pt 顶部安全区把内容压下去。detail 上 `.ignoresSafeArea(.container, edges: .top)` 回收 macOS 26 为红绿灯保留的 ~33pt 安全区，状态栏贴住窗口上沿。**两条红线**：① ignoresSafeArea 在 NavigationSplitView 结构下会引发"切页后状态栏整栏不绘制"，HStack 结构下已实测安全；② detail 的 `.background(Theme.background)` 是唯一背景绘制点，各页面不得自挂背景。窗口拖拽用 `isMovableByWindowBackground` 补回（WindowChromeFixer）；侧栏内容用 `safeAreaPadding(.top, 36)` 让出红绿灯区（代价：侧栏折叠开关随工具栏移除）。
14. **滚动方向语义**：滚动事件 delta 的符号描述**内容移动方向**（deltaX>0 = 内容右移，deltaY>0 = 内容下移），与自然滚动设置无关；自然滚动设置只改变手指方向与内容方向的关系。因此：**日历翻页等"内容跟随手指"的交互直接按 delta 符号映射，无需读设置**（自然开启=相册语义，关闭=轮式语义，都正确）；**上下滑"识别"标签用手指方向语义**，需读 `com.apple.swipescrolldirection` 换算（缺省=开启）。注意历史统计口径：方向语义修正前的 scrollUp/scrollDown 计数是镜像口径。
15. **自定义区间弹层**：选期为三段状态机——第 1 次点击选开始、第 2 次选结束（**不早于开始日期，允许同一天**）、第 3 次点击重置回选开始；`end >= start` 判定贯穿点击/键入/规范化/回填/应用五处。输入框一行排布，`parseFlexible` 接受 `2026-9-3`（缺前导零）与 `20260913`（8 位无分隔符），补零、超月收敛到月末、非法回退；同日端点合并标记「开始 · 结束」。打开弹层回填当前生效区间。
16. **日历跟手 pager**：三联网格（上一月 | 当前月 | 下一月）+ `dragOffset` 跟手位移；单月网格为 **Equatable 子视图**（比较 month/startDay/endDay，挂 `.equatable()`）——拖动中三者不变即跳过全网格重建，每帧只剩 offset 合成（跟手性能的关键）；网格用确定性 `Grid`（非 Lazy，防滑入 popping）。触发判定五路并行：位移 ≥ 面板宽 1/9（32pt）/ 快甩（预测终点 ≥ 1/4 宽且同向）/ 拖过面板 55% 中途翻页 / 双指动量满额延续带过阈值 / 都不满足弹回。**`gestureCommitted` 保证一次手势流只翻一页**，其生命周期必须覆盖 phase 流与 momentum 流的所有结束路径（漏复位会冻结 pager）。
17. **ForEach 身份唯一性红线**：日历网格的空占位格（nil）绝不能用 `Date?.self` 作 ForEach 身份——一行内多个 nil 共享身份会使 SwiftUI diff 未定义（实测：端点标记残留、区间带断档）。格子 id 用行内列下标。
18. **诊断钩子**（环境变量，仅开发验证用）：`INPUTSCAPE_PAGE=<page>` 指定初始页（首帧后切换——**init 阶段直接设 page 会导致状态栏不绘制**）、`INPUTSCAPE_RANGE=start:end` 应用区间、`INPUTSCAPE_OPEN_CUSTOM_RANGE=1` 开弹层、`INPUTSCAPE_PICKER_START=iso` 强制"已选开始待选结束"态。

## 七、已知边界与风险

- **F5/F6（听写/勿扰）无法计数**：默认系统设置下无公开可观察事件；用户开启「F1–F12 作为标准功能键」后可计数。
- **手势计数可能为 0**：缩放/滑动走 NSEvent 全局监听，macOS 对部分手势不投递（替代方案见 TOUCHPAD_PROPOSAL.md）。按键/点击/滚动/修饰键/媒体键走 CGEventTap，可靠。
- **Force Touch 阈值未标定**：pressure ≥ 1.5 经验值，需真机验证；设置页可关闭。
- **监听链路未做真机授权验证**：需在真实会话授权后确认计数、实时高亮、休眠挂起；F3/F4 特殊键码（130/131）在 macOS 26 的实际投递待确认。
- **ⓘ 提示为系统原生 Tooltip**：显示延迟与样式由系统控制（约 1s+），换取绝对稳定。
- F 行图标映射按 2021 MBP 文档口径，与实物出入只需改 `KeyboardLayoutSpec` 一处。
- **侧栏折叠开关已随工具栏移除**（无标题栏重构的取舍）：侧栏固定 200pt 常驻；窗口任意非交互区域可拖动。
- **触控板统计的 scrollUp/scrollDown 历史口径**：方向语义修正前的历史计数是镜像口径，与修正后数据混用（影响仅限历史图表中两类的相对高低，已确认接受）。
- **诊断钩子仅用于开发验证**（环境变量驱动），不影响正常使用。

## 八、下一步（按优先级）

1. **真机授权实测**：按键/修饰键/组合键/F 行媒体键计数、实时高亮、休眠挂起；确认 F3/F4 键码投递；顺带确认日历翻页手感与上下滑标签方向。
2. **键盘快照回归**：用 `scrollWhenNarrow` 离屏渲染管线生成 78 键基线图纳入测试（keyboard-preview.png 即管线产物）。
3. **触控板增强**：手势扩展 / 触点热力图 / 压感——方案与决策点见 `TOUCHPAD_PROPOSAL.md`，等用户拍板后实施。
4. **后续模板**：ISO / JIS / Magic Keyboard（设置页当前固定 US ANSI）。
5. **可选**：自定义暂停快捷键（KeyboardShortcuts 依赖需过审查）；数据保留策略。

## 九、开发阶段简史（详节见 git log）

| 阶段 | 时间 | 内容 |
| --- | --- | --- |
| 核心与首版 | 09-22 | 核心库（78 键主图 / 键码映射 / 聚合 / 存储 / 监听）、七页面 UI、三步引导、测试框架、首轮实测修复、组合键与媒体键闭环、自定义日期区间、Apple Development 证书签名链路 |
| 键盘 UI 精修 | 09-22 深夜 | 物理布局对齐实测 JSON、键帽样式逐键精修（半高方向键 / Unicode 字形 / 描边图标 / Touch ID 矩形键帽）、git 仓库建立 |
| 夜览与顶栏 | 09-23 上午 | 夜览模式（三档显示模式 + Theme 动态颜色 + 持久化）；顶栏重构（无标题栏 + HStack 分栏，状态栏贴顶）；侧栏 SF Symbol 图标 |
| 自定义区间弹层 | 09-23 | 弹层重做（输入框键盘输入 / 三段选期状态机 / 同日区间 / 跟手 pager 翻页动画）；滚动方向语义修复（上下滑标签 + 左右切月）；日历高亮双 bug 根因修复（ForEach 重复 id） |
