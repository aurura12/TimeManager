# TimeManager

个人时间管理应用。以 10 分钟为粒度记录全天时间块，并整合日记、出行、打卡、目标、AI 复盘与多端同步。

Flutter 实现，中文界面（英文为降级），支持 Android、Windows 桌面与 macOS。

当前版本：`1.109.0+27`

## 功能模块

底部默认 6 个 Tab：**记录 / 日记 / 出行 / 打卡 / 目标 / 我的**。手机和桌面均可在「我的 → 设置 → 外观设置 → 底部标签」隐藏标签、拖动排序或用菜单上移/下移，并恢复默认；点击保存后生效，设置只保存在本机。至少保留两个标签，「我的」始终显示以保留设置入口。

有隐藏标签时，「我的」左上角会在设置菜单旁显示九宫格图标「更多功能」。点选即可临时打开对应页面，返回后回到「我的」，底部标签仍保持隐藏；已打开页面的状态会保留。

- **记录** — 10 分钟槽位时间网格，支持单击/拖选刷块、分类与子事件、模板、语音建日程、撤销/重做（20 步）
- **日记** — 按日期记录正文，全文搜索，Git（Gitee/GitHub）同步
- **出行** — 出行记录与地点，支持改期原子迁移与删除 tombstone
- **打卡** — 打卡目标与记录，GPS 定位 + 地图展示，拍照打卡（移动端）、图片压缩、归档，每个目标可设每日提醒
- **目标** — 周期目标与进度统计，桌面端提供编辑表单、右键菜单与拖拽排序
- **我的** — 分类统计（饼图/趋势/词云）、同步中心、AI 每日复盘、当年今日、应用日志、数据备份、写日记提醒（仅 Android）

其他能力：Google 日历事件双向同步、Android 桌面小组件、本地提醒（写日记提醒按身份隔离、打卡目标提醒按目标逐一份）、本机背景图（壁纸，可调界面不透明度）、桌面端键盘快捷键、全局搜索、AI 每日复盘与多轮对话。

## 技术栈

`provider` 状态管理 · `shared_preferences` 本地持久化 · `flutter_secure_storage` 敏感 Token ·
`google_sign_in` + `googleapis` 日历与身份 · `fl_chart` 图表 · `flutter_map` + `latlong2` 地图 ·
`geolocator` + `geocoding` 定位 · `image_picker` + `flutter_image_compress` 拍照 ·
`home_widget` 桌面小组件 · `file_picker` 备份导入导出 ·
`flutter_local_notifications` + `timezone` 本地提醒（经 `dependency_overrides` 使用 `third_party/` 下的本地 fork 做原生埋点）

## 目录结构

```
lib/
  main.dart              入口，全局错误捕获与平台初始化
  providers/             状态层：TimeProvider（核心业务）、ThemeModeProvider、MainTabProvider（导航偏好）、TargetStatsCache、BackgroundImageProvider（背景图）
  models/                数据模型（时间块、分类、打卡、目标、出行、日记、同步状态、提醒等）
  screens/               页面（22 个）
  services/              业务服务（61 个）：Google 日历、Git 同步、打卡、AI、语音、日志、提醒等
  widgets/               可复用组件（19 个）
  utils/                 平台自适应、日期范围、槽位分段等工具
  theme/                 设计令牌与主题（app_tokens / app_theme / app_semantic_colors / background_image_contrast）
  config/                密钥配置（.gitignore，需本地创建）
third_party/             第三方插件的本地 fork（flutter_local_notifications，见其 FORK.md）
docs/                    设计文档与历史方案
```

分层数据流：`Screen → Provider (notifyListeners) → Service → API/Storage`

## 开发

```bash
flutter pub get                     # 安装依赖
flutter run                         # 移动端调试
flutter run -d windows              # Windows 桌面调试
flutter analyze                     # 静态检查
flutter test                        # 运行全部测试
flutter test test/widget_test.dart  # 运行单个测试文件

scripts/build_android.sh            # Android arm64 构建，默认不跑测试；输出到 dist/
scripts/build_windows.bat           # Windows 构建
scripts/update_macos.sh             # macOS 构建并安装到 /Applications，默认不跑测试
scripts/install_latest_android.sh   # 从 Gitee 下载最新 Android 版并安装到 adb 连接的设备
flutter build apk --release         # 直接构建 release APK
```

## 配置文件（必需）

`lib/config/` 下 6 个文件全部被 `.gitignore` 排除，且**没有 `.example.dart` 模板**，需按引用它们的 service 代码手动创建：

| 文件 | 用途 |
| --- | --- |
| `diary_github_config.dart` | GitHub token（日记同步） |
| `diary_gitee_config.dart` | Gitee token（日记同步） |
| `github_config.dart` | GitHub 通用配置 |
| `remote_repo_config.dart` | 远程仓库配置 |
| `siliconflow_config.dart` | AI 服务 API key |
| `google_sign_in_config.dart` | Google OAuth client ID |

缺少这些文件时项目无法编译。请勿提交。

## 测试

`test/` 含 80 个 dart 测试文件，覆盖同步合并、语音解析、日历解析、桌面适配、日志系统、备份回滚、身份隔离、写日记提醒与打卡提醒等核心逻辑。

- `test/widget_test.dart` — smoke test 与平台通道 mock 模板（`_FakeGoogleSignInPlatform`、`SharedPreferences.setMockInitialValues`、mock `home_widget`/`flutter_secure_storage`/`path_provider` 通道）
- `test/visual_system_test.dart` — 视觉系统守护测试，改动 `lib/theme/` 或页面配色时必须运行

## 文档

- `AGENTS.md` — 项目架构与约定
- `docs/design-system.md` — 视觉规范
- `docs/superpowers/plans/`、`docs/superpowers/specs/` — 设计方案与实施计划
- `docs/archive/` — 已完结的问题记录
