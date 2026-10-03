import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_bridge.dart';
import 'supabase_bridge.dart' as bridge;

export 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

/// 2026-09-28: App 直接连 Supabase (跟网站端 js/supabase_bridge.js 同一套做法)，不再打
/// api.php，不再需要这台电脑的 Apache/Cloudflare Tunnel。真正的实现都在 supabase_bridge.dart
/// 里，这个 class 只是保留原本的方法签名，让 main.dart/screens 完全不用改一行。
class ApiService {
  static Future<Map<String, dynamic>?> login(String identifier, String password) async {
    try {
      final res = await signInWithIdentifier(identifier, password);
      final user = res.user;
      if (user == null) throw Exception('邮箱或密码不对');
      if (user.emailConfirmedAt == null) {
        await sb.auth.signOut();
        throw Exception('这个邮箱还没完成验证码，请先去注册页输入邮件里的验证码');
      }
      final profile = await fetchProfile(user.id);
      return publicUserFrom(profile, user.email ?? '');
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('not confirmed')) {
        throw Exception('这个邮箱还没完成验证码，请先去注册页输入邮件里的验证码');
      }
      if (e is Exception && e.toString().contains('验证码')) rethrow;
      throw Exception('邮箱或密码不对');
    }
  }

  /// 注册第一步：送出资料，Supabase 会寄一组 6 位验证码到信箱。
  /// 回传 {'needs_otp': true} 表示还差验证码这一步；直接带回 user 就代表已经登入
  /// (专案没开 Confirm email 的情况)。
  static Future<Map<String, dynamic>> register(String email, String password, String displayName) async {
    if (password.length < 6) throw Exception('密码至少要 6 位');
    final normalized = email.trim().toLowerCase();
    if (!looksLikeEmail(normalized)) throw Exception('请填写有效的邮箱');
    if (displayName.trim().isEmpty) throw Exception('请填写名字');
    AuthResponse res;
    try {
      res = await sb.auth.signUp(
        email: normalized,
        password: password,
        data: {'display_name': displayName.trim()},
      );
    } catch (e) {
      throw Exception(e.toString().contains('already') ? '这个邮箱已经有人用了，换一个' : e.toString());
    }
    if (res.user == null) throw Exception('注册失败，请稍后再试');
    if (res.user!.identities != null && res.user!.identities!.isEmpty) {
      throw Exception('这个邮箱已经有人用了，换一个');
    }
    if (res.session != null) {
      await sb.auth.signOut();
    }
    return {'needs_otp': true, 'email': normalized, 'display_name': displayName.trim()};
  }

  /// 注册第二步：输入信箱收到的验证码。验证成功就同时完成登入。
  static Future<Map<String, dynamic>> verifySignupOtp(String email, String token, String displayName) async {
    final normalized = email.trim().toLowerCase();
    final code = token.trim();
    if (code.isEmpty) throw Exception('请填写验证码');
    AuthResponse res;
    try {
      res = await sb.auth.verifyOTP(email: normalized, token: code, type: OtpType.signup);
    } catch (_) {
      throw Exception('验证码不对或已经过期，请重新获取');
    }
    if (res.user == null) throw Exception('验证失败，请重新获取验证码');
    if (displayName.trim().isNotEmpty) {
      try {
        await sb.from('profiles').upsert({
          'id': res.user!.id,
          'display_name': displayName.trim(),
          'email': normalized,
          'role': 'user',
        });
      } catch (_) {}
    }
    final profile = await fetchProfile(res.user!.id);
    return publicUserFrom(profile, res.user!.email ?? normalized);
  }

  /// 忘记密码第一步：寄验证码。不管这个邮箱存不存在都回一样的讯息，
  /// 免得被人拿来试探哪些邮箱注册过。
  static Future<void> requestPasswordReset(String email) async {
    final normalized = email.trim().toLowerCase();
    if (!looksLikeEmail(normalized)) throw Exception('请填写有效的邮箱');
    try {
      await sb.auth.resetPasswordForEmail(normalized);
    } catch (e) {
      throw Exception(e.toString());
    }
  }

  /// 忘记密码第二步：验证码 + 新密码，使用者自己完成，不需要管理员插手。
  static Future<void> resetPasswordWithOtp(String email, String token, String newPassword) async {
    final normalized = email.trim().toLowerCase();
    final code = token.trim();
    if (code.isEmpty) throw Exception('请填写验证码');
    if (newPassword.length < 6) throw Exception('新密码至少要 6 位');
    try {
      await sb.auth.verifyOTP(email: normalized, token: code, type: OtpType.recovery);
    } catch (_) {
      throw Exception('验证码不对或已经过期，请重新获取');
    }
    await sb.auth.updateUser(UserAttributes(password: newPassword));
  }

  static Future<Map<String, dynamic>?> me() async {
    final session = sb.auth.currentSession;
    if (session == null) return null;
    try {
      final profile = await fetchProfile(session.user.id);
      return publicUserFrom(profile, session.user.email ?? profile['email']?.toString() ?? '');
    } catch (_) {
      return null;
    }
  }

  static Future<void> logout() => sb.auth.signOut();

  static Future<void> changePassword(String oldPassword, String newPassword) async {
    final session = sb.auth.currentSession;
    if (session == null) throw Exception('请先登录');
    try {
      await sb.auth.signInWithPassword(email: session.user.email!, password: oldPassword);
    } catch (_) {
      throw Exception('原密码不对');
    }
    if (newPassword.length < 6) throw Exception('新密码至少要 6 位');
    await sb.auth.updateUser(UserAttributes(password: newPassword));
  }

  // ---------------- 通用 meta/dashboard/CRUD ----------------

  static Future<Map<String, dynamic>> meta() async => {'ok': true, 'resources': await loadMetaConfig()};

  static Future<Map<String, dynamic>> dashboard() async {
    final session = sb.auth.currentSession;
    if (session == null) throw AuthException('请先登录');
    return buildDashboard(session.user.id);
  }

  static Future<List<dynamic>> list(String resource, {Map<String, dynamic>? filters}) async {
    final session = sb.auth.currentSession;
    if (session == null) throw AuthException('请先登录');
    final userId = session.user.id;
    if (resource == 'salary_payments') await autoGenerateDueSalaryPayments(userId);
    if (resource == 'subscriptions') await autoGenerateDueSubscriptions(userId);
    if (resource == 'fixed_deposits') await autoGenerateDueFixedDeposits(userId);
    if (resource == 'reminders') await advanceDueReminders(userId);

    var query = sb.from(resource).select('*').eq('user_id', userId);
    query = applyFilters(query, filters);
    final rows = await query.order('id', ascending: false).limit(500);

    // 银行账户列表额外算出当前余额 + 打码账号 (跟网站端 supabase_bridge.js 的 list 特殊处理一样，
    // current_balance 是靠交易记录算出来的，不是存在表里的栏位，通用 select('*') 拿不到)。
    if (resource == 'bank_accounts') {
      final balances = await computeBankBalances(userId);
      final byId = {for (final b in balances) b['id']: b};
      for (final r in rows) {
        final b = byId[r['id']];
        if (b != null) {
          r['current_balance'] = b['current_balance'];
          r['account_number_masked'] = b['account_number_masked'];
        }
      }
    }

    return rows;
  }

  static Future<Map<String, dynamic>?> get(String resource, String id) async {
    final uid = sb.auth.currentUser?.id;
    var q = sb.from(resource).select('*').eq('id', id);
    if (uid != null) q = q.eq('user_id', uid);
    return q.maybeSingle();
  }

  static Future<void> create(String resource, Map<String, dynamic> data) async {
    var insertData = await normalizeData(resource, data);
    for (final e in insertData.entries) {
      if (identical(e.value, invalidFieldValue)) throw Exception('字段 ${e.key} 格式不对');
    }
    insertData = await applyReminderTimeRule(resource, 'create', null, insertData);
    final row = await sb.from(resource).insert(insertData).select().single();
    if (resource == 'salary_payments') await syncSalaryPayment(row['id']);
    if (resource == 'fixed_deposits') await syncFixedDepositOpen(row['id']);
    if (resource == 'reminders') await maybeAdvanceRecurringReminder(row['id']);
  }

  static Future<void> update(String resource, String id, Map<String, dynamic> data) async {
    var updateData = await normalizeData(resource, data);
    for (final e in updateData.entries) {
      if (identical(e.value, invalidFieldValue)) throw Exception('字段 ${e.key} 格式不对');
    }
    updateData = await applyReminderTimeRule(resource, 'update', id, updateData);

    num? previousFdPrincipal;
    if (resource == 'fixed_deposits' && updateData.containsKey('principal')) {
      final existingFd = await sb.from('fixed_deposits').select('principal').eq('id', id).maybeSingle();
      previousFdPrincipal = existingFd != null ? asNum(existingFd['principal']) : null;
    }

    var upd = sb.from(resource).update(updateData).eq('id', id);
    final uid = sb.auth.currentUser?.id;
    if (uid != null) upd = upd.eq('user_id', uid);
    await upd;
    if (resource == 'salary_payments') await syncSalaryPayment(id);
    if (resource == 'reminders') await maybeAdvanceRecurringReminder(id);
    if (resource == 'fixed_deposits' && previousFdPrincipal != null) await syncFixedDepositPrincipalChange(id, previousFdPrincipal);
  }

  static Future<void> delete(String resource, String id) async {
    final inUse = await checkInUse(resource, id);
    if (inUse > 0) throw Exception('还有 $inUse 条记录在用这个，请先改掉那些记录再删除');
    if (resource == 'salary_payments') {
      final sp = await sb.from('salary_payments').select('transaction_id').eq('id', id).maybeSingle();
      if (sp != null && sp['transaction_id'] != null) await sb.from('transactions').delete().eq('id', sp['transaction_id']);
    }
    var del = sb.from(resource).delete().eq('id', id);
    final delUid = sb.auth.currentUser?.id;
    if (delUid != null) del = del.eq('user_id', delUid);
    await del;
  }

  // ---------------- 订阅 / 定存 / 报表 专属 action ----------------

  static Future<Map<String, dynamic>> markSubscriptionPaid(String id) async {
    final sub = await sb.from('subscriptions').select('*').eq('id', id).maybeSingle();
    if (sub == null) throw Exception('找不到这个订阅');
    if (sub['bank_account_id'] == null) throw Exception('这个订阅还没设置自动扣款账户');
    final today = todayStr();
    final txn = await sb.from('transactions').insert({
      'user_id': sub['user_id'], 'type': 'expense', 'amount': sub['cost'], 'transaction_date': today,
      'bank_account_id': sub['bank_account_id'], 'description': '订阅扣费: ${sub['name']}', 'currency': 'MYR',
    }).select().single();
    final base = sub['next_billing_date'] ?? today;
    final nextDate = sub['billing_cycle'] == 'yearly' ? addMonths(base, 12) : addMonths(base, 1);
    await sb.from('subscriptions').update({'next_billing_date': nextDate}).eq('id', id);
    return {'ok': true, 'transaction_id': txn['id'], 'next_billing_date': nextDate};
  }

  static Future<Map<String, dynamic>> generateReport({
    required String reportType,
    required String periodStart,
    required String periodEnd,
  }) =>
      bridge.generateReport(reportType, periodStart, periodEnd);

  // ---------------- 管理员专属 (只有 role=admin 才能成功) ----------------

  static Future<List<dynamic>> adminListUsers() async {
    final rows = await sb.from('profiles').select('id, display_name, email, role, created_at').order('created_at');
    return rows.map((p) => {
      'id': p['id'],
      'username': p['display_name'],
      'display_name': p['display_name'],
      'email': p['email'] ?? '',
      'role': p['role'],
      'created_at': p['created_at'],
    }).toList();
  }

  static Future<void> adminCreateUser({
    required String email,
    required String password,
    required String displayName,
    String role = 'user',
  }) async {
    final normalized = email.trim().toLowerCase();
    if (!looksLikeEmail(normalized)) throw Exception('请填写有效的邮箱');
    if (displayName.trim().isEmpty) throw Exception('请填写名字');
    if (password.length < 6) throw Exception('密码至少要 6 位');
    final adminSession = sb.auth.currentSession;
    AuthResponse res;
    try {
      res = await sb.auth.signUp(email: normalized, password: password, data: {'display_name': displayName.trim()});
    } catch (e) {
      if (adminSession != null && adminSession.refreshToken != null) {
        await sb.auth.setSession(adminSession.refreshToken!);
      }
      throw Exception(e.toString().contains('already') ? '这个邮箱已经有人用了' : e.toString());
    }
    if (adminSession != null && adminSession.refreshToken != null) {
      await sb.auth.setSession(adminSession.refreshToken!);
    }
    if (res.user == null) throw Exception('注册失败，请稍后再试');
    await sb.from('profiles').upsert({
      'id': res.user!.id,
      'display_name': displayName.trim(),
      'email': normalized,
      'role': role == 'admin' ? 'admin' : 'user',
    });
    if (res.session == null) {
      throw Exception('用户已建立。对方需要先到邮箱点确认链接才能登录。');
    }
  }

  static Future<void> adminUpdateUser({
    required String id,
    String? displayName,
    String? role,
    String? email,
  }) async {
    if (role != null && role != 'admin') {
      final admins = await sb.from('profiles').select('id').eq('role', 'admin');
      final remaining = admins.where((a) => a['id'].toString() != id).length;
      if (remaining == 0) throw Exception('系统至少要留一个管理员');
    }
    final upd = <String, dynamic>{};
    if (displayName != null) upd['display_name'] = displayName;
    if (role != null) upd['role'] = role;
    if (upd.isNotEmpty) await sb.from('profiles').update(upd).eq('id', id);
    if (email != null && email.trim().isNotEmpty) {
      await sb.rpc('admin_update_user_email', params: {
        'target_id': id,
        'new_email': email.trim().toLowerCase(),
      });
    }
  }



  static Future<void> adminDeleteUser(String id) async {
    if (id == sb.auth.currentUser?.id) throw Exception('不能删除自己');
    final target = await sb.from('profiles').select('id, role').eq('id', id).maybeSingle();
    if (target == null) throw Exception('找不到这个用户');
    if (target['role'] == 'admin') {
      final admins = await sb.from('profiles').select('id').eq('role', 'admin');
      final remaining = admins.where((a) => a['id'].toString() != id).length;
      if (remaining == 0) throw Exception('系统至少要留一个管理员');
    }
    final config = await loadMetaConfig();
    for (final entry in config.entries) {
      final cfg = entry.value as Map<String, dynamic>;
      if (cfg['user_scoped'] != true) continue;
      await sb.from(entry.key).delete().eq('user_id', id);
    }
    await sb.from('profiles').delete().eq('id', id);
    await sb.rpc('admin_delete_auth_user', params: {'target_id': id});
  }

  static Future<Map<String, dynamic>> adminExportFullSql() => bridge.adminExportFullSql();

  static Future<Map<String, dynamic>> exportSql() => bridge.exportMySql();
}
