# 统一视觉系统（手机版）

第 4 项「统一视觉系统」的落地规范。目标不是把某个页面做好看，而是让**页面不再各自定义颜色、圆角、间距和按钮样式**。

范围：手机版（Android / iPhone 尺寸）。Windows / macOS / iPad / 桌面小组件 / 原生 Android Widget 不在本轮范围。

不改业务逻辑，不改数据结构。

---

## 一、视觉层级

```
页面背景        AppSurfaces.page        （最底层，铺满）
  ↓
内容区域 / 卡片  AppSurfaces.card        （白色 / 深色内容面，弱边框）
  ↓
主操作 / 选中    colorScheme.primary / primaryContainer
  ↓
语义状态        error / warning / success
```

- 浅色：浅米白背景 `#F8F9FA` + 白色内容面 + 用户选择的强调色（默认橄榄绿）
- 深色：深灰绿背景 `#111315` + 深色内容面 + 低饱和强调色
- 时间块：继续使用清晰实色（分类色）
- 卡片：弱边框（`outlineVariant`）、无阴影
- 导航与按钮：轻浮层感，不做全页面玻璃效果

---

## 二、五个文件，职责不重叠

| 文件 | 职责 | 里面有什么 |
|---|---|---|
| `docs/design-system.md` | 设计规则与白名单 | 本文件 |
| `lib/theme/app_tokens.dart` | **数值** | 间距、圆角、控件高度、文字层级 |
| `lib/theme/app_theme.dart` | **主题色与组件主题** | `ColorScheme`、`AppSurfaces`、`AppWallpaperTheme`、各 Material 组件主题 |
| `lib/theme/app_semantic_colors.dart` | **语义色** | 身份色、分类色、图表色、奖牌色、状态色 |
| `lib/theme/background_image_contrast.dart` | **背景图对比度** | 合成、对比度与安全照片不透明度计算（见 3.5） |

**同一个颜色只允许在一个文件里定义。** 品牌绿 `#9CB86A` 只在 `app_semantic_colors.dart` 的 `AppSemanticColors.brand` 出现，其他文件一律引用。

`AppSurfaces` 是 `ThemeExtension`，用来取代"为了选底色而写的 `isDark ? a : b`"：

```dart
final surfaces = AppSurfaces.of(context);
Container(color: surfaces.card, ...)
```

`AppSurfaces.of()` 在主题未注册该扩展时会按亮度回退，因此在裸 `MaterialApp` 的测试里也不会崩。

---

## 三、颜色

### 3.1 主题色（走 ColorScheme）

| 用途 | 取值 |
|---|---|
| 页面背景 | `AppSurfaces.page` |
| 内容面 | `AppSurfaces.card` |
| 导航 / 侧栏 / AppBar | `AppSurfaces.panel` |
| 次级底色、输入框填充 | `AppSurfaces.subtle` |
| 正文 | `colorScheme.onSurface` |
| 辅助文字 | `colorScheme.onSurfaceVariant` |
| 边框 | `AppSurfaces.border`（即 `outlineVariant`） |
| 主操作 | `colorScheme.primary` |
| 选中区域 | `colorScheme.primaryContainer` |
| 删除 / 错误 | `colorScheme.error` |

默认主题种子色为品牌绿 `#9CB86A`。「我的 → 设置 → 主题色」提供 8 种预设、可视化调色板和十六进制色值输入，先预览、再应用，也可恢复默认绿。调色板用二维面板选择饱和度 / 明暗、色相滑条选择色调；鼠标与触控都可点选 / 拖动，面板获焦后方向键可微调。调色板、预设及输入色值双向同步，黑 / 白 / 灰色保留取色中的色相，取色面板端点颜色集中在 `AppColorPickerColors`。

`ThemeModeProvider` 将外观模式与主题色保存为本机偏好（`app_theme_mode` / `app_theme_color_v1`），不按身份切换、不参与业务同步与备份。`AppTheme.light/dark/themeFor(seedColor:)` 从选定颜色生成浅色 / 深色 `ColorScheme`；未传参数时保持既有默认配色。所有入口将色值收成不透明色，旧设置缺失或无效时回退默认绿。背景图的透明度与对比度继续由原有主题计算负责。

