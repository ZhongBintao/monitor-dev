# 触控板增强方案评估（手势扩展 / 触点热力图 / 压感触控）

> 状态：**①（压感短期项）②（手势扩展）已实施（2026-09-24，分支 `feature/trackpad-enhancement`）；③④ 等隐私决策拍板**
> 调研日期：2026-09-22 · 实施日期：2026-09-24 · ①② 全公开 API 落地，最终态与标定清单见 `PROGRESS.md` §六 19–23
> 实施偏差（1 处，语义更准）：滚动会话改用 **scrollWheel phase 判定**（began→ended 一次接触计 1 次），不用 beginGesture→endGesture——捏合缩放也走 beginGesture，原机制会把缩放误计为滚动会话。
> 关联更新：组合键/修饰键/媒体键事件基础设施已在 M5/M12 就绪（手势统计可直接挂入现有 EventMonitor）。
> 待拍板决策点仍见 §五（隐私边界 / 私有框架定位 / 依赖方式；手势粒度已按建议口径落地）。

---

## 一、手势扩展（捏合缩放 / 双指滚动 / 旋转等）

### 现状
- 双指滚动已统计（上/下，来自 scrollWheel）。
- 缩放/滑动当前走 `NSEvent.addGlobalMonitorForEvents`——**系统对手势事件不投递全局监听**，所以实际大概率收不到（此前已在文档中如实标注）。

### 调研发现
- **Stack Overflow #1383528（经典答案）**：CGEventTap 用 `kCGEventMaskForAllEvents`（listen-only）+ `NSEvent(cgEvent:)` 转换，可以全局收到 `magnify / rotate / swipe / smartMagnify / beginGesture / endGesture`（NSEvent 手势类型与 CGEvent 类型 19–33 一一对应）。开源平铺窗口管理器 **rift**（acsandmann/rift）的 GestureTap 也是这个路线。这是**公开 API**，无私有字段。
- NSEvent 手势事件自带干净数据：`magnify` 的 `magnitude`（>0 张开 / <0 捏合）、`rotate` 的 `rotation`（累计角度）、`phase / momentumPhase`、`smartMagnify`、`swipe`（注意 NSEvent 的 swipe 是三指轻扫；双指轻扫在系统里表现为 scrollWheel + 动量相位）。
- 注意点：all-events tap 回调频率很高（鼠标移动也进来），回调必须只做类型过滤 + 快速派发（现有 tap 线程架构已满足）。

### 方案（建议采纳）
1. 现有 EventMonitor 的 tap 掩码扩到全事件，回调里过滤手势类型后转 NSEvent 处理；删除现有收不到事件的 NSEvent 全局手势监听。
2. 统计口径拆分：`zoomIn / zoomOut`（按 magnitude 符号，一次手势计 1 次）、`rotateCW / rotateCCW`（按角度符号）、`smartZoom`、`swipe`、`scrollVertical（已有拆上下）/ scrollHorizontal`（scrollWheel 的 deltaX）、`scrollSession`（beginGesture→endGesture 的滚动会话数）。
3. 存储：`trackpadCounts` 增加这些类别（枚举扩展，schema 不变）；触控板页构成/排行/时段图自动兼容。
4. 展示：触控板操作页构成卡片按新类别展示（滚动合并展示保留）。

### 工作量 / 风险
- 工作量：约 **1 天**（监听层 0.5 + 统计与展示 0.5），测试随改动补充。
- 风险：低。全公开 API；唯一注意是 all-events tap 的回调性能（纯类型判断，纳秒级）。真实投递行为需真机验证一次（各 macOS 版本对手势事件的 tap 投递偶有差异）。

---

## 二、触控板触点热力图（物理触碰位置可视化）

### 现状与约束
- 设计文档 §7/§9 **明确首版排除**：公开接口拿不到触控板物理触点，且禁止把屏幕鼠标坐标伪装成触点位置。当时结论正确。
- 要做真实热力图只有一条路：**私有框架 MultitouchSupport.framework**（所有触控板增强类工具的历史路线）。

### 调研发现（GitHub 成熟封装）
| 项目 | 许可证 | 状态 | 说明 |
| --- | --- | --- | --- |
| **Kyome22/OpenMultitouchSupport** | MIT | 2025-01 更新，Swift 6 / macOS 13+ | 最完善的封装； posX/posY 归一化 0–1、pressure、fingerID、state（making/touching/breaking…）；SPM + XCFramework |
| KrishKrosh/OpenMultitouchSupport | MIT | 活跃 fork | 增加设备枚举/选择 |
| akinazuki/MultitouchKit | — | SPM, macOS 11+ | 更薄的封装 |
| 鼻祖参考 | — | — | calftrail/Touch（ObjC 经典逆向）、mhuusko5/M5MultitouchSupport、hammerspoon 的 undocumented 绑定 |

- 触点数据字段：归一化坐标（0=左…1=右 / 0=上…1=下）、电容总量、**压力**、指轴/角度、密度、触点状态机。
- **硬性约束**：App Sandbox 必须关闭（本应用为 SwiftPM 直组、无沙箱 entitlement，✓ 满足）；历史上无需额外 TCC 权限，但新系统可能要求输入监听（我们已授权该权限）——需真机验证。

