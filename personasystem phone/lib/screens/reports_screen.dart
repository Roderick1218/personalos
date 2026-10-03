import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';
import '../theme.dart';

const Map<String, String> _kReportTypeLabel = {'weekly': '周报', 'monthly': '月报', 'yearly': '年报'};

/// 报表汇总 —— 跟网站端 renderReportsPage() 同一套逻辑 (生成+查看历史报表)，不是普通的表单 CRUD，
/// 所以这里用专属页面而不是套用通用的 ResourceListScreen/ResourceFormScreen。
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String _reportType = 'monthly';
  String _quickPick = 'this_month';
  DateTime _periodStart = DateTime.now();
  DateTime _periodEnd = DateTime.now();
  bool _generating = false;
  bool _loading = true;
  List<dynamic> _reports = [];

  static const Map<String, List<MapEntry<String, String>>> _quickOptions = {
    'weekly': [MapEntry('this_week', '本周'), MapEntry('last_week', '上周')],
    'monthly': [MapEntry('this_month', '本月'), MapEntry('last_month', '上月')],
    'yearly': [MapEntry('this_year', '今年'), MapEntry('last_year', '去年')],
  };

  @override
  void initState() {
    super.initState();
    _applyQuickPick();
    _load();
  }

  void _applyQuickPick() {
    final now = DateTime.now();
    if (_reportType == 'weekly') {
      final weekday = now.weekday; // 1=周一...7=周日
      var monday = now.subtract(Duration(days: weekday - 1));
      if (_quickPick == 'last_week') monday = monday.subtract(const Duration(days: 7));
      setState(() {
        _periodStart = DateTime(monday.year, monday.month, monday.day);
        _periodEnd = _periodStart.add(const Duration(days: 6));
      });
    } else if (_reportType == 'yearly') {
      var year = now.year;
      if (_quickPick == 'last_year') year -= 1;
      setState(() {
        _periodStart = DateTime(year, 1, 1);
        _periodEnd = DateTime(year, 12, 31);
      });
    } else {
      var year = now.year;
      var month = now.month;
      if (_quickPick == 'last_month') {
        month -= 1;
        if (month < 1) { month = 12; year -= 1; }
      }
      setState(() {
        _periodStart = DateTime(year, month, 1);
        _periodEnd = DateTime(year, month + 1, 0);
      });
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await ApiService.list('reports');
      rows.sort((a, b) => (b['period_start'] as String).compareTo(a['period_start'] as String));
      setState(() { _reports = rows; _loading = false; });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载失败: $e')));
    }
  }

  Future<void> _generate() async {
    setState(() => _generating = true);
    try {
      await ApiService.generateReport(
        reportType: _reportType,
        periodStart: DateFormat('yyyy-MM-dd').format(_periodStart),
        periodEnd: DateFormat('yyyy-MM-dd').format(_periodEnd),
      );
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('生成失败: $e')));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _pickDate(bool isStart) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _periodStart : _periodEnd,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      _quickPick = 'custom';
      if (isStart) { _periodStart = picked; } else { _periodEnd = picked; }
    });
  }

  Future<void> _delete(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除报表'),
        content: const Text('只删除这份汇总快照，不会动到原始的交易/薪资等记录。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirm != true) return;
    await ApiService.delete('reports', id);
    _load();
  }

  String _periodLabel(Map<String, dynamic> r) {
    final start = r['period_start'] as String;
    final end = r['period_end'] as String;
    final type = r['report_type'] as String;
    if (type == 'yearly' && start.endsWith('-01-01') && end.endsWith('-12-31') && start.substring(0, 4) == end.substring(0, 4)) {
      return '${start.substring(0, 4)}年';
    }
    if (type == 'monthly' && start.substring(0, 7) == end.substring(0, 7) && start.endsWith('-01')) {
      final d = DateTime.parse(start);
      final lastDay = DateTime(d.year, d.month + 1, 0).day;
      if (int.parse(end.substring(8, 10)) == lastDay) return '${start.substring(0, 4)}年${d.month}月';
    }
    return '$start ~ $end';
  }

  @override
  Widget build(BuildContext context) {
    final quickOpts = _quickOptions[_reportType]!;
    return Scaffold(
      appBar: AppBar(title: const Text('📑 报表汇总')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  '💡 选一个期间生成报表：收支/分类占比/前5大支出/薪资/EPF供款/订阅扣费/期末各账户余额，外加习惯打卡次数和日记篇数。同一个期间可以重新生成覆盖最新数字。',
                  style: TextStyle(color: AppColors.accent, fontSize: 13, height: 1.4),
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('生成新报表', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _reportType,
                      decoration: const InputDecoration(labelText: '类型'),
                      items: _kReportTypeLabel.entries
                          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                          .toList(),
                      onChanged: (v) {
                        setState(() {
                          _reportType = v!;
                          _quickPick = _quickOptions[_reportType]!.first.key;
                        });
                        _applyQuickPick();
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _quickPick,
                      decoration: const InputDecoration(labelText: '期间'),
                      items: [
                        ...quickOpts.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))),
                        const DropdownMenuItem(value: 'custom', child: Text('自订日期')),
                      ],
                      onChanged: (v) {
                        setState(() => _quickPick = v!);
                        if (v != 'custom') _applyQuickPick();
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _pickDate(true),
                            child: Text('开始 ${DateFormat('yyyy-MM-dd').format(_periodStart)}'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _pickDate(false),
                            child: Text('结束 ${DateFormat('yyyy-MM-dd').format(_periodEnd)}'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _generating ? null : _generate,
                      child: _generating ? const Text('生成中...') : const Text('📑 生成报表'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (_reports.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('还没有生成过报表，选好期间点上面的"生成报表"试试', style: TextStyle(color: AppColors.textMuted)),
              )
            else
              ..._reports.map((r) => _ReportCard(
                    row: r as Map<String, dynamic>,
                    periodLabel: _periodLabel(r),
                    onDelete: () => _delete(r['id'].toString()),
                  )),
          ],
        ),
      ),
    );
  }
}

class _ReportCard extends StatefulWidget {
  final Map<String, dynamic> row;
  final String periodLabel;
  final VoidCallback onDelete;
  const _ReportCard({required this.row, required this.periodLabel, required this.onDelete});

  @override
  State<_ReportCard> createState() => _ReportCardState();
}

class _ReportCardState extends State<_ReportCard> {
  Map<String, dynamic>? _content;

  @override
  void initState() {
    super.initState();
    // content 是 Postgres 的 jsonb 栏位，supabase_flutter 回传时已经是解析好的
    // Map，不再是 MySQL 时代那种要自己 jsonDecode() 的字符串——对一个已经是 Map
    // 的东西呼叫 .toString() 再 jsonDecode() 会得到 Dart 的 "{key: value}" 格式
    // 而不是合法 JSON，解析失败后被吞掉，报表就会永远显示空的。
    final raw = widget.row['content'];
    if (raw is Map<String, dynamic>) {
      _content = raw;
    } else if (raw is String && raw.isNotEmpty) {
      try {
        _content = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _content ?? {};
    final net = (c['net'] as num?)?.toDouble() ?? 0;
    final income = (c['income_total'] as num?)?.toDouble() ?? 0;
    final expense = (c['expense_total'] as num?)?.toDouble() ?? 0;
    final typeLabel = _kReportTypeLabel[widget.row['report_type']] ?? widget.row['report_type'].toString();

    return Card(
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Row(
          children: [
            Text(widget.periodLabel, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
              child: Text(typeLabel, style: const TextStyle(color: AppColors.accent, fontSize: 11)),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Text('收入 RM ${income.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
              const SizedBox(width: 10),
              Text('支出 RM ${expense.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
              const SizedBox(width: 10),
              Text('结余 RM ${net.toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: net >= 0 ? AppColors.success : AppColors.danger)),
            ],
          ),
        ),
        trailing: IconButton(icon: const Icon(Icons.delete_outline, color: AppColors.danger), onPressed: widget.onDelete),
        children: [
          const Divider(),
          if (c.isEmpty)
            const Text('无法解析这份报表内容', style: TextStyle(color: AppColors.textMuted))
          else ...[
            _line('💼 薪资收入', 'RM ${((c['salary_received'] as num?) ?? 0).toStringAsFixed(2)}'),
            _line(
              '🏦 EPF 供款',
              '员工 RM ${(((c['epf_contributed']?['employee']) as num?) ?? 0).toStringAsFixed(2)} · 雇主 RM ${(((c['epf_contributed']?['employer']) as num?) ?? 0).toStringAsFixed(2)}',
            ),
            _line(
              '🔄 订阅扣费',
              '${(c['subscriptions_charged']?['count']) ?? 0} 笔，共 RM ${(((c['subscriptions_charged']?['total']) as num?) ?? 0).toStringAsFixed(2)}',
            ),
            _line('📓 日记', '${c['journal_entry_count'] ?? 0} 篇'),
            const SizedBox(height: 10),
            const Text('支出分类占比', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 6),
            ..._categoryBars(c['category_breakdown'] as List<dynamic>? ?? []),
            const SizedBox(height: 10),
            const Text('前 5 大支出', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 6),
            ...((c['top_expenses'] as List<dynamic>? ?? []).isEmpty
                ? [const Text('这段期间没有支出记录', style: TextStyle(color: AppColors.textMuted, fontSize: 13))]
                : (c['top_expenses'] as List<dynamic>).map((t) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: Text(t['description'].toString(), overflow: TextOverflow.ellipsis)),
                          Text('- RM ${(t['amount'] as num).toStringAsFixed(2)}', style: const TextStyle(color: AppColors.danger)),
                        ],
                      ),
                    ))),
            const SizedBox(height: 10),
            Text(
              '期末账户余额 (合计 RM ${((c['total_balance_at_period_end'] as num?) ?? 0).toStringAsFixed(2)})',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 6),
            ...((c['account_balances'] as List<dynamic>? ?? []).map((a) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(a['nickname'].toString()),
                      Text('RM ${(a['balance'] as num).toStringAsFixed(2)}'),
                    ],
                  ),
                ))),
          ],
        ],
      ),
    );
  }

  Widget _line(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 13)),
            Flexible(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );

  List<Widget> _categoryBars(List<dynamic> breakdown) {
    if (breakdown.isEmpty) {
      return [const Text('这段期间没有支出记录', style: TextStyle(color: AppColors.textMuted, fontSize: 13))];
    }
    final total = breakdown.fold<double>(0, (s, b) => s + ((b['amount'] as num?)?.toDouble() ?? 0));
    if (total <= 0) return [const Text('这段期间没有支出记录', style: TextStyle(color: AppColors.textMuted, fontSize: 13))];
    return breakdown.map<Widget>((b) {
      final amount = (b['amount'] as num).toDouble();
      final pct = amount / total;
      Color color;
      try {
        color = Color(int.parse((b['color'] as String).replaceFirst('#', '0xFF')));
      } catch (_) {
        color = AppColors.accent;
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(b['label'].toString(), style: const TextStyle(fontSize: 12)),
                Text('${(pct * 100).toStringAsFixed(0)}%', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: pct, minHeight: 6, backgroundColor: Colors.white12, color: color),
            ),
          ],
        ),
      );
    }).toList();
  }
}
