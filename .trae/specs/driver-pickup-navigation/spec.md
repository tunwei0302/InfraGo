# 司机接驾导航功能规格 (Driver Pickup Navigation Spec)

## 1. 问题

司机接受订单后，当前 `DriverHomeScreen` 的「Active ride」卡片只显示文字形式的「Pickup → Destination」以及 Contact/Start/Complete/Cancel 按钮，没有地图、没有路线、没有实时 ETA/距离。司机只能凭记忆或退出 app 打开 Google Maps/Waze 才能找到乘客上车点，用户体验不佳。

乘客端 `TripPlannerMapScreen` 已经有 flutter_map + OSRM Polyline + 起终点 Marker + 司机精确位置，但司机端完全没有对应的地图屏幕。

## 2. 用户与目标

| 用户 | 痛点 | 目标 |
|---|---|---|
| **司机 (Driver)** | 接受 ride/group 后不知道怎么开去接乘客 | 接受订单后能看到地图、路线、方向、实时 ETA、上车点信息 |
| **乘客 (Rider)** | 司机找不到上车点导致超时/取消 | 司机更快更准确到达上车点 |

## 3. 范围

### 3.1 功能目标（In-Scope）

1. **司机接受订单后自动弹出导航屏幕**（或主动 ride 卡片中增加 "Navigate" 入口按钮）
2. **导航屏幕展示地图**：
   - 起点：司机当前实时 GPS 位置（蓝点/车标）
   - 终点：本次导航的目标点（对于 group，根据 `current_stop_idx` 动态切换，如 P1 → P2 → D1 → D2）
   - 路线：OSRM RouteResult 的 Polyline（主色粗线，带边框）
3. **实时方向面板**（屏幕顶部或底部卡片）：
   - 当前目标：「Pickup Rider 1 / Drop off Rider 2」 标签 + 匿名骑手槽位
   - 剩余距离：「1.2 km」
   - 预计到达 ETA：「3 min」
   - 大字下一步粗方向指示：「前方 300m 右转」——（基于最近路线节点相对方位，不依赖 OSRM steps）
   - 已到达目标时：「Arrived at pickup point!」提示 + 按钮可触发司机快捷回复或推进 group stop
4. **单人 ride 与 拼车 group 都支持**：
   - 单人：目标固定为 pickup，之后司机回到 Hub 卡片按 Start ride → Complete ride
   - 拼车：group 每 advance 一次 stop，导航目标自动切换到下一个 stop（P1→P2→D1→D2）
5. **实时跟踪**：
   - 司机位置持续更新（沿用 `Geolocator.getCurrentPosition` + `StreamSubscription`，或复用 `DriverPresenceService.lastKnownPosition`）
   - 如司机偏离路线超过阈值（如 50m 直线距离 + 不在 polyline 附近），自动重算 OSRM route 并更新 polyline 与 ETA
6. **集成入口**：
   - `AvailableOrdersScreen._accept()` 成功后：自动跳转到导航屏幕（或从 Hub 点入）
   - `DriverHomeScreen._activeRide()` 卡片中增加 「Navigate」FilledButton 入口，与 Contact/Start/Complete 同级

### 3.2 非目标（Out-of-Scope）

- ❌ 不实现 OS 级「逐弯语音导航」（不集成 Google Maps/Waze turn-by-turn SDK）
- ❌ 不启用 OSRM `steps=true`（保持 `steps=false`，方向指示基于 polyline 下一个节点计算相对 bearing）
- ❌ 不更改后端 SQL / Supabase 表结构（所有数据来自 rides + ride_groups 现有列）
- ❌ 不做历史导航记录

## 4. 功能需求 (Functional Requirements)

