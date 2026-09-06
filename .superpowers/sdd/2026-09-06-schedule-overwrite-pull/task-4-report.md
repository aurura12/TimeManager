# Task 4 修复轮次 2 报告

基线：`96373a7 fix(schedule): harden atomic overwrite pull`

## 本轮修复

- 删除绕过 `_ongoingSave` 的覆盖专用四次 SharedPreferences 写入；覆盖快照改为经一次 staged `_saveData` 请求进入统一串行保存链，逐项检查 `set*` 的返回值。
- staged 保存每个异步边界均核验捕获的身份与 slots revision；`_saveData` 返回后、提交 `_dailySlots` 前再次核验。保存等待期间编辑或身份切换会返回 `false`，不提交远端内存快照。
- 覆盖过程通过日程状态流发布“覆盖拉取中...”、“覆盖拉取完成”或“覆盖拉取失败”，结束时发布空状态；成功仍只通知一次。
- Google 延迟同步在 Google 上传 API 前重新检查覆盖 guard；批量 Google 同步的循环与 push 回调也在真正上传前检查 guard。
- 保留上一轮的固定身份、canonical padded 路径/SHA 校验、Gitee/Google pull 活动锁和防抖重试行为。

## RED 观察

首次运行 `flutter test --timeout 30s test/schedule_overwrite_test.dart`：23 项通过、1 项失败。失败断言为覆盖流程未发布 `覆盖拉取中...`，状态列表为空。

## 验证

通过（每个测试 30 秒超时）：

```text
flutter test --timeout 30s test/schedule_overwrite_test.dart test/desktop_schedule_sync_test.dart
35 tests passed
```

`git diff --check` 通过。

`git diff --check` 通过。未运行完整 analyzer；项目所需的忽略配置文件不在工作树中，且本轮验收要求为上述两套聚焦测试。

补充提交前完整验证：`flutter test --timeout 30s` 通过，137 项测试全部通过。测试输出包含既有地图瓦片 HTTP 400 日志，但命令以退出码 0 结束。

## 提交前状态

待提交：`lib/providers/time_provider.dart`、保留的 `test/schedule_overwrite_test.dart`，以及本报告。

## 修复轮次 3

基线：`900ff97 fix(schedule): complete atomic overwrite transaction`

### 修复

- 覆盖快照保存前捕获 `daily_slots`、`pending_gitee_sync_dates`、`pending_google_sync_dates` 和 `pending_sync_dates` 的完整旧值。
- 四个新值仍经一次 `_saveData()` 请求进入既有 `_ongoingSave` 串行链；每次 `set*` 都检查返回值和写后值，并在每个异步写入边界复查 identity / slots revision。
- 任一写入返回 `false`、抛异常、写后值不符，或写入中发生 identity / revision 冲突时，尽力恢复并逐个验证全部四个旧值；回滚失败会记录错误，调用始终返回 `false`，不提交内存 replacement、undo 或 pending 状态。
- 增加窄的写后观察 seam，仅供测试在真实 `SharedPreferences` 写入成功后制造并发身份变化；生产默认不注入，写入仍由统一保存链和原生 `setString` / `setStringList` 执行。

### RED / GREEN

- RED：新回归测试在旧实现上失败，第一项 `daily_slots` 写入成功后身份变化导致其保留为远端快照，原 `2026-01-01` 数据丢失。
- GREEN：实现回滚后，同一测试通过，四个持久化 key 与覆盖前的内存日程 / pending 集合一致。

### 提交前验证

- `flutter test --timeout 30s test/schedule_overwrite_test.dart test/desktop_schedule_sync_test.dart`：通过，36 项测试。
- `flutter test --timeout 30s`：通过，138 项测试。输出包含既有地图瓦片 HTTP 400 日志，命令退出码为 0。
- `git diff --check`：通过。
