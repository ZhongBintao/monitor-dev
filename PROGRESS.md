# Inputscape 交接文档

> macOS 14+ 本地输入习惯分析器 · 唯一交接主文档，随开发推进更新
> 设计契约：`INPUTSCAPE_DESIGN_PLAN.md`（用户 authored，改动需谨慎）
> 触控板扩展方案（待拍板）：`TOUCHPAD_PROPOSAL.md`
> 最近更新：2026-09-22（M14）

---

## 一、项目概况

- **定位**：本地输入习惯分析工具。仅保存本地聚合统计，不记录文字内容、按键序列、应用名称、屏幕坐标或原始事件，无云同步。
- **首版范围**：内置键盘（MacBook Pro 14/16″ US ANSI，78 键基准）+ 内置触控板；ISO/JIS/Magic Keyboard 为后续模板。
- **技术栈**：Swift 5.9 tools / Swift 6.3 编译器（CommandLineTools，Xcode 许可未接受）、SwiftUI + Swift Charts、CGEventTap（公开 API）、JSON 按日存储。
- **版本管理**：git 仓库（本目录），提交身份 Bintao / zfr45682@icloud.com；构建产物与 `.workbuddy/` 已 gitignore。

## 二、当前状态

**首版功能完成，41/41 测试通过，`build-release.sh` 一键构建/签名/启动。**

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| 键盘主图规范 | ✅ 完成 | 78 键唯一真值；物理布局对齐 `apple-wireless-keyboard.json`（功能行 1.0357u、command 1.25u、space 5u、四方向键半高），键帽字形 Unicode 修饰键 + F 行 SF Symbols，JSON 等价性测试守护 |
| 聚合引擎 | ✅ 完成 | 60s 输入段 / 5 分钟桶 / 跨天 / 预设周期与自定义起止快照 / 组合键计数 |
| 本地存储 | ✅ 完成 | 按日 JSON + 白名单 schema（date/keyCounts/comboCounts/trackpadCounts/buckets/hourlyByOp/activeSeconds），隐私测试守护 |
| 监听层 | ✅ 完成（待真机授权验证） | keyDown/keyUp + flagsChanged（修饰键含释放）+ systemDefined（F 行媒体键含释放）+ 特殊键码；只输出键位 ID / 操作类别 / 组合和弦 |
| 组合键统计 | ✅ 完成 | 修饰键按住 + 普通键按下 → 和弦（⌘C / ⇧⌘3 / 三键）；150ms 去抖；实时页 + 键盘分布 Top5 + 总览摘要 |
| 自定义统计区间 | ✅ 完成 | 竖向单月自绘日历，起止可同一天，全页面联动 |
| 实时跟手反馈 | ✅ 完成 | 三类键释放闭环（keyUp / flagsChanged 位移除 / 媒体键 0xB），按下点亮缩放、松开即灭、无残留 |
| 七页面 UI | ✅ 完成 | 总览 / 键盘分布 / 触控板操作 / 使用趋势 / 实时观察 / 设置 + 三步引导；ⓘ 说明为 AppKit 原生 Tooltip |
| XCTest 测试 | ✅ 43/43 | 布局规范 14（含 JSON 等价性 + 方向键底对齐）、聚合 11、存储 5、隐私 5、键码映射 8 |

## 三、代码结构

```
monitor-dev/
├── Package.swift                    # SwiftPM：InputscapeKit + InputscapeApp + Tests
├── build-release.sh                 # ★ 一键：构建(exit 校验)→稳定签名→重启
├── run-tests.sh                     # ★ 一键测试（CLT + Xcode XCTest.framework 混编）
├── keyboard-preview.png             # 键盘布局离屏渲染预览图
├── apple-wireless-keyboard.json     # ★ 键盘物理布局数据源（Apple Wireless Keyboard 实测）
├── Sources/InputscapeKit/           # 核心库（无 UI 依赖，可独立测试）
│   ├── KeyboardLayoutSpec.swift     # ★ 78 键主键盘图唯一真值（几何源自 apple-wireless-keyboard.json）
│   ├── apple-wireless-keyboard.json # 键盘物理布局数据源（KLE 格式，几何等价性测试守护）
│   ├── KeyCodeMapper.swift          # kVK 键码→键位 ID + 媒体键/fn 改写键码映射 + ComboKeyBuilder
│   ├── AggregationEngine.swift      # 聚合：60s 输入段 / 288 桶 / 跨天 / 两种快照
│   ├── AggregateStore.swift         # 按日 JSON 存储（原子写、白名单 schema）
│   ├── EventMonitor.swift           # CGEventTap（主 run loop）+ 三类键事件分类 + 权限中心
│   └── Models.swift                 # DailyRecord / TimeBucket / LiveState / 快照等
├── Sources/InputscapeApp/           # SwiftUI 应用
│   ├── KeyboardHeatmapView.swift    # ★ 唯一键盘渲染视图（三页共用，12 种键帽样式）
│   ├── AppModel.swift               # 主模型（状态/快照/持久化；高频事件不经此失效全树）
│   ├── LiveModel.swift              # 实时状态（pressedKeys/heldChips，按键只失效实时页）
│   ├── AppKitTooltip.swift          # ⓘ 原生 Tooltip 桥接（NSView.toolTip）
│   ├── CustomRangePicker.swift      # 自定义日期区间（单月自绘日历）
│   ├── RootView.swift               # 侧栏导航 + 状态栏（最小窗口 1100×760）
│   └── …Views.swift                 # 总览/键盘/触控板/趋势/实时/设置/引导
└── Tests/InputscapeKitTests/        # 41 个 XCTest 用例
```

