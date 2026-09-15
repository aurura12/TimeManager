/// 远程日记路径的日期解析和排序工具。
DateTime? parseDiaryDateFromRemotePath(String path) {
  final separator = path.lastIndexOf('/');
  final fileName = separator >= 0 ? path.substring(separator + 1) : path;
  final match = RegExp(r'(\d{4})年(\d{1,2})月(\d{1,2})日').firstMatch(fileName);
  if (match == null) return null;

  final year = int.tryParse(match.group(1) ?? '');
  final month = int.tryParse(match.group(2) ?? '');
  final day = int.tryParse(match.group(3) ?? '');
  if (year == null || month == null || day == null) return null;

  final date = DateTime(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    return null;
  }
  return date;
}

/// 按日记日期正序排列，最新日期在后。
int compareDiaryRemoteFilePaths(String a, String b) {
  final aDate = parseDiaryDateFromRemotePath(a);
  final bDate = parseDiaryDateFromRemotePath(b);
  if (aDate != null && bDate != null) {
    final dateOrder = aDate.compareTo(bDate);
    if (dateOrder != 0) return dateOrder;
  } else if (aDate != null) {
    return -1;
  } else if (bDate != null) {
    return 1;
  }

  final aName = a.substring(a.lastIndexOf('/') + 1);
  final bName = b.substring(b.lastIndexOf('/') + 1);
  final nameOrder = aName.compareTo(bName);
  return nameOrder != 0 ? nameOrder : a.compareTo(b);
}
