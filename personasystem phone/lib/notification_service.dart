import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'api_service.dart';
import 'supabase_bridge.dart' show maybeAdvanceRecurringReminder;
import 'main.dart' show kSupabaseUrl, kSupabaseAnonKey;

/// 2026-09-30 重要修正: 原本"提醒"是用 flutter_local_notifications 的 zonedSchedule() 提前排到
/// 系统 AlarmManager，时间到了由系统闹钗 + 一个背景 receiver 重建通知贴出来——实测在这台设备上
/// 这条路径完全不工作 (闹钟本身每次都准时触发，但触发后通知从来贴不出来，换了好几种排查方向都
/// 没用；反而直接 .show() 立即触发的通知完全正常，证明不是系统拦这个 App 的通知，是 zonedSchedule
/// 那条排程机制本身在这台机器上失效)。改法: 交给 step_service.dart 里那个本来就每 30 秒跑一次、
/// 已经证实稳定的前台服务心跳去轮询"有没有到期的提醒"，到了就直接呼叫 .show() (立即触发那条已确认
/// 可靠的路径)——牺牲一点点精确度 (最多晚 30 秒)，换来真正会响。
/// 2026-09-30 再修正: 订阅续费/生日提醒原本也是"只有 App 打开那一刻检查一次"，同一类可靠性问题
/// (那天没开 App 就整个错过)，现在也一起搬进 step_service.dart 的背景心跳去查 (见那边的
/// _checkSubscriptionsAndBirthdays())。这个文件现在只剩通知初始化 + 点击"✓已提醒"按钮的回应处理。
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );
    await Permission.notification.request();
    _initialized = true;
  }

  static void _onResponse(NotificationResponse response) {
    if (response.actionId == 'mark_done') {
      final reminderId = response.payload;
      if (reminderId != null && reminderId.isNotEmpty) _markDone(reminderId);
    }
    // 一般点击 (不是按"已提醒"那个按钮): 就正常打开 App 就好，不用特别处理。
  }

  /// App 是被"点了已提醒"这个按钮冷启动的话 (App 进程本来是死的)，onDidReceiveNotificationResponse
  /// 不会自动补触发——用这个在 main() 里手动查一次，是的话照样标记已完成。
  static Future<void> handleColdStartLaunch() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    final response = details?.notificationResponse;
    if (details != null && details.didNotificationLaunchApp && response != null && response.actionId == 'mark_done') {
      final reminderId = response.payload;
      if (reminderId != null && reminderId.isNotEmpty) await _markDone(reminderId);
    }
  }

  static Future<void> _markDone(String reminderId) async {
    try {
      await ApiService.update('reminders', reminderId, {'is_sent': true});
    } catch (_) {}
    await cancelReminder(reminderId);
  }

  static int _notificationIdFor(String reminderId) => reminderId.hashCode & 0x7fffffff;

  static Future<void> cancelReminder(String reminderId) => _plugin.cancel(_notificationIdFor(reminderId));
}

/// 背景 (App 进程已经被系统整个杀掉) 点了通知上"已提醒"按钮时的入口——必须是顶层函数。
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  if (response.actionId != 'mark_done') return;
  final reminderId = response.payload;
  if (reminderId == null || reminderId.isEmpty) return;
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Supabase.initialize(url: kSupabaseUrl, anonKey: kSupabaseAnonKey);
    final session = Supabase.instance.client.auth.currentSession;
    if (session != null) {
      // 一定要带上 user_id：管理员账号的 RLS 是"可以看/改所有人"，不带的话按到别人的提醒
      // 也会被写进去。
      await Supabase.instance.client
          .from('reminders')
          .update({'is_sent': true})
          .eq('id', reminderId)
          .eq('user_id', session.user.id);
      await maybeAdvanceRecurringReminder(reminderId);
    }
  } catch (_) {}
  try {
    await FlutterLocalNotificationsPlugin().cancel(reminderId.hashCode & 0x7fffffff);
  } catch (_) {}
}
