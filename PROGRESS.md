# Inputscape 交接文档

> macOS 14+ 本地输入习惯分析器 · 唯一交接主文档，随开发推进更新
> 设计契约：`INPUTSCAPE_DESIGN_PLAN.md`（用户 authored，改动需谨慎）
> 触控板扩展方案：`TOUCHPAD_PROPOSAL.md`（压感 / 热力图已实施；手势口径已收缩）
> 最近更新：2026-09-24（热力图 96×64 双显示模式、按压强度直方图、数据页自动刷新、实时触控板）
> 本文件只保留**最终状态与决策**；完整迭代历史见 git log

---

## 一、项目概况

- **定位**：本地输入习惯分析工具。仅保存本地聚合统计，不记录文字内容、按键序列、应用名称、屏幕坐标或原始事件，无云同步。
- **首版范围**：内置键盘（Apple Wireless Keyboard 实测布局，78 键基准）+ 内置触控板；ISO/JIS/Magic Keyboard 为后续模板。
- **技术栈**：Swift 5.9 tools / Swift 6.3 编译器（CommandLineTools，Xcode 许可未接受）、SwiftUI + Swift Charts、CGEventTap（公开 API）、JSON 按日存储。
- **版本管理**：git 仓库（本目录），提交身份 Bintao / zfr45682@icloud.com；构建产物与 `.workbuddy/` 已 gitignore。

## 二、当前状态

