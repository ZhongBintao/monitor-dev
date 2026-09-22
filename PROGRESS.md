# Inputscape 项目进度

> macOS 本地输入习惯分析器 · 依据 `INPUTSCAPE_DESIGN_PLAN.md` 实现
> 本文件记录开发进度，随开发推进更新。最近更新：2026-09-22（M13 ⓘ 回归平台原生 Tooltip，删除自研悬浮窗）

---

## 一、项目概况

- **定位**：面向 macOS 14+ 的本地输入习惯分析工具。仅保存本地聚合统计，不记录文字内容、按键序列、应用名称、屏幕坐标或原始事件，无云同步。
- **首版范围**：内置键盘（MacBook Pro 14/16″ US ANSI，78 键基准）+ 内置触控板；ISO/JIS/Magic Keyboard 为后续模板。
- **技术栈**：Swift 5.9（tools）/ Swift 6.3 编译器、SwiftUI + Swift Charts、CGEventTap（公开 API）、JSON 按日存储（首版数据量小，暂不引入 GRDB）。

## 二、当前状态

**✅ 首版功能开发完成，35/35 测试通过，已打包可运行（`build/Inputscape.app`）。**

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| 键盘主图规范 | ✅ 完成 | 78 键 US ANSI 唯一真值，三页共用同一渲染视图 |
| 聚合引擎 | ✅ 完成 | 输入段 / 5 分钟桶 / 跨天 / 周期快照 / 组合键计数 |
| 本地存储 | ✅ 完成 | 按日 JSON + 字段白名单（含 comboCounts），隐私测试守护 |
| 监听层 | ✅ 完成（待真实授权验证） | keyDown + flagsChanged（修饰键）+ systemDefined（F 行媒体键）+ 特殊键码，只输出键位 ID / 操作类别 / 组合和弦 |
| 组合键统计 | ✅ 完成 | ⌘C / ⇧⌘3 / 三键和弦；实时页 + 键盘分布 Top5 + 总览摘要展示 |
| 自定义统计区间 | ✅ 完成 | 任意起止（可同一天）双日历选择；全页面联动 |
| 实时跟手反馈 | ✅ 完成 | keyUp 感知、按压缩放动画、按下中/已松开状态 |
| 七页面 UI | ✅ 完成 | 总览 / 键盘分布 / 触控板操作 / 使用趋势 / 实时观察 / 设置 + 三步引导 |
| 必须状态覆盖 | ✅ 完成 | 无数据 / 权限拒绝 / 设备未识别 / 暂停 / 休眠 / 空闲 / Force Touch 不可用 / 删除确认 |
| XCTest 测试 | ✅ 40/40 通过 | 布局规范 12、聚合 11、存储 5、隐私 5、键码映射 7 |

## 三、代码结构

```
monitor-dev/
├── Package.swift                    # SwiftPM：InputscapeKit + InputscapeApp + Tests
├── run-tests.sh                     # 一键测试（绕过 Xcode 许可，见 §六）
├── build/Inputscape.app             # 可直接打开的成品（ad-hoc 签名）
├── Sources/InputscapeKit/           # 核心库（无 UI 依赖，可独立测试）
│   ├── KeyboardLayoutSpec.swift     # ★ 78 键主键盘图唯一真值
│   ├── KeyCodeMapper.swift          # kVK 键码 → 键位 ID（未收录一律丢弃）
│   ├── AggregationEngine.swift      # 聚合：60s 输入段 / 288 桶 / 跨天 / 快照
│   ├── AggregateStore.swift         # 按日 JSON 存储（原子写、白名单 schema）
│   ├── EventMonitor.swift           # CGEventTap 监听 + NSEvent 手势 + 权限中心
│   └── Models.swift                 # DailyRecord / TimeBucket / LiveState 等
├── Sources/InputscapeApp/           # SwiftUI 应用
│   ├── KeyboardHeatmapView.swift    # ★ 唯一键盘渲染视图（三页共用）
│   ├── AppModel.swift               # 单向数据流主模型（@MainActor）
│   ├── RootView.swift               # 侧栏导航 + 状态栏（最小窗口 1100×760）
│   └── …Views.swift                 # 总览/键盘/触控板/趋势/实时/设置/引导
└── Tests/InputscapeKitTests/        # 35 个 XCTest 用例
```

