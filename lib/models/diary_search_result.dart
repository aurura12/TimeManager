class DiarySearchResult {
  final String kind;
  final DateTime date;
  final String snippet;
  final int matchIndex;

  const DiarySearchResult({
    required this.kind,
    required this.date,
    required this.snippet,
    required this.matchIndex,
  });

  String get dateKey => '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String get kindLabel => kind == 'g' ? 'G' : 'J';
}
