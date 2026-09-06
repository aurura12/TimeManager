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