## 四、已完成的里程碑

### M1 核心库与规范（2026-09-22 上午）
- 78 键主键盘图：6 行 14/14/14/13/12/11，行宽统一 14.5u；Tab/Delete 1.5u、Caps/Return 1.75u、Shift 2.25u、Space 5.5u；Touch ID 与 delete 右缘对齐且不可观察；方向键左右全高、上下半高堆叠；Cmd/X 右对齐、数字行双层标注左对齐、F/J 凸点、修饰键图标+文字。
- 键码映射表（kVK_* 公开常量），第三方/小键盘键码一律丢弃。
- 聚合引擎与存储落地，隐私白名单 schema（date/keyCounts/trackpadCounts/buckets/hourlyByOp/activeSeconds）。

### M2 应用与页面（2026-09-22 中午）
- 七页面 + 三步引导（隐私承诺 → 权限申请 → 键盘模板确认）。
- Swift Charts：镜像节奏图（键盘上/触控下）、时段分布、逐日对比。
- 8 个必须状态横幅；删除今日/全部数据二次确认；减少动效开关。

### M3 测试与打包（2026-09-22 下午）
- 35 个 XCTest 全部通过（`./run-tests.sh`）。
- release 构建 + 手工组装 .app（Info.plist）+ ad-hoc codesign + 启动冒烟通过。

### M4 实测修复（2026-09-22 下午，用户实测反馈三轮）
1. **Minus 键下层字符写成 "Minus"**（测试抓出）+ 7 天快照多算一天 → 已修。
2. **键盘整体错位**：画布 frame 默认 `.center` 对齐而 ZStack 自然尺寸只有最大子键 → 键区右下漂移。修复 = 显式 `.topLeading`。连带修：X 键右对齐、command 文字截断、minUnit 38→34。
3. **窗口内容超宽被裁**：detail 列误设 minWidth 1100（+侧栏 200 = 1300 > 窗口 1100）→ 右侧/顶部被裁。修复 = min 尺寸只留根视图。连带修两个状态机 bug（重启后监听不启动、引导完成不落状态）+ 监听器防重复启动。

### M8 界面与交互优化（2026-09-22 17:2x–18:1x，用户实测反馈四项）
1. **caps（中英文切换）长按崩溃修复**：崩溃日志定位为 HIToolbox `TSMAdjustCapsLockPressAndHold → dispatch_assert_queue_fail`（SIGTRAP）——caps 长按的辅助处理 timer 被 HIToolbox 装到了 tap 所在的 run loop，而后台线程不满足其主队列断言。修复 = CGEventTap source 挂到**主 run loop**（.commonModes）并移除专用线程；tap 回调本身极轻，主线程开销可忽略。
2. **组合识别补全（先联网梳理再实现）**：查证 Apple 官方 Events.h kVK 常量——fn 按住时系统改写键码（fn+←→Home 115、fn+→→End 119、fn+↑→PageUp 116、fn+↓→PageDown 121、fn+delete→ForwardDelete 117），这些键码此前不在映射表，导致 fn+⌃/⌘+方向键整个组合丢失。已全部映射回物理键位；组合机制（flags 和弦 × 键码表）本身是通用的，键码表补全后所有修饰键组合（含三键）均可识别。
3. **实时观察页重构**：「当前按键」与「当前组合」两卡合并为「当前按下的键」——按住的修饰键 / 普通键即时显示为紫底徽章（修饰键单独按住显示符号，与普通键同按显示和弦如 ⇧⌘5），松开即消失，无"按下中/已松开"标识；虚拟键盘不再保留"最后一次按键"的残留高亮，完全跟随 pressedKeys。
4. **自定义区间日历重设计**：改为竖向堆叠的单月自绘日历（约 320pt 宽）——顶部「开始 / 结束」模式胶囊显示已选日期，选完开始自动切到结束；月份可前后翻页（未来月份禁用）；区间中间浅紫带、两端实心紫圆、未来日期灰显不可点、起止可同一天。
5. **截断说明统一改 Tooltip**：新增 HelpMarker（标题旁 ⓘ，.help 悬浮全文）——实时页键盘卡/监听状态卡、键盘分布组合说明、总览节奏图说明等不再被截断。
6. 测试 41/41（新增 fn 改写键码映射用例）。

