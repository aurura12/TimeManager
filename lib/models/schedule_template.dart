class TemplateSlot {
  final int index;
  final String label;
  final String? categoryId;
  final int? colorArgb;

  TemplateSlot({
    required this.index,
    required this.label,
    this.categoryId,
    this.colorArgb,
  });

  Map<String, dynamic> toJson() => {
        'i': index,
        'l': label,
        if (categoryId != null && categoryId!.isNotEmpty) 'cid': categoryId,
        if (colorArgb != null) 'c': colorArgb,
      };

  factory TemplateSlot.fromJson(Map<String, dynamic> json) => TemplateSlot(
        index: _asInt(json['i']) ?? 0,
        label: _asString(json['l']) ?? '',
        categoryId: _asString(json['cid']),
        colorArgb: _asInt(json['c']),
      );

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String? _asString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    return value.toString();
  }
}

class ScheduleTemplate {
  final String id;
  final String name;
  final List<TemplateSlot> slots;
  final int createdAt;

  ScheduleTemplate({
    required this.id,
    required this.name,
    required this.slots,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'slots': slots.map((s) => s.toJson()).toList(),
        'createdAt': createdAt,
      };

  factory ScheduleTemplate.fromJson(Map<String, dynamic> json) =>
      ScheduleTemplate(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        slots: _slotsFromJson(json['slots']),
        createdAt: _asInt(json['createdAt']) ?? 0,
      );

  static int? _asInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return num.tryParse(value.trim())?.toInt();
    return null;
  }

  /// 单个槽位解析失败不影响其余槽位，整条模板仍然可用。
  static List<TemplateSlot> _slotsFromJson(dynamic value) {
    if (value is! List) return [];
    final slots = <TemplateSlot>[];
    for (final entry in value) {
      if (entry is! Map) continue;
      try {
        slots.add(TemplateSlot.fromJson(Map<String, dynamic>.from(entry)));
      } catch (_) {
        // 忽略坏槽位
      }
    }
    return slots;
  }

  ScheduleTemplate copyWith({
    String? id,
    String? name,
    List<TemplateSlot>? slots,
    int? createdAt,
  }) =>
      ScheduleTemplate(
        id: id ?? this.id,
        name: name ?? this.name,
        slots: slots ?? this.slots,
        createdAt: createdAt ?? this.createdAt,
      );
}

enum ApplyTemplateMode { replaceAll, fillEmptyOnly }
