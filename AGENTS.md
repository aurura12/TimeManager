# AGENTS.md

> 本文件是本仓库唯一的编码代理指南（CodeBuddy Code / Claude Code 均读取此文件，仓库内不存在 CODEBUDDY.md）。

## Project Overview

Flutter time management app (package name `time_manager`) with Google Calendar integration, daily diary, travel records, check-in tracking, target tracking, AI daily review, voice scheduling, app logging, global search, a unified sync center, and Android local reminders (daily diary + per check-in goal). Chinese-language UI with English fallback. Supports Android, Windows desktop, macOS, and iOS. iOS 的编译、真机安装 / 运行与调试连接均已验证可用，但构建 / 真机调试**必须在 macOS + Xcode 上**进行；平台差异与踩坑见「iOS 平台约束」。

## 改动前必读（高风险区域索引）

本文件很长，核心约束分散在各节。**改动以下区域前，先读对应小节再动手，不要只看代码：**

- **本机提醒（写日记 / 打卡）** → 见「提醒的硬约束」，并先读根目录 `写日记提醒实施方案.md`（历史上两次实现都因静默失效被删）
- **日程自动同步（无感）** → 见「日程自动同步（无感）」，轮询 / 基线记账 / 并发互斥 / **待同步队列的身份归属** 全在里面
- **背景图（壁纸）** → 见「背景图（壁纸，仅本机）」，本地图片路径绝不进同步或备份
- **同步 / 身份分片 / 跨身份数据** → 见「远端文档布局」与「分类不带默认种子 + 「临时」仅本机」；切身份文案差异见「待同步队列的身份归属」
- **视觉（配色 / 间距 / 字号 / 圆角）** → 见「Conventions」，规范在 `docs/design-system.md`，改后必跑 `test/visual_system_test.dart`

## 首次本地开发前提

1. 在 `lib/config/` 下创建 6 个密钥文件（无 `.example.dart` 模板，字段结构参考引用方 service，见「Config Files」）——**缺少任一文件项目无法编译**
2. `flutter pub get` 安装依赖
3. `flutter run`（移动端）或 `flutter run -d windows`（桌面）

Android 构建必须用 JDK 17（详见「环境要求」），用系统默认的 JDK 25 会失败。

iOS 构建 / 真机调试**必须在 macOS + Xcode 上**进行，Windows 上只能完成工程生成与代码适配。`lib/utils/platform_features.dart` 只把 Windows / macOS 判定为桌面端，**iOS 会落进移动端分支**（`supportsCameraCapture` / `updateAssetSuffix` 等按移动端处理）——因此凡是 Android / 桌面独占的能力都必须用该文件显式判定并加守卫，不能只在 UI 上按「移动端 / 桌面端」二分。已按此补的守卫：`supportsHomeWidget`（桌面小组件仅 Android）、`supportsInAppUpdate`（应用内更新仅 Android / Windows / macOS，iOS 无通道）。详见「iOS 平台约束」。

## Architecture

- **Entry**: `lib/main.dart` → `MainScreen` (默认 6-tab bottom nav: 记录/日记/出行/打卡/目标/我的，Android / Windows / macOS 均支持自定义显示与排序)。启动时初始化 `AppLogService` 全局错误捕获，并对 MIUI 设备应用 SSL 修复的 `HttpOverrides`。
- **State**: `lib/providers/`
  - `main_tab_provider.dart` → `MainTabProvider` — 本机导航偏好（`app_main_tabs_v1`），与身份无关、不进同步/备份。入口「我的 → 设置 → 操作与布局 → 底部标签」，至少显示两个标签且保留「我的」；`MainTabId` 的稳定身份与显示顺序分离，排序/隐藏不能交换或销毁已构建页面的状态。启动先读偏好，再按可见顺序懒构建首个页面
  - `time_provider.dart` → `TimeProvider` (~11000 行) — 核心业务状态：时间块、分类、目标、模板、撤销栈、统计缓存、增量保存、Google 日历同步、日程(schedule)同步、已删除事件关系
  - `theme_mode_provider.dart` → `ThemeModeProvider` (52 行) — 主题模式 (light/dark/system)
  - `desktop_shortcut_provider.dart` → `DesktopShortcutProvider` — 本机快捷键偏好（`desktop_shortcuts_v1`），不依赖身份、不进同步或备份；保存成功后更新绑定。稳定命令与键位定义在 `models/desktop_shortcut.dart`，设置在「我的 → 设置 → 操作与布局 → 键盘快捷键」。`DesktopShortcutHost` 分层注册全局 / 主导航 / 当前页 / 表单命令，不能把记录页撤销和切日动作放到 Navigator 外；隐藏 Tab 用 `MainTabActivity` + `ExcludeFocus` 禁用，弹层显示时检查宿主路由 `isCurrent`，输入焦点保留文字编辑并避让 IME composing。数字键按可见标签顺序，表单保存只调用既有校验和保存入口
  - `desktop_layout_provider.dart` → `DesktopLayoutProvider` — 本机桌面导航与事件栏宽度（`desktop_layout_v1`），独立于身份、不进同步/备份，落盘成功后才更新偏好。默认底部导航，可在「我的 → 设置 → 操作与布局 → 桌面布局」选宽屏左侧导航；1000 宽度断点以下回到底部。`MainScreen` 跨导航模式/宽度保持相同 `Row → Expanded → IndexedStack` 结构，不能重建 Tab 状态；排序、隐藏与快捷键仍统一使用 `MainTabProvider.visibleTabs`。`HomeScreen` 分隔条拖动时仅预览、松手保存，窗口变窄只限制显示宽度，不能覆盖用户偏好；桌面事件区用可拖排的多列布局，移动端仍保留列表
  - `target_stats_cache.dart` → `TargetStatsCache` (47 行) — 目标统计内存缓存，按日期失效
  - `wake_up_provider.dart` → `WakeUpProvider` — 目标页起床记录：每个自然日一条、精确到分钟，最近 7 天平均只计已记录日期。卡片「查看更多」进入 `WakeUpHistoryScreen`，可按最近 30 天 / 90 天 / 全部 / 自选日期查看平均、最早、最晚起床时间、趋势与每日明细；`recordsInRange` 按自然日含首尾筛选、日期倒序返回当前身份记录。应用入口全局创建，隐藏目标页也继续同步；本机经 `WakeUpLocalStore` 按身份保存数据与待上传标记，远端经 `WakeUpGiteeService` 双向同步。切身份清空旧视图，异步保存保留原身份归属、旧响应不能混入新身份；保存成功后才更新显示。目前不进 JSON 备份
  - `background_image_provider.dart` → `BackgroundImageProvider` — 背景图（壁纸）本机状态：图片路径 / 开关 / 照片不透明度 / 表面不透明度。**刻意独立于业务数据 Provider：本地图片路径绝不进同步或备份快照**（`lib/services/` 与 `lib/models/` 均不引用它）。契约见「数据流与关键模式」的背景图一节
  - `event_label_style_provider.dart` → `EventLabelStyleProvider` — 事件名显示偏好（`app_event_label_style_v1`，默认两行），**本机设置、独立于身份、不进同步或备份**；只决定 `EventLabelText` 渲染 1 行还是 2 行，名字被截断时靠长按（手机）/ 悬停（桌面）看全名。设置入口是 `EventLabelSettingsScreen`
