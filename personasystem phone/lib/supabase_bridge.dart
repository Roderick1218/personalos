import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:supabase_flutter/supabase_flutter.dart';

/// App 端也跟网站端一样直接连 Supabase，不打 api.php，数据隔离靠 RLS。
/// 这个文件是网站端 js/supabase_bridge.js 逐句翻译成 Dart 的版本，算法/注释含义都一样。
/// (没有自己另外定义 AuthException —— supabase_flutter 套件本身就有一个同名的
/// package:gotrue AuthException，直接沿用它，session 失效时用它来通知 main.dart
/// 弹回登录页，两者语意刚好一致，不用自己重造一个。)

SupabaseClient get sb => Supabase.instance.client;

const userEmailDomain = '@personalos.app';
const legacyUserEmailDomain = '@personalos.local';

bool looksLikeEmail(String value) =>
    RegExp(r'.+@.+\..+').hasMatch(value.trim());

String usernameToEmail(String username, [String? domain]) =>
    '${username.trim().toLowerCase()}${domain ?? userEmailDomain}';

String stripEmailDomain(String email) {
  final s = email.trim();
  if (RegExp(r'@personalos\.(app|local)$', caseSensitive: false).hasMatch(s)) {
    return s.replaceFirst(RegExp(r'@personalos\.(app|local)$', caseSensitive: false), '');
  }
  return s;
}

Future<AuthResponse> signInWithIdentifier(String identifier, String password) async {
  final raw = identifier.trim();
  if (looksLikeEmail(raw)) {
    return sb.auth.signInWithPassword(email: raw.toLowerCase(), password: password);
  }
  try {
    return await sb.auth.signInWithPassword(email: usernameToEmail(raw), password: password);
  } on AuthException {
    return sb.auth.signInWithPassword(email: usernameToEmail(raw, legacyUserEmailDomain), password: password);
  }
}

Map<String, dynamic>? _metaCache;
Future<Map<String, dynamic>> loadMetaConfig() async {
  if (_metaCache != null) return _metaCache!;
  final raw = await rootBundle.loadString('assets/config_resources.json');
  _metaCache = jsonDecode(raw) as Map<String, dynamic>;
  return _metaCache!;
}

Map<String, dynamic> publicUserFrom(Map<String, dynamic> profile, String email) {
  final name = (profile['display_name']?.toString().trim().isNotEmpty == true)
      ? profile['display_name'].toString()
      : stripEmailDomain(email);
  return {
    'id': profile['id'],
    'username': name,
    'email': email,
    'display_name': name,
    'role': profile['role'],
  };
}

Future<Map<String, dynamic>> fetchProfile(String userId) async {
  final existing = await sb.from('profiles').select('id, display_name, email, role').eq('id', userId).maybeSingle();
  if (existing != null) return existing;
  try {
    final inserted = await sb.from('profiles').insert({
      'id': userId,
      'display_name': 'User',
      'role': 'user',
    }).select().single();
    return inserted;
  } catch (_) {
    return {'id': userId, 'display_name': 'User', 'role': 'user'};
  }
}

String todayStr() => DateTime.now().toUtc().toIso8601String().substring(0, 10);

String addDays(String dateStr, int days) {
  final d = DateTime.parse('${dateStr}T00:00:00Z').add(Duration(days: days));
  return d.toIso8601String().substring(0, 10);
}

String addMonths(String dateStr, int months) {
  final d = DateTime.parse('${dateStr}T00:00:00Z');
  var y = d.year, m = d.month + months;
  while (m > 12) { m -= 12; y++; }
  while (m < 1) { m += 12; y--; }
  final lastDay = DateTime.utc(y, m + 1, 0).day;
  final day = d.day > lastDay ? lastDay : d.day;
  return DateTime.utc(y, m, day).toIso8601String().substring(0, 10);
}

int daysBetween(String a, String b) =>
    DateTime.parse('${b}T00:00:00Z').difference(DateTime.parse('${a}T00:00:00Z')).inDays;

num asNum(dynamic v) => v == null ? 0 : (v is num ? v : num.parse(v.toString()));
double round2(num v) => (v * 100).round() / 100;

PostgrestFilterBuilder<T> applyFilters<T>(PostgrestFilterBuilder<T> query, dynamic filters) {
  if (filters == null) return query;
  List<Map<String, dynamic>> list;
  if (filters is List) {
    list = filters.cast<Map<String, dynamic>>();
  } else {
    final map = filters as Map<String, dynamic>;
    list = map.entries.map((e) => {'field': e.key, 'op': 'eq', 'value': e.value}).toList();
  }
  for (final f in list) {
    final v = f['value'];
    if (v == null || v == '') continue;
    switch (f['op']) {
      case 'gte': query = query.gte(f['field'], v); break;
      case 'lte': query = query.lte(f['field'], v); break;
      case 'like': query = query.ilike(f['field'], '%$v%'); break;
      default: query = query.eq(f['field'], v);
    }
  }
  return query;
}

// 跟 api.php 原本的 normalize_value() 逐句对应 —— 最关键的一条: 表单里没填的欄位
// (日期/数字/fk下拉都可能是空字串) 一律转成 null，不能让空字串 '' 直接传给 date/uuid/numeric
// 栏位 (Postgres 会报 "invalid input syntax for type date" 这类错误)。返回 `_invalid`
// sentinel 表示这个值格式不对 (json/url 解析失败)，呼叫端要检查并挡下来。
const Object invalidFieldValue = Object();

dynamic normalizeValue(Map<String, dynamic> meta, dynamic value) {
  if (value == null || value == '') {
    return meta['type'] == 'boolean' ? false : null;
  }
  switch (meta['type']) {
    case 'boolean':
      return value == true || value == 1 || value == '1' || value == 'true';
    case 'tags':
      final trimmed = value.toString().trim();
      if (trimmed.isEmpty) return '[]';
      if (trimmed.startsWith('[')) {
        try { jsonDecode(trimmed); return trimmed; } catch (_) { /* fall through */ }
      }
      final parts = trimmed.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
      return jsonEncode(parts);
    case 'json':
      try { jsonDecode(value); return value; } catch (_) { return invalidFieldValue; }
    case 'url':
      var v = value.toString().trim();
      if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(v)) v = 'https://$v';
      final uri = Uri.tryParse(v);
      return (uri != null && uri.hasScheme) ? v : invalidFieldValue;
    default:
      return value;
  }
}