## 四、构建 / 测试 / 运行

```bash
./build-release.sh   # 一键：release 构建（exit 校验）→ 稳定签名 → 重启
./run-tests.sh       # 41 个测试（CLT 编 Kit + Xcode XCTest.framework 链接 + xctest 运行器）
```

- 签名用钥匙串中的 **Apple Development 证书**（TeamID Y99GV96XD6）——签名身份稳定，**TCC 授权跨构建保留**；ad-hoc 签名（`-s -`）会每次重置授权，已弃用。证书约 1 年有效期，续订后需再授权一次。
- 签名/codesign 访问钥匙串，沙箱内会被拦，需非沙箱执行。
- 运行前置：系统设置 › 隐私与安全性 › 输入监听 + 辅助功能（启动时未授权会自动弹申请）。

## 五、本机工具链备注

- `xcode-select` 指向 Xcode.app 但许可未接受（接受需 sudo）→ 所有 swift 命令用 `DEVELOPER_DIR=/Library/Developer/CommandLineTools`。
- SwiftPM 沙箱在本机起不来 → 必须 `--disable-sandbox`。
- **新版 CLT 不带 XCTest / Swift Testing** → `run-tests.sh` 用 CLT 编 Kit（`-enable-testing`），链接 Xcode 的 XCTest.framework 出 .xctest bundle，再用 Xcode 的 `xctest` 运行器执行（非许可门禁工具，绝对路径）。
- ⚠️ 测试只编 Kit——**测试绿 ≠ 应用 target 编译绿**，交付前必须跑 `build-release.sh` 并确认 "Build complete"。

## 六、关键技术决策与教训（跨里程碑沉淀）

1. **键盘唯一真值**：所有键盘页面从 `KeyboardLayoutSpec` 派生（KeyGlyph unicode/sfSymbol + 12 种 KeycapStyle 逐键定义），禁止硬编码键位数组。物理布局源自 `apple-wireless-keyboard.json`（Apple Wireless Keyboard 实测，KLE 格式）：功能行 14 键 1.0357u、底行 command 1.25u / space 5u；几何等价性由 JSON 比对测试守护。键帽内容与用户参考图逐键对齐：四方向键全半高（←/→/↓ 底对齐、↑ 顶对齐）、右 Shift ⇧ 右下、数字/标点双层居中、Touch ID 裸圆环、caps LED 指示点。JSON 两处应用方修正：功能行/底行高度归一为字母键 1.0；JSON 图标定义忽略（沿用现有 UI 字形）。
2. **三类键释放路径必须闭环**：普通键 keyUp / 修饰键 flagsChanged 标志位"移除" / 媒体键 0xB 帧——缺任何一条就是"按下残留"bug（三类都各自漏过一次）。CapsLock 按下/释放 flags 相同（LED 锁定态），用事件交替判定。
3. **fn 按住会改写键码**（官方 Events.h）：fn+←/→/↑/↓ → Home 115/End 119/PageUp 116/PageDown 121，fn+delete → 117；必须映射回物理方向键/Delete，否则 fn+⌃/⌘+方向键组合整体丢失。
4. **媒体键解析**：`systemDefined(14) + subtype 8 + data1 位域`（高 16 位 NX_KEYTYPE、bits 8-15 = 0xA 按下 / 0xB 释放、bit 0 重复），KeyCastr/MediaKeyTap 标准方案。
5. **CGEventTap source 必须挂主 run loop**：挂后台线程时 HIToolbox 把 caps（中英文切换）长按 timer 装到同一 run loop，其主队列断言失败 → 按住 caps 直接 SIGTRAP 崩溃（有崩溃日志实证）。
6. **组合键 = 和弦快照**：修饰键按住时按下的普通键，Apple 菜单顺序 ⌃⌥⇧⌘ 编码（如 ⇧⌘3）；只存和弦构成不存时间序列，150ms 同和弦去抖。
7. **ⓘ 提示用平台原生 `NSView.toolTip`**：自研悬浮窗（SwiftUI overlay → 独立 NSPanel → 事件驱动状态机）三轮迭代先后出现遮挡、窗口裁切、无缘无故弹出、不消失——判定过度工程，已整体删除。原生方案延迟约 1s+ 由系统控制，换取绝对稳定。教训：**平台已打磨的功能优先用，自研仅当平台做不到时启动**。
8. **构建纪律（M6 事故）**：`swift build | tail && cp` 的管道退出码取 tail 恒 0，编译失败静默拷贝旧二进制（连续两轮交付了旧版本）。构建命令禁止接管道后再链式执行；`build-release.sh` 已固化正确流程（失败输出日志并中止）。
9. **授权持久化**：TCC 按「指定要求」绑定授权，ad-hoc 签名每次重置；Apple Development 证书签名后跨构建稳定（见 §四）。
10. **性能**：高频事件（每次按键）只更新 LiveModel 与引擎计数，不触发主模型 `objectWillChange`；空闲秒数用 TimelineView 局部刷新——否则全树（侧栏/Charts）每秒重算，交互迟缓。

