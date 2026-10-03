import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_state.dart';
import 'api_service.dart';
import 'models.dart';
import 'theme.dart';
import 'notification_service.dart';
import 'step_service.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/resource_list_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/admin_users_screen.dart';
import 'screens/backup_screen.dart';

// v2/v3 规范: 只保留这份文档定义的核心模块，其余先从导航隐藏 (数据库表和数据都还在，
// 网站端 js/app.js 里也有一份一样的 CORE_VISIBLE，两边要保持同步)。
// 2026-09-25 跟网站端重新对齐一次: 补上 reminders/reports/fixed_deposits 这几个后来才加的模块
// (手机版之前一直停留在多用户登录/薪资/EPF 之前的旧版本，跟网站差了好几轮更新)。
const Set<String> kCoreVisibleResources = {
  'tasks', 'projects', 'project_categories', 'habits', 'habit_logs',
  'categories', 'transactions', 'subscriptions', 'journal_entries', 'contacts',
  'bank_accounts', 'banks', 'tags', 'bookmarks',
  'salary_profiles', 'salary_payments', 'epf_contributions', 'socso_contributions', 'eis_contributions',
  'reminders', 'reports', 'fixed_deposits', 'daily_metrics',
};

// 2026-09-28: 跟网站端一样直接连 Supabase，不再打 api.php —— 不用管这台电脑开不开机，
// 只要手机有网络就能用 (anon key 是公开的没关系，安全性靠 Supabase 的 RLS 权限规则)。
const String kSupabaseUrl = 'https://xpbtyfattbqsaasmokoy.supabase.co';
const String kSupabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhwYnR5ZmF0dGJxc2Fhc21va295Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAyMzQ3MzEsImV4cCI6MjEwNTgxMDczMX0.wzP8YkevvVGi4aEtyMg7TKyzfEsjJPLieyh2wTICt6U';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: kSupabaseUrl, anonKey: kSupabaseAnonKey);
  StepService.initialize();
  await NotificationService.init();
  await NotificationService.handleColdStartLaunch();
  runApp(const PersonaOsApp());
}

class PersonaOsApp extends StatelessWidget {
  const PersonaOsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '安本',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const RootScreen(),
    );
  }
}

/// 整个 App 的门口: 先确认有没有登录 session，没有就先卡在登录页，
/// 登录成功才继续拉 meta/跑通知/计步这些初始化 —— 网站端 v4.8 多用户上线之后，
/// api.php 除了 login/register 之外全部要求登录，手机版之前完全没有这一层，
/// 等于目前这个 App 打开就会直接连线失败 (401)，这是这次更新最优先要补的洞。
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

enum _AuthPhase { checking, loggedOut, bootstrapping, ready, error }