品牌色以及分类、身份、状态等语义色保持原值，主题色设置只影响使用 `ColorScheme` 的界面强调色。

### 3.2 语义色白名单

以下颜色**不随主题切换**，也**不允许被主色替换**：

- 乖乖 / 晶晶身份色 —— `identityGuaiGuai` `identityJingJing`
- 用户分类 / 目标 / 打卡颜色 —— `AppSemanticColors.palette`
- 金银铜奖牌色 —— `medalGold` `medalSilver` `medalBronze`
- 统计图表颜色 —— `AppSemanticColors.chart`
- 地图与照片查看器颜色
- 词云颜色 —— `AppSemanticColors.wordCloud`
- 桌面小组件专用颜色（`home_widget_service.dart`，本轮不动）
- 状态色 —— `danger` `warning` `success` `info`
- Google 日历导入色 —— `calendarImport`

统一橙色语义色：警告与"同步中"都用 `AppSemanticColors.warning`。

### 3.3 实色块上的文字

叠在语义实色（分类色、目标色、打卡目标色、身份色、奖牌色）上的文字**不能固定白字**：
调色板里有浅色，`#D9BD2E` 与白色只有 1.86:1、`brandSurface #96B462` 只有 2.33:1，都远低于 4.5:1。

一律走 `AppSemanticColors.onColor(background)`：它在白字与黑字之间取对比度更高的一方，
对整份调色板 + 品牌绿 + 身份色的最差结果是 4.83:1。

```dart
// 对
Text(cat.name, style: TextStyle(color: AppSemanticColors.onColor(cat.color)))
// 错：浅色分类上会糊掉
Text(cat.name, style: const TextStyle(color: Colors.white))
```

描边 / 次级文字用 `onColorMuted(bg, alpha)`（默认 0.7）。

例外：照片查看器、地图标记圆环这类叠在**图片或地图**上的白色元素不属于此列，保留白色。

#### 3.3.1 半透明底：必须先合成

`Color.computeLuminance()` **忽略 alpha**。把 `color.withValues(alpha: 0.6)` 直接丢给
`onColor` 算出来的对比度是"没叠上去的那个色"，结论可能正好反过来。

三个工具方法把这件事封住：

| 方法 | 用途 |
|---|---|
| `compose(color, surface)` | 把半透明色压到 `surface` 上，返回实际看到的颜色 |
| `tint(color, surface, alpha)` | 语义色的淡色调；返回值**不透明**，可直接当 `BoxDecoration.color` |
| `onTint(color, surface, {alpha})` | 叠在该淡色调上的文字/图标色 |
| `readableOn(color, surface, {minRatio})` | 语义色**当文字用**时的可读版本（保持色相，压深/提亮到 ≥ 4.5:1）|

```dart
// 对：半透明底先合成成不透明色
final subBg = AppSemanticColors.tint(cat.color, sidebarSurface, 0.6);
Text(cat.name, style: TextStyle(color: AppSemanticColors.onColor(subBg)))

// 错：alpha 没合成，对比度算错
Text(cat.name, style: TextStyle(
    color: AppSemanticColors.onColor(cat.color.withValues(alpha: 0.6))))
```

`onColor` 收到 `alpha < 1` 而没传 `over:` 时会**直接抛断言**（debug 下），
就是为了不再静默算错。真要传半透明就写 `onColor(bg, over: AppSurfaces.of(context).page)`。

#### 3.3.2 同色系淡底 + 同色系文字

状态徽标、奖牌圆点、统计卡这类"自己淡底 + 自己文字"的组合，如果文字还用原色相就会糊在一起
（`warning #F98E45` 压在 15% 的 `warning` 底上只有约 1.8:1）。统一用 `onTint`：

```dart
final surface = AppSurfaces.of(context).card;
Container(
  decoration: BoxDecoration(color: AppSemanticColors.tint(color, surface)),
  child: Text('准时',
      style: TextStyle(color: AppSemanticColors.onTint(color, surface))),
)
```

