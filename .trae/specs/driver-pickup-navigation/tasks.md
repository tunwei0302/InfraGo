# 司机接驾导航 - 实现任务清单

> 本文件将 AC（验收标准）映射到具体实现任务，按依赖顺序排列。

## 任务依赖图

```
T1 (导航核心) ─┐
               ├─→ T4 (入口集成) → T5 (联调 & 诊断)
T2 (group支持) ─┤
               │
T3 (方向指示) ─┘
```

---

## Task 1: 司机导航主屏幕 (DriverPickupNavigationScreen) 单人 ride MVP

**优先级**: high  
**覆盖 AC**: AC1, AC2, AC3(单人), AC9, AC10, NFR1, NFR2, NFR3, NFR4, NFR6

### 范围
- 新建文件：`lib/heng/driver_pickup_navigation_screen.dart`
- Widget 树结构：
  ```
  Scaffold
    ├─ Stack(fit: expanded)
    │    ├─ FlutterMap (TileLayer + PolylineLayer + MarkerLayer)
    │    ├─ Positioned(bottom): 导航卡片 (目标标签、剩余距离、ETA、下一步方向占位)
    │    └─ Positioned(top-right): 悬浮按钮(打开聊天 + 回Hub + 切换跟随模式)
    └─ AppBar: 「前往接驾」标题 + 返回
  ```
- 构造参数：`DriverPickupNavigationScreen.solo({required String rideId})`
- 加载数据：
  - 从 `rides` 表按 rideId select pickup_lat/lng/pickup/destination_lat/lng/destination/status/group_id
  - 调用 `Geolocator.getCurrentPosition` 获取初始司机位置；用 `getPositionStream(locationSettings: LocationSettings(distanceFilter: 5))` 订阅位置更新（1Hz，位移≥5m）
  - 调用 `OsrmRoutingService.route(driverPos, pickupPos)` 取路线 + ETA
- 路线重算逻辑：封装 `_shouldRecalculateRoute(driverLatLng, polyline, lastRecalcAt)`：
  - 取 polyline 上最近点（迭代每 2 个相邻点做线段投影），计算投影点到司机的 haversine 距离
  - 距离 > 50m && 距上次重算 > 15s → true
- Marker：
  - 司机位置：`_NearbyVehiclePin` 同款出租车图标（或直接复用 widget，注意位置参数）
  - 目标点：SharedRouteMarkers 中 pickup 同款绿圈+标签（或简化版，避免 import rider-specific）
- 到达判定：`haversineMeters(driverPos, targetPos) <= 50` → state = `arrived`，导航卡片换绿色 tertiary 样式
- 降级：OSRM 抛 `RoutingException` → Snackbar 提示 + polyline 改为 2 点直线 + ETA 用直线距离/默认 25km/h 估算
- Dispose：关闭 `_positionSubscription.cancel()`、`_osrm.close()`（如果实例化了独立 client）
- 代码复用：直接 import `OsrmRoutingService`, `RouteResult`, `haversineMeters`, `bearingBetween`

### 测试需求
- **TR1 (rule)**: Widget `build()` 输出树包含 `FlutterMap` widget → 证据：静态代码检查
- **TR2 (rule)**: 当 OSRM 抛错时不崩溃，`snapshot.hasError` 路径能渲染直线 polyline → 证据：mock `OsrmRoutingService.route` 抛异常做 Widget 测试或手动触发
- **TR3 (rubric, 阈值=1)**: 视觉与乘客端 `TripPlannerMapScreen` 一致性，0=完全不同 1=基本一致 2=颜色图标 100%一致 → 证据：截图对比

### Status: pending
### Blocked By: 无
### Completion Evidence: 

---

## Task 2: 拼车 (Group) 支持 — 按 current_stop_idx 自动切换导航目标

**优先级**: high  
**覆盖 AC**: AC3(group), AC6, FR6, FR7

