# AGENTS.md

## Project Overview

Flutter time management app (v1.93.6+7, package name `time_manager`) with Google Calendar integration, daily diary, travel records, check-in tracking, target tracking, AI daily review, voice scheduling, and app logging. Chinese-language UI with English fallback. Supports Android, Windows desktop, and macOS.

## Architecture

- **Entry**: `lib/main.dart` → `MainScreen` (6-tab bottom nav: 记录/日记/出行/打卡/目标/我的)。Windows 平台隐藏"目标" tab（平台特性见 `lib/utils/platform_features.dart`）。启动时初始化 `AppLogService` 全局错误捕获，并对 MIUI 设备应用 SSL 修复的 `HttpOverrides`。
- **State**: `lib/providers/`
  - `time_provider.dart` → `TimeProvider` (~6800 行) — 核心业务状态：时间块、分类、目标、模板、撤销栈、统计缓存、增量保存、Google 日历同步、日程(schedule)同步
  - `theme_mode_provider.dart` → `ThemeModeProvider` (52 行) — 主题模式 (light/dark/system)
  - `target_stats_cache.dart` → `TargetStatsCache` (47 行) — 目标统计内存缓存，按日期失效
- **Models**: `lib/models/` (25 个文件)
  - 时间记录：`TimeSlot`, `Category`, `CalendarBlock`, `ScheduleTemplate`, `VoiceScheduleDraft`, `ScheduleSyncProgress`
  - 打卡系统：`CheckInGoal`, `CheckInRecord`, `CheckInDocument`, `CheckInViewFilter`
  - 目标系统：`Target`
  - 出行：`TravelRecord`, `TravelRecordsDocument`
  - 日记：`DiaryKind`, `DiarySearchResult`
  - AI 复盘：`DailyReviewChatMessage`, `DailyReviewChatSession`
  - 用户/身份：`GoogleCalendarUser`, `KnownGoogleUsers`（手动/Google 双身份模式，见 `AppIdentityService`）
  - 搜索/同步/日志：`SearchResult`, `RemoteSyncPlatform`, `PendingSyncState`, `AppLogEntry`, `OnThisDayEntry`
- **Screens**: `lib/screens/` (21 个) — `MainScreen`, `HomeScreen`, `DiaryScreen`, `TravelScreen`, `CheckInScreen`, `TargetScreen`, `ProfileScreen`, plus `DailyReviewScreen`, `WordCloudScreen`, `EventDetailScreen`, `TargetDetailScreen`, `AddTargetScreen`, `GlobalSearchScreen`, `DiarySearchScreen`, `AddCheckInGoalScreen`, `CheckInDetailScreen`, `CheckInArchiveScreen`, `CheckInMapScreen` (flutter_map 地图), `AppLogScreen`, `OnThisDayScreen`
- **Services**: `lib/services/` (49 个文件)，主要板块：
  - **Google 身份 & 日历**：`GoogleCalendarService` (OAuth 2.0 + 事件同步)、`GoogleCalendarEventParser`、`HomeWidgetService` (Android 桌面小组件)、`AppIdentityService` (手动/Google 双身份)
  - **Git 同步（Gitee/GitHub 双平台）**：`GitHubContentsApi`、`GiteeContentsApi`、`DiaryGitHubService`/`DiaryGiteeService`、`TravelGitHubService`/`TravelGiteeService`、`CheckInGitHubService`/`CheckInGiteeService`、`PendingGoogleDaySyncService`（待同步状态）
  - **日程同步**：`ScheduleDayMergeService`、`ScheduleSyncDependencies`、日程覆盖/坏格式防护相关服务
  - **打卡业务**：`CheckInSyncService` (合并编排)、`CheckInImageService` (图片压缩)、`CheckInLocationService` (GPS 定位 + `geocoding` 逆地理)
  - **AI 板块**：`SiliconFlowAiService` (API 调用带重试 90s 超时)、`DailyReviewSummary` (复盘生成 + 数据哈希缓存)、`DailyReviewChatService` (多轮对话，最多 20 轮)
  - **语音建日程**：`VoiceScheduleParser` (自然语言解析)、`VoiceScheduleSlotPlanner` (10 分钟槽位规划)，UI 在 `lib/widgets/voice_schedule_sheet.dart`
  - **应用日志**：`AppLogService` (全局错误捕获)、`AppLogStore` (持久化)、`AppLogExportService` (导出)
  - **工具**：`DataBackupService` (JSON 导入导出)、`DiarySearchService` (全文搜索)、`OnThisDayService` (当年今日回顾)、`UpdateService`
  - 各数据域有对应的 `*_local_store.dart` 本地存储封装
