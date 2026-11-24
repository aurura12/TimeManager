import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/diary_kind.dart';
import 'package:time_manager/models/feishu_calendar_models.dart';
import 'package:time_manager/services/feishu_auth_sync.dart';
import 'package:time_manager/services/feishu_credentials_store.dart';
import 'package:time_manager/services/feishu_oauth_service.dart';

class _FakeAuthSync extends FeishuAuthSync {
  _FakeAuthSync(this.remote);

  FeishuAuthPullResult remote;
  int pullCount = 0;
  final List<FeishuRemoteAuth> pushed = [];

  @override
  Future<FeishuAuthPullResult> pull(DiaryKind kind) async {
    pullCount++;
    return remote;
  }

  @override
  Future<bool> push(
    DiaryKind kind,
    FeishuRemoteAuth auth, {
    String? expectedSha,
    bool expectNotFound = false,
  }) async {
    pushed.add(auth);
    return true;
  }

  @override
  Future<void> revoke(DiaryKind kind) async {}
}

const kind = DiaryKind.g;

FeishuTokenSet tokenSet({
  required String access,
  required Duration accessIn,
  String? refresh,
  Duration? refreshIn,
}) {
  final now = DateTime.now();
  return FeishuTokenSet(
    accessToken: access,
    accessExpiresAt: now.add(accessIn),
    refreshToken: refresh,
    refreshExpiresAt: refreshIn == null ? null : now.add(refreshIn),
  );
}