Future<Map<String, dynamic>> normalizeData(String resource, Map<String, dynamic> data) async {
  final config = await loadMetaConfig();
  final fields = ((config[resource] as Map<String, dynamic>?) ?? {})['fields'] as Map<String, dynamic>? ?? {};
  final out = <String, dynamic>{};
  for (final entry in data.entries) {
    final meta = fields[entry.key] as Map<String, dynamic>?;
    out[entry.key] = meta != null ? normalizeValue(meta, entry.value) : entry.value;
  }
  return out;
}

const Map<String, List<List<String>>> _usageChecks = {
  'tags': [['transactions', 'tag_id'], ['tasks', 'tag_id'], ['bookmarks', 'tag_id']],
  'bank_accounts': [['transactions', 'bank_account_id']],
  'banks': [['bank_accounts', 'bank_id']],
};
Future<int> checkInUse(String resource, String id) async {
  final checks = _usageChecks[resource];
  if (checks == null) return 0;
  for (final c in checks) {
    final rows = await sb.from(c[0]).select('id').eq(c[1], id);
    if ((rows as List).isNotEmpty) return rows.length;
  }
  return 0;
}

// ---------------- 薪资/EPF/订阅/定存 自动化逻辑 (跟网站端逐句对应) ----------------

Future<String?> getSalaryCategoryId(String userId) async {
  final row = await sb.from('categories').select('id').eq('type', 'income').eq('name', '薪水').eq('user_id', userId).maybeSingle();
  return row?['id'] as String?;
}

Future<void> syncSalaryPayment(String paymentId) async {
  final sp = await sb.from('salary_payments').select('*').eq('id', paymentId).maybeSingle();
  if (sp == null) return;

  if ((sp['status'] ?? 'paid') != 'paid') {
    if (sp['transaction_id'] != null) {
      await sb.from('transactions').delete().eq('id', sp['transaction_id']);
      await sb.from('salary_payments').update({'transaction_id': null}).eq('id', paymentId);
    }
    await sb.from('epf_contributions').delete().eq('salary_payment_id', paymentId);
    await sb.from('socso_contributions').delete().eq('salary_payment_id', paymentId);
    await sb.from('eis_contributions').delete().eq('salary_payment_id', paymentId);
    return;
  }

  final description = '${sp['period_label']} 薪资';
  final categoryId = await getSalaryCategoryId(sp['user_id']);

  if (sp['transaction_id'] != null) {
    await sb.from('transactions').update({
      'category_id': categoryId, 'bank_account_id': sp['bank_account_id'], 'amount': sp['net_salary'],
      'transaction_date': sp['payment_date'], 'description': description,
    }).eq('id', sp['transaction_id']);
  } else {
    final txn = await sb.from('transactions').insert({
      'user_id': sp['user_id'], 'category_id': categoryId, 'bank_account_id': sp['bank_account_id'],
      'type': 'income', 'amount': sp['net_salary'], 'currency': 'MYR', 'description': description,
      'transaction_date': sp['payment_date'],
    }).select().single();
    await sb.from('salary_payments').update({'transaction_id': txn['id']}).eq('id', paymentId);
  }

  final totalEpf = asNum(sp['employee_epf_amount']) + asNum(sp['employer_epf_amount']);
  final existingRow = await sb.from('epf_contributions').select('id').eq('salary_payment_id', paymentId).maybeSingle();

  if (totalEpf > 0) {
    final persaraanAmt = round2(totalEpf * 0.75);
    final sejahteraAmt = round2(totalEpf * 0.15);
    final fleksibelAmt = round2(totalEpf * 0.10);
    if (existingRow != null) {
      await sb.from('epf_contributions').update({
        'contribution_date': sp['payment_date'], 'employee_contribution': sp['employee_epf_amount'],
        'employer_contribution': sp['employer_epf_amount'], 'persaraan_amount': persaraanAmt,
        'sejahtera_amount': sejahteraAmt, 'fleksibel_amount': fleksibelAmt,
      }).eq('id', existingRow['id']);
    } else {
      await sb.from('epf_contributions').insert({
        'user_id': sp['user_id'], 'salary_payment_id': paymentId, 'contribution_date': sp['payment_date'],
        'employee_contribution': sp['employee_epf_amount'], 'employer_contribution': sp['employer_epf_amount'],
        'persaraan_percent': 75.0, 'sejahtera_percent': 15.0, 'fleksibel_percent': 10.0,
        'persaraan_amount': persaraanAmt, 'sejahtera_amount': sejahteraAmt, 'fleksibel_amount': fleksibelAmt,
      });
    }
  } else if (existingRow != null) {
    await sb.from('epf_contributions').delete().eq('id', existingRow['id']);
  }

  await syncSimpleContribution('socso_contributions', sp, paymentId, sp['employee_socso_amount'], sp['employer_socso_amount']);
  await syncSimpleContribution('eis_contributions', sp, paymentId, sp['employee_eis_amount'], sp['employer_eis_amount']);
}

// SOCSO/EIS 供款记录不像 EPF 有 Akaun 三户口要拆分，就是单纯"员工供款 + 雇主供款"两个数字。
Future<void> syncSimpleContribution(String table, Map<String, dynamic> sp, String paymentId, dynamic employeeAmount, dynamic employerAmount) async {
  final total = asNum(employeeAmount) + asNum(employerAmount);
  final existingRow = await sb.from(table).select('id').eq('salary_payment_id', paymentId).maybeSingle();
  if (total > 0) {
    if (existingRow != null) {
      await sb.from(table).update({
        'contribution_date': sp['payment_date'], 'employee_contribution': employeeAmount, 'employer_contribution': employerAmount,
      }).eq('id', existingRow['id']);
    } else {
      await sb.from(table).insert({
        'user_id': sp['user_id'], 'salary_payment_id': paymentId, 'contribution_date': sp['payment_date'],
        'employee_contribution': employeeAmount, 'employer_contribution': employerAmount,
      });
    }
  } else if (existingRow != null) {
    await sb.from(table).delete().eq('id', existingRow['id']);
  }
}