### M9 修饰键残留修复 + Tooltip（2026-09-22 18:2x，用户实测反馈两项）
1. **严重 bug：修饰键松开后永久残留**（⇪ ⌘ ⇧ fn ⌃ 卡死、和弦显示错乱）。根因：修饰键松开不发 keyUp，而是再发一次 flagsChanged，此前 flagsChanged 分支只接了按下没接释放。修复：释放位变化 → onKeyUp 回传；CapsLock 按下/释放 flags 相同（LED 锁定态），改用事件交替判定；另加 120 秒兜底清理（pruneStaleKeys）+ 休眠/暂停时清空。
2. **ⓘ Tooltip 不显示**：.help 在该视图层级不触发，HelpMarker 改为 onHover 自绘悬浮面板（200ms 防误触延迟）；Card 移除内容级 clipShape（浮层需越出卡片边缘，背景改为自裁剪）。

### M10 Tooltip 终版（2026-09-22 18:3x，用户实测反馈）
in-place overlay 被应用窗口边缘裁切且遮挡卡片内容 → 改为独立无边框 NSPanel（悬浮层级、光标穿透、不抢焦点），可越出应用窗口；SwiftUI .global 坐标换算 AppKit 屏幕坐标后按所在屏可视区域自动收敛，下方放不下自动翻到标记上方。另：ad-hoc 重签名导致 TCC 授权每次重置，启动时自动重弹系统授权申请（长期可改固定自签名证书）。

### M11 授权持久化（2026-09-22 18:4x，用户要求）
ad-hoc 签名无稳定身份，TCC 每次重签名都重置授权。改用钥匙串中已有的 **Apple Development 证书**（TeamID Y99GV96XD6）签名：DR 为 identifier + anchor apple generic + 证书 CN，跨构建稳定，授权一次后保留（证书约 1 年有效期，续订后需再授权一次）。新增 **`build-release.sh`** 一键构建脚本（显式 exit 校验 + 稳定签名 + 重启），替代手工命令链。沙箱内 codesign 访问钥匙串被拦，该步骤需非沙箱执行。

### M12 媒体键释放闭环 + Tooltip 系统重写（2026-09-22 20:0x，用户确认方案 A 后实施）
1. **F 行残留修复**：媒体键按下/释放是同一事件的两种状态（0xA/0xB），此前只处理按下帧导致 F 键按下后永久残留（F1/F10/F11/F12 卡死实证）。补上释放分支，与普通键行为对称；计数口径不变。三类键释放路径全部闭环：普通键 keyUp / 修饰键 flagsChanged 位移除 / 媒体键 0xB 帧。
2. **ⓘ 提示从头重设计**（调研 Cindori/fazm.ai NSPanel 配方后重写）：事件驱动状态机控制器 + 成熟 NSPanel 悬浮配方；0.4s 悬停意图延迟、**面板可悬停保持**、离开 0.3s 宽限渐隐、**优先显示在标记上方**（避开正文遮挡）、淡入淡出、单实例。HelpMarker 只上报事件不含时序。

