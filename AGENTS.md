# AGENTS.md

## Project Overview

Flutter time management app (package name `time_manager`) with Google Calendar integration, daily diary, travel records, check-in tracking, target tracking, AI daily review, voice scheduling, app logging, global search, a unified sync center, and Android local reminders (daily diary + per check-in goal). Chinese-language UI with English fallback. Supports Android, Windows desktop, and macOS.

## Architecture

- **Entry**: `lib/main.dart` → `MainScreen` (6-tab bottom nav: 记录/日记/出行/打卡/目标/我的)。Windows 平台隐藏"目标" tab（平台特性见 `lib/utils/platform_features.dart`）。启动时初始化 `AppLogService` 全局错误捕获，并对 MIUI 设备应用 SSL 修复的 `HttpOverrides`。
- **State**: `lib/providers/`
  - `time_provider.dart` → `TimeProvider` (~10000 行) — 核心业务状态：时间块、分类、目标、模板、撤销栈、统计缓存、增量保存、Google 日历同步、日程(schedule)同步、已删除事件关系
  - `theme_mode_provider.dart` → `ThemeModeProvider` (52 行) — 主题模式 (light/dark/system)
  - `target_stats_cache.dart` → `TargetStatsCache` (47 行) — 目标统计内存缓存，按日期失效
- **Models**: `lib/models/` (29 个文件)
  - 时间记录：`TimeSlot`, `Category`, `CalendarBlock`, `ScheduleTemplate`, `VoiceScheduleDraft`, `ScheduleSyncProgress`
  - 打卡系统：`CheckInGoal`, `CheckInRecord`, `CheckInDocument`, `CheckInViewFilter`
  - 目标系统：`Target`
  - 出行：`TravelRecord`, `TravelRecordsDocument`（同一文件）
  - 日记：`DiaryKind`, `DiarySearchResult`
  - AI 复盘：`DailyReviewChatMessage`, `DailyReviewChatSession`
  - 提醒：`DiaryReminderSettings` / `DiaryReminderIssue` / `DiaryReminderStatus`（`diary_reminder.dart`）、`CheckInReminderSettings` / `CheckInReminderResult`（`check_in_reminder.dart`）
  - 用户/身份：`GoogleCalendarUser`, `KnownGoogleUsers`（手动/Google 双身份模式，见 `AppIdentityService`）
  - 搜索/同步/日志：`SearchResult`, `GlobalSearchResult`（含 `GlobalSearchContentType` / `GlobalSearchIdentityFilter`）, `RemoteSyncPlatform`, `PendingSyncState`, `SyncCenterState`（含 `SyncModule` / `SyncModuleStatus`）, `AppLogEntry`, `OnThisDayEntry`
  - 分类生命周期：`DeletedEventRelation`（已删除事件的父子关系，仅本地持久化，见"数据流与关键模式"）
  - 工具：`CoordTransform`
