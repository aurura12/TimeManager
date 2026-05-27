import 'dart:convert';

import 'package:intl/intl.dart';

class TravelRecord {
  final DateTime date;
  final String location;
  final String event;

  const TravelRecord({
    required this.date,
    required this.location,
    required this.event,
  });

  String get dateKey => DateFormat('yyyy-MM-dd').format(date);

  TravelRecord copyWith({DateTime? date, String? location, String? event}) {
    return TravelRecord(
      date: date ?? this.date,
      location: location ?? this.location,
      event: event ?? this.event,
    );
  }

  Map<String, dynamic> toJson() {
    return {'date': dateKey, 'location': location, 'event': event};
  }

  factory TravelRecord.fromJson(Map<String, dynamic> json) {
    final dateText = json['date']?.toString() ?? '';
    final parsed = DateTime.tryParse(dateText);
    if (parsed == null) {
      throw const FormatException('记录 date 字段无效');
    }
    return TravelRecord(
      date: DateTime(parsed.year, parsed.month, parsed.day),
      location: json['location']?.toString() ?? '',
      event: json['event']?.toString() ?? '',
    );
  }
}

class TravelRecordsDocument {
  static const String filePath = 'travel_records.md';

  final List<TravelRecord> records;

  const TravelRecordsDocument({required this.records});

  TravelRecordsDocument upsert(TravelRecord record) {
    final next = [...records];
    final idx = next.indexWhere((e) => e.dateKey == record.dateKey);
    if (idx >= 0) {
      next[idx] = record;
    } else {
      next.add(record);
    }
    next.sort((a, b) => b.date.compareTo(a.date));
    return TravelRecordsDocument(records: next);
  }

  String toMarkdown() {
    final payload = records.map((e) => e.toJson()).toList();
    final body = const JsonEncoder.withIndent('  ').convert(payload);
    final now = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    return '---\n'
        'title: 出行记录\n'
        'updated_at: $now\n'
        '---\n'
        '$body\n';
  }

  static TravelRecordsDocument fromMarkdown(String markdown) {
    final body = _extractBody(markdown).trim();
    if (body.isEmpty) {
      return const TravelRecordsDocument(records: []);
    }
    final decoded = json.decode(body);
    if (decoded is! List) {
      throw const FormatException('出行记录文件正文必须是 JSON 数组');
    }
    final records = <TravelRecord>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final map = item.map((key, value) => MapEntry(key.toString(), value));
      records.add(TravelRecord.fromJson(map));
    }
    records.sort((a, b) => b.date.compareTo(a.date));
    return TravelRecordsDocument(records: records);
  }

  static String _extractBody(String markdown) {
    final match = RegExp(
      r'^---\n([\s\S]*?)\n---\n?',
      multiLine: false,
    ).firstMatch(markdown);
    if (match == null) return markdown;
    return markdown.substring(match.end);
  }
}