同理，**语义色当文字直接压在页面/卡片上**（词云、进度横幅的文字、说明性标签）也要用
`readableOn(color, surface)` —— 品牌绿在白底只有 2.2:1。

#### 3.3.3 用户取到的颜色一律不透明

分类色、目标色、打卡色这些"用户自己选"的颜色，**在入口就把 alpha 收成 `FF`**，
不要留给渲染层去猜底面：

```dart
// 对：入口收一次
color: AppSemanticColors.opaque(Color(raw))
// 错：半透明的块底色会让文字对比度取决于它压在什么上面
```

收 alpha 的位置（新增取色入口时必须一并处理）：

| 入口 | 位置 |
|---|---|
| 十六进制输入框（允许贴 6/8 位，alpha 一律丢弃） | `home_screen.dart` 分类弹窗 |
| `Category.fromJson` / `Target.fromJson` / `CheckInGoal.fromJson` | 治愈历史脏数据 |
| 读取 `daily_slots` 里的 `c` 字段 | `time_provider.dart`，同理 |

背景：十六进制输入框曾接受 8 位 ARGB，`80FFFFFF` 会被存进分类色，再流到时间块就是半透明底。
`onColor` 对这种输入会抛断言（见 3.3.1），所以**入口不收，时间块就会崩**。
兜底：`TimeGrid` 仍然传 `over: surfaces.page`，历史脏数据也不会算错色。

拿不到 `BuildContext` 的兜底 UI（如启动失败页）用 `dangerDeep` / `brandDeep` 这类
"深色变体"常量；能拿到 context 时一律用 `readableOn`，它在深色主题下会正确保留亮色。

### 3.4 禁止

```dart
// 禁止：品牌色字面量散落各页面
backgroundColor: const Color(0xFF9CB86A),

// 禁止：为纯颜色用途写的 isDark 分支
color: isDark ? colorScheme.surface : const Color(0xFF96B462),

// 禁止：页面自己再抄一份调色板 / 用 Colors.primaries 当图表色板
static const List<Color> _colors = [Color(0xFFF16B77), ...];
final color = Colors.primaries[i % Colors.primaries.length];

// 禁止：状态色直接用命名词
color = Colors.green;   // 用 AppSemanticColors.success
color = Colors.orange;  // 用 AppSemanticColors.warning
```

### 3.5 背景图（壁纸）

「我的 → 外观」可选一张**本机照片**作为全窗口壁纸（只存本机，不进同步与备份）。
壁纸是**第 4 个主题量**：它不改色相，只把大面积填充变半透明，让照片透出来。

主题侧由 `AppTheme.light/dark(backgroundEnabled:, surfaceOpacity:)` 生成 `AppWallpaperTheme`
扩展（默认 `surfaceOpacity = 0.72`，即 `AppSurfaces.defaultSurfaceOpacity`）。

**规则：叠在壁纸上的大面积填充一律走 `context.wallpaperFill(color)`，语义实色卡片走
`context.adaptSemanticFill(color)`。** 直接给原始实色会把照片盖死。

```dart
// 对：启用壁纸时按界面不透明度变半透明，未启用时原样返回
Container(color: context.wallpaperFill(colorScheme.surfaceContainerHigh))
// 语义实色卡片：深色压暗一档 + 壁纸半透明
Container(color: context.adaptSemanticFill(goal.color))
```

两个细节：

- `wallpaperFill` **只改 alpha、不改色相、也不做深色压暗**；深色适配仍归 `adaptSemanticColor`
  （`adaptSemanticFill` = `adaptSemanticColor` 再叠 `wallpaperFill`）。
- 算文字对比度时**必须用不透明的原色**：`wallpaperFill` 返回的是半透明填充色，
  **不要**把它喂给 `AppSemanticColors.onColor`（带 alpha 会直接抛断言，见 3.3.1）。