- **Models**: `lib/models/` (36 个文件)
  - 时间记录：`TimeSlot`, `Category`, `CalendarBlock`, `ScheduleTemplate`, `VoiceScheduleDraft`, `ScheduleSyncProgress`
  - 打卡系统：`CheckInGoal`, `CheckInRecord`, `CheckInDocument`, `CheckInViewFilter`
  - 目标系统：`Target`、`TargetProgress` / `TargetPeriodRange`（`target_progress.dart`，统一进度计算的结果模型）
  - 起床记录：`WakeUpRecord`（起床时刻与 `updatedAt` 分开）、`WakeUpDocument`（按日期合并 + 删除墓碑，待上传标记仅写本机）
  - 出行：`TravelRecord`, `TravelRecordsDocument`（同一文件）
  - 日记：`DiaryKind`, `DiarySearchResult`
  - AI 复盘：`DailyReviewChatMessage`, `DailyReviewChatSession`
  - 提醒：`DiaryReminderSettings` / `DiaryReminderIssue` / `DiaryReminderStatus`（`diary_reminder.dart`）、`CheckInReminderSettings` / `CheckInReminderResult`（`check_in_reminder.dart`）
  - 用户/身份：`GoogleCalendarUser`, `KnownGoogleUsers`（手动/Google 双身份模式，见 `AppIdentityService`）
  - 导航/桌面偏好：`MainTabId`（`main_tab_id.dart`）、`DesktopShortcutActionType` / `DesktopKeyBinding`（`desktop_shortcut.dart`）、`EventLabelStyle`（`event_label_style.dart`，事件名两行/单行，带稳定 `id` 与 `maxLines`）
  - 搜索/同步/日志：`SearchRecordEntry` / `SearchRecordGroup`, `GlobalSearchResult`（含 `GlobalSearchContentType` / `GlobalSearchIdentityFilter`）, `RemoteSyncPlatform`, `PendingSyncState`, `SyncModuleState`（含 `SyncModule` / `SyncModuleStatus`）, `AppLogEntry`, `OnThisDayEntry`
  - 分类生命周期：`DeletedEventRelation`（已删除事件的父子关系，仅本地持久化，见"数据流与关键模式"）
  - 工具：`CoordTransform`
- **Screens**: `lib/screens/` (27 个) — `MainScreen`, `HomeScreen`, `DiaryScreen`, `TravelScreen`, `CheckInScreen`, `TargetScreen`, `ProfileScreen`, plus `DailyReviewScreen`, `WordCloudScreen`, `EventDetailScreen`, `TargetDetailScreen`, `AddTargetScreen`, `GlobalSearchScreen`, `GlobalSearchDetailScreen`, `DiarySearchScreen`, `AddCheckInGoalScreen`, `CheckInDetailScreen`, `CheckInArchiveScreen`, `CheckInMapScreen` (flutter_map 地图), `SyncCenterScreen`, `AppLogScreen`, `OnThisDayScreen`, `WakeUpHistoryScreen` (起床历史), `MainTabSettingsScreen` (底部标签设置), `DesktopLayoutSettingsScreen` (桌面布局设置), `DesktopShortcutSettingsScreen` (快捷键设置), `EventLabelSettingsScreen` (事件名显示设置，从「我的 → 设置」进入)
- **Services**: `lib/services/` (67 个文件)，主要板块：
  - **Google 身份 & 日历**：`GoogleCalendarService` (OAuth 2.0 + 事件同步)、`calendarEventToBlock`（`google_calendar_event_parser.dart`）、`HomeWidgetService` (Android 桌面小组件)、`HomeWidgetActionRouter` (小组件深链接路由)、`AppIdentityService` (手动/Google 双身份)、`AppUserIdentityStore` (身份信息本地存储)、`GoogleSessionStore`
  - **Git 同步（Gitee/GitHub 双平台）**：`GitHubContentsApi`、`GiteeContentsApi`、`contents_api_common.dart`（`ContentsTreeEntry` / `ContentsDirectoryResult` 等公共类型）、`DiaryGitHubService`/`DiaryGiteeService`、`DiarySyncService` (列表/拉取/推送编排)、`TravelGitHubService`/`TravelGiteeService`、`CheckInGitHubService`/`CheckInGiteeService`、`PendingGoogleDaySyncResult`（待同步状态）
  - **同步中心**：`SyncCenterOperations` + `SyncCenterController`（`sync_center_service.dart`，统一同步入口与重试）、`SyncStatusCoordinator` + `SharedPreferencesSyncStatusStore`/`InMemorySyncStatusStore`（`sync_status_coordinator.dart`，跨页同步状态）、`SyncOperationLock`（互斥）、`RemoteSyncSettings`
  - **日程同步**：`schedule_day_merge.dart`（`parseScheduleContent` / `mergeScheduleSlots`，单日日程解析与合并）、`ScheduleGiteeService`、`ScheduleOverwriteSnapshot`（`schedule_overwrite.dart`，覆盖拉取校验）、`ScheduleSyncDependencies`、`ScheduleSyncManifestStore`、`ScheduleJsonPatch`（`schedule_json_codec.dart`，后台 isolate 里的 JSON 合并）、日程坏格式防护相关服务
  - **分类 / 目标同步**：`CategoryGiteeService` + `CategoryDocument`（分类文档合并）、`CategorySyncDependencies`（前台分类同步 + 请求限流）、`TargetGiteeService` + `TargetDocument`（目标文档合并 + 删除墓碑）、`TargetSyncDependencies`、`TargetProgressCalculator`（目标进度的统一计算入口）
  - **起床记录同步**：`WakeUpGiteeService` + `WakeUpSyncDependencies`（复用内容 API 与 Gitee Token）、`WakeUpLocalStore`（数据 / 修改时间 / 删除墓碑 / 待上传标记在一个 JSON 中原子保存）
  - **打卡业务**：`CheckInSyncService` (合并编排)、`CheckInImageService` (图片压缩)、`CheckInLocationService` (GPS 定位 + `geocoding` 逆地理)、`CheckInPhotoCache`/`CheckInPhotoResource` (远端照片缓存与校验)
  - **搜索**：`UnifiedSearchService` (时间记录/日记/出行/打卡/目标/AI 复盘聚合搜索)、`DiarySearchService` (日记全文搜索)
  - **AI 板块**：`SiliconFlowAiService` (API 调用带重试 90s 超时)、`DailyReviewSummaryBuilder` (复盘生成 + 数据哈希缓存)、`DailyReviewChatService` + `DailyReviewChatStore` (多轮对话，最多 20 轮)
  - **语音建日程**：`VoiceScheduleParser` (自然语言解析)、`VoiceScheduleSlotPlanner` (10 分钟槽位规划)，UI 在 `lib/widgets/voice_schedule_sheet.dart`
  - **应用日志**：`AppLogService` (全局错误捕获)、`AppLogStore` (持久化)、`AppLogExportService` (导出)
  - **提醒（仅 Android）**：`ReminderPlatform`（插件全局只初始化一次 + 时区 + 按 payload 分发点击路由）、`ReminderBackend`（插件薄封装）、`DiaryReminderService`（每天固定时间提醒写日记，单一实例）、`CheckInReminderService`（每个打卡目标一份，多实例）、`DiaryReminderDiagnostics`（把原生触发事件导入运行日志）。原生埋点在本地 fork 里，见 `third_party/flutter_local_notifications/FORK.md`
  - **工具**：`DataBackupService` (JSON 导入导出)、`OnThisDayService` (当年今日回顾)、`UpdateService`、`calendar_slot_refresh.dart`（`shouldClearCalendarSlotForRefresh`）、`TransactionalPreferenceString`（单键偏好串行读写 + 失败回滚进程内缓存）、`WindowsLegacyPreferencesMigration`
  - 各数据域有对应的 `*_local_store.dart` 本地存储封装