- **Screens**: `lib/screens/` (22 个) — `MainScreen`, `HomeScreen`, `DiaryScreen`, `TravelScreen`, `CheckInScreen`, `TargetScreen`, `ProfileScreen`, plus `DailyReviewScreen`, `WordCloudScreen`, `EventDetailScreen`, `TargetDetailScreen`, `AddTargetScreen`, `GlobalSearchScreen`, `GlobalSearchDetailScreen`, `DiarySearchScreen`, `AddCheckInGoalScreen`, `CheckInDetailScreen`, `CheckInArchiveScreen`, `CheckInMapScreen` (flutter_map 地图), `SyncCenterScreen`, `AppLogScreen`, `OnThisDayScreen`
- **Services**: `lib/services/` (62 个文件)，主要板块：
  - **Google 身份 & 日历**：`GoogleCalendarService` (OAuth 2.0 + 事件同步)、`GoogleCalendarEventParser`、`HomeWidgetService` (Android 桌面小组件)、`HomeWidgetActionRouter` (小组件深链接路由)、`AppIdentityService` (手动/Google 双身份)、`GoogleSessionStore`
  - **Git 同步（Gitee/GitHub 双平台）**：`GitHubContentsApi`、`GiteeContentsApi`、`ContentsApiCommon`、`DiaryGitHubService`/`DiaryGiteeService`、`DiarySyncService` (列表/拉取/推送编排)、`TravelGitHubService`/`TravelGiteeService`、`CheckInGitHubService`/`CheckInGiteeService`、`PendingGoogleDaySyncService`（待同步状态）
  - **同步中心**：`SyncCenterOperations` + `SyncCenterController`（统一同步入口与重试）、`SyncStatusCoordinator` + `SharedPreferencesSyncStatusStore`/`InMemorySyncStatusStore`（跨页同步状态）、`SyncOperationLock`（互斥）、`RemoteSyncSettings`
  - **日程同步**：`ScheduleDayMergeService`、`ScheduleGiteeService`、`ScheduleOverwriteSnapshot`（覆盖拉取校验）、`ScheduleSyncDependencies`、`ScheduleSyncManifestStore`、日程坏格式防护相关服务
  - **分类 / 目标同步**：`CategoryGiteeService` + `CategoryDocumentMerge`（分类文档合并）、`CategorySyncDependencies`（前台分类同步 + 请求限流）、`TargetGiteeService` + `TargetDocument`（目标文档合并 + 删除墓碑）、`TargetSyncDependencies`
  - **打卡业务**：`CheckInSyncService` (合并编排)、`CheckInImageService` (图片压缩)、`CheckInLocationService` (GPS 定位 + `geocoding` 逆地理)、`CheckInPhotoCache`/`CheckInPhotoResource` (远端照片缓存与校验)
  - **搜索**：`UnifiedSearchService` (时间记录/日记/出行/打卡/目标/AI 复盘聚合搜索)、`DiarySearchService` (日记全文搜索)
  - **AI 板块**：`SiliconFlowAiService` (API 调用带重试 90s 超时)、`DailyReviewSummary` (复盘生成 + 数据哈希缓存)、`DailyReviewChatService` + `DailyReviewChatStore` (多轮对话，最多 20 轮)
  - **语音建日程**：`VoiceScheduleParser` (自然语言解析)、`VoiceScheduleSlotPlanner` (10 分钟槽位规划)，UI 在 `lib/widgets/voice_schedule_sheet.dart`
  - **应用日志**：`AppLogService` (全局错误捕获)、`AppLogStore` (持久化)、`AppLogExportService` (导出)
  - **提醒（仅 Android）**：`ReminderPlatform`（插件全局只初始化一次 + 时区 + 按 payload 分发点击路由）、`ReminderBackend`（插件薄封装）、`DiaryReminderService`（每天固定时间提醒写日记，单一实例）、`CheckInReminderService`（每个打卡目标一份，多实例）、`DiaryReminderDiagnostics`（把原生触发事件导入运行日志）。原生埋点在本地 fork 里，见 `third_party/flutter_local_notifications/FORK.md`
  - **工具**：`DataBackupService` (JSON 导入导出)、`OnThisDayService` (当年今日回顾)、`UpdateService`、`calendar_slot_refresh.dart`（`shouldClearCalendarSlotForRefresh`）、`WindowsLegacyPreferencesMigration`
  - 各数据域有对应的 `*_local_store.dart` 本地存储封装
- **Widgets**: `lib/widgets/` (18 个) — `DatePickerPanel`, `TemplateBar`, `TimeGrid`, `BrushModeCard` (刷子模式)、`CalendarSyncStatusBadge`, `VoiceScheduleSheet`, `ScheduleSyncProgressBanner`, `ProfileSettingsDrawer`, `DesktopShortcutHost` (桌面快捷键)、`DailyReviewChatSheet`, `TargetStatsSection`, `TimeWheelSheet` (时/分滚轮面板，替代 `showTimePicker`)、OnThisDay 相关组件 (`OnThisDaySheet`, `OnThisDayYearCard`)、打卡照片与地图相关组件 (`CheckInPhotoSheet`, `CheckInPhotoThumb`, `CheckInPhotoViewer`, `CheckInMapPreview`)
- **Utils**: `lib/utils/` (9 个) — `adaptive` (平台自适应)、`calendar_time_range`、`desktop_selection`、`local_day_range`、`platform_features` (按平台开关功能)、`schedule_view_dates`、`time_slot_segment`、`diary_remote_path_utils` (远端日记文件名里的日期解析与排序)、`map_tile_config` (地图瓦片配置)
- **Theme**: `lib/theme/` — `app_tokens.dart` (间距/圆角/控件高度/文字层级)、`app_theme.dart` (`ColorScheme` + `AppSurfaces` 表面层级扩展 + 全套组件主题)、`app_semantic_colors.dart` (身份色/分类色/图表色/奖牌色/状态色白名单)。规范见 `docs/design-system.md`
- **Config**: `lib/config/` — API keys and service configs (`.gitignore`d，**无 .example.dart 模板**，结构需直接查看引用方代码)

## 数据流与关键模式

