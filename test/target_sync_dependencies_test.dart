import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/services/target_gitee_service.dart';
import 'package:time_manager/services/target_sync_dependencies.dart';

void main() {
  test('目标 Gitee 路径按身份隔离', () {
    expect(TargetGiteeService.targetPath('j'), 'targets/j.json');
    expect(TargetGiteeService.targetPath('g'), 'targets/g.json');
  });

  test('依赖容器转发注入的 Token、拉取和推送回调', () async {
    String? pulledToken;
    String? pulledUserCode;
    String? pushedToken;
    String? pushedUserCode;
    String? pushedContent;
    String? pushedCommitMessage;

    final dependencies = TargetSyncDependencies(
      loadToken: () async => 'token',
      pullTargets: ({required token, required userCode}) async {
        pulledToken = token;
        pulledUserCode = userCode;
        return TargetGiteePullResult.notFound();
      },
      pushTargets: ({
        required token,
        required userCode,
        required content,
        required commitMessage,
      }) async {
        pushedToken = token;
        pushedUserCode = userCode;
        pushedContent = content;
        pushedCommitMessage = commitMessage;
        return TargetGiteePushResult.success(created: true);
      },
    );

    expect(await dependencies.loadToken(), 'token');
    final pullResult = await dependencies.pullTargets(
      token: 'pull-token',
      userCode: 'j',
    );
    final pushResult = await dependencies.pushTargets(
      token: 'push-token',
      userCode: 'g',
      content: '{}',
      commitMessage: 'targets(g): sync',
    );

    expect(pullResult.notFound, isTrue);
    expect(pulledToken, 'pull-token');
    expect(pulledUserCode, 'j');
    expect(pushResult.success, isTrue);
    expect(pushedToken, 'push-token');
    expect(pushedUserCode, 'g');
    expect(pushedContent, '{}');
    expect(pushedCommitMessage, 'targets(g): sync');
  });
}
