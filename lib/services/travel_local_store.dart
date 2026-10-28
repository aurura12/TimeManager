import 'transactional_preference_string.dart';

class TravelLocalStore {
  static final _draft = TransactionalPreferenceString('travel_records_draft');

  static Future<String?> loadDraft() => _draft.load();

  /// 保存成功返回 true；写入失败（磁盘、权限等）返回 false，调用方必须提示用户。
  static Future<bool> saveDraft(String markdown) => _draft.save(markdown);
}
