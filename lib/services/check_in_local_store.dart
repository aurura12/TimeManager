import '../models/check_in_document.dart';
import 'transactional_preference_string.dart';

class CheckInLocalStore {
  static final _draft = TransactionalPreferenceString('check_in_data_draft');

  /// 保存成功返回 true；写入失败（磁盘、权限等）返回 false，调用方必须提示用户。
  static Future<bool> saveDraft(CheckInDocument document) async {
    try {
      return await _draft.save(document.toMarkdown());
    } catch (_) {
      return false;
    }
  }

  static Future<CheckInDocument?> loadDraft() async {
    final raw = await _draft.load();
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return CheckInDocument.fromMarkdown(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearDraft() => _draft.remove();
}
