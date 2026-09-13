/// A local-only snapshot of an event's parent/child relationship at deletion.
///
/// Statistics can still aggregate [eventName] by label, while the detail
/// screen uses the remaining fields to reconstruct the deleted hierarchy.
class DeletedEventRelation {
  final String categoryId;
  final String parentName;
  final String eventName;
  final bool isParentEvent;
  final int deletedAt;

  const DeletedEventRelation({
    required this.categoryId,
    required this.parentName,
    required this.eventName,
    required this.isParentEvent,
    required this.deletedAt,
  });

  String get relationText =>
      isParentEvent ? parentName : '$parentName / $eventName';

  DeletedEventRelation copyWith({
    String? categoryId,
    String? parentName,
    String? eventName,
    bool? isParentEvent,
    int? deletedAt,
  }) {
    return DeletedEventRelation(
      categoryId: categoryId ?? this.categoryId,
      parentName: parentName ?? this.parentName,
      eventName: eventName ?? this.eventName,
      isParentEvent: isParentEvent ?? this.isParentEvent,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'categoryId': categoryId,
      'parentName': parentName,
      'eventName': eventName,
      'isParentEvent': isParentEvent,
      'deletedAt': deletedAt,
    };
  }

  factory DeletedEventRelation.fromJson(Map<String, dynamic> json) {
    final categoryId = json['categoryId'];
    final parentName = json['parentName'];
    final eventName = json['eventName'];
    final isParentEvent = json['isParentEvent'];
    final rawDeletedAt = json['deletedAt'];
    final deletedAt = rawDeletedAt is num
        ? rawDeletedAt.toInt()
        : int.tryParse(rawDeletedAt?.toString() ?? '');

    if (categoryId is! String ||
        categoryId.isEmpty ||
        parentName is! String ||
        parentName.isEmpty ||
        eventName is! String ||
        eventName.isEmpty ||
        isParentEvent is! bool ||
        deletedAt == null ||
        deletedAt <= 0) {
      throw const FormatException('已删除事件关系记录格式无效');
    }

    return DeletedEventRelation(
      categoryId: categoryId,
      parentName: parentName,
      eventName: eventName,
      isParentEvent: isParentEvent,
      deletedAt: deletedAt,
    );
  }
}
