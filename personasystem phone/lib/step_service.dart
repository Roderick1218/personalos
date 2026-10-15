import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'main.dart' show kSupabaseUrl, kSupabaseAnonKey;
import 'supabase_bridge.dart' show daysBetween;

/// flutter_local_notifications 的 zonedSchedule() 在这台 vivo 手机上不可靠：闹钟准时触发
/// (AlarmManager 记录证实)，但通知从来没真正贴出来，换电池设置/ProGuard 规则都没用。
/// 直接 .show() 立即触发则完全正常，所以问题出在 zonedSchedule 这条排程机制本身，不是
/// 系统整个拦掉通知。不再依赖它，改成用这个本来就每 30 秒跑一次、已经证实稳定的
/// 前台服务心跳，自己去查有没有到期的提醒，到了就直接呼叫 .show() (立即触发，已确认在这台机器
/// 上可靠) ——等于自己实现了一个轮询式的"排程"，牺牲一点点精确度 (最多晚 30 秒)，换来真正能用。

/// 步数要 App 关掉/锁屏也继续记，所以用真正的 Android 前台常驻服务 (flutter_foreground_task)，
/// 跑在独立的背景 isolate 里，跟主 App 生命周期脱钩。Android 规定常驻后台服务要搭配一条
/// 看得到的通知，没法完全隐藏，低调的"正在记录步数中"提示算是能接受的折中。
///
/// 背景 isolate 是独立的 Dart 环境，不能直接用主 isolate 已经登入好的 Supabase client——
/// 这里在背景 isolate 里重新 initialize 一次 Supabase (读的是同一份本地持久化的登入 session，
/// 不用重新登入)，才能在背景把步数写回 daily_metrics。
class StepService {
  // 一定要 nullable，不能默认 0——不然仪表盘的 "snapshot.data ?? metric?['steps']" 永远
  // 拿到这个假 0，不会 fallback 到数据库真正的步数，重开 App 瞬间会显示"今日步数: 0"。
  static int? _todaySteps;
  static final StreamController<int> _controller = StreamController<int>.broadcast();

  static Stream<int> get todayStepsStream => _controller.stream;
  static int? get todaySteps => _todaySteps;

  /// App 启动时调用一次：把前台服务需要的通知/选项设置好，并接上"背景传步数回主isolate"的通道。
  static void initialize() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'step_tracking',
        channelName: '步数记录',
        channelDescription: '持续记录你今天走了多少步 (关闭这个通知会停止记步)',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
  }

  static void _onReceiveTaskData(Object data) {
    if (data is int) {
      _todaySteps = data;
      _controller.add(data);
    }
  }

  static Future<void> start() async {
    final activityStatus = await Permission.activityRecognition.request();
    if (!activityStatus.isGranted) return;

    if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      // 不强制要求 (有些用户不想给)，但请求一次可以避免部分机型几分钟就把服务杀掉。
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: '安本 · 步数记录',
      notificationText: '正在记录步数中...',
      callback: startCallback,
    );
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// 换账号时必须调用。背景服务启动时就把当时的 session 收进自己的 client 了，
  /// 主 App 换账号它感觉不到，会继续写旧账号的数据。停掉重开让它重新读当前 session。
  static Future<void> restart() async {
    await stop();
    _todaySteps = null;
    await Future.delayed(const Duration(milliseconds: 600));
    await start();
  }
}

/// 前台服务背景 isolate 的入口——必须是顶层函数 (或 static)，flutter_foreground_task 靠这个
/// 反射式地在新 isolate 里把 TaskHandler 接上去。
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_StepTaskHandler());
}

class _StepTaskHandler extends TaskHandler {
  StreamSubscription<StepCount>? _sub;
  int _todaySteps = 0;
  bool _supabaseReady = false;
  String? _boundUserId;
  // 记住"传感器最后一次回报的开机累计步数"——这样即使跨午夜那一刻用户没有实际在走路
  // (没有新的传感器事件)，onRepeatEvent 的定时检查也能拿这个值重新算出"今天从 0 开始"，
  // 不用等到用户下一次真的踏出一步、或者重开 App，通知/步数才会跟着重置。
  int? _lastRawSteps;

  final FlutterLocalNotificationsPlugin _notifPlugin = FlutterLocalNotificationsPlugin();
  bool _notifReady = false;

  Future<void> _ensureNotifPlugin() async {
    if (_notifReady) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifPlugin.initialize(const InitializationSettings(android: androidInit));
    _notifReady = true;
  }

  int _notificationIdFor(String reminderId) => reminderId.hashCode & 0x7fffffff;

