# Mac 开发机同步清单

Windows 侧已升级到 Flutter 3.50.1，并把 pub 依赖源统一为 `pub.flutter-io.cn`、提交了新的 `pubspec.lock`。Mac 按下面顺序执行一遍，保证两台机器的依赖解析结果一致。

## 1. 检查 Flutter 版本

```bash
flutter --version
```

要求 **3.50.1 及以上**。项目已迁移到 `material_ui ^1.11.0`（要求 Dart ≥ 3.13.0），版本偏低时 `flutter pub get` 会直接求解失败。版本不够就：

```bash
flutter upgrade
```

## 2. 配置 pub 镜像

写入 `~/.zshrc`，与 Windows 侧保持一致：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

```bash
source ~/.zshrc
echo $PUB_HOSTED_URL   # 应输出 https://pub.flutter-io.cn
```

镜像必须在 `flutter pub get` 之前生效，否则 Mac 会把锁文件里的下载源改回 `pub.dev`，两台机器来回改写。

## 3. 拉代码并处理本地锁文件

```bash
git pull
git diff pubspec.lock        # 先看一眼本地是否有锁文件改动
```

如果本地有旧的锁文件改动（例如之前用官方源跑过 `pub get`），丢弃它再继续：

```bash
git checkout -- pubspec.lock
```

## 4. 安装依赖

```bash
flutter pub get
```

只用 `pub get`，**不要 `pub upgrade`**。锁文件是两台机器共用的解析结果，upgrade 会让版本漂移。

## 5. 确认锁文件没有被改写

```bash
git status --short pubspec.lock   # 应无输出
```

如果有输出且只改动了 `url` 行，说明第 2 步的镜像没生效，先修正环境变量再重跑 `pub get`。

## 6. 跑构建前门禁

```bash
flutter analyze
flutter test
```

发布脚本 `scripts/publish_all_release.ps1` 默认在打包前跑这两项，任意一项失败会直接中止构建。

## 7. Mac 侧的两个平台注意

- **日程身份存储**：`AppUserIdentityStore` 在 macOS 上刻意走 `SharedPreferences`（`schedule_user_kind`），其他平台走安全存储，目的是避免本地构建依赖 Keychain 授权。不要"统一"成安全存储。
- **iOS 构建**：需要 macOS + Xcode，并安装 iOS 平台组件（`xcodebuild -downloadPlatform iOS`）；签名与真机步骤见 `AGENTS.md` 的「环境要求」。

## 8. 首次开发还要准备

`lib/config/` 下 6 个密钥文件，缺任意一个 `flutter analyze` / `flutter test` 会直接失败，字段表见 `AGENTS.md` 的「Config Files」。