| FR | 描述 |
|---|---|
| FR1 | 新增 `DriverPickupNavigationScreen` StatefulWidget，接收参数：`rideId`（单人）或 `groupId` + `firstRideId`（拼车）；内部解析当前导航目标点（stop）|
| FR2 | 导航屏幕使用 `flutter_map` + `MapController` + OpenStreetMap TileLayer（与乘客端技术栈一致）|
| FR3 | 加载并实时显示：司机当前位置 Marker（蓝/出租车图标）、目标点 Marker（绿色 Pn 或红色 Dn）、OSRM 路线 Polyline |
| FR4 | 顶部导航卡片展示：目标名称、剩余距离、ETA、下一步方向箭头（基于 polyline 前方第 N 个节点的方位差）|
| FR5 | 单人 ride：目标 = `rides.pickup_latitude` + `rides.pickup_longitude` + `rides.pickup`（文字）；完成导航后司机可返回 Hub 点 Start/Complete |
| FR6 | 拼车 group：目标 = 根据 `ride_groups.current_stop_idx` + `ride_groups.optimised_stop_order` 计算当前是哪一位骑手的 P 或 D，并读取对应 ride 的 pickup/destination 经纬度与文字 |
| FR7 | Group stop advance 后（从 Hub 卡片点 Advance），若司机当前已打开导航屏幕，自动切换目标、重算路线、刷新 UI |
| FR8 | 路线重算：司机位置与 polyline 最近点距离 > 50m，且距上次重算 > 15s → 自动重新调用 OSRM route |
| FR9 | 到达判定：司机位置距目标点直线距离 ≤ 50m 时，顶部卡片切换到「Arrived」状态（换绿、显示到达提示、可选「I arrived」快捷动作按钮触发对应快捷回复消息）|
| FR10 | 入口 1：`AvailableOrdersScreen._accept()` 成功后（`mounted` 且 success），`Navigator.push` 导航屏幕 |
| FR11 | 入口 2：`DriverHomeScreen._activeRide()` 的 Wrap actions 中增加「Navigate」FilledButton（与 Start ride/Complete ride 同级）|
| FR12 | 导航屏幕内提供打开聊天、回到 Hub 的入口（顶部或底部 icon）|

## 5. 非功能需求 (Non-Functional Requirements)

| NFR | 描述 |
|---|---|
| NFR1 | **性能**：在中低端 Android 设备上 60fps 滚动地图，位置刷新频率 ≤ 1Hz（不高于司机在途发布频率）|
| NFR2 | **离线降级**：OSRM 路由失败时回退到直线连接 + 直线距离 + 「Routing unavailable, using straight line」Snackbar 提示 |
| NFR3 | **权限**：导航屏幕 init 时复用 `DriverPresenceService._ensurePermission` 等价逻辑，无权限时显示明确文案 |
| NFR4 | **生命周期**：State.dispose 时取消所有 StreamSubscription、关闭 OSRM client、MapController 不再被引用 |
| NFR5 | **可访问性**：所有 Marker、按钮、进度条均有 Semantics label |
| NFR6 | **代码复用**：重用现有 `OsrmRoutingService`、`bearingBetween`、`haversineMeters`、`RouteResult.distanceLabel/etaLabel`；不重复实现 flutter_map 基础图层 |

## 6. 约束 / 依赖 / 假设

### 约束
- Flutter 依赖保持现状，不得引入 Google Maps SDK、Mapbox、高德等需要 API key 的商业服务
- 保持 `steps=false`，方向指示用 polyline 最近/前方节点方位差模拟（详见 FR4）
- 司机在途的精确位置发布仍由 `DriverPresenceService.startAssigned` 处理，导航屏幕只订阅 `Geolocator.getPositionStream` 作为 UI 显示用，不重复写 DB

### 依赖
- `flutter_map: ^8.3.1`（已在 pubspec.yaml）
- `latlong2: ^0.10.1`（已存在）
- `geolocator: ^14.0.3`（已存在）
- `OsrmRoutingService` + `RouteResult`（lib/kueh/osrm_routing_service.dart，已存在）
- `rides` 表列：`pickup_latitude`, `pickup_longitude`, `pickup`, `destination_latitude`, `destination_longitude`, `destination`, `status`, `group_id`（已存在）
- `ride_groups` 表列：`optimised_stop_order`, `current_stop_idx`（已存在，由 carpool 逻辑维护）

### 假设
- 司机接受订单时，rides 表的 pickup_latitude / pickup_longitude 字段已填充（乘客下单时写入）
- 拼车 `optimised_stop_order` 格式为 `[0, 1, 2, 3]` 四个 int，其中 0 = Rider 0 pickup, 1 = Rider 1 pickup, 2 = Rider 0 dropoff, 3 = Rider 1 dropoff（与现有 `_enrichOrder` 解析一致）
- 马来西亚城市范围内 OSRM 公开服务可用，必要时可替换为自建 baseUrl（OsrmRoutingService 已支持构造参数注入）