Future<Map<String, dynamic>> autoGenerateDueSalaryPayments(String userId) async {
  final generated = <Map<String, dynamic>>[], skipped = <Map<String, dynamic>>[];
  final today = todayStr();
  final monthStart = '${today.substring(0, 7)}-01';
  final daysInMonth = DateTime.utc(int.parse(today.substring(0, 4)), int.parse(today.substring(5, 7)) + 1, 0).day;
  // 有些公司发薪日虽然是这个月，但按比例算基本薪资时是拿"上个月"的天数当分母，不是这个月的。
  final daysInPrevMonth = DateTime.utc(int.parse(today.substring(0, 4)), int.parse(today.substring(5, 7)), 0).day;
  final periodLabel = today.substring(0, 7);

  final profiles = await sb.from('salary_profiles').select('*')
      .eq('user_id', userId).eq('status', 'active').eq('salary_frequency', 'monthly').not('salary_payment_day', 'is', null);

  for (final p in profiles) {
    final paymentDay = (p['salary_payment_day'] as num).toInt().clamp(1, daysInMonth);
    final paymentDate = '${today.substring(0, 8)}${paymentDay.toString().padLeft(2, '0')}';
    if (paymentDate.compareTo(today) > 0) continue;
    if (p['bank_account_id'] == null) { skipped.add({'company_name': p['company_name'], 'reason': '没有设置"入账账户"'}); continue; }
    if (p['end_date'] != null && (p['end_date'] as String).compareTo(monthStart) < 0) continue;
    if (p['start_date'] != null && (p['start_date'] as String).compareTo(paymentDate) > 0) continue;

    final dup1 = await sb.from('salary_payments').select('id').eq('user_id', userId).eq('period_label', periodLabel).eq('salary_profile_id', p['id']).maybeSingle();
    if (dup1 != null) continue;
    final dup2 = await sb.from('salary_payments').select('id').eq('user_id', userId).eq('period_label', periodLabel)
        .isFilter('salary_profile_id', null).eq('bank_account_id', p['bank_account_id']).like('notes', '系统根据薪资档案自动生成%').maybeSingle();
    if (dup2 != null) continue;

    final monthEnd = DateTime.utc(int.parse(today.substring(0, 4)), int.parse(today.substring(5, 7)) + 1, 0).toIso8601String().substring(0, 10);
    final hasPartialStart = p['start_date'] != null && (p['start_date'] as String).compareTo(monthStart) > 0;
    final hasPartialEnd = p['end_date'] != null && (p['end_date'] as String).compareTo(monthEnd) < 0;
    final isFullMonth = !hasPartialStart && !hasPartialEnd;
    final periodStart = hasPartialStart ? p['start_date'] as String : monthStart;
    final periodEnd = hasPartialEnd ? p['end_date'] as String : paymentDate;

    num basicSalary = asNum(p['basic_salary']);
    if (!isFullMonth) {
      final daysWorked = daysBetween(periodStart, periodEnd) + 1;
      final proDivisor = p['prorate_basis'] == 'previous_month' ? daysInPrevMonth : daysInMonth;
      basicSalary = round2(basicSalary * daysWorked / proDivisor);
    }
    final enableEpf = p['enable_epf'] != false; // 旧资料没这个栏位时预设当作 true
    final enableSocso = p['enable_socso'] == true;
    final empPct = enableEpf ? asNum(p['employee_epf_percent']) : 0;
    final emprPct = enableEpf ? asNum(p['employer_epf_percent']) : 0;
    final empAmt = enableEpf ? round2(basicSalary * empPct / 100) : 0;
    final emprAmt = enableEpf ? round2(basicSalary * emprPct / 100) : 0;
    final empSocsoPct = enableSocso ? asNum(p['employee_socso_percent']) : 0;
    final emprSocsoPct = enableSocso ? asNum(p['employer_socso_percent']) : 0;
    final empSocsoAmt = enableSocso ? round2(basicSalary * empSocsoPct / 100) : 0;
    final emprSocsoAmt = enableSocso ? round2(basicSalary * emprSocsoPct / 100) : 0;
    final enableEis = p['enable_eis'] == true;
    final empEisPct = enableEis ? asNum(p['employee_eis_percent']) : 0;
    final emprEisPct = enableEis ? asNum(p['employer_eis_percent']) : 0;
    final empEisAmt = enableEis ? round2(basicSalary * empEisPct / 100) : 0;
    final emprEisAmt = enableEis ? round2(basicSalary * emprEisPct / 100) : 0;
    // SOCSO/EIS 员工那一份也是从实收里扣的，跟 EPF 员工那份一样会让到手的钱变少
    final netSalary = round2(basicSalary - empAmt - empSocsoAmt - empEisAmt);
    final notes = '系统根据薪资档案自动生成 (${DateTime.now().toIso8601String().substring(0, 16).replaceFirst('T', ' ')})。如这个月有花红/津贴等额外收入，可以编辑这笔补上。';

    final ins = await sb.from('salary_payments').insert({
      'user_id': userId, 'salary_profile_id': p['id'], 'payment_date': paymentDate, 'period_label': periodLabel,
      'period_start': isFullMonth ? null : periodStart, 'period_end': isFullMonth ? null : periodEnd,
      'basic_salary': basicSalary, 'employee_epf_percent': empPct, 'employee_epf_amount': empAmt,
      'employer_epf_percent': emprPct, 'employer_epf_amount': emprAmt,
      'employee_socso_percent': empSocsoPct, 'employee_socso_amount': empSocsoAmt,
      'employer_socso_percent': emprSocsoPct, 'employer_socso_amount': emprSocsoAmt,
      'employee_eis_percent': empEisPct, 'employee_eis_amount': empEisAmt,
      'employer_eis_percent': emprEisPct, 'employer_eis_amount': emprEisAmt,
      'net_salary': netSalary, 'bank_account_id': p['bank_account_id'], 'status': 'paid', 'notes': notes,
    }).select().single();
    await syncSalaryPayment(ins['id']);
    generated.add({'salary_payment_id': ins['id'], 'company_name': p['company_name'], 'period_label': periodLabel, 'net_salary': netSalary});
  }
  return {'generated': generated, 'skipped': skipped};
}

