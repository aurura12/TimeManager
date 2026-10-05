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

## 桌面布局

Windows / macOS 可在「我的 → 设置 → 外观设置 → 桌面布局」选择原有底部导航或宽屏左侧导航，默认保留原有布局。左侧导航在窗口宽度至少 1000 时显示，窄窗口自动回到底部；沿用标签的显示与排序及数字快捷键，切换布局不重建已打开的页面。

底部导航与左侧导航共用记录页右侧事件栏，默认宽度均为 240。事件栏支持拖动左边分隔条调宽，事件按可用宽度和文字大小自动分列并排显示，仍支持子事件、右键编辑与拖拽排序。松手后记住宽度，窗口缩小时临时收窄并保留原偏好；双击分隔条恢复默认，分隔条获焦后左右方向键微调、Home 恢复默认。导航和宽度只存本机，不随身份切换，不参与同步或数据备份。

出行页的桌面表格为日期、月份与次数预留更宽的列间距，长地点可换行显示。月历直接展示每天的地点和事件；宽窗口右侧显示当天详情与本月记录，较窄窗口改为上下排列，并可一键返回今天。

## 桌面快捷键

Windows 使用 `Ctrl`，macOS 使用 `⌘`。以下是默认设置，可在「我的 → 设置 → 外观设置 → 键盘快捷键」修改、停用或恢复默认；记录页顶部的键盘图标也能进入。设置只保存在本机，保存后立即生效。

| 操作 | 默认按键 | 范围 |
| --- | --- | --- |
| 全局搜索 | Ctrl / ⌘ + K | 主页面搜索全部模块；搜索页中聚焦搜索框 |
| 当前页搜索 | Ctrl / ⌘ + F | 日记全文搜索；其他页面预选对应模块 |
| 新建 | Ctrl / ⌘ + N | 出行、打卡、目标 |
| 打开设置 | Ctrl / ⌘ + , | 主页面 |
| 切换标签 | Ctrl / ⌘ + 1–6 | 按可见标签顺序，隐藏标签不占位置 |
| 撤销 / 重做 | Ctrl / ⌘ + Z / Shift + Z | 记录页最近编辑的日期；Windows 重做也支持 Ctrl + Y |
| 前一天 / 后一天 / 今天 | ← / → / T | 记录页和日记页 |
| 保存表单 | Ctrl / ⌘ + Enter | 目标、打卡目标、出行编辑、快捷键设置 |
| 关闭临时状态 | Esc | 可取消弹层、设置抽屉、日期面板、刷子和时间选择 |

输入框保留自己的文字撤销和光标移动，组词中的中文输入不会触发应用命令。弹层打开后，底下的页面不能响应日期、撤销、新建或标签切换；整页表单不会被全局 Esc 关闭。修改快捷键时会检查应用内部冲突，并保留复制、粘贴等文字编辑组合键。

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
scripts/publish_windows_release.bat # Windows 构建安装包并发布到 Gitee（在 Windows 上运行）
scripts/update_macos.sh             # macOS 构建并安装到 /Applications，默认不跑测试
scripts/install_latest_android.sh   # 从 Gitee 下载最新 Android 版并安装到 adb 连接的设备
flutter build apk --release         # 直接构建 release APK
```

## Windows 发布到 Gitee

在 Windows 上准备好 Flutter、Visual Studio 的「使用 C++ 的桌面开发」、Inno Setup 6.3+（`installer.iss` 使用 6.3 引入的 `x64compatible` 并以无 BOM 的 UTF-8 保存中文），以及下方列出的本机配置文件。Git 自动提交需要配置作者信息和当前分支的上游。更新 `docs/release-notes.md` 后，在项目根目录的 PowerShell 或 CMD 运行：

```powershell
.\scripts\publish_windows_release.bat
```

脚本默认将次版本号 +1、patch 归零、构建号 +1，构建 Windows x64 应用，按同一版本打包为 `dist/time_manager_setup_<版本>.exe` 并生成同名 `.exe.sha256`。只提交 `pubspec.yaml` 的版本号变更并推送上游，然后在 `zhou-jiaqi10/time_manager_releases` 创建或复用 Release，先上传校验文件，再上传 EXE。默认跳过分析和测试；不需要安装 Bash、jq 或 curl。

Token 优先取 `GITEE_TOKEN` 环境变量，未设置时自动读取 `lib/config/diary_gitee_config.dart` 的 `hardcodedToken`。可在 PowerShell 中临时指定：

```powershell
$env:GITEE_TOKEN = '你的 Gitee Token'
.\scripts\publish_windows_release.bat
```

常用选项：

```powershell
# 预览版本、产物路径和发布仓库；不联网、不改文件
.\scripts\publish_windows_release.bat --dry-run

# 发布前运行 flutter analyze 和 flutter test
.\scripts\publish_windows_release.bat --run-tests

# Android 已发布当前版本时，给同一 Release 补上 Windows 安装包
# 先 git pull 同步 Android 自动提交的 pubspec.yaml 版本，再执行：
.\scripts\publish_windows_release.bat --skip-bump

# 禁用版本号的自动提交和推送
.\scripts\publish_windows_release.bat --no-git

# 上传失败后复用已有安装包；文件名中的版本必须与 pubspec.yaml 一致
.\scripts\publish_windows_release.bat --artifact dist\time_manager_setup_1.114.0.exe

# Inno Setup 装在其他位置时显式指定编译器
.\scripts\publish_windows_release.bat --iscc 'D:\Tools\Inno Setup 6\ISCC.exe'

.\scripts\publish_windows_release.bat --help
```

说明查重在构建前完成；复用同一版本 Release 时不查重，也不会重传同名附件。新版本说明重复会拒绝发布，可用 `--allow-stale-notes` 跳过。自动提交前要求 `pubspec.yaml` 没有未提交改动，其他文件的改动不会带入版本提交。构建失败或中断只回滚本次版本号修改；打包成功后上传失败则保留版本和安装包，便于重试。相对路径以项目根目录为基准。`--owner` / `--repo` 与 `GITEE_OWNER` / `GITEE_REPO` 可覆盖发布仓库，修改正式发布仓库时需同步修改 `UpdateService`。

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
- `test/publish_windows_release_script_test.ps1` — Windows 发布脚本的模拟构建/API 回归测试，在 PowerShell 中运行 `powershell -NoProfile -ExecutionPolicy Bypass -File test/publish_windows_release_script_test.ps1`（macOS/Linux 可用 `pwsh`）；不联网、不构建真实应用、不提交或上传

## 文档

- `AGENTS.md` — 项目架构与约定
- `docs/design-system.md` — 视觉规范
- `docs/superpowers/plans/`、`docs/superpowers/specs/` — 设计方案与实施计划
- `docs/archive/` — 已完结的问题记录