## 七、里程碑简史（详节见 git log 与当日工作记忆）

| # | 时间 | 内容 |
| --- | --- | --- |
| M1 | 09-22 上午 | 核心库：78 键主图规范、键码映射、聚合引擎、JSON 存储 |
| M2 | 09-22 中午 | 七页 UI + 三步引导 + Swift Charts + 8 个必须状态 |
| M3 | 09-22 下午 | XCTest 套件 + 手工打包 .app |
| M4 | 09-22 下午 | 实测修复 ×3：Minus 键文案、键盘画布居中错位、窗口内容超宽被裁 |
| M5 | 09-22 傍晚 | 修饰键 / 组合键 / F 行媒体键识别；LiveModel 拆分解决交互迟缓 |
| M6 | 09-22 晚 | 自定义日期区间 + 实时跟手（含重启当日数据回灌修复） |
| M6R | 09-22 | ⚠️ 事故复盘：M5/M6 构建静默失败（管道退出码），流程修正 |
| M8 | 09-22 17:2x | caps 长按崩溃修复（tap 挂主 run loop）、fn 改写键码补全、实时页合并、自绘日历、Tooltip 首版 |
| M9 | 09-22 18:2x | 修饰键释放残留修复（flagsChanged 补释放 + CapsLock 交替判定） |
| M10 | 09-22 18:3x | Tooltip 改独立 NSPanel（越窗不裁切）；TCC 重置问题暴露 |
| M11 | 09-22 18:4x | 授权持久化（Apple Development 证书）+ build-release.sh |
| M12 | 09-22 20:0x | 媒体键释放闭环；Tooltip 事件驱动状态机重写（仍回归） |
| M13 | 09-22 20:1x | ⓘ 回归平台原生 Tooltip，删除自研悬浮窗 |
| M14 | 09-22 20:5x | 虚拟键盘对齐参考图（半高方向键 / Unicode 字形 / 键帽样式逐键定义）+ git 仓库建立 |
| M15 | 09-22 22:0x | 物理布局对齐 apple-wireless-keyboard.json（功能行 1.0357u / command 1.25u / space 5u；高度归一 1.0；图标沿用现有 UI）；新增 JSON 等价性测试（43 用例） |
| M16 | 09-22 22:2x | 键帽圆角缩小（0.14u→0.09u）；方向键底对齐断言固化（KLE 原始文件方向键向下突出 0.111u 系其风格化 hack，应用已修正为底对齐） |
| M17 | 09-22 23:0x | 右侧 command/option 图标与单词右对齐（.iconWordTrailing）；fn 地球左下 + fn 右下（.iconWordCorners）；键盘画布四周 0.1u 外边距（canvasAspectRatio 供调用方） |
| M7 | — | **待实施**：触控板增强（见 TOUCHPAD_PROPOSAL.md） |

## 八、已知边界与风险

- **F5/F6（听写/勿扰）无法计数**：默认系统设置下无公开可观察事件；用户开启「F1–F12 作为标准功能键」后可计数。
- **手势计数可能为 0**：缩放/滑动走 NSEvent 全局监听，macOS 对部分手势不投递（§TOUCHPAD_PROPOSAL.md 有替代方案）。按键/点击/滚动/修饰键/媒体键走 CGEventTap，可靠。
- **Force Touch 阈值未标定**：pressure ≥ 1.5 经验值，需真机验证；设置页可关闭。
- **监听链路未做真机授权验证**：需在真实会话授权后确认计数、实时高亮、休眠挂起；F3/F4 特殊键码（130/131）在 macOS 26 的实际投递待确认。
- **ⓘ 原生 Tooltip 延迟约 1s+**：系统控制不可调；换来了绝对稳定（自研方案已证实不可靠）。
- F 行图标映射按 2021 MBP 文档口径，与实物出入只需改 `KeyboardLayoutSpec` 一处。

## 九、下一步（按优先级）

1. **真机授权实测**：按键/修饰键/组合键/F 行媒体键计数、实时高亮、空闲时长、休眠挂起；确认 F3/F4 键码投递。
2. **键盘快照回归**：用 `scrollWhenNarrow` 离屏渲染管线生成 78 键基线图纳入测试（本次 keyboard-preview.png 即管线产物）。
3. **触控板增强**：手势扩展 / 触点热力图 / 压感——方案与决策点见 `TOUCHPAD_PROPOSAL.md`，等用户拍板后实施。
4. **后续模板**：ISO / JIS / Magic Keyboard（设置页当前固定 US ANSI）。
5. **可选**：自定义暂停快捷键（KeyboardShortcuts 依赖需过审查）；数据保留策略；固定自签名证书（当前 Apple Development 证书已满足）。