Future<Map<String, dynamic>> autoGenerateDueSubscriptions(String userId) async {
  final generated = <Map<String, dynamic>>[], skipped = <Map<String, dynamic>>[];
  final today = todayStr();
  final subs = await sb.from('subscriptions').select('*').eq('user_id', userId).eq('is_active', true);

  for (final s in subs) {
    String? due = s['next_billing_date'] ?? s['start_date'];
    if (due == null) continue;
    if (s['bank_account_id'] == null) {
      if (due.compareTo(today) <= 0) skipped.add({'name': s['name'], 'reason': '没有设置"自动扣款账户"'});
      continue;
    }
    final originalDue = due;
    var guard = 0;
    while (due!.compareTo(today) <= 0 && guard < 120) {
      await sb.from('transactions').insert({
        'user_id': userId, 'type': 'expense', 'amount': s['cost'], 'transaction_date': due,
        'bank_account_id': s['bank_account_id'], 'description': '订阅扣费: ${s['name']}', 'currency': 'MYR',
      });
      generated.add({'subscription_id': s['id'], 'name': s['name'], 'amount': asNum(s['cost']), 'date': due});
      due = s['billing_cycle'] == 'yearly' ? addMonths(due, 12) : addMonths(due, 1);
      guard++;
    }
    if (due != originalDue) {
      await sb.from('subscriptions').update({'next_billing_date': due}).eq('id', s['id']);
    }
  }
  return {'generated': generated, 'skipped': skipped};
}

Future<void> syncFixedDepositOpen(String fdId) async {
  final fd = await sb.from('fixed_deposits').select('*').eq('id', fdId).maybeSingle();
  if (fd == null || fd['source_account_id'] == null) return;
  final desc = '定存: 存入 (${fd['tenure_months']}个月, 到期 ${fd['maturity_date']})';
  final txn = await sb.from('transactions').insert({
    'user_id': fd['user_id'], 'type': 'expense', 'amount': fd['principal'], 'transaction_date': fd['start_date'],
    'bank_account_id': fd['source_account_id'], 'description': desc, 'currency': 'MYR',
  }).select().single();
  await sb.from('fixed_deposits').update({'opening_transaction_id': txn['id']}).eq('id', fdId);
}

// 编辑既有定存改了本金 (比如追加存入更多钱)，不该悄悄把当初开户那笔历史交易的金额改掉——
// 补一笔"差额"交易，日期算今天，反映"今天又多存了/取回了多少"这个新事实。
Future<void> syncFixedDepositPrincipalChange(String fdId, num previousPrincipal) async {
  final fd = await sb.from('fixed_deposits').select('*').eq('id', fdId).maybeSingle();
  if (fd == null || fd['source_account_id'] == null) return;
  final delta = round2(asNum(fd['principal']) - previousPrincipal);
  if (delta == 0) return;
  final today = todayStr();
  if (delta > 0) {
    await sb.from('transactions').insert({
      'user_id': fd['user_id'], 'type': 'expense', 'amount': delta, 'transaction_date': today,
      'bank_account_id': fd['source_account_id'],
      'description': '定存追加本金 (RM ${previousPrincipal.toStringAsFixed(2)} → RM ${asNum(fd['principal']).toStringAsFixed(2)})',
      'currency': 'MYR',
    });
  } else {
    await sb.from('transactions').insert({
      'user_id': fd['user_id'], 'type': 'income', 'amount': delta.abs(), 'transaction_date': today,
      'bank_account_id': fd['source_account_id'],
      'description': '定存减少本金退回账户 (RM ${previousPrincipal.toStringAsFixed(2)} → RM ${asNum(fd['principal']).toStringAsFixed(2)})',
      'currency': 'MYR',
    });
  }
}

Future<Map<String, dynamic>> autoGenerateDueFixedDeposits(String userId) async {
  final matured = <Map<String, dynamic>>[], skipped = <Map<String, dynamic>>[];
  final today = todayStr();
  final fds = await sb.from('fixed_deposits').select('*').eq('user_id', userId).eq('status', 'active');

  for (final fd in fds) {
    var current = Map<String, dynamic>.from(fd);
    var currentId = fd['id'] as String;
    var guard = 0;
    while (current['maturity_date'] != null && (current['maturity_date'] as String).compareTo(today) <= 0 && guard < 60) {
      final principal = asNum(current['principal']), rate = asNum(current['interest_rate']), months = asNum(current['tenure_months']);
      final interest = round2(principal * rate / 100 * months / 12);
      final maturityAmount = round2(principal + interest);

      if (current['maturity_action'] == 'renew') {
        final newStart = current['maturity_date'] as String;
        final newMaturity = addMonths(newStart, months.toInt());
        final ins = await sb.from('fixed_deposits').insert({
          'user_id': userId, 'bank_id': current['bank_id'], 'principal': maturityAmount, 'interest_rate': rate,
          'tenure_months': months, 'start_date': newStart, 'maturity_date': newMaturity,
          'maturity_action': current['maturity_action'], 'destination_account_id': current['destination_account_id'],
          'status': 'active', 'renewed_from_id': currentId,
        }).select().single();
        await sb.from('fixed_deposits').update({'status': 'matured'}).eq('id', currentId);
        matured.add({'id': currentId, 'action': 'renew', 'principal': principal, 'interest': interest, 'new_id': ins['id'], 'new_maturity_date': newMaturity});
        current = {
          'id': ins['id'], 'bank_id': current['bank_id'], 'principal': maturityAmount, 'interest_rate': rate,
          'tenure_months': months, 'start_date': newStart, 'maturity_date': newMaturity,
          'maturity_action': current['maturity_action'], 'destination_account_id': current['destination_account_id'],
        };
        currentId = ins['id'];
      } else {
        if (current['destination_account_id'] == null) { skipped.add({'id': currentId, 'reason': '没有设置"到期转入账户"'}); break; }
        final desc = '定存到期: 本金 RM ${principal.toStringAsFixed(2)} + 利息 RM ${interest.toStringAsFixed(2)}';
        await sb.from('transactions').insert({
          'user_id': userId, 'type': 'income', 'amount': maturityAmount, 'transaction_date': current['maturity_date'],
          'bank_account_id': current['destination_account_id'], 'description': desc, 'currency': 'MYR',
        });
        await sb.from('fixed_deposits').update({'status': 'matured'}).eq('id', currentId);
        matured.add({'id': currentId, 'action': 'transfer', 'principal': principal, 'interest': interest, 'total': maturityAmount});
        break;
      }
      guard++;
    }
  }
  return {'matured': matured, 'skipped': skipped};
}