**主题只自动把 4 个 surface role 变半透明**：`surface`、`surfaceContainerLowest`、
`surfaceContainerLow`、`surfaceContainer`（日记 / 打卡 / 我的页面直接读它们）。
`surfaceContainerHigh` / `surfaceContainerHighest` **在主题里必须保持不透明**，原因有二，
改动前先读 `app_theme.dart` 里那段注释：

1. Material 的 `DatePicker` / `TimePicker` 默认读 `High`，role 变半透明后会压在 scrim 上；
2. `adaptSemanticColor` 在深色下用 `High` 做 lerp，一旦拿到半透明色会让 `onColor` 断言失败。

这只约束**主题 role 本身**：页面若要画一块 `High` 底色的填充，仍可以自己取
`colorScheme.surfaceContainerHigh` 再经 `wallpaperFill` 变半透明（上面的例子就是这样，
`diary_screen` / `travel_screen` / `profile_screen` 均如此）。

照片不透明度是**独立的一档**（默认 0.15），由 `BackgroundImageContrast.safePhotoOpacity`
计算：拿**未套壁纸的原始** scheme 的 `page` / `onSurface` / `onSurfaceVariant` / `outline`，
对最坏情况照片（浅色主题取纯黑、深色取纯白）二分出仍满足正文 ≥ `bodyTextRatio`(4.5)、
描边 ≥ 3 的最大不透明度；随后用 `readableForeground` 把 `onSurface` / `onSurfaceVariant` /
`outline` / `outlineVariant` 朝黑白推到刚好达标。

对比度契约与合成都在 `lib/theme/background_image_contrast.dart`（`composite` 按 sRGB
逐通道合成，**不依赖渲染器的 blend mode**）。这个安全上限随主题与界面不透明度变化，
**不要**在各页面自行推算照片不透明度。

---

## 四、圆角

不采用"一刀切"：

| 使用场景 | 圆角 | 令牌 |
|---|---:|---|
| 时间块、网格、徽标小角 | 4 | `AppRadius.grid` |
| 徽标、模板 chip、子分类条 | 6 | `AppRadius.badge` |
| 普通按钮、输入框、分段控件 | 12 | `AppRadius.control` |
| 普通卡片、面板 | 16 | `AppRadius.card` |
| 底部面板、弹窗 | 20 | `AppRadius.sheet` |
| **连续时间块的连接处** | **0** | `AppRadius.joined` |

> `joined = 0` 是硬约束。时间块左右相连时必须把相接那一侧的圆角置 0，否则出现缺口。

---

## 五、间距

只允许 `4 / 8 / 12 / 16 / 24`（`AppSpacing.xs/sm/md/lg/xl`）。

手机版统一：

- 页面左右边距：16
- 模块之间：12 或 16
- 卡片内部：12～16
- 可点击控件最小高度：44～48（`AppSizes.button` = 44，`AppSizes.minTapTarget` = 48）

`AppSizes.iconButton`（40）只是**视觉**尺寸，触摸目标不得小于 44 —— 图标按钮用
`AppSizes.minTapTarget`，文字按钮的 `minimumSize` 高度是 44。

---

## 六、文字

统一使用语义层级，页面不自己写字号：

| 层级 | 令牌 |
|---|---|
| 页面标题 | `AppText.pageTitle` |
| 模块标题 | `AppText.sectionTitle` |
| 正文 | `AppText.body` |
| 辅助信息 | `AppText.caption` |
| 网格文字 | `AppText.gridLabel` |
| 标签 / 徽标文字 | `AppText.badge` |
| 按钮文字 | `AppText.button` |

`11～12` 的小字与 `4～6` 的小圆角保留，但必须明确属于**网格、徽标或辅助信息**，不能拿来当正文。

`AppText.*` 不带颜色；颜色由 `Theme` / `colorScheme` 决定。叠在实色块上的文字（例如时间块标签）不写死黑/白，而是走 `AppSemanticColors.onColor(...)` 按底色取。

---

## 七、迁移检查清单

每改一个页面同时检查浅色与深色：

