# AGENTS.md

## Project Overview

Flutter time management app (v1.38.0) with Google Calendar integration, daily diary, travel records, target tracking, and AI daily review. Chinese-language UI with English fallback.

## Architecture

- **Entry**: `lib/main.dart` → `MainScreen` (5-tab bottom nav: 记录/日记/出行/目标/我的)
- **State**: `lib/providers/` — `TimeProvider`, `ThemeModeProvider` (Provider pattern)
- **Models**: `lib/models/` — `TimeSlot`, `TravelRecord`, `Target`, `ScheduleTemplate`, `SearchResult`
- **Screens**: `lib/screens/` — `HomeScreen`, `DiaryScreen`, `TravelScreen`, `TargetScreen`, `ProfileScreen`, plus `DailyReviewScreen`, `WordCloudScreen`, `EventDetailScreen`, `TargetDetailScreen`, `AddTargetScreen`, `GlobalSearchScreen`
- **Services**: `lib/services/` — Google Calendar, Feishu Calendar, diary GitHub sync, travel GitHub sync, SiliconFlow AI, home widget, data backup
- **Config**: `lib/config/` — API keys and service configs (`.gitignore`d)

## Commands

```bash
flutter pub get          # install deps
flutter analyze          # lint check
flutter test             # run tests
flutter run               # start dev (mobile)
flutter build apk        # build Android
```

## Config Files (Secrets — .gitignore'd)

These files must be created locally from examples before the app can function:

1. `lib/config/diary_github_config.dart` — GitHub token for diary sync
2. `lib/config/siliconflow_config.dart` — AI service API key
3. `lib/config/google_sign_in_config.dart` — Google OAuth client IDs

All three are in `.gitignore`. Never commit them.

## Key Dependencies

- `home_widget` — Android home screen widget
- `google_sign_in` + `googleapis` — Google Calendar
- `flutter_secure_storage` — secure key storage
- `provider` — state management

## Testing

- Only one test file exists: `test/widget_test.dart` (boilerplate, references `MyApp` which doesn't exist — needs update)
- No CI workflows configured

## Conventions

- Code and UI text are in Chinese
- Config files with secrets are always `.gitignore`d — always create from `.example.dart` templates
- `lib/config/*.example.dart` files serve as the source of truth for required config structure
