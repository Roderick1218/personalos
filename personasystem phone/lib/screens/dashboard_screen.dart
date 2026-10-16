import 'package:flutter/material.dart';
import '../api_service.dart';
import '../theme.dart';
import '../step_service.dart';
import 'resource_list_screen.dart';

const Map<String, Color> _kPriorityColor = {
  'urgent': AppColors.priorityUrgent,
  'high': AppColors.priorityHigh,
  'medium': AppColors.priorityMedium,
  'low': AppColors.priorityLow,
};
const Map<String, String> _kPriorityLabel = {
  'urgent': '紧急', 'high': '高', 'medium': '中', 'low': '低',
};

/// 今日仪表盘，字段照网站端 build_dashboard() 实际回传的全部补齐，排版照手机重新设计：
/// 单列纵向卡片，数字优先，图表用简单的横向比例条，最急的东西 (今天的任务) 放最上面。
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await ApiService.dashboard();
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _toggleHabit(String habitId, bool checked) async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    await ApiService.create('habit_logs', {
      'habit_id': habitId,
      'log_date': today,
      'completed': checked,
    });
    reload();
  }

  Future<void> _completeTask(String taskId) async {
    await ApiService.update('tasks', taskId, {'status': 'done'});
    reload();
  }

  Future<void> _quickAddTask(String title) async {
    if (title.trim().isEmpty) return;
    await ApiService.create('tasks', {'title': title.trim(), 'status': 'todo', 'priority': 'medium'});
    reload();
  }

  Widget _skeleton() {
    Widget box(double height) => Container(
          height: height,
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
        );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [box(90), box(90), box(90), box(160), box(120)],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return _skeleton();
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('加载失败: $_error', textAlign: TextAlign.center),
        ),
      );
    }
    final d = _data!;
    final habits = d['habits'] as List<dynamic>;
    final tasks = d['tasks_today'] as List<dynamic>;
    final metric = d['metric_today'] as Map<String, dynamic>?;
    final journal = d['journal_today'] as Map<String, dynamic>?;
    final journalTodayCount = (d['journal_today_count'] as num?)?.toInt() ?? 0;
    final upcomingSubs = d['upcoming_subscriptions'] as List<dynamic>? ?? [];
    final upcomingBirthdays = d['upcoming_birthdays'] as List<dynamic>? ?? [];
    final bankAccounts = d['bank_accounts'] as List<dynamic>? ?? [];
    final categoryBreakdown = d['category_breakdown'] as List<dynamic>? ?? [];
    final recentTxns = d['recent_transactions'] as List<dynamic>? ?? [];
    final epf = d['epf_cumulative'] as Map<String, dynamic>? ?? {};
    final socso = d['socso_cumulative'] as Map<String, dynamic>? ?? {};
    final eis = d['eis_cumulative'] as Map<String, dynamic>? ?? {};
    final totalBalance = (d['total_balance'] as num?)?.toDouble() ?? 0;
    final fdTotal = (d['fixed_deposits_total'] as num?)?.toDouble() ?? 0;
    final fdCount = (d['fixed_deposits_count'] as num?)?.toInt() ?? 0;
    final monthIncome = (d['month_income'] as num?)?.toDouble() ?? 0;
    final monthExpense = (d['month_expense'] as num?)?.toDouble() ?? 0;
    final expectedSalary = (d['expected_monthly_salary'] as num?)?.toDouble() ?? 0;
    final actualSalary = (d['actual_monthly_salary'] as num?)?.toDouble() ?? 0;

    final autoSalary = d['auto_generated_salary'] as List<dynamic>? ?? [];
    final skippedSalary = d['auto_generate_skipped_salary'] as List<dynamic>? ?? [];
    final autoSubs = d['auto_generated_subscriptions'] as List<dynamic>? ?? [];
    final skippedSubs = d['auto_generate_skipped_subscriptions'] as List<dynamic>? ?? [];
    final maturedFds = d['auto_matured_fixed_deposits'] as List<dynamic>? ?? [];
    final skippedFds = d['auto_generate_skipped_fixed_deposits'] as List<dynamic>? ?? [];

    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '今日仪表盘 · ${d['date']}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.text),
          ),
          const SizedBox(height: 12),

          if (autoSalary.isNotEmpty)
            _noticeBanner(
              success: true,
              text: '✅ 已自动生成 ${autoSalary.map((g) => '「${g['company_name']}」${g['period_label']} 发薪 RM ${(g['net_salary'] as num).toStringAsFixed(2)}').join('、')}',
            ),
          if (skippedSalary.isNotEmpty)
            _noticeBanner(
              success: false,
              text: '⚠ ${skippedSalary.map((s) => '「${s['company_name']}」发薪日已到但${s['reason']}').join('；')}，去"薪资档案"补上',
            ),
          if (autoSubs.isNotEmpty)
            _noticeBanner(
              success: true,
              text: '✅ 已自动生成 ${autoSubs.map((g) => '「${g['name']}」${g['date']} 扣费 RM ${(g['amount'] as num).toStringAsFixed(2)}').join('、')}',
            ),
          if (skippedSubs.isNotEmpty)
            _noticeBanner(
              success: false,
              text: '⚠ ${skippedSubs.map((s) => '「${s['name']}」已到期但${s['reason']}').join('；')}，去"订阅管理"补上',
            ),
          if (maturedFds.isNotEmpty)
            _noticeBanner(
              success: true,
              text: '✅ ${maturedFds.map((m) => m['action'] == 'renew' ? '一笔定存已自动展期' : '一笔定存到期，已存入 RM ${(m['total'] as num).toStringAsFixed(2)}').join('；')}',
            ),
          if (skippedFds.isNotEmpty)
            _noticeBanner(success: false, text: '⚠ 有 ${skippedFds.length} 笔定存到期但没设置转入账户，去"定期存款"补上'),

          // 总览统计: 2x2 网格 (手机上比网站那种一整排 4 张卡更好排)
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.5,
            children: [
              _statCard('💰 总余额', 'RM ${totalBalance.toStringAsFixed(2)}',
                  foot: fdCount > 0 ? '另有定存 RM ${fdTotal.toStringAsFixed(2)} ($fdCount笔)' : '${bankAccounts.length} 个账户'),
              _statCard('🛍️ 今日支出', 'RM ${(d['expense_today'] as num).toStringAsFixed(2)}', color: AppColors.danger),
              _statCard('📈 今日收入', 'RM ${(d['income_today'] as num).toStringAsFixed(2)}', color: AppColors.success),
              _statCard('📊 本月结余', 'RM ${(monthIncome - monthExpense).toStringAsFixed(2)}',
                  foot: '收入 ${monthIncome.toStringAsFixed(0)} · 支出 ${monthExpense.toStringAsFixed(0)}',
                  color: (monthIncome - monthExpense) >= 0 ? AppColors.success : AppColors.danger),
            ],
          ),
          const SizedBox(height: 16),

          if (bankAccounts.isNotEmpty)
            _tintCard('🏦 资产分布', AppColors.surface, [_barsFromList(bankAccounts, 'nickname', 'current_balance')]),

          if (categoryBreakdown.isNotEmpty)
            _tintCard('📊 支出分类占比 (本月)', AppColors.surface, [_barsFromBreakdown(categoryBreakdown)]),

          if (expectedSalary > 0 || actualSalary > 0)
            _tintCard('💼 本月薪资', AppColors.surface, [
              Text('实际已收到: RM ${actualSalary.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.text)),
              Text('预期 (在职月薪档案): RM ${expectedSalary.toStringAsFixed(2)}', style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
            ]),

          if ((epf['total'] as num? ?? 0) > 0)
            _tintCard('🏦 EPF 累计供款', AppColors.surface, [
              Text('RM ${(epf['total'] as num).toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.text)),
              Text('员工 RM ${((epf['employee'] as num?) ?? 0).toStringAsFixed(2)} · 雇主 RM ${((epf['employer'] as num?) ?? 0).toStringAsFixed(2)} · 自愿 RM ${((epf['additional'] as num?) ?? 0).toStringAsFixed(2)}',
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(height: 10),
              _barsFromMap({
                'Akaun Persaraan': (epf['persaraan'] as num?) ?? 0,
                'Akaun Sejahtera': (epf['sejahtera'] as num?) ?? 0,
                'Akaun Fleksibel': (epf['fleksibel'] as num?) ?? 0,
              }),
            ]),

          if ((socso['total'] as num? ?? 0) > 0)
            _tintCard('🛡️ SOCSO 累计供款', AppColors.surface, [
              Text('RM ${(socso['total'] as num).toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.text)),
              Text('员工 RM ${((socso['employee'] as num?) ?? 0).toStringAsFixed(2)} · 雇主 RM ${((socso['employer'] as num?) ?? 0).toStringAsFixed(2)}',
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
            ]),

          if ((eis['total'] as num? ?? 0) > 0)
            _tintCard('🆘 EIS 累计供款', AppColors.surface, [
              Text('RM ${(eis['total'] as num).toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.text)),
              Text('员工 RM ${((eis['employee'] as num?) ?? 0).toStringAsFixed(2)} · 雇主 RM ${((eis['employer'] as num?) ?? 0).toStringAsFixed(2)}',
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
            ]),

          if (recentTxns.isNotEmpty)
            _tintCard(
              '💳 最近交易',
              AppColors.surface,
              recentTxns.map<Widget>((t) {
                final type = t['type'] as String;
                final color = type == 'income' ? AppColors.success : (type == 'expense' ? AppColors.danger : AppColors.textMuted);
                final sign = type == 'income' ? '+' : (type == 'expense' ? '-' : '');
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Text(t['category_icon']?.toString() ?? '💳', style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text((t['description'] ?? t['category_label'] ?? '').toString(), overflow: TextOverflow.ellipsis),
                            Text('${t['category_label']} · ${t['transaction_date']}', style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
                          ],
                        ),
                      ),
                      Text('$sign RM ${(t['amount'] as num).toStringAsFixed(2)}', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
                    ],
                  ),
                );
              }).toList(),
            ),

          _tintCard(
            '✅ 待办任务',
            AppColors.surface,
            [
              if (tasks.isEmpty)
                const Text('没有待办任务', style: TextStyle(color: AppColors.textMuted))
              else
                ...tasks.map<Widget>((t) {
                  final color = _kPriorityColor[t['priority']] ?? AppColors.textMuted;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(border: Border(left: BorderSide(color: color, width: 4))),
                    child: ListTile(
                      contentPadding: const EdgeInsets.only(left: 10),
                      title: Text(t['title'].toString()),
                      subtitle: Text(
                        _kPriorityLabel[t['priority']] ?? t['priority'].toString(),
                        style: TextStyle(color: color, fontWeight: FontWeight.w600),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.check_circle_outline),
                        onPressed: () => _completeTask(t['id'].toString()),
                      ),
                    ),
                  );
                }),
            ],
            onAdd: (v) => _quickAddTask(v),
            addHint: '输入任务标题，回车快速添加',
          ),
          _tintCard(
            '🔁 习惯打卡',
            AppColors.surface,
            habits.isEmpty
                ? [const Text('还没有习惯', style: TextStyle(color: AppColors.textMuted))]
                : habits.map<Widget>((h) => CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: h['checked_today'] == true,
                      title: Text(h['name'].toString()),
                      subtitle: Text(h['frequency'] == 'daily' ? '每天' : h['frequency'] == 'weekly' ? '每周' : '自定义'),
                      onChanged: (v) => _toggleHabit(h['id'].toString(), v ?? false),
                    )).toList(),
          ),
          _tintCard(
            '❤️ 今日健康',
            AppColors.surface,
            [
              StreamBuilder<int?>(
                stream: StepService.todayStepsStream,
                initialData: StepService.todaySteps,
                builder: (context, snapshot) {
                  final steps = snapshot.data ?? metric?['steps'];
                  if (steps == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('🚶 今日步数: $steps', style: const TextStyle(fontWeight: FontWeight.bold)),
                  );
                },
              ),
              if (metric == null)
                const Text('今天还没记录其他健康数据', style: TextStyle(color: AppColors.textMuted))
              else ...[
                Text('体重 ${metric['weight_kg'] ?? '-'} kg'),
                Text('睡眠 ${metric['sleep_hours'] ?? '-'} 小时'),
                Text('心情 ${metric['mood'] ?? '-'} /5'),
              ],
              const SizedBox(height: 8),
              const Text('点这里查看步数历史', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
            ],
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ResourceListScreen(resourceName: 'daily_metrics')),
              );
            },
          ),
          _tintCard(
            journalTodayCount > 1 ? '📓 今日备忘录 · 共 $journalTodayCount 条' : '📓 今日备忘录',
            AppColors.surface,
            journal == null
                ? [const Text('今天还没写', style: TextStyle(color: AppColors.textMuted))]
                : [Text((journal['content'] ?? '').toString())],
          ),
          _tintCard(
            '⏰ 即将到来的提醒',
            AppColors.surface,
            [
              if (upcomingSubs.isEmpty && upcomingBirthdays.isEmpty)
                const Text('近期没有订阅续费或生日提醒', style: TextStyle(color: AppColors.textMuted))
              else ...[
                ...upcomingSubs.map<Widget>((s) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('🔄 ${s['name']}'),
                      subtitle: Text(s['days_until'] == 0 ? '今天扣费' : '${s['days_until']} 天后扣费'),
                      trailing: Text('RM ${s['cost']}'),
                    )),
                ...upcomingBirthdays.map<Widget>((c) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('🎂 ${c['name']}'),
                      subtitle: Text(c['days_until'] == 0 ? '今天生日' : '${c['days_until']} 天后生日'),
                    )),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _noticeBanner({required bool success, required String text}) {
    final color = success ? AppColors.success : AppColors.warning;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 12.5, height: 1.4)),
    );
  }

  Widget _statCard(String label, String value, {String? foot, Color color = AppColors.text}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          if (foot != null) ...[
            const SizedBox(height: 2),
            Text(foot, style: const TextStyle(color: AppColors.textMuted, fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }

  Widget _barsFromList(List<dynamic> rows, String labelKey, String amountKey) {
    final entries = <MapEntry<String, double>>[];
    for (final r in rows) {
      final amount = (r[amountKey] as num?)?.toDouble() ?? 0;
      if (amount <= 0) continue;
      entries.add(MapEntry(r[labelKey]?.toString() ?? '-', amount));
    }
    return _barsWidget(entries);
  }

  Widget _barsFromBreakdown(List<dynamic> breakdown) {
    final entries = breakdown.map((b) => MapEntry(b['label'].toString(), (b['amount'] as num).toDouble())).toList();
    return _barsWidget(entries);
  }

  Widget _barsFromMap(Map<String, num> map) {
    final entries = map.entries.map((e) => MapEntry(e.key, e.value.toDouble())).toList();
    return _barsWidget(entries);
  }

  Widget _barsWidget(List<MapEntry<String, double>> entries) {
    if (entries.isEmpty) return const Text('还没有数据', style: TextStyle(color: AppColors.textMuted, fontSize: 13));
    final maxVal = entries.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    return Column(
      children: entries.asMap().entries.map((entry) {
        final i = entry.key;
        final e = entry.value;
        final color = kChartPalette[i % kChartPalette.length];
        final pct = maxVal > 0 ? e.value / maxVal : 0.0;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text(e.key, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                  Text('RM ${e.value.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: pct, minHeight: 8, backgroundColor: Colors.white12, color: color),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _tintCard(String title, Color tint, List<Widget> children, {Future<void> Function(String)? onAdd, String? addHint, VoidCallback? onTap}) {
    final controller = onAdd != null ? TextEditingController() : null;
    return Card(
      color: tint,
      margin: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.text)),
                if (onAdd != null)
                  IconButton(
                    icon: const Icon(Icons.add_circle, color: AppColors.accent),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: Text(title),
                          content: TextField(
                            controller: controller,
                            autofocus: true,
                            decoration: InputDecoration(hintText: addHint),
                            onSubmitted: (v) {
                              Navigator.pop(context);
                              onAdd(v);
                            },
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                            FilledButton(
                              onPressed: () {
                                Navigator.pop(context);
                                onAdd(controller!.text);
                              },
                              child: const Text('添加'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
      ),
    );
  }
}