- **Widgets**: `lib/widgets/` (35 个) — `DatePickerPanel`, `TemplateBar`, `TimeGrid`, `BrushModeCard` (刷子模式)、`DataFailureBanner` (数据故障横幅：初始化失败 / 本地保存失败，挂在 `MainScreen` 内容区顶部)、`CalendarSyncStatusBadge`, `VoiceScheduleSheet`, `ScheduleSyncProgressBanner`, `ProfileSettingsDrawer`, `DesktopShortcutHost` (桌面快捷键)、`DailyReviewChatSheet`, `TargetStatsSection`, `showTimeWheelSheet` (时/分滚轮面板，替代 `showTimePicker`)、`BackgroundImageLayer` / `BackgroundImagePreview` (背景图：全窗口壁纸层 + 设置预览)、OnThisDay 相关组件 (`showOnThisDaySheet`, `OnThisDayYearCard`)、打卡照片与地图相关组件 (`CheckInPhotoSheet`, `CheckInPhotoThumb`, `CheckInPhotoViewer`, `CheckInMapPreview`)、导航组件 (`MainTabNavigation`, `MainTabActivity`)、目标组件 (`DesktopTargetCard`, `TargetCalendarDay` 目标月历、`TargetProgressIndicator`)、跨日 (`DayChangeBoundary` 可见时定到零点并在跨日 / 回前台 / 重新可见时回调，`TargetDayRefresh` 沿用同一计时方式)、出行桌面组件 (`TravelDesktopCalendar`, `TravelRecordTable` / `TravelMonthlyTable`, `TravelDateDetails`)、起床组件 (`WakeUpCard`, `WakeUpChart`)、颜色选择 (`ColorPickerPanel`, `showThemeColorSheet`)、事件名文本 (`EventLabelText`：按 `EventLabelStyle` 渲染 1/2 行，只在真被省略时才挂 Tooltip，手机长按 / 桌面悬停看全名)、`CurrentTimeMarker` (今天这一列的「现在」小圆点，每分钟刷新、随滚动移动，不拦手势)
- **Utils**: `lib/utils/` (13 个) — `adaptive` (平台自适应)、`app_lifecycle` (`isAppBackgroundedLifecycleState`：只有 `paused` / `hidden` / `detached` 算后台，桌面最小化走 `hidden`)、`calendar_time_range`、`desktop_selection`、`local_day_range`、`platform_features` (按平台开关功能)、`schedule_view_dates`、`time_block_resize` (拖动时间块边界调时长的纯函数)、`time_slot_segment`、`timeline_geometry` (分钟 ↔ 时间轴 y / 「滚到现在」偏移)、`swipe_navigation` (左右滑切日判定)、`diary_remote_path_utils` (远端日记文件名里的日期解析与排序)、`map_tile_config` (地图瓦片配置)
- **Theme**: `lib/theme/` — `app_tokens.dart` (间距/圆角/控件高度/文字层级)、`app_theme.dart` (`ColorScheme` + `AppSurfaces` 表面层级扩展 + `AppWallpaperTheme` 壁纸扩展 + `context.wallpaperFill()`/`adaptSemanticFill()` + 全套组件主题)、`app_semantic_colors.dart` (身份色/分类色/图表色/奖牌色/状态色白名单)、`background_image_contrast.dart` (`BackgroundImageContrast` 背景图对比度与 sRGB 逐通道合成)、`app_scroll_behavior.dart` (`AppScrollBehavior`：桌面端纵向列表常显滚动条，移动端不变)。规范见 `docs/design-system.md`
- **Config**: `lib/config/` — API keys and service configs (`.gitignore`d，**无 .example.dart 模板**，结构需直接查看引用方代码)

## 数据流与关键模式

- **时间粒度**：全天 144 个 10 分钟槽位 (`hour=0..23`, `minute10=0..5`)
- **跨日自动推进**：`TimeProvider` 用构造时的「今天」基线判断是否跨日；`advanceToTodayIfNeeded()` **只在用户仍停留在此前那个今天时**才把 `_currentDate` 推进到新的一天，手动翻到历史日期时不抢视图（导航被身份切换 / 覆盖恢复挡住时返回 false，等下次检查重试）。触发点：回前台（`onAppResumed`）+ 记录 / 日记 / 出行 / 打卡 / 我的页的 `DayChangeBoundary`（可见且前台时定到零点，跨日 / 回前台 / 重新可见时补检，隐藏页暂停）。日记和出行只在自己选中的正是旧「今天」时跟着翻页；记录页翻页时清掉旧日期的待分配选择与刷子状态，避免把数据写进昨天。路由页同样接 `DayChangeBoundary`：每日复盘把新的一天补到日期条顶部（用户停在历史日期时不抢视图；程序化滚动期间按 `_anchoringSelection` 屏蔽滚动反推选中日期），全局搜索的相对区间（近 7 天 / 30 天 / 一年）在跨日后重算，全部与自定义区间不动
- **空槽位兜底**：`slotsForDate` 在初始化失败或身份 / 覆盖事务进行中会返回**空列表**（`time_provider.dart:1901-1903`），`TimeGrid` 遇到长度不足的列表只画空行、绝不下标取槽位；失败原因由壳层 `DataFailureBanner`（顶部横幅 + 查看日志）说明。删掉这条兜底，初始化失败会直接红屏而不是提示
- **持久化分层**：
  - 时间块/分类/目标/模板 → `SharedPreferences`（JSON 序列化）
  - 敏感 Token → `FlutterSecureStorage`
  - AI 复盘缓存 → `SharedPreferences`（带数据哈希键，数据变化导致缓存失效）
  - 打卡照片 → 本地文件缓存 + Git 仓库
  - 应用日志 → `AppLogStore` 本地持久化
- **远端文档布局**：所有同步文档按**身份 code 分片**（`'g'` / `'j'`，即 `DiaryKind`），切换身份看到的是不同数据集，不存在跨身份合并
  - `categories/{userCode}.json` — 分类文档（合并见 `CategoryDocument`）
  - `targets/{userCode}.json` — 目标文档（合并 + 删除墓碑，见 `TargetDocument`）
  - `wake_up/{userCode}.json` — 起床文档（独立于目标文档，避免旧版目标上传抹掉起床记录）
  - `schedule/{userCode}/{dateKey}.json` — 日程，按天一份（覆盖拉取校验见 `ScheduleOverwriteSnapshot`）
  - 日记 / 出行 / 打卡 — `index.txt` 列表 + 逐条文件（日记文件名形如 `…YYYY年M月D日….md`，日期解析见 `lib/utils/diary_remote_path_utils.dart`）