### M13 ⓘ 回归平台原生 Tooltip（2026-09-22 20:1x，用户报告第三次回归）
症状：ⓘ 无缘无故弹出、移开不消失、实时页按键也触发。根因：M12 设计把 GeometryReader frame 变化当作悬停意图——布局任何微变（按键刷新、数据更新）都触发"进入"，而光标从未真正悬停 → 永无"离开"。**决策：删除整套自研悬浮窗（控制器/面板/状态机），回归 AppKit 原生 Tooltip（NSView.toolTip 的 NSViewRepresentable 桥接）**——悬停/延迟/定位/消失全由系统管理。自研悬浮窗路线经三轮迭代仍有边界缺陷，判定为过度工程，平台机制优先。
另修：build-release.sh 的 `set -e` 会吞掉构建失败日志（改为 `|| { … exit 1; }`）；NSViewRepresentable 的 NSView 子类不可 private。

### ⚠️ M6 复盘（2026-09-22 17:2x）：M5/M6 构建静默失败事故
用户反馈"还是老样子"后排查发现：M5/M6 的 release 构建**均编译失败**，但构建命令写成
`swift build | tail -2 && cp …`，管道退出码取 tail 恒 0，失败被掩盖，拷贝的一直是
14:53 的 M4 旧二进制。修复了三个编译错误（AppModel 丢失 shared 单例、\.dismiss 转义、
PeriodPicker 标签顺序）后重新构建（exit=0），显式 kill -9 全部旧进程再重启，经产物
mtime 与进程新鲜度核验，当前运行的是包含 M5+M6 全部功能的二进制。
**流程修正：构建与产物校验不再接管道；每次交付前核对构建 exit code 与产物 mtime。**

### M6 自定义日期区间 + 实时跟手（2026-09-22 晚）
1. **自定义统计区间**：顶栏"自定义"入口 → 双图形日历弹层（起止允许同一天、倒序自动交换、终点限今天）；引擎新增闭区间快照 `snapshot(from:to:)`；总览/键盘/触控板页标题与标签随区间联动。顺带修复存量 bug：应用重启后当日已落盘数据未回灌引擎（今日统计曾会清零）。
2. **实时跟手反馈**：tap 掩码补 keyUp；LiveModel 维护"按下中"键位集合——按下瞬间键帽缩放高亮（0.06s linear）、松开即回弹；"当前按键"状态改为"按下中 / 已松开"；暂停时清空按压集合防长亮；减少动效时禁用缩放动画。
3. 测试 40/40 通过（新增自定义区间：跨天/单日/倒序交换/含与不含今天/跨月日期枚举）。

### M7 待实施：触控板增强（方案评估见 TOUCHPAD_PROPOSAL.md）
手势扩展（全公开 API，SO #1383528 / rift 路线）、触点热力图（MultitouchSupport 私有框架，Kyome22/OpenMultitouchSupport 等成熟封装调研完毕）、压感接入（三层压力数据源）。**待确认隐私边界与依赖方式后实施**。

### M5 修饰键 / 组合键 / F 行媒体键 / 性能（2026-09-22 傍晚，用户实测反馈四项）

先检索了成熟开源方案再动手：媒体键解析用 KeyCastr / MediaKeyTap 系的
`systemDefined(14) + subtype 8 + data1 位域`标准方案；修饰键用 flagsChanged +
`event.flags` 位变化判定（KeyCastr 模式）；组合键 = 普通键 keyDown 时的 flags
和弦快照（Apple 菜单顺序 ⌃⌥⇧⌘）。

1. **修饰键单独按下识别**：tap mask 增加 flagsChanged；Command/Control/Option/Shift/Fn/CapsLock
   按下计入键位统计（按下/释放按「对应标志位是否新增」区分，CapsLock 的 LED 锁定态天然正确）。
2. **组合键统计**：修饰键按住 + 普通键按下 → 和弦 ID（如 ⌘C、⇧⌘3、⌃⌥⌘Delete），
   持久化新增 `comboCounts` 白名单字段（只存和弦构成，不存时间序列）；实时页「当前组合」、
   键盘分布页「组合键 Top 5」、总览摘要均有展示；150ms 同和弦去抖防按键重复爆量。