### 范围
- 在 `DriverPickupNavigationScreen` 新增命名构造：`DriverPickupNavigationScreen.group({required String groupId, required String firstRideId})`
- 解析 `_resolveCurrentStop() → `{LatLng targetPoint, String targetLabel, bool isPickup, int riderSlot}`
  - 根据 groupId 查 `ride_groups` 表 select `optimised_stop_order`, `current_stop_idx`（Realtime Stream 订阅 `ride_groups.id = groupId`，变化触发 UI 自动刷新
  - `optimised_stop_order[current_stop_idx ?? 0`：0/1 = pickup，值/3 = dropoff
  - 根据 stop 0/1/2/3 和 ride 映射：group 对应 2 rides，通过 `rides.group_id = groupId` 按 created_at 顺序映射 rider0/rider1
- 每 2 个 pickup/destination 映射：rider0 pickup = rides[0].pickup_*, rider1 pickup = rides[1].pickup_*, rider0 dropoff = rides[0].destination_*, rider1 dropoff = rides[1].destination_*
- Realtime：`rides` 或 `ride_groups` stream 上任意变化 → 3s 内 debounce → setState 刷新目标，重算 route，Snackbar「Navigating to {next stop: P2/D1..."
- 到达时卡片：R到达状态改变时，若 current_stop_idx = 0→1 即 P1→P2（到达 P2，自动切换目标 P2，重算路线
- 最后一到达 到最后一站（D2 最后一个 dropoff）：到达时卡片显示「Final dropoff」并显示目的地」
- 「Solo 构造中，当 status 变为 en_route 后（司机可继续导航目的地（可选）或返回：默认仍导航 pickup（保持原 pickup，不做自动切到 destination，除非用户手动点 Navigate 后再 decide 再切换 destination

### 测试需求
- **TR4 (rule)**: group 2 riders，当 `current_stop_idx` 增加时，目标坐标从 Pn 5s 内改变 → 证据：Supabase stream mock 数据+Widget测试或手动执行 advance 或 Widget 测试
- **TR5 (rule)**: 4 种 stop_idx (0/1/2/3) 映射 正确取 正确取对应 pickup/destination 对应 rider → 证据：日志输出
- **TR6 (rubric, 阈值=1): stop 切换时有明确视觉反馈（颜色动画/或 Snackbar 提示），0=无反馈 1=文字 Snackbar 2=动画+Snackbar → 证据：手动

### Status: pending
### Blocked By: Task 1（单人导航屏幕已完成后才做 group
### Completion Evidence: 

---

## Task 3: 顶部导航方向指示 (Next-Mane方向箭头 + 距拐弯距离

**优先级**: medium  
**覆盖 AC**: R1, FR4, NFR6

### 范围
- 新增辅助函数 `_NextDirectionHint(driverPos, polyline, remainingDistanceMeters):
  - 在 polyline 上找到司机当前位置投影点 index i (已在 T1 已做 polyline → 在 点到下一个几何顶点集合里投影，取沿 polyline 前方约 80-150 米处的那个或下一个 N 个节点作为「waypoint」
  - 计算 driverPos→waypoint 的 bearing
  - bearing 差（方式差 相对司机 heading → 分类为 8 向：直行 / 轻微左 / 左 / 大左 / 掉头 / 轻微右 / 右 / 大右
  - 距离 = 沿 polyline 从投影点到 waypoint 的累加距离
- 根据相对司机 heading：取 `position.heading`，若 `heading` 无效（0 0 近 0 或 isFinite=false）回退→使用上一个有效 heading，若仍无效使用 `driverPos` → waypoint bearing 作为前进向
- 导航卡片显示：大号 `Icon(Icons.*_round` + 文字 "右转" + "前方 150m"
- 8 方向到 icon 映射：直行= `arrow_upward`，右 = `turn_right`，轻微右 = `trending_flat` + 斜 `arrow_forward`，左= `turn_left` 等...
- 当到达距目标 ≤ 50m:
  - 方向指示区改为绿底 success 样式：显示到达点 Marker + "你已到达上车点"
  - 按钮："I'm arrived" → 自动调发送对应 Chat 快捷回复 "I have arrived at the pickup point"

### 测试需求
- **TR7 (rule)**: 投影点后 100m 处 waypoint存在，bearing 差落入对应方向对应 8 之一 → 证据：单元测试 `_classifyDirection` 函数
- **TR8 (rubric, 阈值 = 1): 方向 UI 清晰度，0=看不清 1=基本能认 2=清晰大字 + icon 图标大，距离大，对比度高 → 证据：UI 截图

### Status: pending
### Blocked By: Task 1
### Completion Evidence: 

---

## Task 4: 入口集成 — Accept 后自动跳转 + Hub 卡片 Navigate 按钮

**优先级**: high  
**覆盖 AC**: AC1, AC7, FR10/FR11/FR12

### 范围
- 修改 `available_orders_screen.dart` 中 `_accept()` 方法 success 分支中：Scaffold Snackbar 之后（或前）push navigation screen：
  - 如果 order['group_id'] == null → `DriverPickupNavigationScreen.solo(rideId: order['id'].toString())`
  - 否则 → `DriverPickupNavigationScreen.group(groupId: order['group_id'], firstRideId: order['id'].toString())`
- 修改 `driver_home_screen.dart` 的 `_activeRide()` 中 actions Wrap：
  - 在 Contact rider 按钮右侧或旁边，对单人 ride，status=driver_assigned（尚未 Start ride）→ Navigate 按钮（导航到 pickup）
  - 单人 ride en_route 状态 → 可选显示「Navigate to destination」（或在同按钮复用同构造传目的地点 或 单独 enum destination`
  - Group 任何 active 均显示 Navigate 按钮 → push group 构造
- 导航屏幕顶部/悬浮按钮中的 "打开聊天"：
  - 单人 ride → ChatWithDriverScreen(rideId, isDriverView: true, quickReplies = const [..)
  - Group → 显示一个 PopupMenu「选择 Rider 1 / Rider 2 → 对应 rideId 打开

### 测试需求
- **TR9 (rule)**: `_accept()` success 后 `Navigator.push` 被调用 → 证据：代码审查或手动点击 Accept 调用
- **TR10 (rule)**: Hub card 中 `Navigate` 按钮在 driver_assigned/en_route 均存在且 onPressed 非 null → 证据：Widget build 代码检查 + 手动观察 UI

### Status: pending
### Blocked By: Task 1 + Task 2（group 入口）
### Completion Evidence: 

---

## Task 5: 诊断 & 润色 — 修复 lint/诊断、flutter analyze

**优先级**: medium  
**覆盖 AC**: AC8, AC4, AC5, R2, R3, R4

### 范围
- 运行 `flutter analyze lib/heng/`，新增 warning/error 修复
- IDE Diagnostics 对所有新老文件
- 可选增强：
  - R2 (rubric 代码复用优化：抽离 `Driver 专用 marker widgets 到 新的 widget，避免重复（可选，若时间够
  - R3 (rubric auto跟随模式切换：默认开启「Locate button + follow me」按钮，长按地图自动跟随（默认 true；手指拖动画布时取消跟随；点击 my location 按钮 resume follow（类似乘客端已实现方式
  - R4 (rubric 到达状态：到达后提供「I arrived」快捷回复
  - AC 4 路线重算功能在真实触发验证：模拟偏离 polyline 50m+ 手动偏离 >15s 自动重算

### 测试需求
- **TR11 (rule)**: `flutter analyze lib/heng/` 输出 0 新增 errors/warnings → 证据：terminal 输出
- **TR12 (rule)**: 所有 IDE 诊断空 → 证据：GetDiagnostics 输出
- **TR13 (rubric 综合 R2/R3/R4 每项至少 ≥ 1 分 → 证据：评分记录

### Status: pending
### Blocked By: Task 1-4
### Completion Evidence: 

---

## AC ↔ Task 覆盖矩阵

| AC | 覆盖 Task |
|---|---|
| AC1 (Accept 跳转) | Task 4 |
| AC2 (FlutterMap 存在) | Task 1 |
| AC3 (单人 + group 坐标) | Task 1 + Task 2 |
| AC4 (route 重算) | Task 5 + Task 1 |
| AC5 (到达状态颜色) | Task 1 + Task 3 |
| AC6 (group advance 切换) | Task 2 |
| AC7 (Hub Navigate 按钮) | Task 4 |
| AC8 (analyze clean) | Task 5 |
| AC9 (dispose 清理) | Task 1 |
| AC10 (降级) | Task 1 |
| R1 (方向指示清晰) | Task 3 |
| R2 (代码复用) | Task 1 + Task 5 |
| R3 (跟随模式) | Task 5 |
| R4 (到达反馈) | Task 3 + Task 5 |

