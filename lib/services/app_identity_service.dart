import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/diary_kind.dart';
import '../models/google_calendar_user.dart';
import '../models/known_google_users.dart';
import 'app_user_identity_store.dart';
import 'google_calendar_service.dart';

/// The two ways the app can decide who is using it.
enum AppIdentityMode { manual, google }

extension AppIdentityModeX on AppIdentityMode {
  String get code => this == AppIdentityMode.google ? 'google' : 'manual';

  static AppIdentityMode fromCode(String? value) {
    return value?.trim().toLowerCase() == 'google'
        ? AppIdentityMode.google
        : AppIdentityMode.manual;
  }
}

/// The effective identity used by app-owned data and business services.
///
/// The remote repositories already partition data by the logical person (g/j),
/// so both a manual identity and its matching Google identity intentionally
/// resolve to the same [person].
class AppIdentity {
  final AppIdentityMode mode;
  final DiaryKind person;
  final String stableId;
  final String email;
  final GoogleCalendarUser? googleUser;

  const AppIdentity({
    required this.mode,
    required this.person,
    required this.stableId,
    required this.email,
    this.googleUser,
  });
}

/// Pure identity resolution rules shared by the runtime and tests.
class AppIdentityResolver {
  AppIdentityResolver._();

  static AppIdentity manual(DiaryKind kind) {
    return AppIdentity(
      mode: AppIdentityMode.manual,
      person: kind,
      stableId: 'manual-${kind.code}',
      email: kind == DiaryKind.g
          ? KnownGoogleUsers.guaiGuaiEmail
          : KnownGoogleUsers.jingJingEmail,
    );
  }

  static AppIdentity? google(GoogleCalendarUser user) {
    final nickname = KnownGoogleUsers.nicknameFor(user.email);
    final kind = switch (nickname) {
      '乖乖' => DiaryKind.g,
      '晶晶' => DiaryKind.j,
      _ => null,
    };
    if (kind == null) return null;
    return AppIdentity(
      mode: AppIdentityMode.google,
      person: kind,
      stableId: 'google-${user.id}',
      email: user.email,
      googleUser: user,
    );
  }

  static AppIdentity? resolve({
    required AppIdentityMode mode,
    DiaryKind? manualKind,
    GoogleCalendarUser? googleUser,
  }) {
    if (mode == AppIdentityMode.manual) {
      return manualKind == null ? null : manual(manualKind);
    }
    return googleUser == null ? null : google(googleUser);
  }

  /// Local data is partitioned by logical person, matching the existing g/j
  /// remote paths.  Keeping this in one place prevents accidental global keys.
  static String dataKey(DiaryKind kind, String baseKey) {
    return 'identity_${kind.code}_$baseKey';
  }
}

/// Shared, synchronous view of the current app identity for screens and
/// services that do not own the [TimeProvider].
class AppIdentityService {
  AppIdentityService._();

  static const String modeKey = 'app_identity_mode';
  static const String legacySyncKey = 'google_calendar_sync_enabled';
  static const String legacyScheduleUserKey = 'schedule_user_kind';

  static AppIdentityMode _mode = AppIdentityMode.manual;
  static DiaryKind? _manualKind;
  static GoogleCalendarUser? _storedGoogleUser;
  static bool _loaded = false;
  static Future<void>? _loading;
  static final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  static Stream<void> get changes => _changeController.stream;
  static AppIdentityMode get mode => _mode;
  static bool get isManualMode => _mode == AppIdentityMode.manual;
  static bool get isGoogleMode => _mode == AppIdentityMode.google;
  static DiaryKind? get manualKind => _manualKind;
  static bool get isLoaded => _loaded;

  /// Loads the persisted mode and identities. Calls are coalesced so startup
  /// and the check-in screen cannot race secure-storage reads.
  static Future<void> load() {
    final loading = _loading;
    if (loading != null) return loading;
    final future = _loadInternal();
    _loading = future;
    return future.whenComplete(() {
      if (identical(_loading, future)) _loading = null;
    });
  }