- **分类不带默认种子 + 「临时」仅本机**：新装**不再注入默认分类**（`_defaultCategories()` 已删除），本地分类初始为空，靠远端拉取或用户自建；解析失败也只回退为空列表，避免把默认数据推到远端覆盖真实分类。`temporaryCategoryName`（「临时」）是首页的快捷入口分类，**只在本机存在**：所有同步边界——合并、冲突判定、推送编码——都必须走 `_syncableCategories()` 把它剔除，不要直接用 `_categories`；`_applyMergedCategories()` 应用合并结果后要 `_ensureTempCategory()` 补回本机入口。分类同步在「本地没有可同步分类且无删除墓碑」时**只采纳远端、绝不推送**，避免新设备/新装把远端真实分类覆盖成空
- **增量保存**：`TimeProvider` 追踪 `_categoriesDirty` / `_targetsDirty` / `_slotsDirty` 脏标记，只序列化变化部分。普通时间块编辑经 `_scheduleDataSave` 做 250ms 防抖；`_saveData` 直接取消防抖并等待落盘，供同步、切后台、切身份、导入等流程使用。`daily_slots` 格式保持单个 JSON blob，增量分支通过 `ScheduleJsonPatch` 在同一后台 isolate 中解码、合并和编码。保存成功清脏时同时核对保存请求版本与槽位编辑版本，避免后台编码期间的新编辑被清掉。统计缓存在内存修改时按日期区间立即失效，不能等防抖落盘再失效
- **撤销系统**：`_undoStacks` / `_redoStacks` 深拷贝按日快照，最多 20 步，保留最近编辑的 7 个日期；桌面三列撤销以 `_lastEditedDateKey` 为准。新编辑清空重做分支，切身份 / 覆盖恢复 / 成功导入备份清空两种栈。撤销和重做本身是新修改，变化的槽位更新修改时间，恢复为空槽时写删除墓碑，并走既有缓存失效、待同步和防抖保存链路
- **拖动时间块边界调时长**：网格里「块」= 连续且 `canJoinTimeSlots` 的槽位集合，可跨小时；改时长 = 改首尾槽位，由 `TimeProvider.resizeTimeBlock(TimeSlotResizeRequest)`（`lib/models/time_slot_resize.dart`）完成，纯函数在 `lib/utils/time_block_resize.dart`。约束：**一次手势只调一次 `_saveSnapshot`**（拖拽期间 `TimeGrid` 只做 `applyTimeBlockResizePreview` 预览，松手才提交）；缩短必须用 `_clearSlotAt(markDeleted: true)` 给被裁掉的一端写墓碑；与相邻记录重叠按既有语义**直接覆盖**；`isFromCalendar` 的日历块不显示把手、Provider 二次拒绝。**边缘手势必须用外层 `Listener` + `_ResizeSession`，不能挂子 `GestureDetector`**——预览会改变 `Row` 的 children 数量，段的 Element 被销毁重建后识别器会丢指针。提交时用 `expectedStart/expectedEnd` + label/categoryId/color 做 stale 校验，拖拽期间被后台同步改写就放弃写入
- **数据故障提示**：`MainScreen` 内容区顶部按优先级显示 `DataFailureBanner`——初始化失败（编辑已暂停 + 查看日志）优先于本地保存失败（`hasLocalSaveFailure` + 重试保存）。**必须挂在壳层而不是记录页**：底部标签允许隐藏「记录」，挂在页面里用户可能永远看不到。保存失败只在「真的写盘失败」时置位（`_shouldReportLocalSaveFailure` 排除初始化失败、身份切换、覆盖事务这些既定阻塞），脏标记保留、下次编辑或 `retryLocalSave()` 重试，成功后自动清除横幅
- **其它模块的本地保存失败也不静默**：出行 / 打卡 / 日记的 `*_local_store.save*` 返回 `bool`，调用方必须处理。出行删除失败会回滚内存且不推送远端；日记保存失败会显示「本地保存失败」并拒绝切换日期（否则会丢掉编辑框里未落盘的文字），切后台 / 桌面最小化（paused / hidden）时会立即落盘，不等 350ms 防抖；打卡落盘失败直接返回失败结果，不报「同步成功」。store 内已把平台通道异常统一折算成 `false`；新增本地写入时不要忽略 `prefs.setString` 的返回值，也不要让异常冒到 UI
- **统计缓存**：分类区间、每日趋势与连续块次数各用独立缓存，修改日期只使相交区间失效。日期统计统一忽略时分秒并按自然日遍历，词云缓存键不能包含 `DateTime.now()` 的时分秒。「总览」区间的起点取 `TimeProvider.earliestRecordedDay`（最早有已记录槽位的自然日），不要再写死年份；没有记录时退回今天。`MainTabActivity` 给保活 Tab 传递可见状态；`ProfileScreen` 隐藏时复用已构建内容，返回时重新读取最新统计并保留滚动与筛选状态
- **Google 日历同步**：3 秒防抖 + `_isSyncing` 锁防并发。事件以 "乖乖爱心晶晶" 为识别签名，区分本 App 创建和外部事件
- **打卡合并策略**：`CheckInDocument.merge(local, remote)` 按 ID 去重，同 ID 保留较新记录
- **起床同步**：修改后 3 秒防抖，启动 / 切身份 / 回前台自动拉取，前台每 60 秒刷新；后台停表，有待上传记录时补同步一次，慢拉取占用同步锁时由收尾补做。自动同步与同步中心共用入口和 `SyncOperationLock`：先读取并严格校验远端文档、按日期合并并本机落盘，再带 SHA 上传，版本冲突最多重试三次。`updatedAt` 较大的修改胜出，同时间戳取较早起床时间，删除同版本优先；删除墓碑保留以防离线旧记录复活。上传期间的新编辑保留待上传标记，失败不能覆盖远端或清掉本机记录；原先仅本机的 v1 记录迁移为最低版本加入首次同步
- **已删除事件聚合**：删除子事件/父事件时写入本地 `DeletedEventRelation`（含 `categoryId`、删除时父名、事件名、`isParentEvent`），历史时间块保留原 `categoryId` 以便恢复父子关系。统计口径优先级：存活分类关系 > 已删除 > 临时。该关系**只本地持久化 + 进备份**，不写入远端分类文档
- **日程自动同步（无感）**：推送靠编辑后 3 秒防抖（`_markScheduleGiteePending` → `_flushPendingScheduleGiteeSync`），切后台立即补推一次。拉取除启动/切日/切身份外，还有**前台每 60 秒轮询 + 回前台检查**（`refreshSchedulesFromRemoteInBackground`，间隔由 `scheduleAutoRefreshInterval` 控制，生产在 `main.dart` 传 60 秒）。轮询**只做一次远端文件列表请求**取 Git blob SHA，用 `ScheduleSyncManifest`（远端 SHA + 本地 FNV-1a 指纹，按身份分片存 `schedule_sync_manifest_v1_<userCode>`）判断哪些可见日期需要重新下载正文——远端与本地完全一致时 0 次正文下载、0 次落盘、0 次 `notifyListeners`；窗口为桌面 3 天 / 手机 1 天（`scheduleDatesForView`）。**改动这块前先读下面这些约束，都是踩过坑换来的：**
  - **远端文件列表**必须走 `GiteeContentsApi.listTree()`（它会读 `truncated` 并展开子树）。**不要裸调 tree 接口**——拿到被截断的列表会把缺失日期误判成"远端不存在"，之后长期看不到远端修改。另外：**目录列表不能按单文件大小否决**（`_giteeFetchTree` 曾对每个 blob 套 2MB 上限，而共享仓库里打卡照片合法到 10MB → 一张照片就让整份列表失败、后台日程同步全废）。单文件大小限制只属于正文读取/上传路径（`pullText`/`pushText`），tree 元数据使用独立的 `maxTreeResponseBytes`，并由 `maxTreeEntries` 等上限兜底。
  - **基线记账**：只对"这一轮真的下载并合并过"的日期记账（含"远端没有这天"的情况）。正文没读到就只留 `pendingKinds='error'` 让下一轮重试，**绝不**写本地指纹——否则 SHA 与指纹都不再变化，会变成永久漏同步。本地数据先落盘、成功后才提交基线。基线里的远端 SHA 用**正文实际对应的**版本（列表 SHA 可能在下发期间就已过期）。
  - **并发互斥**：轮询与 `pullScheduleFromGitee`（切日拉取）、`syncAllSchedulesToGitee`/`pullAllSchedulesFromGitee`（全量同步/拉取）共用 `_scheduleSyncChecking` / `hasScheduleModuleSyncInFlight`。切日拉取被轮询挡住后，由轮询收尾补一次；判断要比较**新旧可见日期集合的差集**（桌面三列从 05/06/07 前滚到 06/07/08 时当前日仍在旧集合里，只比较当前日会漏掉 08），并且**只拉差集里的日期**，不要重拉整个窗口（旧日期本轮刚处理过，重拉会多出正文请求、落盘、通知与日志）。
  - **前后台**：`_isAppForeground` 决定能不能创建轮询/100ms 重试定时器（初始化或身份切换的异步流程可能在切后台之后才跑完，不能把定时器装回来）。`onAppBackgrounded` 最先置标志并停表，**早于所有提前返回**；它那一次补推是**有意**的，所以先用 `_scheduleAutoRefreshInFlight` 等轮询释放同步锁再补推，等不到（慢网络，5 秒窗口）就置 `_backgroundFlushOwed`，由轮询收尾在后台补做一次——这条是"有意补推"唯一的例外，其余收尾补推/补拉仍要求 `_isAppForeground`。身份切换停表后由 `_pullIdentityScopedRemoteData` 重装。桌面最小化走 `AppLifecycleState.hidden` 而不是 `paused`（见 `isAppBackgroundedLifecycleState`）。
  - **待同步队列的身份归属**：桌面端本地时间块与 `pending_gitee_sync_dates` 都跨身份共享，所以归属只能记在**日期维度**上，且必须是**日期 → 身份集合**（`_pendingGiteeOwnerByDate`，`_recordPendingGiteeOwner`）——同一天可能在两个身份下都改过且都推送失败，只记一个身份会让后一个身份覆盖掉前一个，前一个的待推送就永久丢了。解除归属走 `_releasePendingGiteeOwner`：**只有这一天不再欠任何身份时**才能把它从共享待同步队列摘掉。整体持久化成 `pending_gitee_sync_owners`（已加入 `_identityScopedPreferenceBases`，**并且进了用户备份的导出/导入契约**——只导出日期的话，恢复后这些日期会变成"归属未知"被永久跳过）。记录归属必须在"这一天是否已在共享队列"的提前返回**之前**：日期可能已属于别的身份，但当前身份同样欠着它（例如发现自己身份的远端文件被删时也要能重建）。轮询收尾的自动补推**只推归属包含本次身份的日期**；归属缺失（旧版本数据、备份导入、迁移残留）按"未知"处理、一律不自动推（fail-closed）。否则 g 身份推送失败的日期会在切到 j 之后被推到 `schedule/j/`，造成跨身份数据污染。注意：用户手动触发的全量同步仍按既有语义把所有本地记录日期推到当前身份，这是桌面端"本地数据随当前身份走"的既定行为，不在自动补推的约束范围内（正因如此，**两端切换身份都要二次确认**，由 `ProfileSettingsDrawer._selectIdentity` 负责，但文案必须分开：桌面端说"会把对方远端日程合并进本机记录、之后的修改也会同步到对方文件"，移动端数据按身份分片、只能说"会换成对方自己的那套数据"。**不要**把桌面文案复用到移动端——那是错的。首次选择身份（`previous == null`）不弹。想只看对方日程应走首页「查看对方日程」——那条路有本地备份/还原保护）。
  - **只序列化必要日期**：`_localScheduleEntriesByDate({onlyDates})` 支持过滤。轮询只传可见日期与本次对账过的日期，不要遍历序列化全部历史日期（历史多时会拖慢每轮轮询）。
  - **推送回写基线**：推送/合并成功后回写新 blob SHA + 本地指纹（`_recordScheduleBaselineForDate`），否则刚推上去的那天下一轮会被当成"远端变了"重下一次。回写要带推送前的 `expectedRevision`，版本变了就不写指纹；版本判断必须在 manifest 读盘**之后**做（读盘窗口里用户也可能编辑）。覆盖拉取成功后整体重建基线。
  - **远端文件消失**：基线里原本存在过（被别处删掉）→ 入队待上传并补推重建；**从未存在过 → 什么都不做**，避免切身份时把整份本地数据批量复制到对方命名空间。
  - **`PendingSyncState.giteeDates` / `googleDates` 是不可变视图**：只能走 `markGitee` / `markGoogle` / `clearGitee` / `clearGoogle`。直接 `.add` 会抛 `UnsupportedError`（曾让同步中心的状态检查整段静默失败）。
  - **「覆盖拉取日程」**是破坏性恢复入口，放在同步中心（`SyncCenterController.recoverScheduleOverwrite`），「我的」抽屉里不再有手动同步按钮。