Future<List<Map<String, dynamic>>> computeBankBalances(String userId, {String? asOfDate}) async {
  final accounts = await sb.from('bank_accounts').select('*').eq('user_id', userId).eq('is_active', true).order('id');
  final result = <Map<String, dynamic>>[];
  for (final a in accounts) {
    var txnQuery = sb.from('transactions').select('type,amount,bank_account_id,transfer_to_account_id').eq('user_id', userId);
    if (asOfDate != null) txnQuery = txnQuery.lte('transaction_date', asOfDate);
    final txns = await txnQuery;
    num income = 0, expense = 0, transferOut = 0, transferIn = 0;
    for (final t in txns) {
      final amt = asNum(t['amount']);
      if (t['type'] == 'income' && t['bank_account_id'] == a['id']) income += amt;
      else if (t['type'] == 'expense' && t['bank_account_id'] == a['id']) expense += amt;
      else if (t['type'] == 'transfer' && t['bank_account_id'] == a['id']) transferOut += amt;
      else if (t['type'] == 'transfer' && t['transfer_to_account_id'] == a['id']) transferIn += amt;
    }
    final currentBalance = round2(asNum(a['opening_balance']) + income - expense - transferOut + transferIn);
    final acctNum = a['account_number']?.toString();
    result.add({
      ...a, 'current_balance': currentBalance,
      'account_number_masked': (acctNum != null && acctNum.isNotEmpty) ? '**** ${acctNum.substring(acctNum.length - 4)}' : null,
    });
  }
  return result;
}

Future<Map<String, dynamic>> buildDashboard(String userId) async {
  final today = todayStr();
  final out = <String, dynamic>{'ok': true, 'date': today};

  final salaryAuto = await autoGenerateDueSalaryPayments(userId);
  out['auto_generated_salary'] = salaryAuto['generated'];
  out['auto_generate_skipped_salary'] = salaryAuto['skipped'];
  final subAuto = await autoGenerateDueSubscriptions(userId);
  out['auto_generated_subscriptions'] = subAuto['generated'];
  out['auto_generate_skipped_subscriptions'] = subAuto['skipped'];
  final fdAuto = await autoGenerateDueFixedDeposits(userId);
  out['auto_matured_fixed_deposits'] = fdAuto['matured'];
  out['auto_generate_skipped_fixed_deposits'] = fdAuto['skipped'];

  // 状态只有 todo/done 两种，仪表盘显示全部未完成任务。
  out['tasks_today'] = await sb.from('tasks').select('*').eq('user_id', userId).eq('status', 'todo').order('priority', ascending: false).order('id', ascending: false);

  final habits = await sb.from('habits').select('*').eq('user_id', userId).eq('is_active', true).order('id');
  final logs = await sb.from('habit_logs').select('habit_id,completed').eq('user_id', userId).eq('log_date', today);
  final logMap = <String, bool>{};
  for (final l in logs) logMap[l['habit_id'].toString()] = l['completed'] == true;
  out['habits'] = habits.map((h) => {...h, 'checked_today': logMap[h['id'].toString()] ?? false}).toList();

  out['journal_today'] = await sb.from('journal_entries').select('*').eq('user_id', userId).eq('entry_date', today).maybeSingle();

  final txnsToday = await sb.from('transactions').select('*').eq('user_id', userId).eq('transaction_date', today).order('id', ascending: false);
  out['transactions_today'] = txnsToday;
  out['income_today'] = txnsToday.where((r) => r['type'] == 'income').fold<num>(0, (s, r) => s + asNum(r['amount']));
  out['expense_today'] = txnsToday.where((r) => r['type'] == 'expense').fold<num>(0, (s, r) => s + asNum(r['amount']));

  final bankAccounts = await computeBankBalances(userId);
  out['bank_accounts'] = bankAccounts;
  out['total_balance'] = bankAccounts.fold<num>(0, (s, a) => s + asNum(a['current_balance']));

  final fdAgg = await sb.from('fixed_deposits').select('principal').eq('user_id', userId).eq('status', 'active');
  out['fixed_deposits_total'] = fdAgg.fold<num>(0, (s, r) => s + asNum(r['principal']));
  out['fixed_deposits_count'] = fdAgg.length;

  final monthStart = '${today.substring(0, 7)}-01';
  final monthEnd = DateTime.utc(int.parse(today.substring(0, 4)), int.parse(today.substring(5, 7)) + 1, 0).toIso8601String().substring(0, 10);
  final monthRows = await sb.from('transactions').select('*').eq('user_id', userId).gte('transaction_date', monthStart).lte('transaction_date', monthEnd);
  num monthIncome = 0, monthExpense = 0;
  final categoryTotals = <String, num>{};
  for (final r in monthRows) {
    if (r['type'] == 'income') monthIncome += asNum(r['amount']);
    else if (r['type'] == 'expense') {
      monthExpense += asNum(r['amount']);
      final cid = r['category_id']?.toString() ?? 'none';
      categoryTotals[cid] = (categoryTotals[cid] ?? 0) + asNum(r['amount']);
    }
  }
  out['month_income'] = monthIncome;
  out['month_expense'] = monthExpense;

  final categories = await sb.from('categories').select('*').eq('user_id', userId);
  final categoryById = {for (final c in categories) c['id'].toString(): c};
  final breakdown = categoryTotals.entries.map((e) {
    final cat = categoryById[e.key];
    return {'label': cat != null ? cat['name'] : '未分类', 'color': cat != null ? cat['color'] : '#9CA3AF', 'amount': round2(e.value)};
  }).toList()
    ..sort((a, b) => (b['amount'] as num).compareTo(a['amount'] as num));
  out['category_breakdown'] = breakdown;

  final recentRows = await sb.from('transactions').select('*').eq('user_id', userId).order('transaction_date', ascending: false).order('id', ascending: false).limit(5);
  out['recent_transactions'] = recentRows.map((r) {
    final cat = categoryById[r['category_id']?.toString()];
    return {...r, 'category_label': cat != null ? cat['name'] : '未分类', 'category_icon': cat != null ? cat['icon'] : '💳'};
  }).toList();

  final activeProfiles = await sb.from('salary_profiles').select('*').eq('user_id', userId).eq('status', 'active').eq('salary_frequency', 'monthly');
  out['expected_monthly_salary'] = activeProfiles.fold<num>(0, (s, p) => s + asNum(p['basic_salary']));

  final paidRows = await sb.from('salary_payments').select('net_salary').eq('user_id', userId).eq('status', 'paid').gte('payment_date', monthStart).lte('payment_date', monthEnd);
  out['actual_monthly_salary'] = paidRows.fold<num>(0, (s, r) => s + asNum(r['net_salary']));

  final epfRows = await sb.from('epf_contributions').select('employee_contribution,employer_contribution,additional_contribution,persaraan_amount,sejahtera_amount,fleksibel_amount').eq('user_id', userId);
  num epfEmp = 0, epfEmpr = 0, epfAdd = 0, epfPersaraan = 0, epfSejahtera = 0, epfFleksibel = 0;
  for (final r in epfRows) {
    epfEmp += asNum(r['employee_contribution']); epfEmpr += asNum(r['employer_contribution']); epfAdd += asNum(r['additional_contribution']);
    epfPersaraan += asNum(r['persaraan_amount']); epfSejahtera += asNum(r['sejahtera_amount']); epfFleksibel += asNum(r['fleksibel_amount']);
  }
  out['epf_cumulative'] = {
    'employee': epfEmp, 'employer': epfEmpr, 'additional': epfAdd, 'total': epfEmp + epfEmpr + epfAdd,
    'persaraan': epfPersaraan, 'sejahtera': epfSejahtera, 'fleksibel': epfFleksibel,
  };

  final socsoRows = await sb.from('socso_contributions').select('employee_contribution,employer_contribution').eq('user_id', userId);
  num socsoEmp = 0, socsoEmpr = 0;
  for (final r in socsoRows) { socsoEmp += asNum(r['employee_contribution']); socsoEmpr += asNum(r['employer_contribution']); }
  out['socso_cumulative'] = {'employee': socsoEmp, 'employer': socsoEmpr, 'total': socsoEmp + socsoEmpr};

  final eisRows = await sb.from('eis_contributions').select('employee_contribution,employer_contribution').eq('user_id', userId);
  num eisEmp = 0, eisEmpr = 0;
  for (final r in eisRows) { eisEmp += asNum(r['employee_contribution']); eisEmpr += asNum(r['employer_contribution']); }
  out['eis_cumulative'] = {'employee': eisEmp, 'employer': eisEmpr, 'total': eisEmp + eisEmpr};

  out['metric_today'] = await sb.from('daily_metrics').select('*').eq('user_id', userId).eq('metric_date', today).maybeSingle();
  out['inbox_unprocessed'] = await sb.from('inbox_items').select('*').eq('user_id', userId).eq('is_processed', false).order('id', ascending: false).limit(10);

  final subsActive = await sb.from('subscriptions').select('*').eq('user_id', userId).eq('is_active', true).not('next_billing_date', 'is', null);
  final upcomingSubs = <Map<String, dynamic>>[];
  for (final s in subsActive) {
    final daysUntil = daysBetween(today, s['next_billing_date']);
    if (daysUntil >= 0 && daysUntil <= (s['remind_days_before'] as num)) upcomingSubs.add({...s, 'days_until': daysUntil});
  }
  upcomingSubs.sort((a, b) => (a['days_until'] as int).compareTo(b['days_until'] as int));
  out['upcoming_subscriptions'] = upcomingSubs;

  final contacts = await sb.from('contacts').select('*').eq('user_id', userId).not('birthday', 'is', null);
  final upcomingBirthdays = <Map<String, dynamic>>[];
  final todayYear = int.parse(today.substring(0, 4));
  for (final c in contacts) {
    final bday = c['birthday'] as String;
    var next = '$todayYear-${bday.substring(5, 10)}';
    if (next.compareTo(today) < 0) next = '${todayYear + 1}-${bday.substring(5, 10)}';
    final daysUntil = daysBetween(today, next);
    if (daysUntil >= 0 && daysUntil <= (c['remind_days_before'] as num)) upcomingBirthdays.add({...c, 'days_until': daysUntil});
  }
  upcomingBirthdays.sort((a, b) => (a['days_until'] as int).compareTo(b['days_until'] as int));
  out['upcoming_birthdays'] = upcomingBirthdays;

  return out;
}

