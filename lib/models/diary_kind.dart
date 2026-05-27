enum DiaryKind { g, j }

extension DiaryKindX on DiaryKind {
  String get code => this == DiaryKind.g ? 'g' : 'j';

  String get prefix => this == DiaryKind.g ? 'G🛹' : 'J🕊️';

  String get label => this == DiaryKind.g ? 'G' : 'J';

  static DiaryKind fromCode(String? value) {
    return value?.toLowerCase() == 'j' ? DiaryKind.j : DiaryKind.g;
  }
}