- **同步状态**：`SyncStatusCoordinator` 统一收集各模块状态并在 `SyncCenterScreen` 呈现；`SyncOperationLock` 保证同一模块不并发操作。无可靠实时读取器的模块保留本次业务操作结果，不用默认 0 覆盖
- **AI 对话**：`fromReview` 标记的复盘消息不参与 API 多轮上下文，每次附带完整当日记录作为 system prompt
- **数据流**：`Screen → Provider (notifyListeners) → Service → API/Storage`。应用切后台时自动保存并取消等待中的同步
- **背景图（壁纸，仅本机）**：`BackgroundImageProvider` 持有图片路径与两档不透明度，`BackgroundImageLayer` 经 `MaterialApp.builder` 挂在 Navigator 之下（均在 `lib/main.dart`：`BackgroundImageProvider` 在该文件注册，`BackgroundImageLayer` 包在 `MaterialApp.builder` 里）；主题侧由 `AppTheme.light/dark(backgroundEnabled:, surfaceOpacity:)` 生成 `AppWallpaperTheme` 扩展。**改动前先读这些约束：**
  - **绝不进同步与备份**：本地图片路径只存本机偏好，`lib/services/`（含 `DataBackupService`）与 `lib/models/` 均不引用它——路径一旦泄漏到远端/备份，在别的设备上指向不存在的文件。Provider 也因此刻意独立于业务数据 Provider
  - **叠在照片上的填充必须走 `context.wallpaperFill(color)` / `adaptSemanticFill(color)`**，不能直接给原始色（半透明色要能透出壁纸）；`test/visual_system_test.dart` 断言填充 alpha 等于 `surfaceOpacity`
  - **浮层保持不透明**：对话框、底部弹层、弹出菜单使用 `AppSurfaces.overlay` 或对应组件主题，不能用 `card` / `wallpaperFill` 覆盖浮层底色，否则底层图表与文字会穿透菜单
  - **对比度契约**：正文对比度下限 4.5（`BackgroundImageContrast.bodyTextRatio`），按 sRGB 逐通道合成（`BackgroundImageContrast.composite`），不要依赖渲染器的 blend mode
  - **默认值与上限**：照片不透明度 0.15、界面表面 0.72，单张图片上限 32MB；图片复制进应用支持目录 `time_manager/backgrounds`，偏好键 `background_image_{path,enabled,opacity,surface_opacity}_v1`；照片文件丢失时启动校验会清掉该路径
  - 改动背景图相关代码要跑 `test/background_image_contrast_test.dart`、`test/background_image_provider_test.dart` 与 `test/visual_system_test.dart`
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
bash test/update_macos_script_test.sh           # shell 脚本测试（flutter test 不会收集）
bash test/update_metadata_script_test.sh        # shell 脚本测试（flutter test 不会收集）
bash test/publish_android_release_script_test.sh # shell 脚本测试（flutter test 不会收集）
powershell -NoProfile -ExecutionPolicy Bypass -File test/publish_windows_release_script_test.ps1 # Windows 发布模拟测试（macOS/Linux 用 pwsh）
flutter run                        # 启动开发模式（移动端）
flutter run -d windows             # Windows 桌面版启动
flutter build apk --release        # 构建 Android release APK