// ---------------- 提醒事项 ----------------

String nextReminderTime(String fromDateTime, String rule, num? interval, String? unit) {
  var d = DateTime.parse(fromDateTime.replaceFirst(' ', 'T'));
  switch (rule) {
    case 'daily': d = d.add(const Duration(days: 1)); break;
    case 'weekly': d = d.add(const Duration(days: 7)); break;
    case 'biweekly': d = d.add(const Duration(days: 14)); break;
    case 'monthly': d = DateTime.utc(d.year, d.month + 1, d.day, d.hour, d.minute, d.second); break;
    case 'yearly': d = DateTime.utc(d.year + 1, d.month, d.day, d.hour, d.minute, d.second); break;
    case 'custom':
      final n = (interval ?? 1).toInt().clamp(1, 999999);
      if (unit == 'week') d = d.add(Duration(days: 7 * n));
      else if (unit == 'month') d = DateTime.utc(d.year, d.month + n, d.day, d.hour, d.minute, d.second);
      else if (unit == 'year') d = DateTime.utc(d.year + n, d.month, d.day, d.hour, d.minute, d.second);
      else d = d.add(Duration(days: n));
      break;
    default: break;
  }
  return d.toIso8601String().substring(0, 19).replaceFirst('T', ' ');
}

Future<void> maybeAdvanceRecurringReminder(String id) async {
  final r = await sb.from('reminders').select('*').eq('id', id).maybeSingle();
  if (r == null || r['is_sent'] != true) return;
  if (r['repeat_rule'] == null || r['repeat_rule'] == 'none') return;
  final next = nextReminderTime(r['remind_at'], r['repeat_rule'], r['repeat_interval'] as num?, r['repeat_unit'] as String?);
  await sb.from('reminders').update({'remind_at': next, 'is_sent': false}).eq('id', id);
}

Future<void> advanceDueReminders(String userId) async {
  final now = DateTime.now().toUtc().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
  final rows = await sb.from('reminders').select('*').eq('user_id', userId).not('repeat_rule', 'is', null).neq('repeat_rule', 'none').eq('is_sent', false).lte('remind_at', now);
  for (final r in rows) {
    var next = r['remind_at'] as String;
    var guard = 0;
    while (next.compareTo(now) <= 0 && guard < 1000) {
      next = nextReminderTime(next, r['repeat_rule'], r['repeat_interval'] as num?, r['repeat_unit'] as String?);
      guard++;
    }
    if (next != r['remind_at']) await sb.from('reminders').update({'remind_at': next}).eq('id', r['id']);
  }
}

