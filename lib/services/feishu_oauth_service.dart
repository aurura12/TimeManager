import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/diary_kind.dart';
import '../models/feishu_calendar_models.dart';
import 'contents_api_common.dart';
import 'feishu_calendar_constants.dart';
import 'feishu_calendar_log.dart';
import 'feishu_calendar_planner.dart';
import 'feishu_credentials_store.dart';

/// 飞书 OAuth：授权、换 token、刷新 token。
///
/// 授权走「拉起浏览器 + 本机回环收 code」，收不到时由设置页的粘贴回调兜底。
class FeishuOAuthService {
  FeishuOAuthService({http.Client? client}) : _client = client;

  final http.Client? _client;

  /// 同一个 refresh_token 只能用一次，并发刷新必须共享同一个 Future。
  static final Map<DiaryKind, Future<FeishuTokenSet?>> _refreshInFlight = {};

  /// 发起授权：登记 pending、尽量起回环服务器，返回授权链接。
  Future<FeishuAuthFlow> beginAuthorization({
    required DiaryKind kind,
    required FeishuCredentials credentials,
  }) async {
    final state = _randomState();
    final verifier = generateFeishuCodeVerifier();
    await FeishuCredentialStore.savePendingAuth(
      kind,
      FeishuPendingAuth(
        state: state,
        codeVerifier: verifier,
        createdAt: DateTime.now(),
      ),
    );

    HttpServer? server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        FeishuCalendarConfig.redirectPort,
      );
    } on SocketException catch (e) {
      // 端口被占或沙箱不允许监听：不阻断授权，用户可粘贴回调链接。
      feishuLogWarning('飞书授权回环端口不可用，改用粘贴回调', error: e);
      server = null;
    }

    final authUri = buildFeishuAuthorizeUri(
      appId: credentials.appId,
      state: state,
      codeChallenge: feishuCodeChallenge(verifier),
    );

    return FeishuAuthFlow._(
      service: this,
      kind: kind,
      credentials: credentials,
      state: state,
      codeVerifier: verifier,
      authUri: authUri,
      server: server,
    );
  }

  /// 拿一个可用令牌；快过期时自动刷新。
  Future<FeishuTokenSet?> ensureAccessToken(DiaryKind kind) async {
    final tokens = await FeishuCredentialStore.loadTokens(kind);
    if (tokens == null) return null;
    if (tokens.isRefreshExpired(DateTime.now())) {
      feishuLogWarning('飞书刷新令牌已过期，需要重新授权');
      await FeishuCredentialStore.clearTokens(kind);
      await FeishuCredentialStore.saveNeedsReauth(kind, true);
      return null;
    }
    if (!tokens.isAccessExpired(DateTime.now())) return tokens;
    return refreshAccessToken(kind);
  }

  Future<FeishuTokenSet?> refreshAccessToken(DiaryKind kind) {
    final inFlight = _refreshInFlight[kind];
    if (inFlight != null) return inFlight;
    final future =
        _doRefresh(kind).whenComplete(() => _refreshInFlight.remove(kind));
    _refreshInFlight[kind] = future;
    return future;
  }

  Future<FeishuTokenSet?> _doRefresh(DiaryKind kind) async {
    final credentials = await FeishuCredentialStore.loadCredentials(kind);
    final tokens = await FeishuCredentialStore.loadTokens(kind);
    if (credentials == null || tokens == null || !tokens.hasRefreshToken) {
      await FeishuCredentialStore.saveNeedsReauth(kind, true);
      return null;
    }
    final result = await _requestToken(
      kind: kind,
      credentials: credentials,
      body: {
        'grant_type': 'refresh_token',
        'client_id': credentials.appId,
        'client_secret': credentials.appSecret,
        'refresh_token': tokens.refreshToken!,
      },
    );
    final refreshed = result.tokens;
    if (refreshed == null) {
      feishuLogWarning('飞书令牌刷新失败：${result.error ?? '未知错误'}');
      await FeishuCredentialStore.clearTokens(kind);
      await FeishuCredentialStore.saveNeedsReauth(kind, true);
      return null;
    }
    await FeishuCredentialStore.saveTokens(
      kind,
      refreshed.hasRefreshToken
          ? refreshed
          : FeishuTokenSet(
              accessToken: refreshed.accessToken,
              accessExpiresAt: refreshed.accessExpiresAt,
              refreshToken: tokens.refreshToken,
              refreshExpiresAt: tokens.refreshExpiresAt,
              scope: refreshed.scope ?? tokens.scope,
            ),
    );
    await FeishuCredentialStore.saveNeedsReauth(kind, false);
    feishuLog('飞书令牌已刷新');
    return refreshed;
  }

  Future<_TokenResult> _exchangeAuthorizationCode({
    required DiaryKind kind,
    required FeishuCredentials credentials,
    required String code,
    required String codeVerifier,
  }) {
    return _requestToken(
      kind: kind,
      credentials: credentials,
      body: {
        'grant_type': 'authorization_code',
        'client_id': credentials.appId,
        'client_secret': credentials.appSecret,
        'code': code,
        'redirect_uri': FeishuCalendarConfig.redirectUri,
        'code_verifier': codeVerifier,
      },
    );
  }

  Future<_TokenResult> _requestToken({
    required DiaryKind kind,
    required FeishuCredentials credentials,
    required Map<String, String> body,
  }) async {
    final client = _client ?? http.Client();
    try {
      final response = await requestWithRetry(
        () => client.post(
          Uri.parse(FeishuCalendarConfig.tokenV3Url),
          headers: const {
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: body,
        ),
      );
      if (response.statusCode == 404 || response.statusCode == 405) {
        return await _requestTokenV2(client: client, body: body);
      }
      return _parseTokenResponse(response.body);
    } catch (e, stackTrace) {
      feishuLogError('飞书换取令牌失败', error: e, stackTrace: stackTrace);
      return _TokenResult.failed('网络错误，请稍后重试');
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<_TokenResult> _requestTokenV2({
    required http.Client client,
    required Map<String, String> body,
  }) async {
    final response = await requestWithRetry(
      () => client.post(
        Uri.parse(FeishuCalendarConfig.tokenV2Url),
        headers: const {
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode(body),
      ),
    );
    return _parseTokenResponse(response.body);
  }

  _TokenResult _parseTokenResponse(String body) {
    Map<String, dynamic> decoded;
    try {
      final raw = jsonDecode(body);
      if (raw is! Map<String, dynamic>) {
        return _TokenResult.failed('飞书返回了无法识别的数据');
      }
      decoded = raw;
    } catch (_) {
      return _TokenResult.failed('飞书返回了无法识别的数据');
    }

    final payload = decoded['data'] is Map<String, dynamic>
        ? decoded['data'] as Map<String, dynamic>
        : decoded;
    final accessToken = _stringOf(payload, 'access_token', 'accessToken');
    if (accessToken == null || accessToken.isEmpty) {
      final error = _stringOf(payload, 'error', 'error') ??
          _stringOf(decoded, 'error', 'error');
      final description = _stringOf(
            payload,
            'error_description',
            'errorDescription',
          ) ??
          _stringOf(decoded, 'error_description', 'errorDescription') ??
          _stringOf(decoded, 'msg', 'message');
      return _TokenResult.failed(description ?? error ?? '授权失败');
    }

    final now = DateTime.now();
    final expiresIn = int.tryParse(
          _stringOf(payload, 'expires_in', 'expiresIn') ?? '',
        ) ??
        7200;
    final refreshExpiresIn = int.tryParse(
      _stringOf(payload, 'refresh_token_expires_in', 'refreshTokenExpiresIn') ??
          '',
    );
    final refreshToken = _stringOf(payload, 'refresh_token', 'refreshToken');
    return _TokenResult.ok(FeishuTokenSet(
      accessToken: accessToken,
      accessExpiresAt: now.add(Duration(seconds: expiresIn)),
      refreshToken: refreshToken,
      refreshExpiresAt: refreshExpiresIn == null
          ? null
          : now.add(Duration(seconds: refreshExpiresIn)),
      scope: _stringOf(payload, 'scope', 'scope'),
    ));
  }

  static String? _stringOf(
      Map<String, dynamic> json, String snake, String camel) {
    final value = json[snake] ?? json[camel];
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static String _randomState() {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = DateTime.now().microsecondsSinceEpoch;
    final buffer = StringBuffer();
    var seed = random;
    for (var i = 0; i < 32; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      buffer.write(alphabet[seed % alphabet.length]);
    }
    return buffer.toString();
  }
}

class _TokenResult {
  const _TokenResult._({this.tokens, this.error});

  const _TokenResult.ok(FeishuTokenSet tokens) : this._(tokens: tokens);

  const _TokenResult.failed(String message) : this._(error: message);

  final FeishuTokenSet? tokens;
  final String? error;
}

/// 一次进行中的授权：等回环回调，或接受用户粘贴的回调链接。
class FeishuAuthFlow {
  FeishuAuthFlow._({
    required this.service,
    required this.kind,
    required this.credentials,
    required this.state,
    required this.codeVerifier,
    required this.authUri,
    HttpServer? server,
  }) : _server = server {
    _attachServer();
    _timeoutTimer = Timer(FeishuCalendarConfig.authTimeout, () {
      unawaited(_finish(
        const FeishuAuthResult.failed('授权超时，请重新发起'),
      ));
    });
  }

  final FeishuOAuthService service;
  final DiaryKind kind;
  final FeishuCredentials credentials;
  final String state;
  final String codeVerifier;
  final Uri authUri;

  final Completer<FeishuAuthResult> _completer = Completer<FeishuAuthResult>();
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  Timer? _timeoutTimer;

  Future<FeishuAuthResult> get result => _completer.future;

  Future<void> cancel() async {
    await _finish(const FeishuAuthResult.failed('已取消授权'));
  }

  /// 用户从浏览器地址栏粘贴整条回调链接，或只粘 code。
  Future<FeishuAuthResult> submitCallbackText(String text) async {
    if (_completer.isCompleted) return _completer.future;
    final callback = parseFeishuAuthCallback(text);
    if ((callback.error ?? '').isNotEmpty) {
      return _finish(FeishuAuthResult.failed(
        callback.description ?? '授权被拒绝（${callback.error}）',
      ));
    }
    if ((callback.code ?? '').isEmpty) {
      return _finish(const FeishuAuthResult.failed('没有找到授权码'));
    }
    if ((callback.state ?? '').isNotEmpty && callback.state != state) {
      return _finish(const FeishuAuthResult.failed('授权状态不匹配，请重新授权'));
    }

    final result = await service._exchangeAuthorizationCode(
      kind: kind,
      credentials: credentials,
      code: callback.code!,
      codeVerifier: codeVerifier,
    );
    final tokens = result.tokens;
    if (tokens == null) {
      return _finish(FeishuAuthResult.failed(result.error ?? '授权失败'));
    }
    await FeishuCredentialStore.saveTokens(kind, tokens);
    await FeishuCredentialStore.clearPendingAuth(kind);
    await FeishuCredentialStore.saveNeedsReauth(kind, false);
    feishuLog('飞书授权成功（${kind.code}）');
    return _finish(const FeishuAuthResult.ok());
  }

  void _attachServer() {
    final server = _server;
    if (server == null) return;
    _subscription = server.listen((request) async {
      if (request.uri.path != FeishuCalendarConfig.redirectPath) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_resultPage);
      await request.response.close();
      unawaited(submitCallbackText(request.uri.toString()));
    }, onError: (Object error, StackTrace stackTrace) {
      feishuLogWarning('飞书授权回环监听出错', error: error, stackTrace: stackTrace);
    });
  }

  Future<FeishuAuthResult> _finish(FeishuAuthResult result) async {
    if (!_completer.isCompleted) _completer.complete(result);
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _server?.close(force: true);
    _server = null;
    return result;
  }

  static const String _resultPage = '''
<!doctype html><html><head><meta charset="utf-8"><title>授权完成</title></head>
<body style="font-family:sans-serif;text-align:center;margin-top:20vh">
<h2>授权完成</h2><p>可以关闭这个页面，回到「时间块」。</p>
</body></html>
''';
}
