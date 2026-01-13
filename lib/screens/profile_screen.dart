import 'package:flutter/material.dart';
import '../services/google_calendar_service.dart';

// 1. 将类定义从 StatelessWidget 改为 StatefulWidget
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

// 2. 所有的逻辑和 UI 构建都移到这个 _State 类中
class _ProfileScreenState extends State<ProfileScreen> {
  @override
  Widget build(BuildContext context) {
    // 获取当前 Google 登录的用户信息
    final user = GoogleCalendarService.currentUser;

    return Scaffold(
      appBar: AppBar(title: const Text("我的")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (user != null) ...[
              // 已登录状态：展示头像和昵称
              CircleAvatar(
                radius: 40,
                // 如果有 URL 则使用 backgroundImage
                backgroundImage:
                    (user.photoUrl != null && user.photoUrl!.isNotEmpty)
                        ? NetworkImage(user.photoUrl!)
                        : null,
                // 如果没有图片，则显示后备内容（如图标或文字）
                child: (user.photoUrl == null || user.photoUrl!.isEmpty)
                    ? const Icon(Icons.person, size: 40)
                    : null,
              ),
              const SizedBox(height: 16),
              Text(user.displayName ?? '谷歌用户',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              Text(user.email),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () async {
                  await GoogleCalendarService.logout();
                  // 退出后调用 setState 刷新 UI，回到未登录状态
                  setState(() {});
                },
                child: const Text("退出登录"),
              ),
            ] else ...[
              // 未登录状态：展示绑定按钮
              const Icon(Icons.account_circle, size: 80, color: Colors.grey),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  await GoogleCalendarService.login();
                  // 登录成功后调用 setState，由于 user 不再为 null，UI 会切换
                  setState(() {});
                },
                child: const Text("绑定 Google 账号以同步日历"),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