// 字串一定要带 +08:00，不然 Postgres 会当 UTC 存，提醒会晚 8 小时才触发。
// "今天过了没"也要用同样明确带时区的方式比，不能直接拿本地时钟数字跟 UTC 的 now 比。
Future<Map<String, dynamic>> applyReminderTimeRule(String resource, String action, String? id, Map<String, dynamic> data) async {
  final remindAt = data['remind_at']?.toString() ?? '';
  if (resource != 'reminders' || !RegExp(r'^\d{2}:\d{2}$').hasMatch(remindAt)) return data;
  final time = remindAt;
  String datePart;
  if (action == 'update') {
    final ex = await sb.from('reminders').select('remind_at').eq('id', id as Object).maybeSingle();
    datePart = ex != null ? (ex['remind_at'] as String).substring(0, 10) : todayStr();
  } else {
    datePart = todayStr();
    final candidate = DateTime.parse('${datePart}T$time:00+08:00');
    if (!candidate.isAfter(DateTime.now())) datePart = addDays(datePart, 1);
  }
  return {...data, 'remind_at': '$datePart $time:00+08:00'};
}

// ---------------- 搜索 / 报表 / 导出 ----------------

final Map<String, Map<String, dynamic>> _searchTargets = {
  'transactions': {'cols': ['description'], 'title': (r) => r['description'] ?? '（无说明）', 'sub': (r) => 'RM ${asNum(r['amount']).toStringAsFixed(2)} · ${r['transaction_date']}'},
  'salary_payments': {'cols': ['period_label', 'notes'], 'title': (r) => r['period_label'], 'sub': (r) => 'RM ${asNum(r['net_salary']).toStringAsFixed(2)} · ${r['payment_date']}'},
  'tasks': {'cols': ['title', 'description'], 'title': (r) => r['title'], 'sub': (r) => r['status'] ?? ''},
  'projects': {'cols': ['name', 'description'], 'title': (r) => r['name'], 'sub': (r) => r['status'] ?? ''},
  'contacts': {'cols': ['name', 'notes'], 'title': (r) => r['name'], 'sub': (r) => r['phone'] ?? ''},
  'bookmarks': {'cols': ['title', 'url'], 'title': (r) => r['title'] ?? r['url'], 'sub': (r) => r['url']},
  'journal_entries': {'cols': ['content'], 'title': (r) => r['entry_date'], 'sub': (r) => ((r['content'] ?? '') as String).substring(0, ((r['content'] ?? '') as String).length > 40 ? 40 : ((r['content'] ?? '') as String).length)},
  'subscriptions': {'cols': ['name', 'notes'], 'title': (r) => r['name'], 'sub': (r) => 'RM ${asNum(r['cost']).toStringAsFixed(2)}'},
  'reminders': {'cols': ['message'], 'title': (r) => r['message'], 'sub': (r) => r['remind_at'] ?? ''},
};

Future<Map<String, dynamic>> runSearch(String q) async {
  q = q.trim();
  if (q.isEmpty) return {'ok': true, 'results': []};
  final config = await loadMetaConfig();
  final results = <Map<String, dynamic>>[];
  for (final entry in _searchTargets.entries) {
    final tbl = entry.key;
    final spec = entry.value;
    final cols = (spec['cols'] as List).cast<String>();
    final orExpr = cols.map((c) => '$c.ilike.%$q%').join(',');
    final rows = await sb.from(tbl).select('*').or(orExpr).order('id', ascending: false).limit(8);
    final cfg = (config[tbl] as Map<String, dynamic>?) ?? {};
    for (final row in rows) {
      results.add({
        'resource': tbl, 'resource_label': cfg['label'] ?? tbl, 'icon': cfg['icon'] ?? '📄',
        'id': row['id'], 'title': (spec['title'] as Function)(row).toString(), 'sub': (spec['sub'] as Function)(row).toString(),
      });
    }
  }
  return {'ok': true, 'results': results};
}