3. **F 行识别对齐系统行为**：默认设置下按 F1/F2/F7–F12 走媒体事件，
   按 NX_KEYTYPE（ev_keymap.h）映射回物理键位 ID 统计（亮度↓→F1、播放→F8、音量±→F11/F12…）；
   F3/F4 走 Apple Silicon 特殊键码 130/131；fn+F1（标准键码 122）同样计入 F1 ——
   两种系统配置下物理键位统计一致。已知边界：F5（听写）/F6（勿扰）无公开可观察事件，暂无法计数。
4. **侧栏/页面交互迟缓**：根因是每次按键 + 每秒空闲定时器都触发 `objectWillChange` 全树失效
   （侧栏 List、所有 Charts 每秒重算）。修复：实时状态拆分到独立 `LiveModel`（按键只失效实时页）、
   空闲秒数改 `TimelineView` 局部刷新、空闲结算定时器不再触碰 UI 状态（5s 只调引擎）。

## 五、构建 / 测试 / 运行

```bash
# 构建（Xcode 许可未接受 → 用 CommandLineTools；SwiftPM 沙箱在本机需禁用）
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build -c release --disable-sandbox

# 跑全部 35 个测试（CLT 不带 XCTest，脚本用 Xcode 的 XCTest.framework + xctest 运行器）
./run-tests.sh

# 打包（release 二进制 → .app → ad-hoc 签名）
cp .build/release/Inputscape build/Inputscape.app/Contents/MacOS/Inputscape
codesign --force --sign - build/Inputscape.app
open build/Inputscape.app
```

运行前置：系统设置 › 隐私与安全性 › 输入监听 + 辅助功能，两项都授权后才开始观察。

## 六、本机工具链备注（为什么有 run-tests.sh）

- `xcode-select` 指向 Xcode.app 但许可未接受（接受需 sudo），swift/xcodebuild 直跑会报许可错误 → 所有命令用 `DEVELOPER_DIR=/Library/Developer/CommandLineTools`。
- SwiftPM 自带沙箱在本机起不来 → 必须加 `--disable-sandbox`。
- **新版 CLT 不带 XCTest / Swift Testing** → `run-tests.sh` 用 CLT 编译 Kit（`-enable-testing`），链接 Xcode 的 XCTest.framework 出 .xctest bundle，再用 Xcode 的 `xctest` 运行器（非许可门禁工具）执行。

## 七、已知边界与风险

- **手势计数**：缩放/滑动走 NSEvent 全局监听，macOS 对部分手势不投递全局监听 → 这两类计数可能为 0（设计文档 §7 已注明"部分手势"）。按键/点击/滚动/修饰键/媒体键走 CGEventTap，可靠。
- **F5/F6 无法计数**：听写与勿扰键在默认设置下无公开可观察事件；用户开启「F1–F12 作为标准功能键」后可按标准键码计数。
- **Force Touch 判定**：pressure ≥ 1.5 为经验阈值，需真实设备验证；设备不支持时可在设置关闭。
- **实时观察未做真机授权验证**：监听链路编译通过、权限门禁齐全，但沙箱环境无法授予输入监听权限实测，需 Bintao 在真实会话里授权后确认计数正确。
- 键盘 F 行图标映射按 2021 MBP 文档口径（F3 调度中心 / F4 聚焦 / F5 听写 / F6 勿扰），与实物如有出入只需改 `KeyboardLayoutSpec` 一处。

## 八、下一步（按优先级）

1. **真机授权实测**：授权后验证按键/修饰键/组合键/F 行媒体键计数、实时高亮、空闲时长与休眠挂起；确认 F3/F4 特殊键码在本机 macOS 26 上的实际投递。
2. **键盘快照回归**：用已有的 `scrollWhenNarrow` 离屏渲染管线生成 78 键基线图，纳入测试（设计文档 §10 提到的 snapshot 思路）。
3. **手势可靠性**：实测确认缩放/滑动投递情况；必要时评估 CGEventTap 手势子类型（仍限公开 API）。
4. **后续模板**：ISO / JIS / Magic Keyboard（当前设置页固定 US ANSI）。
5. **可选**：自定义暂停快捷键（引入 KeyboardShortcuts 前需过依赖审查）；数据保留策略设置。
