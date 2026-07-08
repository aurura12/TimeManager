# AGENTS.md

## Project Overview

Flutter time management app (v1.62.0) with Google Calendar integration, daily diary, travel records, check-in tracking, target tracking, and AI daily review. Chinese-language UI with English fallback. Supports Android and Windows desktop.

## Architecture

- **Entry**: `lib/main.dart` → `MainScreen` (6-tab bottom nav: 记录/日记/出行/打卡/目标/我的)
- **State**: `lib/providers/`
  - `TimeProvider` (~2173 行) — 核心业务状态：时间块、分类、目标、模板、撤销栈、统计缓存、增量保存、Google 日历同步
  - `ThemeModeProvider` (52 行) — 主题模式 (light/dark/system)
  - `TargetStatsCache` (41 行) — 目标统计内存缓存，按日期失效
- **Models**: `lib/models/` (18 个文件)
  - 时间记录：`TimeSlot`, `Category`, `CalendarBlock`, `ScheduleTemplate`
  - 打卡系统：`CheckInGoal`, `CheckInRecord`, `CheckInDocument`, `CheckInViewFilter`
  - 目标系统：`Target`
  - 出行：`TravelRecord`, `TravelRecordsDocument`
  - 日记：`DiaryKind`, `DiarySearchResult`
  - AI 复盘：`DailyReviewChatMessage`, `DailyReviewChatSession`
  - 用户：`GoogleCalendarUser`, `KnownGoogleUsers`
  - 搜索/同步：`SearchResult`, `RemoteSyncPlatform`
- **Screens**: `lib/screens/` — `MainScreen`, `HomeScreen`, `DiaryScreen`, `TravelScreen`, `CheckInScreen`, `TargetScreen`, `ProfileScreen`, plus `DailyReviewScreen`, `WordCloudScreen`, `EventDetailScreen`, `TargetDetailScreen`, `AddTargetScreen`, `GlobalSearchScreen`, `DiarySearchScreen`, `AddCheckInGoalScreen`, `CheckInDetailScreen`, `CheckInArchiveScreen`, `CheckInMapScreen`
- **Services**: `lib/services/` (24 个文件)，分为五大板块
  - **Google 身份 & 日历**：`GoogleCalendarService` (OAuth 2.0 + 事件同步)、`HomeWidgetService` (桌面小组件)
  - **Git 同步**：`GitHubContentsApi` (双平台 Gitee/GitHub API 封装)、`DiaryGitHubService`、`TravelGitHubService`、`CheckInGitHubService`
  - **打卡业务**：`CheckInSyncService` (合并编排)、`CheckInImageService` (图片压缩)、`CheckInLocationService` (GPS 定位)
  - **AI 板块**：`SiliconFlowAiService` (API 调用带重试 90s 超时)、`DailyReviewSummary` (复盘生成 + 数据哈希缓存)、`DailyReviewChatService` (多轮对话，最多 20 轮)
  - **飞书日历**：`FeishuCalendarService` (OAuth 2.0 授权码模式)
  - **工具**：`DataBackupService` (JSON 导入导出)、`DiarySearchService` (全文搜索)、`UpdateService`
- **Widgets**: `lib/widgets/` — `DatePickerPanel`, `TemplateBar`, `TimeGridTile`, `CalendarSyncStatusBadge`, 打卡照片相关组件等
- **Config**: `lib/config/` — API keys and service configs (`.gitignore`d)

## 数据流与关键模式

- **时间粒度**：全天 144 个 10 分钟槽位 (`hour=0..23`, `minute10=0..5`)
- **持久化分层**：
  - 时间块/分类/目标/模板 → `SharedPreferences`（JSON 序列化）
  - 敏感 Token → `FlutterSecureStorage`
  - AI 复盘缓存 → `SharedPreferences`（带数据哈希键，数据变化导致缓存失效）
  - 打卡照片 → 本地文件缓存 + Git 仓库
- **增量保存**：`TimeProvider` 追踪 `_categoriesDirty` / `_targetsDirty` / `_slotsDirty` 脏标记，只序列化变化部分
- **撤销系统**：`_undoStacks` 深拷贝快照，最多 20 步
- **Google 日历同步**：3 秒防抖 + `_isSyncing` 锁防并发。事件以 "乖乖爱心晶晶" 为识别签名，区分本 App 创建和外部事件
- **打卡合并策略**：`CheckInDocument.merge(local, remote)` 按 ID 去重，同 ID 保留较新记录
- **AI 对话**：`fromReview` 标记的复盘消息不参与 API 多轮上下文，每次附带完整当日记录作为 system prompt
- **数据流**：`Screen → Provider (notifyListeners) → Service → API/Storage`。应用切后台时自动保存并取消等待中的同步

## Commands

```bash
flutter pub get                    # 安装依赖
flutter analyze                    # 静态检查
flutter test                       # 运行所有测试
flutter test test/widget_test.dart # 运行单个测试
flutter run                        # 启动开发模式（移动端）
flutter run -d windows             # Windows 桌面版启动
flutter build apk                  # 构建 Android debug APK
flutter build apk --release        # 构建 Android release APK
```

## Config Files (Secrets — .gitignore'd)

These files must be created locally from examples before the app can function:

1. `lib/config/diary_github_config.dart` — GitHub token for diary sync
2. `lib/config/siliconflow_config.dart` — AI service API key
3. `lib/config/google_sign_in_config.dart` — Google OAuth client IDs

All three are in `.gitignore`. Never commit them.

## Key Dependencies

- `provider` — 状态管理 (ChangeNotifier)
- `google_sign_in` + `googleapis` — Google OAuth + Calendar API
- `flutter_secure_storage` — 加密存储 Token
- `home_widget` — Android 桌面小组件
- `fl_chart` — 统计图表 (折线图/饼图)
- `shared_preferences` — 本地数据持久化
- `http` — HTTP 请求 (Git API / AI API)
- `file_picker` — 文件选择 (备份导入导出)
- `geolocator` — GPS 定位 (打卡)
- `image_picker` + `flutter_image_compress` — 打卡拍照和压缩

## Testing

- `test/widget_test.dart` (29 行) — basic smoke test，创建 `MultiProvider` 包装的 `TimeManagerApp`，验证 widget 可渲染。注意：`MyApp` 类实际上不存在，代码中的引用可能需要更新。
- 无集成测试、无 CI 流程配置

## Conventions

- Code and UI text are in Chinese
- Config files with secrets are always `.gitignore`d — always create from `.example.dart` templates
- `lib/config/*.example.dart` files serve as the source of truth for required config structure