## 7. 开放问题

> 已由实现方自行处理，无需用户回复：
> 1. **Q1**：导航屏幕是否覆盖 Hub（作为新 route push）还是嵌入 Hub（作为新 Tab）？→ 实现为独立 Navigator.push 全屏屏幕，保持简单
> 2. **Q2**：「下一步方向指示」精度需要多高？→ 使用 polyline 上司机投影点后约 80~150m 的下一个节点，计算相对 bearing（前/左/右/轻微左转/轻微右转/掉头）
> 3. **Q3**：拼车场景下导航切换到下一个 stop 是否需要司机确认？→ 不需要，监听 `ride_groups.current_stop_idx` 的 Supabase stream，变化时自动切换并 Snackbar 通知

## 8. 验收标准 (Acceptance Criteria)

### 规则型 (rule)

| ID | 类型 | 通过条件 | 证据来源 |
|---|---|---|---|
| AC1 | rule | Accept 单人 ride 后，调用栈能触发 `Navigator.push` → `DriverPickupNavigationScreen`，屏幕非 null | 运行 app + 代码检查 `_accept()` 末尾 |
| AC2 | rule | 导航屏幕 build 中存在 `FlutterMap` widget，包含至少 1 个 TileLayer + 1 个 PolylineLayer（或空状态降级）| Widget 树检查 + 代码静态 |
| AC3 | rule | 目标点坐标正确：单人取 rides.pickup_lat/lng；group 按 current_stop_idx + optimised_stop_order 找到 ride + pickup/destination | 构造测试数据对照输出 LatLng |
| AC4 | rule | 司机距离 polyline 最近点 > 50m 且上次重算 > 15s → 下一次 tick 会重新调用 `OsrmRoutingService.route` | 在导航 service 的方法上加可观测计数器做单元测试 |
| AC5 | rule | 距离目标 ≤ 50m 时顶部卡片状态 = arrived 且颜色 = tertiary / success 色 | Widget 测试 snapshot / 手动观察 |
| AC6 | rule | group advance 后（current_stop_idx 增加 1），导航屏幕在 <=5s 内切换目标并刷新路线 | Supabase 实时订阅 + 手动触发 advance |
| AC7 | rule | `DriverHomeScreen._activeRide()` 中存在 Navigate 按钮：单人 ride（status=driver_assigned 前未开始）与 group（status=en_route）均渲染 | 代码 + UI 检查 |
| AC8 | rule | 所有新增文件无 IDE 诊断错误，`flutter analyze` 不出现新增 warning 以上 | `flutter analyze lib/heng/` 输出 |
| AC9 | rule | State.dispose 中取消所有 StreamSubscription、关闭 OsrmRoutingService client（若独立实例化） | 代码审查 dispose 方法 |
| AC10 | rule | OSRM 失败或网络异常时：不崩溃，Snackbar 显示错误 + 显示直线 Marker 链接（降级）| 断网/设 baseUrl 错误测试 |

### 评估型 (rubric)

| ID | 维度 | 0 分 | 1 分 (通过阈值) | 2 分 | 证据来源 |
|---|---|---|---|---|---|
| R1 | 方向指示 UI 清晰性 | 没有方向指示，只有距离+ETA | 有箭头图标 + 简单 4 方向（前/后/左/右）文字 | 有箭头图标 + 8 方向 + 距离下一拐弯的「200m 右转」| 导航屏幕 UI 快照 |
| R2 | 代码复用度 | flutter_map/Marker/Polyline 全部重复实现，乘客端 marker 样式不一致 | 复用了 Polyline/Marker 基本结构，与乘客端视觉有 70% 一致 | 直接抽取独立 shared widget（如 SharedRouteMarkers 扩展），视觉/尺寸/颜色 100% 与乘客端保持一致 | 代码引用 diff |
| R3 | 地图跟随用户体验 | 地图不自动跟随司机位置，需手动拖动 | 开启自动跟随，也可手动拖动取消跟随 | 自动跟随 + 可切换跟随模式按钮 + 自动 fitCamera 同时框选起终点+路线 | 手动体验 + 代码 |
| R4 | 到达状态反馈 | 只有文字变化 | 颜色 + 文字变化 | 颜色 + 文字 + 可选「I'm arrived」发送快捷消息动作 + 轻微 haptic 反馈 | UI + 代码 |
