import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/main_tab_id.dart';

/// 本机导航偏好，不随身份切换，也不参与业务同步或备份。
class MainTabProvider extends ChangeNotifier {
  MainTabProvider({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferences = (preferencesLoader ?? SharedPreferences.getInstance)() {
    ready = _load();
  }

  static const storageKey = 'app_main_tabs_v1';
  static const minimumVisibleTabs = 2;

  final Future<SharedPreferences> _preferences;
  late final Future<void> ready;
  Future<void> _saveQueue = Future<void>.value();
  List<MainTabId> _order = List.unmodifiable(MainTabId.values);
  Set<MainTabId> _hiddenTabs = const {};
  bool _isLoaded = false;
  bool _disposed = false;

  List<MainTabId> get order => _order;
  Set<MainTabId> get hiddenTabs => _hiddenTabs;
  bool get isLoaded => _isLoaded;
  List<MainTabId> get visibleTabs => List.unmodifiable(
        _order.where((tab) => !_hiddenTabs.contains(tab)),
      );

  Future<void> _load() async {
    try {
      final prefs = await _preferences;
      if (_disposed) return;
      final raw = prefs.get(storageKey);
      if (raw is String) {
        final document = jsonDecode(raw);
        if (document is Map<String, dynamic>) {
          final order = <MainTabId>[];
          final storedOrder = document['order'];
          if (storedOrder is List) {
            for (final id in storedOrder) {
              final tab = MainTabId.fromId(id);
              if (tab != null && !order.contains(tab)) order.add(tab);
            }
          }
          // 新增标签或旧偏好缺项时，按默认顺序补齐。
          order.addAll(MainTabId.values.where((tab) => !order.contains(tab)));
          final hidden = <MainTabId>{};
          final storedHidden = document['hidden'];
          if (storedHidden is List) {
            for (final id in storedHidden) {
              final tab = MainTabId.fromId(id);
              if (tab != null && tab != MainTabId.profile) hidden.add(tab);
            }
          }
          // 保留设置入口，并满足 NavigationBar / NavigationRail 的最少项数。
          if (order.length - hidden.length < minimumVisibleTabs) {
            hidden.remove(MainTabId.record);
          }
          _order = List.unmodifiable(order);
          _hiddenTabs = Set.unmodifiable(hidden);
        }
      }
    } on Object {
      // 偏好损坏或不可读时使用默认导航，不阻止启动。
    } finally {
      if (!_disposed) {
        _isLoaded = true;
        notifyListeners();
      }
    }
  }

  /// 顺序和开关作为同一份文档保存；落盘成功后才更新导航。
  Future<void> save({
    required List<MainTabId> order,
    required Set<MainTabId> hiddenTabs,
  }) {
    final nextOrder = List<MainTabId>.unmodifiable(order);
    final nextHidden = Set<MainTabId>.unmodifiable(hiddenTabs);
    if (nextOrder.length != MainTabId.values.length ||
        nextOrder.toSet().length != MainTabId.values.length) {
      throw ArgumentError('标签顺序必须包含所有标签且不能重复');
    }
    if (nextHidden.contains(MainTabId.profile) ||
        nextOrder.length - nextHidden.length < minimumVisibleTabs) {
      throw ArgumentError('至少显示两个标签，且必须保留“我的”');
    }

    final operation = _saveQueue.then((_) async {
      await ready;
      if (_disposed ||
          (listEquals(_order, nextOrder) &&
              setEquals(_hiddenTabs, nextHidden))) {
        return;
      }
      final prefs = await _preferences;
      try {
        final saved = await prefs.setString(
          storageKey,
          jsonEncode({
            'order': nextOrder.map((tab) => tab.id).toList(),
            'hidden': nextHidden.map((tab) => tab.id).toList(),
          }),
        );
        if (!saved) throw StateError('保存标签设置失败');
      } on Object {
        // SharedPreferences 在写入前就更新缓存；失败后重新读盘，避免
        // 新建 Provider 时把尚未保存的草稿当作成功保存的偏好。
        try {
          await prefs.reload();
        } on Object {
          // 保留原始保存错误，供界面提示重试。
        }
        rethrow;
      }
      if (_disposed) return;
      _order = nextOrder;
      _hiddenTabs = nextHidden;
      notifyListeners();
    });
    // 一次失败不阻断之后的重试；并发保存按提交顺序落盘。
    _saveQueue = operation.catchError((Object _) {});
    return operation;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