  static Future<void> _loadInternal() async {
    final prefs = await SharedPreferences.getInstance();
    final persistedMode = prefs.getString(modeKey);
    final legacySyncEnabled = prefs.getBool(legacySyncKey);
    _mode = persistedMode == null
        ? (legacySyncEnabled == true
            ? AppIdentityMode.google
            : AppIdentityMode.manual)
        : AppIdentityModeX.fromCode(persistedMode);

    _manualKind = await AppUserIdentityStore.loadManualKind();
    if (_manualKind == null) {
      // Existing releases stored the manual selection only in preferences.
      // Read it as a migration source; the next explicit selection writes the
      // secure copy without making an implicit identity choice.
      final legacyKind = prefs.getString(legacyScheduleUserKey);
      if (legacyKind != null && legacyKind.trim().isNotEmpty) {
        _manualKind = DiaryKindX.fromCode(legacyKind);
      }
    }
    _storedGoogleUser = await AppUserIdentityStore.load();
    _loaded = true;
    _notifyChanged();
  }

  /// The current Google identity, if it is one of the two supported users.
  /// An unknown active account must not fall back to a previously stored one.
  static GoogleCalendarUser? get googleUser {
    final active = GoogleCalendarService.sessionUser;
    final candidate = active ?? _storedGoogleUser;
    if (candidate == null || !KnownGoogleUsers.isKnownEmail(candidate.email)) {
      return null;
    }
    return candidate;
  }

  static DiaryKind? get personKind {
    if (_mode == AppIdentityMode.manual) return _manualKind;
    final identity = googleUser;
    return identity == null
        ? null
        : AppIdentityResolver.google(identity)?.person;
  }

  static AppIdentity? get currentIdentity {
    if (_mode == AppIdentityMode.manual) {
      return _manualKind == null
          ? null
          : AppIdentityResolver.manual(_manualKind!);
    }
    final identity = googleUser;
    return identity == null ? null : AppIdentityResolver.google(identity);
  }

  static GoogleCalendarUser? get currentUser {
    final identity = currentIdentity;
    if (identity == null) return null;
    return _mode == AppIdentityMode.manual
        ? _manualUser(_manualKind!)
        : googleUser;
  }

  static bool get hasIdentity => currentIdentity != null;

  /// Returns a preference key in the namespace of the current logical person.
  /// Unknown or not-yet-selected identities use an isolated unbound namespace
  /// so they can never read another person's local data.
  static String dataKeyForCurrentIdentity(String baseKey) {
    final kind = personKind;
    return kind == null
        ? 'identity_unbound_$baseKey'
        : AppIdentityResolver.dataKey(kind, baseKey);
  }

  static GoogleCalendarUser _manualUser(DiaryKind kind) {
    return GoogleCalendarUser(
      email: kind == DiaryKind.g
          ? KnownGoogleUsers.guaiGuaiEmail
          : KnownGoogleUsers.jingJingEmail,
      id: 'manual-${kind.code}',
      displayName: kind == DiaryKind.g ? '乖乖' : '晶晶',
    );
  }

  static Future<bool> setMode(AppIdentityMode nextMode) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(modeKey, nextMode.code)) return false;
    _mode = nextMode;
    _notifyChanged();
    return true;
  }

  static Future<bool> setManualKind(DiaryKind kind) async {
    try {
      await AppUserIdentityStore.saveManualKind(kind);
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(legacyScheduleUserKey, kind.code)) {
        return false;
      }
      _manualKind = kind;
      _notifyChanged();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 让不拥有身份状态的宿主（例如 Windows 的 [TimeProvider]）把已确认的
  /// 手动身份同步到进程内视图。持久化由调用方负责，这里只更新共享上下文
  /// 并通知同步状态中心，避免出现“业务身份是 g、状态中心仍是 unbound”。
  static void adoptManualKind(DiaryKind? kind) {
    _mode = AppIdentityMode.manual;
    // 桌面端调用方可能只读到了当前版本的 secure storage，而 load()
    // 已经通过 legacy preference 解析出了旧身份。此时 null 表示“没有
    // 新值”，不能把刚解析出的 legacy 身份抹掉。
    if (kind != null) _manualKind = kind;
    _loaded = true;
    _notifyChanged();
  }

  static void notifyChanged() => _notifyChanged();

  static void _notifyChanged() {
    if (!_changeController.isClosed) _changeController.add(null);
  }

  /// Test-only reset hook. Production code never needs to reset this process
  /// singleton, while isolated Flutter tests do.
  static void resetForTesting() {
    _mode = AppIdentityMode.manual;
    _manualKind = null;
    _storedGoogleUser = null;
    _loaded = false;
    _loading = null;
  }
}