  // 每次心跳查一次有没有到期还没处理的提醒，直接 .show() 贴出来——onlyAlertOnce 让同一条提醒
  // 还没被用户点"已提醒"之前，即使每 30 秒重复贴一次，也不会一直重复震动/出声，只是让通知内容
  // 保持最新、留在通知栏。
  Future<void> _checkReminders() async {
    await _ensureSupabase();
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return;
    if (_boundUserId != null && _boundUserId != session.user.id) return; // 主 App 换账号了，等重启
    try {
      final nowIso = DateTime.now().toUtc().toIso8601String();
      final due = await Supabase.instance.client
          .from('reminders')
          .select('id, message')
          .eq('user_id', session.user.id)
          .eq('is_sent', false)
          .lte('remind_at', nowIso);
      if ((due as List).isEmpty) return;
      await _ensureNotifPlugin();
      for (final r in due) {
        final id = _notificationIdFor(r['id'].toString());
        await _notifPlugin.show(
          id,
          '⏰ 提醒',
          r['message'].toString(),
          NotificationDetails(
            android: AndroidNotificationDetails(
              'personal_os_reminder_alerts',
              '⏰ 到点提醒 (需要手动确认)',
              channelDescription: '到了设定时间的提醒——会一直留在通知栏，直到你点"已提醒"才消失',
              importance: Importance.max,
              priority: Priority.high,
              ongoing: true,
              autoCancel: false,
              onlyAlertOnce: true,
              category: AndroidNotificationCategory.reminder,
              // showsUserInterface: true —— 之前用 false (纯背景广播处理，不开 App) 完全点不动，
              // 这个机制在不少机型上本来就不太可靠。改用 true，跟"直接点通知本体"同一套机制
              // (用 startActivity 的 PendingIntent，已经证实这条路径正常)，牺牲"不用开 App"这个
              // 细节，换取按钮真的按得动。
              actions: const [
                AndroidNotificationAction('mark_done', '✓ 已提醒', cancelNotification: true, showsUserInterface: true),
              ],
            ),
          ),
          payload: r['id'].toString(),
        );
      }
    } catch (_) {
      // 查询/贴通知失败就等下一次 30 秒心跳再试，不特别处理重试队列。
    }
  }