- **时间粒度**：全天 144 个 10 分钟槽位 (`hour=0..23`, `minute10=0..5`)
- **持久化分层**：
  - 时间块/分类/目标/模板 → `SharedPreferences`（JSON 序列化）
  - 敏感 Token → `FlutterSecureStorage`
  - AI 复盘缓存 → `SharedPreferences`（带数据哈希键，数据变化导致缓存失效）
  - 打卡照片 → 本地文件缓存 + Git 仓库
  - 应用日志 → `AppLogStore` 本地持久化
- **远端文档布局**：所有同步文档按**身份 code 分片**（`'g'` / `'j'`，即 `DiaryKind`），切换身份看到的是不同数据集，不存在跨身份合并
  - `categories/{userCode}.json` — 分类文档（合并见 `CategoryDocumentMerge`）
  - `targets/{userCode}.json` — 目标文档（合并 + 删除墓碑，见 `TargetDocument`）
  - `schedule/{userCode}/{dateKey}.json` — 日程，按天一份（覆盖拉取校验见 `ScheduleOverwriteSnapshot`）
  - 日记 / 出行 / 打卡 — `index.txt` 列表 + 逐条文件（日记文件名形如 `…YYYY年M月D日….md`，日期解析见 `lib/utils/diary_remote_path_utils.dart`）
- **增量保存**：`TimeProvider` 追踪 `_categoriesDirty` / `_targetsDirty` / `_slotsDirty` 脏标记，只序列化变化部分
- **撤销系统**：`_undoStacks` 深拷贝快照，最多 20 步
- **Google 日历同步**：3 秒防抖 + `_isSyncing` 锁防并发。事件以 "乖乖爱心晶晶" 为识别签名，区分本 App 创建和外部事件
- **打卡合并策略**：`CheckInDocument.merge(local, remote)` 按 ID 去重，同 ID 保留较新记录
- **已删除事件聚合**：删除子事件/父事件时写入本地 `DeletedEventRelation`（含 `categoryId`、删除时父名、事件名、`isParentEvent`），历史时间块保留原 `categoryId` 以便恢复父子关系。统计口径优先级：存活分类关系 > 已删除 > 临时。该关系**只本地持久化 + 进备份**，不写入远端分类文档
- **同步状态**：`SyncStatusCoordinator` 统一收集各模块状态并在 `SyncCenterScreen` 呈现；`SyncOperationLock` 保证同一模块不并发操作。无可靠实时读取器的模块保留本次业务操作结果，不用默认 0 覆盖
- **AI 对话**：`fromReview` 标记的复盘消息不参与 API 多轮上下文，每次附带完整当日记录作为 system prompt
- **数据流**：`Screen → Provider (notifyListeners) → Service → API/Storage`。应用切后台时自动保存并取消等待中的同步
- **提醒的硬约束**（写日记提醒历史上实现过两次都因静默失效被删除，改动前务必先读 `写日记提醒实施方案.md`）：
  - 重复交给系统的 `matchDateTimeComponents: DateTimeComponents.time`，**不要**自建「到点回调再排下一次」的续订链——丢一次就永久断链
  - **不要**引入 `android_alarm_manager_plus` 或后台 Dart isolate（旧方案靠反射往后台引擎挂插件，第三方库一升级就静默失败）
  - 通知通道用 `diary_reminder_v2` 并**只创建不删除**：原生 `createNotificationChannel` 无法把已存在通道的重要性改回高，复用旧 ID 会「能发但不弹横幅、不出声」
  - 时区不可用时**拒绝排程**，不要回退 UTC；没有精确闹钟权限时降级目标是 `inexactAllowWhileIdle`（`exactAllowWhileIdle` 同样需要该权限，等于没降级）
  - `ScheduledNotificationBootReceiver` **不能**写 `android:enabled="false"`（旧实现这样写导致重启后永久不响）
  - 设置按身份隔离，未选身份时开关置灰：否则会写进 `identity_unbound_*`，选完身份后设置「凭空消失」
  - **插件只能初始化一次**：`FlutterLocalNotificationsPlugin.initialize()` 每次调用都会覆盖
    `onDidReceiveNotificationResponse`，两类提醒各自初始化会把前一个的点击回调顶掉。
    新增提醒类型必须走 `ReminderPlatform`，不要自己调 `initialize()`
  - 打卡提醒的设置**存本机、不进同步文档**：`CheckInGoal` 是白名单序列化 + 整对象按
    `updatedAt` 覆盖，往目标模型加字段会被老版本的任意一次推送静默抹掉
  - 打卡提醒的通知 id 占 `2200–2299`，用 `goalId → id` 分配表映射（目标 id 是毫秒
    时间戳，不能直接当通知 id）
  - `CheckInReminderService.reconcile(allGoals:)` 的 `allGoals` **必须是完整目标列表**，
    传部分列表会把没列进来的目标的提醒误删
  - 提醒的**日期区间只在 Dart 侧、只在 `reconcile` 时生效**：fork 的原生
    `zonedSchedule` 在 `matchDateTimeComponents != null` 时会丢弃传入的首触发日期，
    系统的每日重复也是无条件自续期的。所以「开始日后必须打开过一次 App 才会开始提醒」
    「结束日后会继续响到下次打开 App」是既定边界——**不要**试图把首触发时刻推到开始日
    （会被原生压回今天/明天，反而变成提前响），也不要改成一次性闹钟逐日铺排

