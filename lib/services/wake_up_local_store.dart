import 'package:shared_preferences/shared_preferences.dart';

import '../models/diary_kind.dart';
import '../models/wake_up_document.dart';
import 'app_identity_service.dart';

/// 所有平台都按身份隔离，数据和待上传标记在同一份 JSON 中原子保存。
class WakeUpLocalStore {
  static const preferenceBaseKey = 'wake_up_records_v1';

  static String keyFor(DiaryKind kind) =>
      AppIdentityResolver.dataKey(kind, preferenceBaseKey);

  Future<WakeUpDocument> load(DiaryKind kind) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(keyFor(kind));
    return raw == null ? WakeUpDocument() : WakeUpDocument.decode(raw);
  }

  Future<void> save(DiaryKind kind, WakeUpDocument document) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      keyFor(kind),
      document.encode(includeLocalState: true),
    );
    if (!saved) throw StateError('无法保存起床记录，请重试');
  }
}