  // 订阅续费/生日提醒——之前只有"App 打开那一刻检查一次"，如果提醒生效那天刚好没开 App 就会
  // 整个错过。现在改成也交给这个背景心跳查，进入提醒窗口 (还没到期但天数 <= remind_days_before)
  // 就会弹一次；用 SharedPreferences 记"这次到期日期上次通知过了没"来去重，同一次到期只弹一次，
  // 不会每 30 秒重复弹，但换了一轮新的到期日 (比如上一期已经处理掉，进到下一期) 就会重新弹一次。
  Future<void> _checkSubscriptionsAndBirthdays() async {
    await _ensureSupabase();
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return;
    if (_boundUserId != null && _boundUserId != session.user.id) return;
    final today = _todayKey();
    final prefs = await SharedPreferences.getInstance();

    try {
      final subs = await Supabase.instance.client
          .from('subscriptions')
          .select('id, name, cost, next_billing_date, remind_days_before')
          .eq('user_id', session.user.id)
          .eq('is_active', true)
          .not('next_billing_date', 'is', null);
      await _ensureNotifPlugin();
      for (final s in subs) {
        final nextBilling = s['next_billing_date'].toString();
        final daysUntil = daysBetween(today, nextBilling);
        final remindDaysBefore = (s['remind_days_before'] as num).toInt();
        if (daysUntil < 0 || daysUntil > remindDaysBefore) continue;
        final key = 'sub_notified_${s['id']}';
        if (prefs.getString(key) == nextBilling) continue; // 这一期已经通知过了
        await prefs.setString(key, nextBilling);
        final id = ('sub_${s['id']}').hashCode & 0x7fffffff;
        await _notifPlugin.show(
          id,
          '🔄 订阅续费提醒',
          '「${s['name']}」还有 $daysUntil 天续费，RM ${s['cost']}',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'personal_os_reminders',
              '安本提醒',
              channelDescription: '订阅续费 / 生日提醒',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
        );
      }
    } catch (_) {}

    try {
      final contacts = await Supabase.instance.client
          .from('contacts')
          .select('id, name, birthday, remind_days_before')
          .eq('user_id', session.user.id)
          .not('birthday', 'is', null);
      await _ensureNotifPlugin();
      final todayYear = int.parse(today.substring(0, 4));
      for (final c in contacts) {
        final bday = c['birthday'].toString();
        var next = '$todayYear-${bday.substring(5, 10)}';
        if (next.compareTo(today) < 0) next = '${todayYear + 1}-${bday.substring(5, 10)}';
        final daysUntil = daysBetween(today, next);
        final remindDaysBefore = (c['remind_days_before'] as num).toInt();
        if (daysUntil < 0 || daysUntil > remindDaysBefore) continue;
        final key = 'bday_notified_${c['id']}';
        if (prefs.getString(key) == next) continue;
        await prefs.setString(key, next);
        final id = ('bday_${c['id']}').hashCode & 0x7fffffff;
        await _notifPlugin.show(
          id,
          '🎂 生日提醒',
          daysUntil == 0 ? '${c['name']} 今天生日！' : '${c['name']} 还有 $daysUntil 天生日',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'personal_os_reminders',
              '安本提醒',
              channelDescription: '订阅续费 / 生日提醒',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _ensureSupabase() async {
    if (_supabaseReady) return;
    try {
      // 背景 isolate 跟主 App isolate 是两个独立的 GoTrueClient，却共用同一份登入存档。
      // Refresh token 是一次性的，两边各自的自动续期定时器撞在一起会互抢，背景这边的
      // Dart Timer 在系统省电模式下又不保证准时，拖到过期才续期就会被判真失效、直接登出。
      // 关掉背景的内建定时器，改成靠前台服务那个稳定的 30 秒心跳自己检查续期 (见下面
      // _ensureFreshSession)，主 isolate 维持原本设定不动。
      await Supabase.initialize(
        url: kSupabaseUrl,
        anonKey: kSupabaseAnonKey,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      );
    } catch (_) {
      // 已经初始化过 (比如服务重启但 isolate 没真的销毁) 会丢例外，忽略即可。
    }
    _supabaseReady = true;
    // 记下"这个 isolate 是替哪个账号跑的"。每次心跳都会拿它跟当前 session 比一次，
    // 对不上就整轮跳过，宁可这一轮什么都不做，也不要把旧账号的数据写到别人名下。
    _boundUserId = Supabase.instance.client.auth.currentSession?.user.id;
  }

  // 借这个 30 秒心跳当续期时钟，比等 GoTrueClient 内建的定时器靠谱。
  Future<void> _ensureFreshSession() async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null || !session.isExpired) return;
    try {
      await Supabase.instance.client.auth.refreshSession();
    } catch (_) {
      // 续期失败就算了，下一次 30 秒心跳再试；各个查询自己也还有各自的失败重试保险。
    }
  }

  String _todayKey() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  // 检查"今天"跟上次记的 baseline 日期是否还一样，不一样就用给定的开机累计步数重新起算——
  // 传感器事件、跟每 30 秒一次的心跳都会呼叫这个，确保跨午夜不用靠"刚好在走路"才会重置。
  Future<int> _resolveBaseline(int rawSteps) async {
    final prefs = await SharedPreferences.getInstance();
    final todayStr = _todayKey();
    final savedDate = prefs.getString('step_baseline_date');
    if (savedDate == todayStr && prefs.containsKey('step_baseline')) {
      return prefs.getInt('step_baseline')!;
    }
    await prefs.setString('step_baseline_date', todayStr);
    await prefs.setInt('step_baseline', rawSteps);
    return rawSteps;
  }

  Future<void> _recomputeAndPush(int rawSteps) async {
    final baseline = await _resolveBaseline(rawSteps);
    final steps = rawSteps - baseline;
    _todaySteps = steps < 0 ? 0 : steps;
    FlutterForegroundTask.updateService(
      notificationTitle: '安本 · 步数记录',
      notificationText: '今天已走 $_todaySteps 步',
    );
    FlutterForegroundTask.sendDataToMain(_todaySteps);
    await _syncToServer();
  }

  Future<void> _onStepCount(StepCount event) async {
    _lastRawSteps = event.steps;
    await _recomputeAndPush(event.steps);
  }

  Future<void> _syncToServer() async {
    await _ensureSupabase();
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return; // 没登入 (比如刚开机自动重启服务但还没登入过)，先不写
    if (_boundUserId != null && _boundUserId != session.user.id) return;
    try {
      await Supabase.instance.client.from('daily_metrics').upsert(
        {'user_id': session.user.id, 'metric_date': _todayKey(), 'steps': _todaySteps},
        onConflict: 'user_id,metric_date',
      );
    } catch (_) {
      // 失败先手动催一次续期再试——能成功就是 token 过期，下次心跳会恢复正常；
      // 续期也失败就是真的网络不通，等下一次心跳再试。
      try {
        await Supabase.instance.client.auth.refreshSession();
        await Supabase.instance.client.from('daily_metrics').upsert(
          {'user_id': session.user.id, 'metric_date': _todayKey(), 'steps': _todaySteps},
          onConflict: 'user_id,metric_date',
        );
      } catch (_) {
        // 还是失败就真的跳过，下一次 30 秒心跳再试，不特别处理重试队列。
      }
    }
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _sub = Pedometer.stepCountStream.listen(_onStepCount, onError: (_) {});
    await _ensureSupabase();
    await _ensureFreshSession();
    _checkReminders();
    _checkSubscriptionsAndBirthdays();
  }

  @override
  void onRepeatEvent(DateTime timestamp) async {
    // 30 秒心跳：续期 session、补一次步数同步、跑 baseline 检查 (跨午夜最多 30 秒内归零)、
    // 查提醒和订阅/生日。
    await _ensureSupabase();
    await _ensureFreshSession();
    if (_lastRawSteps != null) {
      _recomputeAndPush(_lastRawSteps!);
    } else {
      _syncToServer();
    }
    _checkReminders();
    _checkSubscriptionsAndBirthdays();
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _sub?.cancel();
  }
}