### 方案（建议：做，标记为实验性功能）
1. **依赖策略（推荐）**：不引 XCFramework 二进制（供应链风险），参考 M5MultitouchSupport / Kyome22 源码，自写 ~150 行 C 回调桥（`MTDeviceCreateList` → `MTRegisterFrameCallback` → 解析 `MTTouch` 结构）。接口面极小（start/stop/回调 touches 数组），后续维护可控；或按你的偏好直接引 SPM 源码版 Kyome22（需过依赖审查清单）。
2. **热力采集**：24×16 网格，`state ∈ {making, touching}` 的触点计入所在格；按日持久化 `touchGrid: [Int]`（384 个整数/天，JSON 增量几 KB，符合聚合白名单思路——**新增字段需同步 allowedEncodedKeys 与隐私测试**）。
3. **可视化**：触控板操作页新增热力卡（珊瑚红色阶 + 悬停/选中格显示具体次数，遵守"不只依赖颜色"）；触控板纵横比按实物（~16:10）绘制圆角面板。
4. **开关与文档**：设置页"实验性：触点热力图"默认开启（设备不支持时自动隐藏）；**设计文档 §7/§9 边界需同步修订**（原文"不实现触点热力图"→"基于 MultitouchSupport 的实验性实现"）。

### 工作量 / 风险
- 工作量：**2.5–3 天**（桥接 0.5–1、采集与存储 1、可视化 0.5、真机标定与测试 0.5）。
- 风险：中。私有框架（macOS 大版本更新可能失效——但该框架十余年接口稳定，同类工具广泛在用）；**隐私面扩大**（触点位置虽是触控板表面坐标、非屏幕坐标，但属于新增采集维度，需要你确认接受）；无上架需求所以无商店审核问题。

---

## 三、压感触控板（Force Touch）接入

### 现状（你观察到的"未生效"属实）
- 设置开关目前只 gate 深按计数；深按判定阈值 `pressure ≥ 1.5` 是未标定经验值，很可能从未触发 → 开关形同虚设。另外没有任何压力可视化。

### 调研发现（三层数据源）
1. **点击压力（公开 API，已有链路）**：`kCGMouseEventPressure` 在 leftMouseDown 时给出 0–1+ 压力，深按（stage 2）明显大于普通点击。无需新权限。
2. **NSEvent `.pressure` 事件（type 34，公开 API）**：连续压力 + `stage`（0 悬浮 / 1 轻按 / 2 深按）。全局可达性需真机探针验证（与手势同一 all-events tap 路线即可携带）。
3. **MultitouchSupport 手指压力（私有，随热力图顺带获得）**：触摸过程连续压力，而不只是点击瞬间——数据最丰富。

### 方案（分两期）
- **短期（不引依赖，建议先做）**：
  1. 点击压力分级统计：轻/中/深三档直方图（阈值真机标定，先按 0.4 / 0.9 分界，可在设置页微调）；Force Touch 深按计数用同一阈值联动。
  2. 触控板页新增"压力分布"卡：三档占比条 + 平均压力 + 深按次数；`deviceProfile.supportsForceTouch = false` 时整卡隐藏（开关从此真正生效）。
  3. 若探针验证 `.pressure` 全局可达：加入轻按压力曲线的会话级统计（press-and-hold 深度）。
- **长期（随热力图）**：手指连续压力分布直方图 + 触点热力图叠加压力权重。

### 工作量 / 风险
- 短期 **0.5–1 天**（含真机阈值标定）；长期随热力图 +0.5 天。
- 风险：低（短期全公开 API）；`.pressure` 全局投递不确定性用一个 20 行探针先测再定。

---

## 四、总体建议与顺序

| 顺序 | 内容 | API | 工作量 | 价值 |
| --- | --- | --- | --- | --- |
| ① | 压感短期项 + `.pressure` 探针 | 公开 | 0.5–1 天 | 让现有开关真正生效，收益最快 |
| ② | 手势扩展（缩放/旋转/智能缩放/水平滚动/滚动会话） | 公开 | 1 天 | 补齐"操作构成"完整度 |
| ③ | 触点热力图（MultitouchSupport 桥） | 私有框架 | 2.5–3 天 | 视觉与数据完整性最大件 |
| ④ | 压感长期项（连续压力） | 私有框架 | +0.5 天 | 随 ③ 顺带 |

①② 可合并为一轮开发（合计约 1.5–2 天）；③④ 单独一轮。

## 五、需要你确认的决策点

1. **隐私边界**：③ 热力图要采集触控板表面归一化触点位置（按日聚合到 24×16 网格，不存原始轨迹、不涉屏幕坐标）。设计文档 §9 当时明确"不实现"，这次是**主动扩边界**——是否接受？（接受则我同步修订设计文档边界描述与隐私白名单）
2. **私有框架**：③ 必须链接私有 MultitouchSupport.framework。接受"实验性功能 + macOS 更新可能失效"的定位吗？（本地应用无上架需求，风险可控）
3. **依赖方式**：③ 桥接层选「自写 ~150 行（参考 MIT 项目）」还是「直接引 Kyome22/OpenMultitouchSupport SPM 源码」？我推荐前者（供应链更干净、接口面小）。
4. **手势口径**：② 的分类粒度按上文（缩放分方向、旋转分方向、滚动分横竖 + 会话数）可以吗？还是要更粗（只分缩放/旋转/滚动三类）？

确认后我按顺序开工；①② 先做，③④ 等隐私决策。
