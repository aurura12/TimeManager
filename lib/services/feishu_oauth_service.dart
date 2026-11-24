import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/diary_kind.dart';
import '../models/feishu_calendar_models.dart';
import 'contents_api_common.dart';
import 'feishu_calendar_constants.dart';
import 'feishu_calendar_log.dart';
import 'feishu_auth_sync.dart';
import 'feishu_calendar_planner.dart';
import 'feishu_credentials_store.dart';

/// 飞书 OAuth：授权、换 token、刷新 token。
///
/// 授权走「拉起浏览器 + 本机回环收 code」，收不到时由设置页的粘贴回调兜底。
class FeishuOAuthService {
  FeishuOAuthService({http.Client? client, FeishuAuthSync? authSync})
      : _client = client,
        _authSync = authSync ?? FeishuAuthSync();

  final http.Client? _client;
  final FeishuAuthSync _authSync;

  /// 同一个 refresh_token 只能用一次，并发刷新必须共享同一个 Future。
  static final Map<DiaryKind, Future<FeishuTokenResult>> _refreshInFlight = {};

  @visibleForTesting
  static void resetRefreshStateForTesting() => _refreshInFlight.clear();

  /// 发起授权：登记 pending、尽量起回环服务器，返回授权链接。
  Future<FeishuAuthFlow> beginAuthorization({
    required DiaryKind kind,
    required FeishuCredentials credentials,
  }) async {
    final state = _randomState();
    await FeishuCredentialStore.savePendingAuth(
      kind,
      FeishuPendingAuth(
        state: state,
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
    );

    return FeishuAuthFlow._(
      service: this,
      kind: kind,
      credentials: credentials,
      state: state,
      codeVerifier: '',
      authUri: authUri,
      server: server,
    );
  }

  /// App 被杀后重新打开时，用本地 pending 恢复未完成的授权（只走粘贴）。
  Future<FeishuAuthFlow?> resumePendingAuthorization({
    required DiaryKind kind,
  }) async {
    final pending = await FeishuCredentialStore.loadPendingAuth(kind);
    final credentials = await FeishuCredentialStore.loadCredentials(kind);
    if (pending == null || credentials == null) return null;
    if (DateTime.now().difference(pending.createdAt) >
        FeishuCalendarConfig.authTimeout) {
      await FeishuCredentialStore.clearPendingAuth(kind);
      return null;
    }
    return FeishuAuthFlow._(
      service: this,
      kind: kind,
      credentials: credentials,
      state: pending.state,
      codeVerifier: pending.codeVerifier,
      authUri: buildFeishuAuthorizeUri(
        appId: credentials.appId,
        state: pending.state,
      ),
      server: null,
    );
  }

  /// 拿一个可用令牌；本地过期时先看别的设备是否刚刷新过，再自己刷。
  Future<FeishuTokenResult> ensureAccessToken(DiaryKind kind) async {
    final now = DateTime.now();
    final local = await FeishuCredentialStore.loadTokens(kind);
    if (local != null &&
        !local.isAccessExpired(now) &&
        !local.isRefreshExpired(now)) {
      return FeishuTokenResult.ok(local);
    }

    final remote = await _authSync.pull(kind);
    final remoteAuth = remote.auth;
    final remoteTokens = remoteAuth?.tokens;
    if (remoteTokens != null &&
        !remoteTokens.isAccessExpired(now) &&
        !remoteTokens.isRefreshExpired(now)) {
      await _adoptRemote(kind, remoteAuth!);
      return FeishuTokenResult.ok(remoteTokens);
    }

    if (local == null && remoteTokens == null) {
      if (remoteAuth != null && remoteAuth.revoked) {
        await FeishuCredentialStore.clearTokens(kind);
        return const FeishuTokenResult.needReauth('飞书授权已失效，请重新授权');
      }
      // 读远端失败不代表授权失效：本地没令牌只是这次查不到，让调用方稍后重试。
      if (remote.error != null) {
        return const FeishuTokenResult.transient('网络异常，飞书日程稍后自动重试');
      }
      return const FeishuTokenResult.needReauth('飞书授权已失效，请重新授权');
    }
    return refreshAccessToken(kind, prefetched: remote);
  }

  Future<FeishuTokenResult> refreshAccessToken(
    DiaryKind kind, {
    FeishuAuthPullResult? prefetched,
  }) {
    final inFlight = _refreshInFlight[kind];
    if (inFlight != null) return inFlight;
    final future = _doRefresh(kind, prefetched);
    _refreshInFlight[kind] = future;
    // 注意：whenComplete 的回调如果返回 Future 会等它完成，而 remove 正好返回
    // 这个 Future 本身，写成箭头函数会自锁。用块体并忽略派生 future。
    future.whenComplete(() {
      _refreshInFlight.remove(kind);
    }).ignore();
    return future;
  }

  Future<FeishuTokenResult> _doRefresh(
    DiaryKind kind,
    FeishuAuthPullResult? prefetched,
  ) async {
    final now = DateTime.now();
    final pull = prefetched ?? await _authSync.pull(kind);
    final remoteAuth = pull.auth;
    final remoteTokens = remoteAuth?.tokens;
    if (remoteTokens != null &&
        !remoteTokens.isAccessExpired(now) &&
        !remoteTokens.isRefreshExpired(now)) {
      await _adoptRemote(kind, remoteAuth!);
      return FeishuTokenResult.ok(remoteTokens);
    }

    final credentials = remoteAuth?.credentials ??
        await FeishuCredentialStore.loadCredentials(kind);
    final tokens = remoteTokens ?? await FeishuCredentialStore.loadTokens(kind);
    if (credentials == null || tokens == null || !tokens.hasRefreshToken) {
      await FeishuCredentialStore.saveNeedsReauth(kind, true);
      return const FeishuTokenResult.needReauth('飞书授权已失效，请重新授权');
    }
    if (tokens.isRefreshExpired(now)) {
      feishuLogWarning('飞书刷新令牌已过期，需要重新授权');
      await FeishuCredentialStore.clearTokens(kind);
      await FeishuCredentialStore.saveNeedsReauth(kind, true);
      return const FeishuTokenResult.needReauth('飞书授权已过期，请重新授权');
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
      // 网络/服务端故障只是这一次没换成：令牌还留着，下次启动或下次同步再试。
      // 清掉令牌会让用户被无谓地要求重走浏览器授权。
      if (result.network) {
        feishuLogWarning('飞书令牌刷新暂时失败：${result.error ?? '未知错误'}');
        return FeishuTokenResult.transient(
          result.error ?? '网络异常，飞书日程稍后自动重试',
        );
      }
      // refresh_token 一次性：可能是另一台抢先刷过并把新令牌写回仓库了。
      final retry = await _authSync.pull(kind);
      final retryTokens = retry.auth?.tokens;
      if (retryTokens != null &&
          !retryTokens.isAccessExpired(now) &&
          !retryTokens.isRefreshExpired(now)) {
        await _adoptRemote(kind, retry.auth!);
        return FeishuTokenResult.ok(retryTokens);
      }
      feishuLogWarning('飞书令牌刷新失败：${result.error ?? '未知错误'}');
      await FeishuCredentialStore.clearTokens(kind);
      await FeishuCredentialStore.saveNeedsReauth(kind, true);
      return const FeishuTokenResult.needReauth('飞书授权已失效，请重新授权');
    }

    final merged = refreshed.hasRefreshToken
        ? refreshed
        : FeishuTokenSet(
            accessToken: refreshed.accessToken,
            accessExpiresAt: refreshed.accessExpiresAt,
            refreshToken: tokens.refreshToken,
            refreshExpiresAt: tokens.refreshExpiresAt,
            scope: refreshed.scope ?? tokens.scope,
          );
    await FeishuCredentialStore.saveTokens(kind, merged);
    await FeishuCredentialStore.saveNeedsReauth(kind, false);
    await _publishAuth(
      kind,
      merged,
      baseSha: pull.auth?.sha,
      expectNotFound: pull.notFound,
    );
    feishuLog('飞书令牌已刷新');
    return FeishuTokenResult.ok(merged);
  }

  /// 打开设置页时调用：本地没有可用授权就从同步仓库捞一份回来。
  Future<bool> syncFromRemote(DiaryKind kind) async {
    final pull = await _authSync.pull(kind);
    final auth = pull.auth;
    if (auth == null) return false;
    if (auth.revoked) {
      await FeishuCredentialStore.clearTokens(kind);
      return true;
    }
    if (auth.credentials != null) {
      final local = await FeishuCredentialStore.loadCredentials(kind);
      if (local == null) {
        await FeishuCredentialStore.saveCredentials(kind, auth.credentials!);
      }
    }
    final now = DateTime.now();
    final remoteTokens = auth.tokens;
    final localTokens = await FeishuCredentialStore.loadTokens(kind);
    final localUnusable =
        localTokens == null || localTokens.isAccessExpired(now);
    if (remoteTokens != null &&
        localUnusable &&
        !remoteTokens.isAccessExpired(now) &&
        !remoteTokens.isRefreshExpired(now)) {
      await _adoptRemote(kind, auth);
    }
    return true;
  }

  /// 授权成功后把令牌写进同步仓库，另一台设备直接复用。
  Future<void> publishAuthorization(DiaryKind kind) async {
    final tokens = await FeishuCredentialStore.loadTokens(kind);
    if (tokens == null) return;
    final pull = await _authSync.pull(kind);
    if (!pull.available) return;
    await _publishAuth(
      kind,
      tokens,
      baseSha: pull.auth?.sha,
      expectNotFound: pull.notFound,
    );
  }

  Future<void> _adoptRemote(DiaryKind kind, FeishuRemoteAuth auth) async {
    final credentials = auth.credentials;
    if (credentials != null) {
      await FeishuCredentialStore.saveCredentials(kind, credentials);
    }
    final tokens = auth.tokens;
    if (tokens != null) {
      await FeishuCredentialStore.saveTokens(kind, tokens);
    }
    await FeishuCredentialStore.saveNeedsReauth(kind, false);
    feishuLog('已采用同步仓库里的飞书授权（${kind.code}）');
  }

  Future<void> _publishAuth(
    DiaryKind kind,
    FeishuTokenSet tokens, {
    String? baseSha,
    bool expectNotFound = false,
  }) async {
    final credentials = await FeishuCredentialStore.loadCredentials(kind);
    if (credentials == null) return;
    await _authSync.push(
      kind,
      FeishuRemoteAuth(
        credentials: credentials,
        tokens: tokens,
        updatedAt: DateTime.now(),
      ),
      expectedSha: baseSha,
      expectNotFound: expectNotFound,
    );
  }

  Future<_TokenResult> _exchangeAuthorizationCode({
    required DiaryKind kind,
    required FeishuCredentials credentials,
    required String code,
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
      // 5xx 是服务端暂时不可用，判定为可重试的暂时失败，不能当授权失效。
      if (response.statusCode >= 500) {
        return _TokenResult.network('飞书服务暂时不可用（${response.statusCode}）');
      }
      return _parseTokenResponse(response.body);
    } catch (e, stackTrace) {
      feishuLogError('飞书换取令牌失败', error: e, stackTrace: stackTrace);
      return const _TokenResult.network('网络错误，请稍后重试');
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
  const _TokenResult._({this.tokens, this.error, this.network = false});

  const _TokenResult.ok(FeishuTokenSet tokens) : this._(tokens: tokens);

  const _TokenResult.failed(String message) : this._(error: message);

  /// 网络中断 / 超时 / 服务端 5xx：可以重试，不代表授权失效。
  const _TokenResult.network(String message)
      : this._(error: message, network: true);

  final FeishuTokenSet? tokens;
  final String? error;
  final bool network;
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
    );
    final tokens = result.tokens;
    if (tokens == null) {
      final error = result.error ?? '授权失败';
      return _finish(FeishuAuthResult.failed(
        '$error（授权码 5 分钟内有效且只能用一次，'
        '如果这条链接是之前几次尝试留下的，请重新点「保存并授权」用最新链接）',
      ));
    }
    await FeishuCredentialStore.saveTokens(kind, tokens);
    await FeishuCredentialStore.clearPendingAuth(kind);
    await FeishuCredentialStore.saveNeedsReauth(kind, false);
    feishuLog('飞书授权成功（${kind.code}）');
    await service.publishAuthorization(kind);
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