**首版功能完成 + 触控板增强（压感 / 热力图）已实施。65/65 测试通过，`build-release.sh` 一键构建/签名/启动。**

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| 键盘主图规范 | ✅ 完成 | 78 键唯一真值；物理布局对齐 `apple-wireless-keyboard.json`（功能行 1.0357u、command 1.25u、space 5u、四方向键半高、右修饰键右对齐、fn 地球左下+字母右下、Touch ID 矩形键帽+居中指纹圆环、caps LED 点），三页共用同一渲染视图；F3 = `rectangle.3.group` |
| 键帽样式 | ✅ 完成 | 修饰键图标用标准 Unicode（⌘⌥⇧⌃⇪⌫⏎⇥），F1–F12 用 SF Symbols 描边图标；左侧修饰键图标上/单词下左对齐、右侧 command/option 右对齐；数字/标点双层居中；键帽小圆角（0.09u）、画布四周 0.1u 留白 |
| 聚合引擎 | ✅ 完成 | 60s 输入段 / 5 分钟桶 / 跨天 / 预设周期与自定义起止快照（含同日区间）/ 组合键计数 / 手指压力 20 桶直方图 / 触点 96×64 网格聚合 |
| 本地存储 | ✅ 完成 | 按日 JSON + 白名单 schema（date/keyCounts/comboCounts/trackpadCounts/buckets/hourlyByOp/activeSeconds/touchGrid/touchPressureHistogram），隐私测试守护；增量字段旧 JSON 容缺解码，旧 384 格网格解码/合并时自动 4×4 上采样迁移 |
| 监听层 | ✅ 完成（待真机授权验证） | keyDown/keyUp + flagsChanged（修饰键含释放）+ systemDefined（F 行媒体键含释放）+ 特殊键码；**全事件 tap 过滤官方手势事件**（smartMagnify/swipe 直计）；只输出键位 ID / 操作类别 / 组合和弦 |
| 组合键统计 | ✅ 完成 | 修饰键按住 + 普通键按下 → 和弦（⌘C / ⇧⌘3 / 三键）；150ms 去抖；实时页 + 键盘分布 Top5 + 总览摘要 |
| 触控板操作统计 | ✅ 完成（待真机验证） | 官方事件直计口径：点击/上滚/下滚/智能缩放/滑动/Force Touch + zoom（历史口径，仅旧数据可见）；**按压强度分布卡**（手指连续压力 20 桶直方图 + 轻/中/深汇总 + 平均压力）；`supportsForceTouch=false` 时该卡隐藏 |
| 触点热力图 | ✅ 完成（待真机验证） | TouchpointMonitor：MultitouchSupport 私有框架最小桥（接口事实取自 calftrail/Touch、M5MultitouchSupport、Kyome22/OpenMultitouchSupport）；触点归一化坐标 → 96×64 网格按日聚合（旧 384 格自动迁移）；**双显示模式**（设置页切换）：「网格 24×16」降采样方块 / 「连续 96×64」高斯扩散无级热力面；数据页 3 秒自动刷新 + 三页刷新按钮 |
| 实时触控板 | ✅ 完成 | 实时观察页新增触控板卡：当前接触手指位置圆点实时显示，大小/透明度随手指压力变化；MT 回调 125Hz 只更新内存缓存，30Hz 合并发布（避免实时页按回报率重绘）；暂停/撤销权限即清空 |
| 自定义统计区间 | ✅ 完成 | 三段状态机（开始 → 结束不早于开始，**允许同一天** → 点击重置）；开始/结束输入框一行排布，支持键入 `YYYY-MM-DD` / 缺前导零 / `20260913` 八位无分隔符（补零、超月收敛、非法回退）；日历跟手 pager 翻页（拖拽/双指横扫/箭头，方向性滑动过渡）；端点带「开始/结束」标记；标题按区间显示中文日期（跨年补年份） |
| 实时反馈 | ✅ 完成 | 三类键释放闭环，按下点亮缩放、松开即灭、无残留 |
| 七页面 UI | ✅ 完成 | 总览 / 键盘分布 / 触控板操作 / 使用趋势 / 实时观察 / 设置 + 三步引导；侧栏每项带 SF Symbol 图标；ⓘ 说明为 AppKit 原生 Tooltip |
| 夜览模式 | ✅ 完成 | 设置页三档显示模式（开启夜览 / 关闭夜览 / 跟随系统），UserDefaults 持久化、重启保持；`Theme` 全量语义色动态化（明暗双套色板），切换即时生效无需重启 |
| XCTest 测试 | ✅ 65/65 | 布局规范 14（含 JSON 等价性、方向键底对齐、高度归一）、聚合 11、存储 5、隐私 5、键码映射 8、显示模式 5、触控板增强 17（压力分档/直方图/网格映射/旧网格迁移/白名单） |

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
│   ├── AggregationEngine.swift      # 聚合：60s 输入段 / 288 桶 / 跨天 / 两种快照 / 压力直方图 / 触点网格
│   ├── AggregateStore.swift         # 按日 JSON 存储（原子写、白名单 schema）
│   ├── EventMonitor.swift           # CGEventTap（全事件掩码，主 run loop）+ 键盘/官方手势/压力分类 + 权限中心
│   ├── TouchpointMonitor.swift      # ★ MultitouchSupport 最小桥（@_silgen_name 绑定 + MTTouch 布局转写 + 全局回调路由）
│   └── Models.swift                 # DailyRecord / TimeBucket / PressureTier / LiveState / 快照等
├── Sources/InputscapeApp/           # SwiftUI 应用
│   ├── KeyboardHeatmapView.swift    # ★ 唯一键盘渲染视图（三页共用，键帽样式渲染 + 画布外边距）
│   ├── AppearanceManager.swift      # 夜览切换核心：NSApp.appearance 应用 + 系统深浅色监听
│   ├── WindowChrome.swift           # 无标题栏窗口的拖拽补回（isMovableByWindowBackground）
│   ├── AppModel.swift               # 主模型（状态/快照/持久化；高频事件不经此失效全树）+ 触点监听生命周期
│   ├── LiveModel.swift              # 实时状态（pressedKeys/heldChips，按键只失效实时页）
│   ├── AppKitTooltip.swift          # ⓘ 原生 Tooltip 桥接（NSView.toolTip）
│   ├── CustomRangePicker.swift      # ★ 自定义区间弹层（三段状态机 + 键盘输入 + 跟手 pager）
│   ├── RootView.swift               # HStack 分栏（侧栏 | 分割线 | 内容）+ 状态栏 + 诊断钩子
│   ├── Theme.swift                  # ★ 全量语义色（NSColor dynamicProvider 明暗双套色板）
│   ├── Components.swift             # 卡片 / 周期切换 / 状态横幅 / 空状态 / Tooltip 标记
│   ├── OverviewAndKeyboardViews.swift   # 总览 + 键盘分布
│   ├── TrackpadAndTrendsViews.swift     # 触控板操作（构成/时段/压力/热力/排行） + 使用趋势
│   └── LiveSettingsOnboardingViews.swift # 实时观察 + 设置 + 首次引导
└── Tests/InputscapeKitTests/        # 62 个 XCTest 用例（6 个文件）
```

## 四、构建 / 测试 / 运行

```bash
./build-release.sh   # 一键：release 构建（exit 校验）→ 稳定签名 → 重启
./run-tests.sh       # 62 个测试（CLT 编 Kit + Xcode XCTest.framework 链接 + xctest 运行器）
```

- 签名用钥匙串中的 **Apple Development 证书**（TeamID Y99GV96XD6）——签名身份稳定，**TCC 授权跨构建保留**；ad-hoc 签名（`-s -`）会每次重置授权，已弃用。证书约 1 年有效期，续订后需再授权一次。
- 签名/codesign 访问钥匙串，沙箱内会被拦，需非沙箱执行。
- 运行前置：系统设置 › 隐私与安全性 › 输入监听 + 辅助功能（启动时未授权会自动弹申请）。
- **MultitouchSupport 私有框架链接**（TouchpointMonitor）：Package.swift 用 `unsafeFlags`、run-tests.sh 用 `-F /System/Library/PrivateFrameworks -framework MultitouchSupport`——路径不带 SDK 前缀，链接器自动以 sysroot 前缀化，升级 SDK 无需改动。历史上触点采集无需额外 TCC 权限，需真机确认。

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
18. **诊断钩子**（环境变量，仅开发验证用）：`INPUTSCAPE_PAGE=<page>` 指定初始页（首帧后切换——**init 阶段直接设 page 会导致状态栏不绘制**）、`INPUTSCAPE_RANGE=start:end` 应用区间、`INPUTSCAPE_OPEN_CUSTOM_RANGE=1` 开弹层、`INPUTSCAPE_PICKER_START=iso` 强制"已选开始待选结束"态、`INPUTSCAPE_DEBUG_EVENTS=1` 开启事件探针（tap 看到的 keyDown 键码与全部 systemDefined 事件落 /tmp/inputscape-events.log，用于特殊功能键投递形态排查；触控板增强后兼记手势与压力事件数值，作为 `.pressure` 全局可达性探针）。
19. **触控板手势走全事件 tap，只消费官方事件直计类别**（2026-09-24 定稿）：系统不向 `NSEvent.addGlobalMonitorForEvents` 投递手势事件（旧路线计数恒 0），但对 listen-only CGEventTap 会以原始数值类型投递，与 NSEvent 手势类型同号（smartMagnify 32 / swipe 31，来源 AppKit NSEvent.h + SO #1383528 / rift 路线，全公开 API）。tap 掩码为 `~0`，回调按 rawValue 过滤（过滤集用 `NSEvent.EventType` 运行时取值构造）后 `NSEvent(cgEvent:)` 转换；非手势事件只付一次 switch + 集合查找。**NSEvent 全局手势监听已删除。**
20. **手势口径收缩（2026-09-24 用户决策）**：只保留「Apple 官方事件直接计数」——smartZoom（smartMagnify 事件）与 swipe（swipe 事件），收到即计 1 次，无任何自定义判定逻辑；缩放分向 / 旋转 / 横滚 / 滚动会话等自定义识别口径（及 GestureSessionTracker）已全部删除、无残留。真机验证后若 smartMagnify/swipe 投递不可靠，整组事件级手势也可下线。历史口径：`zoom` 保留为「缩放（历史）」，旧数据可见、不再新增。
21. **点击压力三档直方图 + Force Touch 联动**：leftMouseDown 的 `kCGMouseEventPressure` 按 `PressureTier` 分轻（<0.4）/ 中（0.4–0.9）/ 深（≥0.9），**深按档阈值即 Force Touch 计数阈值**（替换未标定的 1.5 经验值——旧阈值形同虚设；0.4/0.9 仍待真机标定）。存储为 DailyRecord 白名单字段 `pressureTierCounts` + `pressureSumMilli`（压力×1000 整数和，展示平均压力）；压力是点击的派生维度：**不进 5 分钟桶 / 时段分布 / 活跃输入段**（与组合键同口径），旧 JSON 用 `decodeIfPresent` 容缺解码。设置开关 `supportsForceTouch` 真正生效：关闭时引擎停采压力、深按不计数、触控板页压力卡整卡隐藏。
22. **触点热力图 = MultitouchSupport 最小桥（2026-09-24 用户授权）**：不引第三方依赖，Kit 内 `@_silgen_name` 绑定 + Swift 转写 MTTouch 布局——接口事实取自三个成熟开源实现（calftrail/Touch 的头文件、M5MultitouchSupport、Kyome22/OpenMultitouchSupport，代码注释保留出处），链接走 `-F /System/Library/PrivateFrameworks`（sysroot 相对路径，SDK 升级免改）。要点：回调无 refcon，经全局路由表派发；只消费 state 3(making)/4(touching)（接触）与 5/6/7（离开信号），输出归一化坐标 + 手指压力（`TouchSample`）；`@convention(c)` 签名不能含 Swift struct → 传 `UnsafeMutableRawPointer` 按 stride load，start 时断言 `MemoryLayout<MTTouchC>.stride == 96` 守护布局；`MTDeviceCreateList` 的 +1 由 Swift ARC 接管（CFRelease 不可用）。引擎只做 96×64 格子累加（不进桶/时段/活跃段），触点数据靠 5s 结算定时器节流落盘（MT 回调高频，不进保存热路径）。
23. **触控板构成卡只显示有数据的类别**，占比按有数据部分归一；压力分布卡与热力图卡均含 ⓘ 说明 + 数字/文字读数（不只依赖颜色）；热力图网格模式为 Canvas 单次绘制，连续模式为格点 Canvas + `.blur` 扩散（边框/选中格走独立不模糊层，clipShape 防溢出）。
24. **按压强度数据源切换（2026-09-24）**：旧方案 kCGMouseEventPressure（leftMouseDown 点击瞬间标量）多数触控板恒值无区分度 → 已废弃；改用 **MTTouch 手指连续压力**（0–1，接触中每帧一条，按帧累计 = 按压时长权重）进 20 桶直方图（0.05 步进），轻/中/深阈值 0.25/0.55（恰好对齐桶边界），`INPUTSCAPE_DEBUG_TOUCH=1` 探针核对真机值域后校准。Force Touch 深按判定（kCGMouseEventPressure 口径）独立保留：`EventMonitor.forceTouchClickThreshold = 0.9`，与手指压力档值域不同、禁止联动。旧 pressureTierCounts/pressureSumMilli 字段删除，旧数据无信息量直接弃用。
25. **热力图双显示模式**：数据层统一 96×64（6144 格，一格约 1.7mm）；设置页「触点热力图显示模式」二选一——「网格 24×16」（4×4 降采样方块，首版视觉）与「连续 96×64」（高斯扩散无级热力面，默认）；旧 384 格数据解码/合并时自动 4×4 上采样迁移（余数按块顺序补齐），上采样→降采样往返守恒。无独立开关：热力图随观察状态自动启停（确认设备 + 权限齐备 + 正在观察）。
26. **数据页自动刷新 + 手动刷新**：总览/键盘/触控板三页 3 秒定时 refresh()（仅当正在观察且页面可见；实时页/设置页不刷），切页到数据页立即刷新一次；三页 header 各有「刷新」按钮（`RefreshButton`）即时重算。此前 UI 只在切周期/删数据时重算快照，是"更新延迟"的根因。
27. **实时触控板 30Hz 合并发布**：MT 回调（~125Hz）只写 LiveModel 内存缓存，30Hz Timer 统一发布 `touchDots`——实时页触点圆点位置/大小/透明度随手指压力实时变化，避免按回报率重绘；暂停/撤销权限/退出即清空。

## 七、已知边界与风险

- **F5/F6（听写/勿扰）无法计数**：默认系统设置下无公开可观察事件；用户开启「F1–F12 作为标准功能键」后可计数。
- **官方手势 / 压力阈值待真机标定**：smartMagnify/swipe 经全事件 tap 的实际投递、手指压力三档阈值（0.25/0.55）与 Force Touch 点击阈值（0.9）都需真机确认或校准——`INPUTSCAPE_DEBUG_TOUCH=1` 记录手指压力值域、`INPUTSCAPE_DEBUG_EVENTS=1` 记录点击压力与手势事件。若 smartMagnify/swipe 投递不可靠，事件级手势整组下线。按键/点击/滚动/修饰键/媒体键走 CGEventTap，可靠。
- **触点热力图待真机验证**：MultitouchSupport 历史上无需额外 TCC 权限、接口十余年稳定，但 macOS 大版本更新可能失效——失效时自动空态，不影响其他功能；触点坐标方向（y 上→下）与手指压力值域以真机数据核对一次。
- **监听链路未做真机授权验证**：需在真实会话授权后确认计数、实时高亮、休眠挂起；F3/F4 特殊键码（130/131）在 macOS 26 的实际投递待确认。
- **ⓘ 提示为系统原生 Tooltip**：显示延迟与样式由系统控制（约 1s+），换取绝对稳定。
- F 行图标映射按 2021 MBP 文档口径，与实物出入只需改 `KeyboardLayoutSpec` 一处。
- **侧栏折叠开关已随工具栏移除**（无标题栏重构的取舍）：侧栏固定 200pt 常驻；窗口任意非交互区域可拖动。
- **触控板统计的 scrollUp/scrollDown 历史口径**：方向语义修正前的历史计数是镜像口径，与修正后数据混用（影响仅限历史图表中两类的相对高低，已确认接受）。
- **诊断钩子仅用于开发验证**（环境变量驱动），不影响正常使用。

## 八、下一步（按优先级）

1. **真机授权实测**：按键/修饰键/组合键/F 行媒体键计数、实时高亮、休眠挂起；确认 F3/F4 键码投递；**触控板增强真机标定**：`INPUTSCAPE_DEBUG_TOUCH=1` 核对手指压力值域（校准 0.25/0.55）与坐标方向、`INPUTSCAPE_DEBUG_EVENTS=1` 确认 smartMagnify/swipe 投递与点击压力（校准 0.9）；热力图两种显示模式与实时触控板手感。
2. **键盘快照回归**：用 `scrollWhenNarrow` 离屏渲染管线生成 78 键基线图纳入测试（keyboard-preview.png 即管线产物）。
3. **后续模板**：ISO / JIS / Magic Keyboard（设置页当前固定 US ANSI）。
4. **可选**：自定义暂停快捷键（KeyboardShortcuts 依赖需过审查）；数据保留策略；连续压力随时间的按压曲线（数据源已就绪）。

## 九、开发阶段简史（详节见 git log）

| 阶段 | 时间 | 内容 |
| --- | --- | --- |
| 核心与首版 | 09-22 | 核心库（78 键主图 / 键码映射 / 聚合 / 存储 / 监听）、七页面 UI、三步引导、测试框架、首轮实测修复、组合键与媒体键闭环、自定义日期区间、Apple Development 证书签名链路 |
| 键盘 UI 精修 | 09-22 深夜 | 物理布局对齐实测 JSON、键帽样式逐键精修（半高方向键 / Unicode 字形 / 描边图标 / Touch ID 矩形键帽）、git 仓库建立 |
| 夜览与顶栏 | 09-23 上午 | 夜览模式（三档显示模式 + Theme 动态颜色 + 持久化）；顶栏重构（无标题栏 + HStack 分栏，状态栏贴顶）；侧栏 SF Symbol 图标 |
| 自定义区间弹层 | 09-23 | 弹层重做（输入框键盘输入 / 三段选期状态机 / 同日区间 / 跟手 pager 翻页动画）；滚动方向语义修复（上下滑标签 + 左右切月）；日历高亮双 bug 根因修复（ForEach 重复 id） |
| 触控板增强 ①② | 09-24 | 手势扩展（全事件 tap + 手势过滤：缩放分向/旋转/智能缩放/轻扫/横滚/滚动会话）+ 点击压力三档直方图与 Force Touch 阈值联动（0.9）；压力分布卡；存储白名单加 pressureTierCounts/pressureSumMilli（旧 JSON 容缺）；测试 48→64。分支 `feature/trackpad-enhancement` |
| 热力图 + 口径收缩 | 09-24 | 用户实测反馈识别不准后拍板：**删除全部自定义手势识别**（缩放分向/旋转/横滚/滚动会话/GestureSessionTracker，仅留官方 smartMagnify/swipe 事件直计）；**触点热力图转正**——MultitouchSupport 最小桥（接口事实取自 calftrail/M5/Kyome22）+ 网格聚合 + 热力卡 UI + touchGrid 白名单字段；设计契约 §7/§9 边界按授权修订 |
| 热力 96×64 + 实时触控板 | 09-24 | 用户确认四项改进：**热力图数据层升 96×64**（旧 384 格自动上采样迁移，设置页双显示模式「网格 24×16 / 连续 96×64」高斯扩散无级渲染，去实验性标识无开关）；**按压强度换数据源**（MTTouch 手指连续压力 20 桶直方图按帧聚合，阈值 0.25/0.55，废弃无区分度的 kCGMouseEventPressure，Force Touch 阈值 0.9 独立标定）；**数据页 3 秒自动刷新 + 三页刷新按钮**（根因：UI 无周期刷新机制）；**实时观察页触控板卡**（触点圆点随压力，125Hz 缓存 30Hz 发布）；测试 62→65 |
