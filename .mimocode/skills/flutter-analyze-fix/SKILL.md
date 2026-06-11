---
name: flutter-analyze-fix
description: Run flutter analyze on modified files, interpret results, and fix errors iteratively until clean
---

# Flutter Analyze → Fix Cycle

Standard workflow for making code changes in this Flutter project. Run after every edit to catch errors early.

## Steps

1. **Read** the target file(s) to understand current code
2. **Edit** the file with your change
3. **Run analyzer** on modified files only (fast feedback):
   ```bash
   flutter analyze lib/path/to/file.dart 2>&1 | tail -10
   ```
4. **Check output**:
   - `No issues found` → done
   - Errors/warnings → read the error messages, fix, re-run
5. **For broad changes** affecting many files, run full lib analysis:
   ```bash
   flutter analyze lib/ 2>&1 | tail -5
   ```
6. **Filter noise** — ignore `unused_import`, `unused_local_variable`, `deprecated_member_use`, `unnecessary_string` warnings; focus on real errors:
   ```bash
   flutter analyze lib/ 2>&1 | grep -E "error|warning" | grep -v "unused_import\|unused_local\|deprecated_member\|unnecessary_string"
   ```

## Notes

- This project uses `flutter analyze` (dart analyze), not `dartanalyzer`
- Config files in `lib/config/` are `.gitignore`d and may cause import errors if missing — check for `*_config.dart` files before analyzing
- The test file `test/widget_test.dart` is boilerplate and references a non-existent `MyApp` — ignore test errors unless actively fixing tests
