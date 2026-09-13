import 'category_gitee_service.dart';
import 'diary_local_store.dart';

typedef CategoryTokenLoader = Future<String?> Function();
typedef CategoryDocumentLoader = Future<CategoryGiteePullResult> Function({
  required String token,
  required String userCode,
});

class CategorySyncDependencies {
  const CategorySyncDependencies({
    required this.loadToken,
    required this.pullCategories,
  });

  final CategoryTokenLoader loadToken;
  final CategoryDocumentLoader pullCategories;

  factory CategorySyncDependencies.production() {
    return CategorySyncDependencies(
      loadToken: DiaryLocalStore.loadToken,
      pullCategories: CategoryGiteeService.pullCategories,
    );
  }

  /// 用于离线测试或只测试其他同步流程的 Provider，避免意外发起网络请求。
  factory CategorySyncDependencies.disabled() {
    return CategorySyncDependencies(
      loadToken: () async => null,
      pullCategories: ({required token, required userCode}) async {
        return CategoryGiteePullResult.notFound();
      },
    );
  }
}