# iOS（需要 macOS + Xcode，见「环境要求」与「iOS 平台约束」）
xcrun devicectl manage pair --device <id>          # 首次配对真机（触发手机上「信任此电脑」）
flutter run -d <device-id>                         # 真机调试：debug、带 DEBUG 角标、支持热重载
flutter run -d "iPhone 17"                         # iOS 模拟器（无需签名）
flutter build ios --release                        # 真机 release：已签名、无 DEBUG 角标、无热重载
xcrun devicectl device install app --device <id> build/ios/iphoneos/Runner.app   # 安装更早构建的 release 产物
xcrun devicectl device process launch --device <id> com.zhoujiaqi1027.timeManager # 直接启动已安装的 App
flutter devices                                    # 列出设备/模拟器（真机 id 形如 00008130-…）

# 平台构建脚本
scripts/build_android.sh           # Android arm64 构建：默认静态分析、不跑测试；成功后自动 bump/commit/push（见「构建与发布」）
scripts/build_windows.bat          # Windows 构建（含自动下载 nuget.exe）
scripts/update_macos.sh            # macOS 构建并安装到 /Applications
scripts/run_android.sh             # 拉起 Android 模拟器/设备再 flutter run（默认 AVD Pixel_7，可用 ANDROID_EMULATOR_NAME 覆盖；多余参数透传给 flutter run）
scripts/install_latest_android.sh  # 下载 Gitee 最新 Android APK，校验 SHA-256 后安装到 adb 连接的设备
scripts/package_macos_release.sh   # macOS .app 打包为 dist/*.dmg + .dmg.sha256
scripts/generate_update_metadata.sh <安装包…>  # 为 APK/EXE/DMG 生成同名 .sha256（Windows 用 generate_update_metadata.ps1）
scripts/publish_android_release.sh # 构建 + 发布到 Gitee Release（见「构建与发布」）
scripts/publish_windows_release.bat # Windows x64 构建 + Inno Setup 打包 + 发布 Gitee Release（PowerShell 5.1+，见「构建与发布」）
scripts/publish_all_release.bat    # 一键：版本号 +1、构建并发布 Android + Windows 到同一个 Gitee Release（PowerShell 5.1+，见「构建与发布」）
scripts/installer.iss              # Inno Setup 6.3+ 打 Windows 安装包（上传 Gitee release）
```

### 环境要求

- **Android 构建需要 JDK 17**（Temurin）。Gradle 版本在 `android/gradle/wrapper/gradle-wrapper.properties` 固定为 8.14，它无法在 JDK 25 下运行——用系统默认的 JDK 25 会构建失败
- `flutter.sdk` / `sdk.dir` 写在 `android/local.properties`（本机绝对路径，勿提交改动）
- 升级 Flutter 要在 SDK 目录里执行 `flutter upgrade`，在项目目录直接跑会刷新项目的 `pubspec.lock`
- **macOS 端刻意关掉了 Impeller**：`macos/Runner/Info.plist` 里 `FLTEnableImpeller=false`，退回 Skia。原因是 Flutter 3.47 起 macOS 默认 Impeller + SDF 文字，会偶发字体 / 图标缺字形（显示成方框，重启才恢复）。这是临时规避，**不要当成遗留调试开关清掉**，等上游修复后再删
- **iOS（仅 macOS + Xcode）**：
  - Xcode 必须装 iOS 平台组件：`xcodebuild -downloadPlatform iOS`。缺了 xcodebuild 会报 `iOS xx is not installed`，**连「Any iOS Device」都解析不出来**，`flutter build ios` 直接失败——这与工程无关，别去改项目
  - 真机三步：**配对电脑**（`xcrun devicectl manage pair --device <id>`，或 Xcode → Window → Devices）→ 手机开**开发者模式**（设置 → 隐私与安全性 → 开发者模式，需重启）→ **信任开发者证书**（设置 → 通用 → VPN 与设备管理；首次安装后必须手动信任）
  - 签名已写入 `ios/Runner.xcodeproj/project.pbxproj`：自动签名 + 开发团队 + 唯一 Bundle ID。**免费个人证书 7 天有效期**，过期 App 打不开，重装一次续期
  - Xcode 构建会自动把部署目标提升到 **iOS 15**（有依赖要求）

## iOS 平台约束

iOS 会落进「移动端」分支（见「首次本地开发前提」），因此 Android / 桌面独占能力**必须显式加平台守卫**。改动 iOS 相关代码前先读这一节：

- **平台判定统一走 `lib/utils/platform_features.dart`**，不要用 `isDesktopPlatform` 反推「移动端」——iOS 既不是桌面端、也不该走 Android 分支。已加的守卫：
  - `supportsHomeWidget` — 桌面小组件（`home_widget`）仅 Android。iOS 若照旧调用会抛 `AppGroupId not set` 并持续写错误日志（`TimeProvider._refreshHomeWidget` 曾漏守卫）
  - `supportsInAppUpdate` — 应用内自更新仅 Android（APK）/ Windows（EXE）/ macOS（DMG）。iOS 无通道：`updateAssetSuffix` 在 iOS 返回 `.apk`，`UpdateService.checkForUpdate` / `downloadAndInstall` 会落到 Android 的 `install_apk` 分支。iOS 上「我的 → 关于应用」隐藏「检查更新」入口
- **提醒（写日记 / 打卡）在 iOS 无实现**：UI 已按 `ReminderPlatform.isAndroid` 隐藏（见「提醒的硬约束」）。iOS 上没有这两类提醒，属平台能力差异，不是 bug
- **地图瓦片必须 HTTPS**（`lib/utils/map_tile_config.dart` 已是 `https://`），否则被 iOS ATS 拦截
- **相机 / 相册 / 定位**的 `Info.plist` 权限说明已配齐；新增权限时同步补 `NS*UsageDescription`
- 验证 iOS 改动：`flutter run -d "iPhone 17"`（模拟器，免签名）或真机；桌面小组件、应用内更新这类 Android 专属路径在日志里应无相关错误

## 构建与发布

`scripts/build_android.sh` 的默认行为不只是构建，成功后还会 **git commit + push**：

1. 获取依赖并跑 `flutter analyze`；默认不跑 `flutter test`，需要时加 `--run-tests`
2. 自动递增版本号：次版本 +1、patch 归零、构建号 +1（如 `1.114.0+32` → `1.115.0+33`）
3. 构建 Android arm64-v8a release APK
4. 把带版本号的 APK 和同名 `.sha256` 复制到 `dist/`
5. 只提交 `pubspec.yaml` 的版本号变更并 push 到当前分支的上游（不会把其他未提交改动带进这次提交）

构建失败或中断时只回滚 `pubspec.yaml` 的版本号改动。开关：`--run-tests`、`--skip-tests`（跳过静态分析和测试）、`--skip-bump`、`--no-git`、`--no-copy`、`--target-platform android-arm|android-arm64|android-x64`、`--dist-dir DIR`、`--dry-run`。

