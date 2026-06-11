---
name: flutter-state-persistence
description: Persist UI state (expand/collapse, selections) across app restarts using SharedPreferences via Provider
---

# Flutter UI State Persistence

This project stores persistent data via `TimeProvider` which uses `SharedPreferences` (JSON-serialized maps). When UI state like expand/collapse needs to survive restarts, follow this pattern.

## Pattern

### 1. Add state field to `TimeProvider`

```dart
// lib/providers/time_provider.dart
Map<String, bool> _uiStates = {};
```

### 2. Add getter/setter with `notifyListeners()`

```dart
bool getUiState(String key, {bool defaultValue = true}) {
  return _uiStates[key] ?? defaultValue;
}

void setUiState(String key, bool value) {
  _uiStates[key] = value;
  notifyListeners();  // CRITICAL: must call to trigger UI rebuild
}
```

### 3. Add to `_saveDataImpl()`

```dart
// In _saveDataImpl(), add:
data['uiStates'] = _uiStates;
```

### 4. Add to `_loadData()`

```dart
// In _loadData(), add:
if (data['uiStates'] != null) {
  _uiStates = Map<String, bool>.from(data['uiStates']);
}
```

### 5. Use in UI widget

```dart
// Replace local state with provider:
final isExpanded = Provider.of<TimeProvider>(context).getUiState('category_$id');
```

## Key files

- `lib/providers/time_provider.dart` — central state + SharedPreferences persistence
- `lib/screens/home_screen.dart` — main UI consuming provider state

## Common pitfall

**`setCategoryExpandState` without `notifyListeners()`** — the most common bug. The state updates in memory but UI doesn't rebuild, causing click/drag conflicts. Always add `notifyListeners()` after state mutation.