## Commands

```bash
flutter pub get                    # 安装依赖
flutter analyze                    # 静态检查 (flutter_lints，无自定义规则)
flutter test                       # 运行所有测试
flutter test test/widget_test.dart # 运行单个测试文件
flutter test test/foo_test.dart --plain-name "测试用例名"  # 运行单个测试用例
flutter run                        # 启动开发模式（移动端）
flutter run -d windows             # Windows 桌面版启动
flutter build apk --release        # 构建 Android release APK

# 平台构建脚本
scripts/build_android.sh           # Android arm64 构建：bump 版本/跑测试/输出到 dist/（成功后会自动 commit + push，见「构建与发布」）
scripts/build_windows.bat          # Windows 构建（含自动下载 nuget.exe）
scripts/update_macos.sh            # macOS 构建并安装到 /Applications
scripts/run_android.sh             # 拉起 Android 模拟器/设备再 flutter run（默认 AVD Pixel_7，可用 ANDROID_EMULATOR_NAME 覆盖；多余参数透传给 flutter run）
scripts/package_macos_release.sh   # macOS .app 打包为 dist/*.dmg + .dmg.sha256
scripts/generate_update_metadata.sh <安装包…>  # 为 APK/EXE/DMG 生成同名 .sha256（Windows 用 generate_update_metadata.ps1）
scripts/publish_android_release.sh # 构建 + 发布到 Gitee Release（见「构建与发布」）
scripts/installer.iss              # Inno Setup 6 打 Windows 安装包（上传 Gitee release）
```

## 构建与发布

`scripts/build_android.sh` 的默认行为不只是构建，成功后还会 **git commit + push**：

1. 获取依赖、跑 `flutter analyze` + `flutter test`
2. 自动递增版本号：次版本 +1、patch 归零、构建号 +1（如 `1.95.3+13` → `1.96.0+14`）
3. 构建 Android arm64-v8a release APK
4. 把带版本号的 APK 和同名 `.sha256` 复制到 `dist/`
5. 只提交 `pubspec.yaml` 的版本号变更并 push 到当前分支的上游（不会把其他未提交改动带进这次提交）

构建失败或中断时只回滚 `pubspec.yaml` 的版本号改动。开关：`--skip-tests`、`--skip-bump`、`--no-git`、`--no-copy`、`--target-platform android-arm|android-arm64|android-x64`、`--dist-dir DIR`、`--dry-run`。

`scripts/publish_android_release.sh` 在构建之上发布到 Gitee Release：

- 发布仓库默认 `zhou-jiaqi10/time_manager_releases`（`GITEE_OWNER` / `GITEE_REPO` 可覆盖）。**必须与 `lib/services/update_service.dart` 保持一致**，改发布仓库要两边一起改
- Release 说明文件固定为 `docs/release-notes.md`（`--notes-file` 覆盖）
- 上传顺序是**先 `.sha256` 后 APK**，避免手机在发布过程中拿到缺校验摘要的安装包
- 默认**跳过** `flutter analyze` + `flutter test`，发布前想再检查一次要显式加 `--run-tests`
- Token 优先读 `GITEE_TOKEN` 环境变量，未设置时回落到 `lib/config/diary_gitee_config.dart`
- 用 `--artifact <已有 APK>` + `--skip-build` 可以跳过构建、只发已有的包

两个仓库不要混淆：**同步数据**在 `RemoteRepoConfig` 里的 `love_diary`，**应用发布**在 `time_manager_releases`。

## Config Files (Secrets — .gitignore'd)

`lib/config/` 下 6 个文件全部被 gitignore，需本地手动创建（**没有 .example.dart 模板**，字段结构参考引用它们的 service 代码）：

1. `lib/config/diary_github_config.dart` — GitHub token (日记同步)
2. `lib/config/diary_gitee_config.dart` — Gitee token (日记同步)
3. `lib/config/github_config.dart` — GitHub 通用配置
4. `lib/config/remote_repo_config.dart` — 远程仓库配置
5. `lib/config/siliconflow_config.dart` — AI service API key
6. `lib/config/google_sign_in_config.dart` — Google OAuth client IDs

