# Inputscape 交接文档

> macOS 14+ 本地输入习惯分析器 · 唯一交接主文档，随开发推进更新
> 设计契约：`INPUTSCAPE_DESIGN_PLAN.md`（用户 authored，改动需谨慎）
> 触控板扩展方案（待拍板）：`TOUCHPAD_PROPOSAL.md`
> 最近更新：2026-09-23（夜览深色模式 + Touch ID 矩形键帽）

---

## 一、项目概况

- **定位**：本地输入习惯分析工具。仅保存本地聚合统计，不记录文字内容、按键序列、应用名称、屏幕坐标或原始事件，无云同步。
- **首版范围**：内置键盘（Apple 无线键盘实测布局，78 键基准）+ 内置触控板；ISO/JIS/Magic Keyboard 为后续模板。
- **技术栈**：Swift 5.9 tools / Swift 6.3 编译器（CommandLineTools，Xcode 许可未接受）、SwiftUI + Swift Charts、CGEventTap（公开 API）、JSON 按日存储。
- **版本管理**：git 仓库（本目录），提交身份 Bintao / zfr45682@icloud.com；构建产物与 `.workbuddy/` 已 gitignore。

## 二、当前状态

**首版功能完成，48/48 测试通过，`build-release.sh` 一键构建/签名/启动。**

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| 键盘主图规范 | ✅ 完成 | 78 键唯一真值；物理布局对齐 `apple-wireless-keyboard.json` + 用户参考图（功能行 1.0357u、command 1.25u、space 5u、四方向键半高、右修饰键右对齐、fn 地球左下+字母右下、Touch ID 裸圆环、caps LED 点），三页共用同一渲染视图 |
| 键帽样式 | ✅ 完成 | 修饰键图标用标准 Unicode（⌘⌥⇧⌃⇪⌫⏎⇥），F1–F12 用 SF Symbols 描边图标；左侧修饰键左对齐、右侧 command/option 右对齐；数字/标点双层居中；键帽小圆角（0.09u）、画布四周 0.1u 留白 |
| 聚合引擎 | ✅ 完成 | 60s 输入段 / 5 分钟桶 / 跨天 / 预设周期与自定义起止快照 / 组合键计数 |
| 本地存储 | ✅ 完成 | 按日 JSON + 白名单 schema（date/keyCounts/comboCounts/trackpadCounts/buckets/hourlyByOp/activeSeconds），隐私测试守护 |
| 监听层 | ✅ 完成（待真机授权验证） | keyDown/keyUp + flagsChanged（修饰键含释放）+ systemDefined（F 行媒体键含释放）+ 特殊键码；只输出键位 ID / 操作类别 / 组合和弦 |
| 组合键统计 | ✅ 完成 | 修饰键按住 + 普通键按下 → 和弦（⌘C / ⇧⌘3 / 三键）；150ms 去抖；实时页 + 键盘分布 Top5 + 总览摘要 |
| 自定义统计区间 | ✅ 完成 | 竖向单月自绘日历，起止可同一天，全页面联动 |
| 实时跟手反馈 | ✅ 完成 | 三类键释放闭环，按下点亮缩放、松开即灭、无残留 |
| 七页面 UI | ✅ 完成 | 总览 / 键盘分布 / 触控板操作 / 使用趋势 / 实时观察 / 设置 + 三步引导；ⓘ 说明为 AppKit 原生 Tooltip |
| 夜览（深色）模式 | ✅ 完成 | 三档显示模式（开启/关闭/跟随系统）、Theme 动态颜色明暗双套色板、设置页分段控件、即时生效重启保持（M21，用户实现） |
| XCTest 测试 | ✅ 48/48 | 布局规范 14（含 JSON 等价性、方向键底对齐、高度归一）、聚合 11、存储 5、隐私 5、键码映射 8、外观模式 5 |

## 三、代码结构