`scripts/update_macos.sh` 同样默认只跑静态分析、不跑测试；需要时加 `--run-tests`，`--skip-tests` 会同时跳过分析和测试。

`scripts/publish_android_release.sh` 在构建之上发布到 Gitee Release：

- 发布仓库默认 `zhou-jiaqi10/time_manager_releases`（`GITEE_OWNER` / `GITEE_REPO` 可覆盖）。**必须与 `lib/services/update_service.dart` 保持一致**，改发布仓库要两边一起改
- Release 说明文件固定为 `docs/release-notes.md`（`--notes-file` 覆盖）
- 发布前会用本地说明与**线上最新 Release 的说明查重**：完全相同就拒绝发布（提示先更新说明，`--allow-stale-notes` 可跳过）——查重在构建**之前**做，防止忘了更新说明还白跑一次构建；复用当前版本 tag 重传附件时不查重
- 上传顺序是**先 `.sha256` 后 APK**，避免手机在发布过程中拿到缺校验摘要的安装包
- 默认**跳过** `flutter analyze` + `flutter test`，发布前想再检查一次要显式加 `--run-tests`
- Token 优先读 `GITEE_TOKEN` 环境变量，未设置时回落到 `lib/config/diary_gitee_config.dart`
- 用 `--artifact <已有 APK>` + `--skip-build` 可以跳过构建、只发已有的包

两个仓库不要混淆：**同步数据**在 `RemoteRepoConfig` 里的 `love_diary`，**应用发布**在 `time_manager_releases`。

`scripts/publish_windows_release.bat` 是 Windows 的同类发布入口，由 `publish_windows_release.ps1` 实现，参数沿用 `--run-tests` / `--bump` / `--no-git` / `--artifact` 等写法，无需 Bash、jq 或 curl：

- 默认**不**查重 `docs/release-notes.md`（需要与线上最新 Release 的说明对比时加 `--check-notes`，完全相同才拒绝发布），并默认**按 `pubspec.yaml` 当前版本发布**（即给已有 Release 补 EXE，不自增版本号）；加 `--bump` 才做次版本 +1、patch 归零、构建号 +1 并发起版本提交
- 构建 Windows x64 release，自动定位 Inno Setup 6.3+（可用 `--iscc` / `ISCC_PATH` 指定，版本低于 6.3 会明确报错），从 `pubspec.yaml` 传入安装包版本；`build_windows.bat` 也自动传入版本，直接编译 `installer.iss` 时必须传 `/DMyAppVersion=<版本>`
- 输出 `dist/time_manager_setup_<版本>.exe` 和同名 `.exe.sha256`，只提交并推送 `pubspec.yaml`；自动提交前拒绝该文件已有未提交改动，其他文件的 staged / unstaged 改动不带入提交
- 发布仓库、Token 来源和先传校验文件的顺序与 Android 一致；复用同版本 Release、不重传同名附件
- Android 已发布后，Windows 先拉取最新 `pubspec.yaml` 直接运行即可（默认按当前版本补包），给同一个 Release 补 Windows 安装包；`--skip-bump` 保留为显式等价写法
- 构建失败 / 中断只回滚本次版本号；打包成功后的提交 / 上传失败保留版本与产物，可通过 `--artifact` 重试；已有 EXE 文件名中的版本必须与 `pubspec.yaml` 一致
- PowerShell 中文脚本使用 UTF-8 BOM，以兼容 Windows PowerShell 5.1；模拟回归测试为 `test/publish_windows_release_script_test.ps1`，不联网、不发布

`scripts/publish_all_release.bat`（由 `publish_all_release.ps1` 实现）是**一键双端发布**入口，把 Android 与 Windows 合成一步，同样无需 Bash、jq 或 curl：

- 默认**版本号 +1**（次版本 +1、patch 归零、构建号 +1）、构建前跑 `flutter analyze` + `flutter test`、构建成功后代提交并推送 `pubspec.yaml`；`--skip-bump` / `--skip-tests` / `--no-git` 可关掉
- 依次构建 Windows x64 安装包（Inno Setup 6.3+）和 Android arm64-v8a APK（`flutter build apk --release --target-platform android-arm64 --split-per-abi`，**需要 JDK 17**），产出 `dist/time_manager_setup_<版本>.exe` 与 `dist/time_manager-v<版本>-arm64-v8a.apk` 及各自 `.sha256`
- 版本号只写一次，两端用同一版本构建；tag = 版本名（不带 `v`、不带 `+build`），上传到**同一个** Gitee Release，顺序为 APK 的 sha→apk、EXE 的 sha→exe
- `--skip-android` / `--skip-windows` 只发单端；`--check-notes` 才与线上最新说明查重（默认不查）；`--dry-run` 只看计划；`--skip-build`（配 `--apk` / `--exe`）可跳过构建直接上传
- 回滚边界与 Windows 脚本一致：只有构建失败 / 中断才回滚版本号；构建成功后上传失败保留产物与版本号。是自带一份实现的独立脚本，改 Gitee 协议时需与 `publish_windows_release.ps1` 一起改

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

