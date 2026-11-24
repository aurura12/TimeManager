import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../models/feishu_calendar_models.dart';
import '../models/time_slot.dart';
import 'feishu_calendar_constants.dart';

/// 一天有 144 个 10 分钟槽位。
const int feishuSlotsPerDay = 144;

/// 把一天的槽位合并成「连续同标签」的日程草稿。
///
/// 与 Google 日历同步的口径保持一致：跳过外部日历导入的槽位、空标签槽位
/// 和已删除的墓碑槽位；跨越 24:00 的块结束时间自然落到次日 00:00。
List<FeishuEventDraft> mergeSlotsToEvents(List<TimeSlot> slots, DateTime date) {
  final dayStart = DateTime(date.year, date.month, date.day);
  final drafts = <FeishuEventDraft>[];
  var index = 0;
  while (index < slots.length) {
    final slot = slots[index];
    final label = slot.label?.trim() ?? '';
    if (!slot.recorded ||
        slot.isFromCalendar ||
        slot.deletedAt != null ||
        label.isEmpty) {
      index++;
      continue;
    }
    final startIndex = index;
    while (index < slots.length) {
      final next = slots[index];
      final nextLabel = next.label?.trim() ?? '';
      if (!next.recorded ||
          next.isFromCalendar ||
          next.deletedAt != null ||
          nextLabel != label) {
        break;
      }
      index++;
    }
    final endIndex = index;
    drafts.add(FeishuEventDraft(
      summary: label,
      start: _slotStart(dayStart, startIndex),
      end: _slotStart(dayStart, endIndex),
    ));
  }
  return drafts;
}

DateTime _slotStart(DateTime dayStart, int slotIndex) {
  final hour = slotIndex ~/ 6;
  final minute = (slotIndex % 6) * 10;
  return DateTime(dayStart.year, dayStart.month, dayStart.day, hour, minute);
}

/// 按 (标题, 开始, 结束) 做精确差集。
///
/// [remoteTruncated] 为真表示这次没把当天事件读全（飞书列表接口不支持分页），
/// 此时不删也不建，交给下一次重试，避免把没看到的事件当成孤儿删掉。
FeishuDayDiff diffFeishuDayEvents({
  required List<FeishuEventDraft> local,
  required List<FeishuRemoteEvent> remote,
  required bool remoteTruncated,
}) {
  if (remoteTruncated) return const FeishuDayDiff.empty();

  final unmatched = List<FeishuRemoteEvent>.of(remote);
  final toCreate = <FeishuEventDraft>[];
  for (final draft in local) {
    final matched = unmatched.indexWhere(
      (event) =>
          event.summary == draft.summary &&
          event.startSeconds == draft.startSeconds &&
          event.endSeconds == draft.endSeconds,
    );
    if (matched >= 0) {
      unmatched.removeAt(matched);
    } else {
      toCreate.add(draft);
    }
  }
  return FeishuDayDiff(toCreate: toCreate, toDelete: unmatched);
}

/// 组装创建日程的请求体。
Map<String, dynamic> buildFeishuEventBody(
  FeishuEventDraft draft, {
  required String timezone,
}) {
  final summary = draft.summary.length > 200
      ? draft.summary.substring(0, 200)
      : draft.summary;
  return {
    'summary': summary,
    'description': FeishuCalendarConfig.eventMarker,
    'start_time': {
      'timestamp': '${draft.startSeconds}',
      'timezone': timezone,
    },
    'end_time': {
      'timestamp': '${draft.endSeconds}',
      'timezone': timezone,
    },
  };
}

/// 解析事件列表里的一条事件；不是本 App 创建的、已取消的、时间不完整的一律忽略。
FeishuRemoteEvent? parseFeishuRemoteEvent(Map<String, dynamic> json) {
  if ((json['description'] ?? '').toString() !=
      FeishuCalendarConfig.eventMarker) {
    return null;
  }
  if ((json['status'] ?? '').toString() == 'cancelled') return null;
  final eventId = (json['event_id'] ?? '').toString();
  if (eventId.isEmpty) return null;
  final startSeconds = _timeInfoSeconds(json['start_time']);
  final endSeconds = _timeInfoSeconds(json['end_time']);
  if (startSeconds == null || endSeconds == null) return null;
  return FeishuRemoteEvent(
    eventId: eventId,
    summary: (json['summary'] ?? '').toString(),
    startSeconds: startSeconds,
    endSeconds: endSeconds,
  );
}

int? _timeInfoSeconds(Object? value) {
  if (value is! Map) return null;
  final timestamp = value['timestamp'];
  if (timestamp != null) {
    final parsed = int.tryParse(timestamp.toString());
    if (parsed != null) return parsed;
  }
  final dateTime = value['date_time']?.toString();
  if (dateTime == null || dateTime.isEmpty) return null;
  final parsed = DateTime.tryParse(dateTime);
  if (parsed == null) return null;
  return parsed.millisecondsSinceEpoch ~/ 1000;
}

/// 拼授权链接。redirect_uri 必须与飞书后台登记值完全一致。
/// [codeChallenge] 为空时不带 PKCE：自带 App Secret 的应用不需要它，
/// 带了反而会因为旧链接的 verifier 不匹配报 "PKCE code challenge failed"。
Uri buildFeishuAuthorizeUri({
  required String appId,
  required String state,
  String? codeChallenge,
  String redirectUri = '',
  String scopes = FeishuCalendarConfig.scopes,
}) {
  final hasChallenge = (codeChallenge ?? '').isNotEmpty;
  return Uri.parse(FeishuCalendarConfig.authorizeUrl).replace(
    queryParameters: {
      'client_id': appId,
      'response_type': 'code',
      'redirect_uri':
          redirectUri.isEmpty ? FeishuCalendarConfig.redirectUri : redirectUri,
      'scope': scopes,
      'state': state,
      if (hasChallenge) 'code_challenge': codeChallenge!,
      if (hasChallenge) 'code_challenge_method': 'S256',
    },
  );
}

/// 解析回调：支持整条回调 URL、只有 query 的片段，或直接粘一个 code。
FeishuAuthCallback parseFeishuAuthCallback(String input) {
  final text = input.trim();
  if (text.isEmpty) return const FeishuAuthCallback();
  if (text.startsWith('http') &&
      !text.contains('code=') &&
      !text.contains('error=')) {
    return const FeishuAuthCallback(
      error: 'invalid_input',
      description: '回调链接里没有授权码',
    );
  }

  Uri? uri;
  if (text.contains('code=') || text.contains('error=')) {
    uri = Uri.tryParse(text);
    if (uri == null || uri.queryParameters.isEmpty) {
      uri = Uri.tryParse('http://127.0.0.1/?$text');
    }
  }
  if (uri != null && uri.queryParameters.isNotEmpty) {
    final params = uri.queryParameters;
    return FeishuAuthCallback(
      code: params['code'],
      state: params['state'],
      error: params['error'],
      description: params['error_description'],
    );
  }
  return FeishuAuthCallback(code: text);
}

/// 生成 PKCE verifier（43~128 位，字符集限定）。
String generateFeishuCodeVerifier([Random? random]) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final source = random ?? Random.secure();
  return List.generate(64, (_) => alphabet[source.nextInt(alphabet.length)])
      .join();
}

/// PKCE S256 challenge：base64url(sha256(verifier))，去掉 padding。
String feishuCodeChallenge(String verifier) {
  final digest = sha256.convert(utf8.encode(verifier));
  return base64UrlEncode(digest.bytes).replaceAll('=', '');
}
