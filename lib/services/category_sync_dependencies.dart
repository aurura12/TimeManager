import 'category_gitee_service.dart';
import 'diary_local_store.dart';

typedef CategoryTokenLoader = Future<String?> Function();
typedef CategoryDocumentLoader = Future<CategoryGiteePullResult> Function({
  required String token,
  required String userCode,
});
typedef CategoryDocumentPusher = Future<CategoryGiteePushResult> Function({
  required String token,
  required String userCode,
  required String content,
  required String commitMessage,
  /// 读取远端时拿到的 sha；写入时交给服务端做版本校验。
  String? expectedSha,
  /// 读取时远端文件不存在（此时 expectedSha 为 null）。
  bool expectNotFound,
});

class CategorySyncDependencies {
  const CategorySyncDependencies({
    required this.loadToken,
    required this.pullCategories,
    required this.pushCategories,
  });

  final CategoryTokenLoader loadToken;
  final CategoryDocumentLoader pullCategories;
  final CategoryDocumentPusher pushCategories;

  factory CategorySyncDependencies.production() {
    return CategorySyncDependencies(
      loadToken: DiaryLocalStore.loadToken,
      pullCategories: CategoryGiteeService.pullCategories,
      pushCategories: CategoryGiteeService.pushCategories,
    );
  }

  /// 用于离线测试或只测试其他同步流程的 Provider，避免意外发起网络请求。
  factory CategorySyncDependencies.disabled() {
    return CategorySyncDependencies(
      loadToken: () async => null,
      pullCategories: ({required token, required userCode}) async {
        return CategoryGiteePullResult.notFound();
      },
      pushCategories: ({
        required token,
        required userCode,
        required content,
        required commitMessage,
        String? expectedSha,
        bool expectNotFound = false,
      }) async {
        return CategoryGiteePushResult.success(created: false);
      },
    );
  }
}