```
monitor-dev/
├── Package.swift                    # SwiftPM：InputscapeKit + InputscapeApp + Tests
├── build-release.sh                 # ★ 一键：构建(exit 校验)→稳定签名→重启
├── run-tests.sh                     # ★ 一键测试（CLT + Xcode XCTest.framework 混编）
├── apple-wireless-keyboard.json     # ★ 键盘物理布局数据源（Apple Wireless Keyboard 实测，KLE 格式）
├── keyboard-preview.png             # 键盘布局离屏渲染预览图
├── Sources/InputscapeKit/           # 核心库（无 UI 依赖，可独立测试）
│   ├── KeyboardLayoutSpec.swift     # ★ 78 键主键盘图唯一真值（几何源自 JSON + KeyGlyph/KeycapStyle 逐键定义）
│   ├── KeyCodeMapper.swift          # kVK 键码→键位 ID + 媒体键/fn 改写键码映射 + ComboKeyBuilder
│   ├── AggregationEngine.swift      # 聚合：60s 输入段 / 288 桶 / 跨天 / 两种快照
│   ├── AggregateStore.swift         # 按日 JSON 存储（原子写、白名单 schema）
│   ├── EventMonitor.swift           # CGEventTap（主 run loop）+ 三类键事件分类 + 权限中心
│   └── Models.swift                 # DailyRecord / TimeBucket / LiveState / 快照等
├── Sources/InputscapeApp/           # SwiftUI 应用
│   ├── KeyboardHeatmapView.swift    # ★ 唯一键盘渲染视图（三页共用，键帽样式渲染 + 画布外边距）
│   ├── AppearanceManager.swift      # 夜览切换核心：NSApp.appearance 应用 + 系统深浅色监听
│   ├── AppModel.swift               # 主模型（状态/快照/持久化；高频事件不经此失效全树）
│   ├── LiveModel.swift              # 实时状态（pressedKeys/heldChips，按键只失效实时页）
│   ├── AppKitTooltip.swift          # ⓘ 原生 Tooltip 桥接（NSView.toolTip）
│   ├── AppearanceManager.swift      # 夜览切换核心：NSApp.appearance 应用 + 系统深浅色监听
│   ├── CustomRangePicker.swift      # 自定义日期区间（单月自绘日历）
│   ├── RootView.swift               # 侧栏导航 + 状态栏（最小窗口 1100×760）
│   └── …Views.swift                 # 总览/键盘/触控板/趋势/实时/设置/引导
└── Tests/InputscapeKitTests/        # 48 个 XCTest 用例
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

## 六、关键技术决策

1. **键盘唯一真值**：所有键盘页面从 `KeyboardLayoutSpec` 派生（KeyGlyph unicode/sfSymbol + KeycapStyle 逐键定义），禁止硬编码键位数组。物理布局源自 `apple-wireless-keyboard.json`（Apple Wireless Keyboard 实测，KLE 格式）：功能行 14 键 1.0357u、底行 command 1.25u / space 5u；几何等价性由 JSON 比对测试守护（容差 0.002）。对 JSON 的两处应用方修正：各行高度归一为字母键 1.0（JSON 功能行 0.75 / 底行 1.111 为 KLE 风格化值）、JSON 图标定义忽略（键帽字形沿用应用 UI）。
2. **键帽样式**：修饰键图标用标准 Unicode 字符（⌘ U+2318、⌥ U+2325、⇧ U+21E7、⌃ U+2303、⇪ U+21EA、⌫ U+232B、⏎ U+2324、⇥ U+21E5），方向键用 Unicode 三角（▲▼◀▶），F1–F12 用 SF Symbols 描边图标；fn 地球用 SF `globe`。左侧修饰键图标上/单词下左对齐，右侧 command/option 右对齐，fn 地球左下 + 字母右下同线。键帽小圆角（0.09u），画布四周 0.1u 外边距（画布 14.7×6.2u，纵横比经 `canvasAspectRatio` 暴露给调用方）。
3. **方向键**：四键全半高（↑ 顶对齐、←/↓/→ 底对齐，底边与行底平齐），箭头字形随半高缩小；对齐关系有测试断言（JSON 原始文件中方向键下移 0.111u 的 KLE hack 已归一）。
4. **三类键释放路径闭环**：普通键 keyUp / 修饰键 flagsChanged 标志位"移除"（CapsLock 按下与释放 flags 相同，用事件交替判定）/ 媒体键 0xB 帧——实时"按下中"状态与统计都依赖这三条路径完整。
5. **fn 按住会改写键码**（官方 Events.h）：fn+←/→/↑/↓ → Home 115/End 119/PageUp 116/PageDown 121，fn+delete → ForwardDelete 117；映射回物理方向键/Delete，保证 fn+⌃/⌘+方向键等组合可识别。
6. **媒体键解析**：`systemDefined(14) + subtype 8 + data1 位域`（高 16 位 NX_KEYTYPE、bits 8-15 = 0xA 按下 / 0xB 释放、bit 0 重复），KeyCastr/MediaKeyTap 标准方案；默认设置下 F1/F2/F7–F12 按此映射回物理键位，fn+F1（键码 122）同样计入——两种系统配置下统计一致。
7. **CGEventTap source 必须挂主 run loop**：挂后台线程时 HIToolbox 把 caps（中英文切换）长按 timer 装到同一 run loop，其主队列断言失败 → 按住 caps 直接 SIGTRAP 崩溃。
8. **组合键 = 和弦快照**：修饰键按住时按下的普通键，Apple 菜单顺序 ⌃⌥⇧⌘ 编码（如 ⇧⌘3）；只存和弦构成不存时间序列（comboCounts 白名单字段），150ms 同和弦去抖。
9. **ⓘ 提示用平台原生 `NSView.toolTip`**：悬停检测、延迟、定位、消失全由系统管理。
10. **性能**：高频事件（每次按键）只更新 LiveModel 与引擎计数，不触发主模型 `objectWillChange`；空闲秒数用 TimelineView 局部刷新。
11. **交付纪律**：`build-release.sh` 固化构建流程（构建退出码显式校验、失败输出日志并中止、稳定签名、重启冒烟）；构建命令禁止接管道后再链式执行（管道退出码会掩盖编译失败）。
12. **夜览（深色）模式走 AppKit 原生外观机制**：`Theme` 全部语义色改为 `NSColor(name:dynamicProvider:)` 动态颜色（明暗两套配对值），应用侧只改 `NSApp.appearance`（开启=darkAqua / 关闭=aqua / 跟随=nil）——外观变化由系统传播到所有窗口并触发动态颜色重解析，即时生效、无需重启，也不需要逐视图订阅 colorScheme。模式选择持久化在 UserDefaults（`Inputscape.AppearanceMode`），Kit 层枚举 + 存储可测（5 个用例）；唯一非 Theme 颜色（键帽 `Color.white`）已收敛为 `Theme.keycap`。新增颜色必须走 `Theme.dynamicColor(浅, 深)`，禁止引入静态色。
13. **顶部品牌区 = 无标题栏窗口 + 纯 HStack 分栏**：`.windowStyle(.hiddenTitleBar)`，根布局用 `HStack { sidebar | 1pt hairline | detail }` 而非 NavigationSplitView——后者会安装隐式 NSToolbar，即使 hiddenTitleBar 也保留 ~52pt 顶部安全区把内容压下去（顶部空白的根源）。detail 上 `.ignoresSafeArea(.container, edges: .top)` 回收 macOS 26 为红绿灯保留的 ~33pt 安全区，状态栏贴住窗口上沿。**两条红线**：① ignoresSafeArea 在 NavigationSplitView 结构下曾引发"切页后状态栏整栏不绘制"（占位保留、内容消失），HStack 结构下已实测切页安全；② detail 的 `.background(Theme.background)` 是唯一背景绘制点，各页面不得自挂背景。窗口拖拽用 `isMovableByWindowBackground` 补回（WindowChromeFixer）；侧栏内容用 `safeAreaPadding(.top, 36)` 让出红绿灯区（代价：侧栏折叠开关随工具栏移除）。逐页验证钩子：`INPUTSCAPE_PAGE=<page>` 环境变量在首帧后切页（RootView.onAppear），**禁止在 init 阶段直接设 page**（同样触发状态栏不绘制）。

## 七、里程碑简史（详节见 git log）

| # | 时间 | 内容 |
| --- | --- | --- |
| M1 | 09-22 上午 | 核心库：78 键主图规范、键码映射、聚合引擎、JSON 存储 |
| M2 | 09-22 中午 | 七页 UI + 三步引导 + Swift Charts + 8 个必须状态 |
| M3 | 09-22 下午 | XCTest 套件 + 打包 .app |
| M4 | 09-22 下午 | 首轮实测修复（键帽文案 / 键盘画布对齐 / 窗口布局） |
| M5 | 09-22 傍晚 | 修饰键 / 组合键 / F 行媒体键识别；LiveModel 性能拆分 |
| M6 | 09-22 晚 | 自定义日期区间 + 实时跟手反馈 |
| M7 | — | **待实施**：触控板增强（见 TOUCHPAD_PROPOSAL.md） |
| M8 | 09-22 17:2x | caps 长按崩溃修复、fn 改写键码补全、实时观察页合并、自绘日历 |
| M9 | 09-22 18:2x | 修饰键释放闭环（flagsChanged 补释放 + CapsLock 交替判定） |
| M10 | 09-22 18:4x | 授权持久化（Apple Development 证书）+ build-release.sh |
| M11 | 09-22 20:0x | 媒体键释放闭环；ⓘ 提示收敛为平台原生 Tooltip |
| M12 | 09-22 20:5x | 键盘对齐用户参考图（半高方向键 / Unicode 字形 / 键帽样式模型）+ git 仓库建立 |
| M13 | 09-22 22:0x | 物理布局对齐 apple-wireless-keyboard.json + JSON 等价性测试 |
| M14–M20 | 09-22 22:2x–23:1x | 键帽样式精修：小圆角、右侧修饰键右对齐、fn 分角布局与基线对齐、F6–F12 描边图标、画布四周外边距 |
| M21 | 09-23 00:1x | 夜览（深色）模式：三档显示模式（开启/关闭/跟随系统）、Theme 动态颜色明暗双套色板、设置页分段控件、UserDefaults 持久化重启保持、即时切换无需重启；测试 43→48 |
| M22 | 09-23 10:5x | Touch ID 改为与字母键一致的矩形键帽 + 居中指纹圆环；键帽填充接入 Theme.keycap |
| M23 | 09-23 11:2x | 侧栏分割线（1pt Theme.hairline 挂侧栏列 trailing，明暗自适应）+ 隐藏标题栏窗口标题（windowToolbarStyle showsTitle:false，消除与状态栏品牌行的重复标识） |
| M24 | 09-23 11:5x | 顶栏结构合并为一栏：标题栏透明 + toolbarBackground 隐藏（消除系统材质带与分隔线）；F3 图标改 `square.stack.3d.up`（对齐调度中心"多窗平铺"语义） |
| M25 | 09-23 13:3x | 顶部空白根治：`.hiddenTitleBar` + 纯 HStack 分栏替代 NavigationSplitView（其隐式 NSToolbar 保留 ~52pt 安全区压低内容）；状态栏贴顶、切页安全；`INPUTSCAPE_PAGE` 环境变量诊断钩子 |

## 八、已知边界与风险

- **F5/F6（听写/勿扰）无法计数**：默认系统设置下无公开可观察事件；用户开启「F1–F12 作为标准功能键」后可计数。
- **手势计数可能为 0**：缩放/滑动走 NSEvent 全局监听，macOS 对部分手势不投递（替代方案见 TOUCHPAD_PROPOSAL.md）。按键/点击/滚动/修饰键/媒体键走 CGEventTap，可靠。
- **Force Touch 阈值未标定**：pressure ≥ 1.5 经验值，需真机验证；设置页可关闭。
- **监听链路未做真机授权验证**：需在真实会话授权后确认计数、实时高亮、休眠挂起；F3/F4 特殊键码（130/131）在 macOS 26 的实际投递待确认。
- **ⓘ 提示为系统原生 Tooltip**：显示延迟与样式由系统控制（约 1s+），换取绝对稳定。
- F 行图标映射按 2021 MBP 文档口径，与实物出入只需改 `KeyboardLayoutSpec` 一处。

## 九、下一步（按优先级）

1. **真机授权实测**：按键/修饰键/组合键/F 行媒体键计数、实时高亮、空闲时长、休眠挂起；确认 F3/F4 键码投递。
2. **键盘快照回归**：用 `scrollWhenNarrow` 离屏渲染管线生成 78 键基线图纳入测试（keyboard-preview.png 即管线产物）。
3. **触控板增强**：手势扩展 / 触点热力图 / 压感——方案与决策点见 `TOUCHPAD_PROPOSAL.md`，等用户拍板后实施。
4. **后续模板**：ISO / JIS / Magic Keyboard（设置页当前固定 US ANSI）。
5. **可选**：自定义暂停快捷键（KeyboardShortcuts 依赖需过审查）；数据保留策略。
