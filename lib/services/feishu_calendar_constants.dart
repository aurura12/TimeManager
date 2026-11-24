/// 飞书日历同步用到的固定配置。
///
/// 两个使用者各自在自己的租户里建「企业自建应用」，所以 App ID / App Secret
/// 属于运行期凭据，不放这里（`lib/config` 整层被 gitignore）。
class FeishuCalendarConfig {
  FeishuCalendarConfig._();

  /// 用户主动授权页。
  static const String authorizeUrl =
      'https://accounts.feishu.cn/open-apis/authen/v1/authorize';

  /// 授权码换 token（v3，官方当前端点，form 表单）。
  static const String tokenV3Url = 'https://accounts.feishu.cn/oauth/v3/token';

  /// 老版本 token 端点，仅当 v3 返回 404/405 时回退。
  static const String tokenV2Url =
      'https://open.feishu.cn/open-apis/authen/v2/oauth/token';

  /// OpenAPI 根路径。
  static const String apiBase = 'https://open.feishu.cn/open-apis';

  /// `calendar:calendar` 才能建/删日程；`offline_access` 才拿得到 refresh_token。
  static const String scopes = 'calendar:calendar offline_access';

  /// 本 App 创建的事件用这个 description 认领，用户在飞书自建的事件绝不碰。
  static const String eventMarker = '由「时间块」自动同步';

  /// 回环授权端口：必须与飞书后台登记的重定向 URL 完全一致，不能动态改。
  static const int redirectPort = 17890;

  static const String redirectPath = '/feishu/oauth/callback';

  static String get redirectUri =>
      'http://127.0.0.1:$redirectPort$redirectPath';

  /// 单次授权等待时长。
  static const Duration authTimeout = Duration(minutes: 5);

  static const String openPlatformUrl = 'https://open.feishu.cn/app';
}