class _RootScreenState extends State<RootScreen> {
  _AuthPhase _phase = _AuthPhase.checking;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    setState(() => _phase = _AuthPhase.checking);
    final user = await ApiService.me();
    if (user == null) {
      setState(() => _phase = _AuthPhase.loggedOut);
      return;
    }
    AppState.currentUser = user;
    await _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() => _phase = _AuthPhase.bootstrapping);
    try {
      await AppState.loadMeta();
      // 提醒/订阅续费/生日/步数现在全部交给 step_service.dart 的背景服务心跳处理，
      // 不用在这里另外检查——失败也不应该挡住主流程，各自内部已经吞掉了异常。
      //
      // 用 restart 而不是 start：这个服务可能在上一次开机时就已经跑起来了 (autoRunOnBoot)，
      // 那时绑定的账号不一定是现在登入的这个人。停掉重开一次，让背景 isolate 重新读当前
      // session，换账号之后通知和步数才会跟着换到对的人。
      unawaited(StepService.restart());
      if (mounted) setState(() => _phase = _AuthPhase.ready);
    } catch (e) {
      if (!mounted) return;
      if (e is AuthException) {
        // session 失效 (比如本地存的 cookie 已经过期/无效，或服务器重启清了 session) ——
        // 这不是真的"连接失败"，不该卡在那个转圈重试的错误页 (重试也只会再失败一次)，
        // 直接当作登出处理，弹回登录页重新登录就好，跟网站端 api() 遇到 401 的行为一致。
        AppState.reset();
        setState(() => _phase = _AuthPhase.loggedOut);
        return;
      }
      setState(() {
        _error = e.toString();
        _phase = _AuthPhase.error;
      });
    }
  }

  void _onLoggedIn(Map<String, dynamic> user) {
    AppState.currentUser = user;
    _bootstrap();
  }

  Future<void> _logout() async {
    // 先停掉背景记步/提醒服务再登出：它是独立 isolate，会拿着"现在这个账号"的 session 一直跑，
    // 不停掉的话登出后它还会继续往这个账号写步数、弹这个账号的提醒。
    try {
      await StepService.stop();
    } catch (_) {}
    try {
      await ApiService.logout();
    } catch (_) {}
    AppState.reset();
    setState(() => _phase = _AuthPhase.loggedOut);
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _AuthPhase.checking:
      case _AuthPhase.bootstrapping:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case _AuthPhase.loggedOut:
        return LoginScreen(onLoggedIn: _onLoggedIn);
      case _AuthPhase.error:
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('连接失败: $_error', textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  const Text(
                    '请确认手机有网络连接。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(onPressed: _bootstrap, child: const Text('重试')),
                ],
              ),
            ),
          ),
        );
      case _AuthPhase.ready:
        return HomeShell(onLogout: _logout);
    }
  }
}

