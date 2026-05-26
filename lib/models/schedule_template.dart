class TemplateSlot {
  final int index;
  final String label;
  final int? colorArgb;

  TemplateSlot({
    required this.index,
    required this.label,
    this.colorArgb,
  });

  Map<String, dynamic> toJson() => {
        'i': index,
        'l': label,
        if (colorArgb != null) 'c': colorArgb,
      };

  factory TemplateSlot.fromJson(Map<String, dynamic> json) => TemplateSlot(
        index: json['i'] as int,
        label: json['l'] as String,
        colorArgb: json['c'] as int?,
      );
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
        id: json['id'] as String,
        name: json['name'] as String,
        slots: (json['slots'] as List<dynamic>)
            .map((e) => TemplateSlot.fromJson(e as Map<String, dynamic>))
            .toList(),
        createdAt: json['createdAt'] as int,
      );

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