- **Widgets**: `lib/widgets/` (16 个) — `DatePickerPanel`, `TemplateBar`, `TimeGridTile`, `TimeGrid`, `CalendarSyncStatusBadge`, `VoiceScheduleSheet`, `ScheduleSyncProgressBanner`, `ProfileSettingsDrawer`, OnThisDay 相关组件、打卡照片相关组件等
- **Utils**: `lib/utils/` — `adaptive` (平台自适应)、`calendar_time_range`、`desktop_selection`、`local_day_range`、`platform_features` (按平台开关功能)、`schedule_view_dates`、`time_slot_segment`
- **Theme**: `lib/theme/app_theme.dart`
- **Config**: `lib/config/` — API keys and service configs (`.gitignore`d，**无 .example.dart 模板**，结构需直接查看引用方代码)

## 数据流与关键模式

- **时间粒度**：全天 144 个 10 分钟槽位 (`hour=0..23`, `minute10=0..5`)
- **持久化分层**：
  - 时间块/分类/目标/模板 → `SharedPreferences`（JSON 序列化）
  - 敏感 Token → `FlutterSecureStorage`
  - AI 复盘缓存 → `SharedPreferences`（带数据哈希键，数据变化导致缓存失效）
  - 打卡照片 → 本地文件缓存 + Git 仓库
  - 应用日志 → `AppLogStore` 本地持久化
- **增量保存**：`TimeProvider` 追踪 `_categoriesDirty` / `_targetsDirty` / `_slotsDirty` 脏标记，只序列化变化部分
- **撤销系统**：`_undoStacks` 深拷贝快照，最多 20 步
- **Google 日历同步**：3 秒防抖 + `_isSyncing` 锁防并发。事件以 "乖乖爱心晶晶" 为识别签名，区分本 App 创建和外部事件
- **打卡合并策略**：`CheckInDocument.merge(local, remote)` 按 ID 去重，同 ID 保留较新记录
- **AI 对话**：`fromReview` 标记的复盘消息不参与 API 多轮上下文，每次附带完整当日记录作为 system prompt
- **数据流**：`Screen → Provider (notifyListeners) → Service → API/Storage`。应用切后台时自动保存并取消等待中的同步

## Commands

```bash
flutter pub get                    # 安装依赖
flutter analyze                    # 静态检查 (flutter_lints，无自定义规则)
flutter test                       # 运行所有测试
flutter test test/widget_test.dart # 运行单个测试文件
flutter run                        # 启动开发模式（移动端）
flutter run -d windows             # Windows 桌面版启动
flutter build apk --release        # 构建 Android release APK

# 平台构建脚本
scripts/build_android.sh           # Android arm64 构建：bump 版本/跑测试/输出到 dist/
build_windows.bat                  # Windows 构建（含自动下载 nuget.exe）
scripts/update_macos.sh            # macOS 构建并安装到 /Applications
installer.iss                      # Inno Setup 6 打 Windows 安装包（上传 Gitee release）
```

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
- `flutter_slidable` / `reorderables` — 列表滑动操作与拖拽排序
- `url_launcher` / `package_info_plus` — 外链与版本信息

## Testing

- `test/` 有 34 个 dart 测试文件（约 6000 行）+ `update_macos_script_test.sh`，覆盖同步合并、语音解析、日历解析、桌面适配、日志系统等核心逻辑
- `test/widget_test.dart` — smoke test + platform channel mock 模板：`_FakeGoogleSignInPlatform`、`SharedPreferences.setMockInitialValues`、mock `home_widget`/`flutter_secure_storage`/`path_provider` 通道、`tester.runAsync` 真实 IO。新写 widget 测试可参照此文件搭建环境
- `test/support/fake_app_log_store.dart` — 可注入失败的 Fake store
- 无 CI 流程配置

## Conventions

- Code and UI text are in Chinese
- Config files with secrets are always `.gitignore`d — never commit
- 平台差异化功能通过 `lib/utils/platform_features.dart` 控制（如 Windows 隐藏目标 tab）
- 设计文档在 `docs/superpowers/{plans,specs}/`；根目录 `父事件临时标签方案.md` 是饼图聚合临时事件的设计方案