// 底部导航: 今日 / 任务 / 习惯 / 财务 4 个核心 tab 直接嵌入，"更多"打开抽屉看全部模块。
class HomeShell extends StatefulWidget {
  final VoidCallback onLogout;
  const HomeShell({super.key, required this.onLogout});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<DashboardScreenState> _dashboardKey = GlobalKey<DashboardScreenState>();
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
  }

  static const List<String> _tabTitles = ['今日仪表盘', '任务', '习惯', '财务记账'];
  // 按功能分类，不按使用频率分 (跟网站端 js/app.js 的 GROUP_LABELS 保持一致)
  // 2026-09-29: 补上 'system' 分组——之前漏了这组，导致 group='system' 的 reminders
  // (通用提醒) 虽然在 kCoreVisibleResources 里，却因为它的分组从没被遍历到，
  // 从来没有在抽屉导航里显示过 (网站端 js/app.js 的 GROUP_ORDER 一直都有这组，只有手机版漏了)。
  static const Map<String, String> _groupLabels = {'core': '核心', 'finance': '财务', 'personal': '个人', 'tools': '工具', 'system': '系统'};
  static const List<String> _groupOrder = ['core', 'finance', 'personal', 'tools', 'system'];

  late final List<Widget> _tabs = [
    DashboardScreen(key: _dashboardKey),
    const ResourceListScreen(resourceName: 'tasks', embedded: true),
    const ResourceListScreen(resourceName: 'habits', embedded: true),
    const ResourceListScreen(resourceName: 'transactions', embedded: true),
  ];

  void _openResource(BuildContext context, String name, ResourceConfig cfg) {
    Navigator.pop(context);
    // reports 是自订流程 (生成+查看报表，不是普通表单 CRUD)，走专属页面
    if (name == 'reports') {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const ReportsScreen()));
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => ResourceListScreen(resourceName: name)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(title: Text(_tabTitles[_tabIndex])),
      drawer: _buildDrawer(context),
      body: IndexedStack(index: _tabIndex, children: _tabs),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        type: BottomNavigationBarType.fixed,
        onTap: (index) {
          if (index == 4) {
            _scaffoldKey.currentState?.openDrawer();
            return;
          }
          setState(() => _tabIndex = index);
          if (index == 0) _dashboardKey.currentState?.reload();
        },
        items: const [
          BottomNavigationBarItem(icon: Text('🏠', style: TextStyle(fontSize: 20)), label: '今日'),
          BottomNavigationBarItem(icon: Text('✅', style: TextStyle(fontSize: 20)), label: '任务'),
          BottomNavigationBarItem(icon: Text('🔁', style: TextStyle(fontSize: 20)), label: '习惯'),
          BottomNavigationBarItem(icon: Text('💰', style: TextStyle(fontSize: 20)), label: '财务'),
          BottomNavigationBarItem(icon: Text('☰', style: TextStyle(fontSize: 20)), label: '更多'),
        ],
      ),
    );
  }

  Widget _buildDrawer(BuildContext context) {
    final groups = <String, List<MapEntry<String, ResourceConfig>>>{};
    for (final g in _groupOrder) groups[g] = [];
    for (final entry in AppState.resources.entries) {
      if (!kCoreVisibleResources.contains(entry.key)) continue; // 非核心模块暂不在导航展示
      groups.putIfAbsent(entry.value.group, () => []).add(entry);
    }
    final user = AppState.currentUser;

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: AppColors.surfaceAlt),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Row(
                  children: [
                    Image.asset('assets/logo.png', width: 28, height: 28),
                    const SizedBox(width: 8),
                    const Text('安本', style: TextStyle(color: AppColors.text, fontSize: 20)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.person, size: 16, color: AppColors.textMuted),
                    const SizedBox(width: 4),
                    Text(
                      user?['display_name']?.toString() ?? user?['username']?.toString() ?? '',
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                    ),
                    if (AppState.isAdmin) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text('管理员', style: TextStyle(color: AppColors.accent, fontSize: 11)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          for (final g in _groupOrder)
            if (groups[g]!.isNotEmpty) ...[
              _groupTitle(_groupLabels[g] ?? g),
              for (final entry in groups[g]!)
                ListTile(
                  leading: Text(entry.value.icon, style: const TextStyle(fontSize: 18)),
                  title: Text(entry.value.label),
                  onTap: () => _openResource(context, entry.key, entry.value),
                ),
            ],
          _groupTitle('系统'),
          ListTile(
            leading: const Text('💾', style: TextStyle(fontSize: 18)),
            title: const Text('备份与恢复'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupScreen()));
            },
          ),
          if (AppState.isAdmin)
            ListTile(
              leading: const Text('🛡️', style: TextStyle(fontSize: 18)),
              title: const Text('用户管理'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminUsersScreen()));
              },
            ),
          ListTile(
            leading: const Icon(Icons.lock_outline, color: AppColors.textMuted),
            title: const Text('修改密码'),
            onTap: () {
              Navigator.pop(context);
              showChangePasswordDialog(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: AppColors.danger),
            title: const Text('退出登录', style: TextStyle(color: AppColors.danger)),
            onTap: () {
              Navigator.pop(context);
              widget.onLogout();
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _groupTitle(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12, fontWeight: FontWeight.bold)),
      );
}

Future<void> showChangePasswordDialog(BuildContext context) async {
  final oldCtrl = TextEditingController();
  final newCtrl = TextEditingController();
  final confirmCtrl = TextEditingController();
  String? error;
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            title: const Text('修改密码'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: oldCtrl, obscureText: true, decoration: const InputDecoration(labelText: '原密码')),
                const SizedBox(height: 8),
                TextField(controller: newCtrl, obscureText: true, decoration: const InputDecoration(labelText: '新密码（至少 6 位）')),
                const SizedBox(height: 8),
                TextField(controller: confirmCtrl, obscureText: true, decoration: const InputDecoration(labelText: '再输入一次新密码')),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
                ],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              TextButton(
                onPressed: () async {
                  if (newCtrl.text != confirmCtrl.text) {
                    setLocal(() => error = '两次输入的新密码不一样');
                    return;
                  }
                  try {
                    await ApiService.changePassword(oldCtrl.text, newCtrl.text);
                    if (ctx.mounted) Navigator.pop(ctx);
                  } catch (e) {
                    setLocal(() => error = e.toString().replaceFirst('Exception: ', ''));
                  }
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
    },
  );
}
