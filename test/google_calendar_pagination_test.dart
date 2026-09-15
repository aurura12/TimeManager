import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/calendar/v3.dart' as calendar;
import 'package:time_manager/services/google_calendar_service.dart';

calendar.Events _events(
  List<String> summaries, {
  String? nextPageToken,
}) {
  return calendar.Events(
    items:
        summaries.map((summary) => calendar.Event(summary: summary)).toList(),
    nextPageToken: nextPageToken,
  );
}

void main() {
  test('reads two pages and requests each page with maxResults 250', () async {
    final requestedTokens = <String?>[];

    final result = await paginateGoogleCalendarEvents(
      fetchPage: ({pageToken, required maxResults}) async {
        expect(maxResults, 250);
        requestedTokens.add(pageToken);
        if (pageToken == null) {
          return _events(['first'], nextPageToken: 'page-2');
        }
        return _events(['second']);
      },
    );

    expect(result.isTruncated, isFalse);
    expect(result.events.map((event) => event.summary), ['first', 'second']);
    expect(requestedTokens, [null, 'page-2']);
  });

  test('stops immediately when the API repeats a page token', () async {
    final requestedTokens = <String?>[];

    final result = await paginateGoogleCalendarEvents(
      fetchPage: ({pageToken, required maxResults}) async {
        requestedTokens.add(pageToken);
        if (pageToken == null) {
          return _events(['first'], nextPageToken: 'same-token');
        }
        return _events(['second'], nextPageToken: 'same-token');
      },
    );

    expect(
      result.truncationReason,
      GoogleCalendarPaginationTruncationReason.repeatedPageToken,
    );
    expect(result.events.map((event) => event.summary), ['first', 'second']);
    expect(requestedTokens, [null, 'same-token']);
  });

  test('reports truncation when the page limit is reached', () async {
    final requestedTokens = <String?>[];

    final result = await paginateGoogleCalendarEvents(
      maxPages: 2,
      fetchPage: ({pageToken, required maxResults}) async {
        requestedTokens.add(pageToken);
        return _events(
          ['page-${requestedTokens.length}'],
          nextPageToken: 'page-${requestedTokens.length + 1}',
        );
      },
    );

    expect(
      result.truncationReason,
      GoogleCalendarPaginationTruncationReason.maxPages,
    );
    expect(result.events, hasLength(2));
    expect(requestedTokens, [null, 'page-2']);
  });

  test('reports truncation when the cumulative event limit is reached',
      () async {
    var calls = 0;

    final result = await paginateGoogleCalendarEvents(
      maxEvents: 2,
      fetchPage: ({pageToken, required maxResults}) async {
        calls++;
        return _events(['first', 'second'], nextPageToken: 'page-2');
      },
    );

    expect(
      result.truncationReason,
      GoogleCalendarPaginationTruncationReason.maxEvents,
    );
    expect(result.events, hasLength(2));
    expect(calls, 1);
  });
}