FeishuRemoteAuth remoteAuth(FeishuTokenSet tokens) {
  return FeishuRemoteAuth(
    updatedAt: DateTime.now(),
    credentials: const FeishuCredentials(appId: 'cli_x', appSecret: 'secret'),
    tokens: tokens,
  );
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    FeishuOAuthService.resetRefreshStateForTesting();
  });

  test('本地没有授权时采用另一台设备的令牌，不再走浏览器', () async {
    final remote = remoteAuth(tokenSet(
      access: 'remote-access',
      accessIn: const Duration(hours: 1),
      refresh: 'remote-refresh',
      refreshIn: const Duration(days: 20),
    ));
    final fake = _FakeAuthSync(FeishuAuthPullResult(auth: remote));
    final service = FeishuOAuthService(authSync: fake);

    final result = await service.ensureAccessToken(kind);

    expect(result.tokens?.accessToken, 'remote-access');
    expect(fake.pullCount, 1);
    final stored = await FeishuCredentialStore.loadTokens(kind);
    expect(stored?.accessToken, 'remote-access');
    final credentials = await FeishuCredentialStore.loadCredentials(kind);
    expect(credentials?.appId, 'cli_x');
  });

  test('本地令牌还有效时不访问同步仓库', () async {
    await FeishuCredentialStore.saveTokens(
      kind,
      tokenSet(
        access: 'local-access',
        accessIn: const Duration(hours: 1),
        refresh: 'local-refresh',
        refreshIn: const Duration(days: 20),
      ),
    );
    final fake = _FakeAuthSync(const FeishuAuthPullResult(notFound: true));
    final service = FeishuOAuthService(authSync: fake);

    final result = await service.ensureAccessToken(kind);

    expect(result.tokens?.accessToken, 'local-access');
    expect(fake.pullCount, 0);
  });

  test('本地过期但另一台已刷新过，直接采用远端的', () async {
    await FeishuCredentialStore.saveTokens(
      kind,
      tokenSet(
        access: 'stale-access',
        accessIn: const Duration(hours: -3),
        refresh: 'stale-refresh',
        refreshIn: const Duration(days: 20),
      ),
    );
    final remote = remoteAuth(tokenSet(
      access: 'fresh-access',
      accessIn: const Duration(minutes: 90),
      refresh: 'fresh-refresh',
      refreshIn: const Duration(days: 25),
    ));
    final fake = _FakeAuthSync(FeishuAuthPullResult(auth: remote));
    // 这个 client 一旦被调用就说明又多刷了一次，直接失败。
    final client = MockClient((request) async {
      throw StateError('不应发起刷新请求');
    });
    addTearDown(client.close);
    final service = FeishuOAuthService(client: client, authSync: fake);

    final result = await service.ensureAccessToken(kind);

    expect(result.tokens?.accessToken, 'fresh-access');
    expect(fake.pushed, isEmpty);
  });

  test('两端都过期时自己刷新，并把新令牌写回仓库', () async {
    await FeishuCredentialStore.saveCredentials(
      kind,
      const FeishuCredentials(appId: 'cli_x', appSecret: 'secret'),
    );
    await FeishuCredentialStore.saveTokens(
      kind,
      tokenSet(
        access: 'stale-access',
        accessIn: const Duration(hours: -3),
        refresh: 'stale-refresh',
        refreshIn: const Duration(days: 20),
      ),
    );
    final fake = _FakeAuthSync(const FeishuAuthPullResult(notFound: true));
    final client = MockClient((request) async {
      final body = Uri.splitQueryString(request.body);
      expect(body['grant_type'], 'refresh_token');
      expect(body['refresh_token'], 'stale-refresh');
      return http.Response(
        jsonEncode({
          'access_token': 'new-access',
          'expires_in': 7200,
          'refresh_token': 'new-refresh',
          'refresh_token_expires_in': 2592000,
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    addTearDown(client.close);
    final service = FeishuOAuthService(client: client, authSync: fake);

    final result = await service.ensureAccessToken(kind);
    expect(result.tokens?.accessToken, 'new-access');
    expect(fake.pushed.single.tokens?.refreshToken, 'new-refresh');
    final stored = await FeishuCredentialStore.loadTokens(kind);
    expect(stored?.refreshToken, 'new-refresh');
  });

  test('刷新失败但另一台刚好刷新成功时，采用对方的令牌而不是要求重新授权', () async {
    await FeishuCredentialStore.saveCredentials(
      kind,
      const FeishuCredentials(appId: 'cli_x', appSecret: 'secret'),
    );
    await FeishuCredentialStore.saveTokens(
      kind,
      tokenSet(
        access: 'stale-access',
        accessIn: const Duration(hours: -3),
        refresh: 'consumed-refresh',
        refreshIn: const Duration(days: 20),
      ),
    );

    // 第一次读远端：文件还不存在；刷新失败后再读：对方已经写好了新令牌。
    var pulls = 0;
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({'error': 'invalid_grant', 'error_description': 'expired'}),
        400,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    addTearDown(client.close);

    // 用包装类替换 fake 的返回，模拟第二次读取拿到新授权。
    final remote = remoteAuth(tokenSet(
      access: 'other-device-access',
      accessIn: const Duration(hours: 1),
      refresh: 'other-device-refresh',
      refreshIn: const Duration(days: 20),
    ));
    final service2 = _SecondPullAuthSync(remote, (kind) {
      pulls++;
      return pulls;
    });
    final result = await FeishuOAuthService(client: client, authSync: service2)
        .ensureAccessToken(kind);

    expect(result.tokens?.accessToken, 'other-device-access');
    final stored = await FeishuCredentialStore.loadTokens(kind);
    expect(stored?.accessToken, 'other-device-access');
    expect(await FeishuCredentialStore.loadNeedsReauth(kind), isFalse);
  });

  test('刷新时网络失败不清空本地令牌，也不要求重新授权', () async {
    await FeishuCredentialStore.saveCredentials(
      kind,
      const FeishuCredentials(appId: 'cli_x', appSecret: 'secret'),
    );
    await FeishuCredentialStore.saveTokens(
      kind,
      tokenSet(
        access: 'stale-access',
        accessIn: const Duration(hours: -3),
        refresh: 'still-good-refresh',
        refreshIn: const Duration(days: 20),
      ),
    );
    // 网络层直接抛错：走的是「暂时失败」而不是「授权失效」。
    final client = MockClient((request) async {
      throw http.RequestAbortedException(request.url);
    });
    addTearDown(client.close);
    final fake = _FakeAuthSync(const FeishuAuthPullResult(notFound: true));
    final service = FeishuOAuthService(client: client, authSync: fake);

    final result = await service.ensureAccessToken(kind);

    expect(result.tokens, isNull);
    expect(result.needReauth, isFalse);
    expect(result.error, isNotNull);
    final stored = await FeishuCredentialStore.loadTokens(kind);
    expect(stored?.refreshToken, 'still-good-refresh');
    expect(await FeishuCredentialStore.loadNeedsReauth(kind), isFalse);
  });

  test('服务端 5xx 视为暂时失败，不清空令牌', () async {
    await FeishuCredentialStore.saveCredentials(
      kind,
      const FeishuCredentials(appId: 'cli_x', appSecret: 'secret'),
    );
    await FeishuCredentialStore.saveTokens(
      kind,
      tokenSet(
        access: 'stale-access',
        accessIn: const Duration(hours: -3),
        refresh: 'still-good-refresh',
        refreshIn: const Duration(days: 20),
      ),
    );
    final client = MockClient((request) async => http.Response('busy', 503));
    addTearDown(client.close);
    final fake = _FakeAuthSync(const FeishuAuthPullResult(notFound: true));

    final result = await FeishuOAuthService(client: client, authSync: fake)
        .ensureAccessToken(kind);

    expect(result.tokens, isNull);
    expect(result.needReauth, isFalse);
    final stored = await FeishuCredentialStore.loadTokens(kind);
    expect(stored?.refreshToken, 'still-good-refresh');
  });
}

/// 第一次返回 notFound，之后返回对方刷新好的令牌。
class _SecondPullAuthSync extends FeishuAuthSync {
  _SecondPullAuthSync(this.remote, this.counter);

  final FeishuRemoteAuth remote;
  final int Function(DiaryKind kind) counter;
  int _pulls = 0;

  @override
  Future<FeishuAuthPullResult> pull(DiaryKind kind) async {
    _pulls++;
    return _pulls == 1
        ? const FeishuAuthPullResult(notFound: true)
        : FeishuAuthPullResult(auth: remote);
  }

  @override
  Future<bool> push(
    DiaryKind kind,
    FeishuRemoteAuth auth, {
    String? expectedSha,
    bool expectNotFound = false,
  }) async =>
      true;
}