- `test/` 有 113 个 dart 测试文件（另有 `test/support/` 下 3 个共用 Fake）+ 3 个 bash 脚本测试（`update_macos_script_test.sh`、`update_metadata_script_test.sh`、`publish_android_release_script_test.sh`，用 `bash test/<脚本>.sh` 运行，`flutter test` 不会收集）+ 1 个 PowerShell 测试（`publish_windows_release_script_test.ps1`，macOS/Linux 用 `pwsh` 运行；不联网、不构建、不发布），覆盖同步合并、语音解析、日历解析、桌面适配、日志系统、备份回滚、身份隔离等核心逻辑
- `test/background_image_contrast_test.dart` / `background_image_provider_test.dart` — 背景图对比度契约与 Provider 状态（不透明度只在 commit 时落盘、启动清失效路径、超限/取消属正常结果）
- `test/visual_system_test.dart` — 视觉系统守护测试：对比度计算、主题一致性、令牌使用约束与源码守卫（页面无颜色 / 圆角 / 字号字面量，字号一律走 `AppText.*`；改 `lib/theme/` 或页面配色时必跑）
- `test/widget_test.dart` — smoke test + platform channel mock 模板：`_FakeGoogleSignInPlatform`、`SharedPreferences.setMockInitialValues`、mock `home_widget`/`flutter_secure_storage`/`path_provider` 通道、`tester.runAsync` 真实 IO。新写 widget 测试可参照此文件搭建环境
- `test/support/fake_app_log_store.dart` — 可注入失败的 Fake store
- `test/support/fake_reminder_backend.dart` — 两类提醒共用的后端 Fake（刻意不实现删除通道的方法，作为「绝不删通道」的编译期保证）
- `test/support/fake_main_tab_preferences_store.dart` — 可注入的导航偏好存储 Fake（配合 `main_tab_provider_test.dart`）
- `test/time_provider_save_test.dart` / `test/schedule_json_codec_test.dart` — 普通编辑保存合并、切后台/身份即时落盘、保存期间新编辑与待同步归属不丢、统计缓存按日期失效、后台 JSON 合并及旧哈希兼容
- `test/time_block_resize_test.dart` / `test/time_provider_resize_test.dart` / `test/time_grid_resize_test.dart` — 时间块拖拽调时长：块范围扫描与边界夹取、预览覆盖、覆盖相邻记录、缩短写墓碑、单次快照、stale 拒绝、日历块拒绝、鼠标 / 触摸手势与把手可见性
- `test/route_day_change_test.dart` — 路由页跨午夜：复盘日期条补新的一天并跟随 / 不抢视图、全局搜索相对区间重算（时钟注入）
- `test/earliest_recorded_day_test.dart` — 最早记录日期：空白天 / 墓碑 / 无事件名不计入，兼容旧的不补零日期键与坏键
- `test/diary_date_navigation_test.dart` — 日期前后切换、跨天连续前进、切后台时立即落盘（不等 350ms 防抖）与生命周期状态恢复
- `test/day_change_boundary_test.dart` / `test/date_change_schedule_sync_test.dart` 的跨日用例 — 零点通知只发一次、隐藏页与后台暂停后补发、仅在仍停留在今天时推进日期、手动停在历史日期不被抢走
- `test/target_desktop_ui_test.dart` — 桌面目标编辑表单、键盘保存/取消、数值与时间校验、子事件关联、周期天数与时长独立、右键删除、鼠标拖拽及浅深主题/窄窗口布局；桌面编辑入口统一走 `showTargetEditor`，移动端保留整页编辑
- `test/wake_up_provider_test.dart` / `test/wake_up_card_test.dart` — 起床记录持久化、补填/修改/删除、未来时间校验、跨日与近 7 天平均、身份切换及保存失败保护；卡片每分钟重新计算经过时长，隐藏 Tab 或切后台停表，返回立即刷新
- `test/wake_up_history_screen_test.dart` — 起床历史入口、30 / 90 天边界、跨年全部记录、自选日期含首尾、单日与空时段、身份隔离、实时更新、窄屏大字与浅深壁纸主题
- `test/wake_up_sync_test.dart` / `test/wake_up_gitee_service_test.dart` — 双端读改写与删除、离线重启恢复、旧记录迁移、SHA 冲突重试、损坏远端保护、上传期间编辑与身份切换、同步中心合并状态、自动刷新前后台边界与 Gitee 文档路径
- `test/statistics_cache_test.dart` / `test/main_screen_lazy_loading_test.dart` — 趋势与分类缓存互不覆盖、词云按自然日复用、跨日边界、编辑/撤销/切身份失效，以及隐藏统计页零查询、返回刷新与筛选状态保活
- `test/main_tab_provider_test.dart` / `test/main_tab_settings_screen_test.dart` — 导航偏好持久化与损坏修复、设置入口与最少标签约束、草稿取消/保存/恢复默认、触控和鼠标排序、窄屏大字与壁纸；`main_screen_lazy_loading_test.dart` 另覆盖自定义顺序启动、导航映射与隐藏/恢复页面保活
- `test/desktop_layout_provider_test.dart` / `test/desktop_layout_settings_test.dart` — 桌面布局与宽度持久化、损坏恢复、保存失败与并发不丢设置；`main_screen_lazy_loading_test.dart` 覆盖两种导航切换/跨断点保活、快捷键和设置入口，`brush_mode_test.dart` 覆盖事件栏拖宽/自动分列/跨列排序、调宽后的刷子归属与方向键微调
- `test/diary_reminder_service_test.dart` / `diary_reminder_diagnostics_test.dart` / `diary_reminder_drawer_test.dart` / `time_wheel_sheet_test.dart` — 写日记提醒的排程、原生事件导入、抽屉 UI 与滚轮时间面板
- `test/check_in_reminder_service_test.dart` / `check_in_reminder_ui_test.dart` — 打卡提醒的多实例排程与编辑页入口
- 其他按模块覆盖的测试文件：`desktop_shortcut_provider_test.dart` / `desktop_shortcut_settings_test.dart` / `desktop_shortcuts_test.dart` / `desktop_platform_test.dart`（桌面快捷键与平台适配）、`event_label_style_test.dart`（默认两行、切换后落盘、脏数据回落、`EventLabelText` 截断才挂 Tooltip、时间网格接入偏好）、`local_save_storage_failure_test.dart`（真实写盘失败：`daily_slots` 的 setValue 返回 false / 抛 PlatformException，断言置位、异常被吞、墓碑恢复后才落盘、防抖路径也置位、正常写盘不误报；出行 / 打卡 / 日记的 store 返回 false，打卡 `saveGoal` 落盘失败返回失败结果）、`failure_banner_test.dart`（数据故障横幅：原因文案、壁纸不透明度、窄屏大字、初始化失败与保存失败在壳层可见、隐藏「记录」页仍可见、重试保存成功/失败、正常时不渲染）、`main_screen_lifecycle_test.dart`（应用生命周期）、`schedule_overwrite_test.dart` / `schedule_background_refresh_test.dart` / `schedule_bad_data_guard_test.dart` / `schedule_merge_test.dart`（日程覆盖、后台刷新、坏格式与合并）、`travel_desktop_ui_test.dart`（出行桌面 UI）、`diary_sync_service_test.dart`（日记同步编排）、`category_document_merge_test.dart` / `target_document_merge_test.dart`（分类/目标文档合并）、`check_in_photo_security_test.dart` / `privacy_boundary_test.dart`（照片与隐私边界）、`deserialization_tolerance_test.dart` / `windows_legacy_preferences_migration_test.dart`（反序列化容错与旧偏好迁移）
- 写提醒相关的 widget 测试要注意：抽屉是长 `ListView`，懒构建会让折叠线以下的条目根本不挂载，需要把测试视口调高；另外 `AppIdentityService.load()` 每次都会重读偏好，测试里的身份必须放在偏好键 `schedule_user_kind` 里，靠 `adoptManualKind` 设进去会被覆盖
- 测滚轮用 `tester.drag(finder, Offset(0, -44))` 拖动一格；换主题重跑时**必须先把面板关掉**，否则 `pumpWidget` 会复用 Navigator 状态，上一轮的弹层还在、下一次点击落不到按钮上
- 无 CI 流程配置

## Conventions

- Code and UI text are in Chinese
- Config files with secrets are always `.gitignore`d — never commit
- 平台差异化功能通过 `lib/utils/platform_features.dart` 控制（如拍照仅限移动端、桌面小组件仅 Android、应用内更新不支持 iOS，见「iOS 平台约束」）
- 视觉规范：页面不得硬编码颜色/圆角/间距/字号字面量，统一引用 `lib/theme/` 三文件（`AppSpacing`/`AppRadius`/`AppSizes`/`AppText`、`AppSurfaces.of(context)`、`AppSemanticColors`）；照片浮层等主题无关的黑色 scrim 属于允许的例外。**启用背景图时，叠在壁纸上的填充必须走 `context.wallpaperFill()` / `adaptSemanticFill()`（见「背景图」一节）**。守卫测试 `test/visual_system_test.dart`
- 设计文档在 `docs/superpowers/{plans,specs}/`、已完结问题归档在 `docs/archive/`——这些目录**仅本地存在、被 `docs/*` 规则 gitignore**（`.gitignore` 只放行 `docs/design-system.md` 与 `docs/release-notes.md`），按需创建，**不要在 git 里找它们**。视觉规范在 `docs/design-system.md`；`docs/release-notes.md` 是两个发布脚本默认的 Release 说明来源，发版前必须先更新（否则发布查重会拒绝）。根目录只保留 `AGENTS.md`、`README.md` 与活跃的 `待修复问题.md` / `写日记提醒实施方案.md`
- `third_party/` 下是 vendored 的第三方插件 fork，已在 `analysis_options.yaml` 里整体 exclude，不参与本项目的静态检查；升级上游时按该目录下 `FORK.md` 的步骤重做