Future<Map<String, dynamic>> generateReport(String reportType, String periodStart, String periodEnd) async {
  final userId = sb.auth.currentSession!.user.id;
  final content = <String, dynamic>{'period_start': periodStart, 'period_end': periodEnd};

  final rows = await sb.from('transactions').select('*').eq('user_id', userId).gte('transaction_date', periodStart).lte('transaction_date', periodEnd);
  final categories = await sb.from('categories').select('*').eq('user_id', userId);
  final categoryById = {for (final c in categories) c['id'].toString(): c};

  num income = 0, expense = 0;
  final categoryTotals = <String, num>{};
  for (final r in rows) {
    if (r['type'] == 'income') income += asNum(r['amount']);
    else if (r['type'] == 'expense') {
      expense += asNum(r['amount']);
      final cid = r['category_id']?.toString() ?? 'none';
      categoryTotals[cid] = (categoryTotals[cid] ?? 0) + asNum(r['amount']);
    }
  }
  content['income_total'] = round2(income);
  content['expense_total'] = round2(expense);
  content['net'] = round2(income - expense);
  content['category_breakdown'] = categoryTotals.entries.map((e) {
    final cat = categoryById[e.key];
    return {'label': cat != null ? cat['name'] : '未分类', 'color': cat != null ? cat['color'] : '#9CA3AF', 'amount': round2(e.value)};
  }).toList()
    ..sort((a, b) => (b['amount'] as num).compareTo(a['amount'] as num));

  final expenseRows = rows.where((r) => r['type'] == 'expense').toList()..sort((a, b) => asNum(b['amount']).compareTo(asNum(a['amount'])));
  content['top_expenses'] = expenseRows.take(5).map((r) {
    final cat = categoryById[r['category_id']?.toString()];
    return {'description': r['description'] ?? (cat != null ? cat['name'] : '未分类'), 'amount': asNum(r['amount']), 'date': r['transaction_date'], 'category_label': cat != null ? cat['name'] : '未分类'};
  }).toList();

  final paidRows = await sb.from('salary_payments').select('net_salary').eq('user_id', userId).eq('status', 'paid').gte('payment_date', periodStart).lte('payment_date', periodEnd);
  content['salary_received'] = paidRows.fold<num>(0, (s, r) => s + asNum(r['net_salary']));

  final epfRows = await sb.from('epf_contributions').select('employee_contribution,employer_contribution,additional_contribution').eq('user_id', userId).gte('contribution_date', periodStart).lte('contribution_date', periodEnd);
  num epfE = 0, epfR = 0, epfA = 0;
  for (final r in epfRows) { epfE += asNum(r['employee_contribution']); epfR += asNum(r['employer_contribution']); epfA += asNum(r['additional_contribution']); }
  content['epf_contributed'] = {'employee': epfE, 'employer': epfR, 'additional': epfA};

  var subCount = 0; num subTotal = 0;
  for (final r in rows) {
    if (r['type'] == 'expense' && ((r['description'] ?? '') as String).startsWith('订阅扣费: ')) { subCount++; subTotal += asNum(r['amount']); }
  }
  content['subscriptions_charged'] = {'count': subCount, 'total': round2(subTotal)};

  final accountBalances = await computeBankBalances(userId, asOfDate: periodEnd);
  content['account_balances'] = accountBalances.map((a) => {'nickname': a['nickname'], 'kind': a['account_kind'], 'balance': a['current_balance']}).toList();
  content['total_balance_at_period_end'] = round2(accountBalances.fold<num>(0, (s, a) => s + asNum(a['current_balance'])));

  final habitLogs = await sb.from('habit_logs').select('habit_id, habits(name)').eq('user_id', userId).eq('completed', true).gte('log_date', periodStart).lte('log_date', periodEnd);
  final habitCounts = <String, int>{};
  for (final l in habitLogs) {
    final name = (l['habits'] != null ? l['habits']['name'] : null) ?? '未知习惯';
    habitCounts[name] = (habitCounts[name] ?? 0) + 1;
  }
  content['habit_checkins'] = habitCounts.entries.map((e) => {'name': e.key, 'cnt': e.value}).toList()..sort((a, b) => (b['cnt'] as int).compareTo(a['cnt'] as int));

  final journalRows = await sb.from('journal_entries').select('id').eq('user_id', userId).gte('entry_date', periodStart).lte('entry_date', periodEnd);
  content['journal_entry_count'] = journalRows.length;

  final existing = await sb.from('reports').select('id').eq('user_id', userId).eq('report_type', reportType).eq('period_start', periodStart).eq('period_end', periodEnd).maybeSingle();
  String id;
  if (existing != null) {
    await sb.from('reports').update({'content': content, 'generated_at': DateTime.now().toIso8601String()}).eq('id', existing['id']);
    id = existing['id'];
  } else {
    final ins = await sb.from('reports').insert({'user_id': userId, 'report_type': reportType, 'period_start': periodStart, 'period_end': periodEnd, 'content': content}).select().single();
    id = ins['id'];
  }
  return {'ok': true, 'id': id, 'report_type': reportType, 'content': content};
}

Future<Map<String, dynamic>> exportMySql() async {
  final config = await loadMetaConfig();
  final userId = sb.auth.currentSession!.user.id;
  final buf = StringBuffer('-- personal_os 我的数据导出 (${DateTime.now().toIso8601String()})，仅包含当前账号自己的数据\n\n');
  for (final entry in config.entries) {
    final cfg = entry.value as Map<String, dynamic>;
    if (cfg['user_scoped'] != true) continue;
    final rows = await sb.from(entry.key).select('*').eq('user_id', userId);
    if (rows.isEmpty) continue;
    for (final row in rows) {
      final cols = row.keys.toList();
      final vals = cols.map((c) {
        final v = row[c];
        if (v == null) return 'NULL';
        if (v is bool) return v ? 'true' : 'false';
        if (v is Map || v is List) return "'${jsonEncode(v).replaceAll("'", "''")}'";
        return "'${v.toString().replaceAll("'", "''")}'";
      }).join(',');
      buf.write('INSERT INTO ${entry.key} (${cols.join(',')}) VALUES ($vals);\n');
    }
    buf.write('\n');
  }
  return {'ok': true, 'sql': buf.toString(), 'filename': 'personal_os_mydata_${todayStr().replaceAll('-', '')}.sql'};
}

Future<Map<String, dynamic>> adminExportFullSql() async {
  final data = await sb.rpc('admin_export_full_sql');
  final sql = data is String ? data : (data?.toString() ?? '');
  if (sql.isEmpty) throw Exception('备份是空的，请稍后再试');
  return {'ok': true, 'sql': sql, 'filename': 'personal_os_full_backup_${todayStr().replaceAll('-', '')}.sql'};
}

Future<Map<String, dynamic>> exportCsv(String resource, dynamic filters) async {
  final config = await loadMetaConfig();
  final fields = (config[resource] as Map<String, dynamic>)['fields'] as Map<String, dynamic>;
  var query = sb.from(resource).select('*');
  query = applyFilters(query, filters);
  final rows = await query.order('id', ascending: false).limit(5000);

  final fkMaps = <String, Map<String, dynamic>>{};
  for (final entry in fields.entries) {
    final meta = entry.value as Map<String, dynamic>;
    if (meta['type'] != 'fk') continue;
    final fkTable = meta['fk_resource'] as String;
    final fkDisplay = ((config[fkTable] as Map<String, dynamic>?) ?? {})['display_field'] ?? 'id';
    final fkRows = await sb.from(fkTable).select('id, $fkDisplay');
    fkMaps[entry.key] = {for (final r in fkRows) r['id'].toString(): r[fkDisplay]};
  }

  String csvLine(List<dynamic> values) => values.map((v) => '"${(v ?? '').toString().replaceAll('"', '""')}"').join(',');
  final columns = fields.keys.toList();
  final lines = [csvLine(columns.map((c) => (fields[c] as Map<String, dynamic>)['label']).toList())];
  for (final row in rows) {
    lines.add(csvLine(columns.map((c) {
      var v = row[c];
      if (fkMaps[c] != null && v != null && v != '') v = fkMaps[c]![v.toString()] ?? v;
      return v;
    }).toList()));
  }
  return {'ok': true, 'csv': lines.join('\n'), 'filename': '${resource}_${todayStr().replaceAll('-', '')}.csv'};
}