- [ ] 文字对比度（尤其是叠在实色块上的文字，见 3.3）
- [ ] 底色是否不透明（用户取的色必须在入口收 alpha，见 3.3.3）
- [ ] 同色系淡底上的文字是否用了 `onTint`（见 3.3.2）
- [ ] 语义色当文字/图标色时是否经 `readableOn`
- [ ] 选中状态
- [ ] 卡片层级
- [ ] 背景图：大面积填充是否走 `wallpaperFill` / `adaptSemanticFill`，且没有把半透明色喂给 `onColor`（见 3.5）
- [ ] 时间块可读性
- [ ] 删除 / 警告颜色（亮红 `danger` 在白底只有 3.34:1，当文字必须压深）
- [ ] 输入框、弹窗、底部弹层、PopupMenu 背景（分别是 `surfaces.card`）
- [ ] 带缓存/记忆化的组件：缓存里是否混进了与主题相关的量（如词云曾把文字色存进布局缓存）
- [ ] 小屏幕上没有按钮或文字溢出（360×640 是基准尺寸）

删除的只是"纯颜色用途"的 `isDark` 分支；特殊场景（例如地图自定义样式）仍允许保留。

---

## 八、验收标准

- 核心手机版页面使用同一套主色和表面层级
- 页面不再各自定义品牌绿色
- 时间块仍保持原有 10 分钟网格与连续连接
- 浅色、深色都有一致表现
- 底部导航、按钮、卡片、弹窗样式统一
- 身份色、分类色、图表色等语义色没有被误覆盖
- 小屏幕上没有按钮或文字溢出
- 用户的核心操作方式不发生变化

---

## 九、规范是被测试守住的

`test/visual_system_test.dart` 里有两组测试：

1. **令牌与对比度断言** —— `AppSurfaces` 的浅/深取值、圆角档位、按钮最小高度、
   日期面板选中/今天的表现、真实 `MainScreen` 在 360×640 下不溢出；
   对比度方面覆盖：实色块上的 `onColor`、状态色、`primary`+`onPrimary`、
   **半透明底的合成结果（`compose` / `tint` / `onTint`：3 种底面 × 3 档透明度 × 整份调色板）**、
   `readableOn` 覆盖词云/图表/状态色、选中时间块的高亮底、
   被点名过的具体位置（「补」徽标、我的 TabBar 标签、删除按钮、`dangerDeep`）、
   `opaque` 与模型 `fromJson` 的治愈行为、**词云文字色随浅/深底色改变且都达标**、
   **背景图启用时 `wallpaperFill` / `adaptSemanticFill` 的 alpha 等于 `surfaceOpacity`**。
2. **源码守卫（正则扫描 `lib/`，theme 之外）** —— 禁止：
   `Color(0x…)` 与 `0xFF…` 字面量、`isDark`、`estimateBrightnessForColor`、
   `Colors.primaries|green|orange|red|redAccent|…|grey`、`Colors.white`、
   `onColor(<带 alpha 的色>)`、不在 4/6/12/16/20 档位内的 `BorderRadius.circular(N)`、
   以及**语义色直接当 `TextStyle` / `Icon` / `foregroundColor` 的颜色**
   （必须经 `onColor` / `readableOn` / `onTint`，或 `*Deep` 常量）。

> 修完不写守卫，下一轮评审还会点到同一类问题 —— 上一轮 5 条里有 4 条就是这么来的。

白名单（写死在测试里，改动需说明理由）：

- `Colors.white` 允许：`check_in_photo_viewer.dart`、`check_in_photo_sheet.dart`、
  `check_in_map_preview.dart`（白色叠在图片 / 地图上）
- 颜色字面量允许：`services/home_widget_service.dart`（桌面小组件，本轮范围外）

背景图另有专门的测试：`test/background_image_contrast_test.dart`（`composite` / 对比度 /
`safePhotoOpacity` / `readableForeground`）与 `test/background_image_provider_test.dart`
（不透明度只在 commit 时落盘、启动清失效路径、超限/取消属正常结果）。

新增例外时请在 PR/提交信息里写清原因，不要直接放宽正则。