Never commit them.

## Key Dependencies

- `provider` — 状态管理 (ChangeNotifier)
- `google_sign_in` + `googleapis` + `extension_google_sign_in_as_googleapis_auth` — Google OAuth + Calendar API
- `flutter_secure_storage` — 加密存储 Token
- `home_widget` — Android 桌面小组件
- `fl_chart` — 统计图表 (折线图/饼图)
- `flutter_map` + `latlong2` — 打卡地图
- `geolocator` + `geocoding` — GPS 定位与逆地理 (打卡)
- `shared_preferences` — 本地数据持久化
- `http` — HTTP 请求 (Git API / AI API)
- `file_picker` + `path_provider` — 备份导入导出
- `image_picker` + `flutter_image_compress` — 打卡拍照和压缩
- `logger` — 日志
- `flutter_local_notifications` — 本地通知（**经 `dependency_overrides` 指向 `third_party/flutter_local_notifications` 的本地 fork**，用于给写日记提醒的原生触发埋点；改动见该目录下 `FORK.md`）+ `timezone` / `flutter_timezone` — 时区
- `flutter_slidable` / `reorderables` — 列表滑动操作与拖拽排序
- `url_launcher` / `package_info_plus` — 外链与版本信息

## Testing

- `test/` 有 76 个 dart 测试文件（约 18100 行）+ 2 个 shell 脚本测试（`update_macos_script_test.sh`、`update_metadata_script_test.sh`），覆盖同步合并、语音解析、日历解析、桌面适配、日志系统、备份回滚、身份隔离等核心逻辑
- `test/visual_system_test.dart` — 视觉系统守护测试：对比度计算、主题一致性、令牌使用约束（改 `lib/theme/` 或页面配色时必跑）
- `test/widget_test.dart` — smoke test + platform channel mock 模板：`_FakeGoogleSignInPlatform`、`SharedPreferences.setMockInitialValues`、mock `home_widget`/`flutter_secure_storage`/`path_provider` 通道、`tester.runAsync` 真实 IO。新写 widget 测试可参照此文件搭建环境
- `test/support/fake_app_log_store.dart` — 可注入失败的 Fake store
- `test/support/fake_reminder_backend.dart` — 两类提醒共用的后端 Fake（刻意不实现删除通道的方法，作为「绝不删通道」的编译期保证）
- `test/diary_reminder_service_test.dart` / `diary_reminder_diagnostics_test.dart` / `diary_reminder_drawer_test.dart` / `time_wheel_sheet_test.dart` — 写日记提醒的排程、原生事件导入、抽屉 UI 与滚轮时间面板
- `test/check_in_reminder_service_test.dart` / `check_in_reminder_ui_test.dart` — 打卡提醒的多实例排程与编辑页入口
- 写提醒相关的 widget 测试要注意：抽屉是长 `ListView`，懒构建会让折叠线以下的条目根本不挂载，需要把测试视口调高；另外 `AppIdentityService.load()` 每次都会重读偏好，测试里的身份必须放在偏好键 `schedule_user_kind` 里，靠 `adoptManualKind` 设进去会被覆盖
- 测滚轮用 `tester.drag(finder, Offset(0, -44))` 拖动一格；换主题重跑时**必须先把面板关掉**，否则 `pumpWidget` 会复用 Navigator 状态，上一轮的弹层还在、下一次点击落不到按钮上
- 无 CI 流程配置

## Conventions

- Code and UI text are in Chinese
- Config files with secrets are always `.gitignore`d — never commit
- 平台差异化功能通过 `lib/utils/platform_features.dart` 控制（如 Windows 隐藏目标 tab）
- 视觉规范：页面不得硬编码颜色/圆角/间距/字号字面量，统一引用 `lib/theme/` 三文件（`AppSpacing`/`AppRadius`/`AppSizes`/`AppText`、`AppSurfaces.of(context)`、`AppSemanticColors`）；照片浮层等主题无关的黑色 scrim 属于允许的例外。守卫测试 `test/visual_system_test.dart`
- 设计文档在 `docs/superpowers/{plans,specs}/`；已完结的问题记录归档在 `docs/archive/`。根目录只保留 `AGENTS.md`、`README.md` 和活跃的 `待修复问题.md` / `写日记提醒实施方案.md`
- `third_party/` 下是 vendored 的第三方插件 fork，已在 `analysis_options.yaml` 里整体 exclude，不参与本项目的静态检查；升级上游时按该目录下 `FORK.md` 的步骤重做
