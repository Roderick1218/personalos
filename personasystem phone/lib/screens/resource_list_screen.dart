import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';
import '../app_state.dart';
import '../models.dart';
import '../notification_service.dart';
import '../theme.dart';
import 'resource_form_screen.dart';

class ResourceListScreen extends StatefulWidget {
  final String resourceName;
  final bool embedded; // true = 作为底部导航的 tab 内容嵌入，不带自己的 Scaffold/AppBar

  const ResourceListScreen({super.key, required this.resourceName, this.embedded = false});

  @override
  State<ResourceListScreen> createState() => ResourceListScreenState();
}

class ResourceListScreenState extends State<ResourceListScreen> {
  List<dynamic> _rows = [];
  bool _loading = true;
  String? _error;
  final Map<String, String> _filterValues = {};

  ResourceConfig get cfg => AppState.resources[widget.resourceName]!;

  @override
  void initState() {
    super.initState();
    if (widget.resourceName == 'daily_metrics') {
      _filterValues['_period'] = 'week';
    }
    reload();
  }

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, String>? _periodRange(String preset) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (preset == 'week') {
      final from = today.subtract(const Duration(days: 6));
      return {'from': _ymd(from), 'to': _ymd(today)};
    }
    if (preset == 'month') {
      final from = DateTime(today.year, today.month, 1);
      final to = DateTime(today.year, today.month + 1, 0);
      return {'from': _ymd(from), 'to': _ymd(to)};
    }
    return null;
  }

  List<Map<String, dynamic>> _filtersPayload() {
    final payload = <Map<String, dynamic>>[];
    for (final f in cfg.filters) {
      if (f.type == 'period') {
        final range = _periodRange(_filterValues[f.field] ?? '');
        if (range != null) {
          payload.add({'field': 'metric_date', 'op': 'gte', 'value': range['from']});
          payload.add({'field': 'metric_date', 'op': 'lte', 'value': range['to']});
        }
        continue;
      }
      final fieldCfg = cfg.fields[f.field];
      if (fieldCfg == null) continue;
      if (f.type == 'month') {
        final y = _filterValues['${f.field}:year'] ?? '';
        final m = _filterValues['${f.field}:month'] ?? '';
        if (y.isEmpty) continue;
        if (m.isNotEmpty) {
          final last = DateTime(int.parse(y), int.parse(m) + 1, 0).day;
          payload.add({'field': f.field, 'op': 'gte', 'value': '$y-${m.padLeft(2, '0')}-01'});
          payload.add({'field': f.field, 'op': 'lte', 'value': '$y-${m.padLeft(2, '0')}-${last.toString().padLeft(2, '0')}'});
        } else {
          payload.add({'field': f.field, 'op': 'gte', 'value': '$y-01-01'});
          payload.add({'field': f.field, 'op': 'lte', 'value': '$y-12-31'});
        }
      } else if (f.type == 'daterange') {
        if ((_filterValues['_period'] ?? '').isNotEmpty) continue;
        final from = _filterValues['${f.field}:from'] ?? '';
        final to = _filterValues['${f.field}:to'] ?? '';
        if (from.isNotEmpty) payload.add({'field': f.field, 'op': 'gte', 'value': from});
        if (to.isNotEmpty) payload.add({'field': f.field, 'op': 'lte', 'value': to});
      } else if (f.type == 'text_search' || f.type == 'tag_search') {
        final val = _filterValues[f.field] ?? '';
        if (val.isNotEmpty) payload.add({'field': f.field, 'op': 'like', 'value': val});
      } else {
        final val = _filterValues[f.field] ?? '';
        if (val.isNotEmpty) payload.add({'field': f.field, 'op': 'eq', 'value': val});
      }
    }
    return payload;
  }

  Future<void> reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      for (final f in cfg.fields.values) {
        if (f.type == 'fk' && f.fkResource != null) {
          await AppState.loadFk(f.fkResource!);
        }
      }
      final rows = await ApiService.list(widget.resourceName, filters: _filtersPayload());
      if (widget.resourceName == 'daily_metrics') {
        rows.sort((a, b) => b['metric_date'].toString().compareTo(a['metric_date'].toString()));
      }
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _delete(String id) async {
    await ApiService.delete(widget.resourceName, id);
    AppState.invalidateFk(widget.resourceName);
    if (widget.resourceName == 'reminders') {
      await NotificationService.cancelReminder(id);
    }
    reload();
  }

  Future<bool> _confirmDelete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除这条记录吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    return confirm == true;
  }

  Future<void> _complete(String id) async {
    await ApiService.update(widget.resourceName, id, {'status': 'done'});
    reload();
  }

  Future<void> _markSubscriptionPaid(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('标记已扣费'),
        content: const Text('会自动生成一笔支出记录，并把下次扣费日期推后一个周期。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ApiService.markSubscriptionPaid(id);
      reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  String _subtitle(Map<String, dynamic> row) {
    final parts = <String>[];
    if (widget.resourceName == 'bank_accounts' && row['current_balance'] != null) {
      parts.add('当前余额 RM ${(row['current_balance'] as num).toStringAsFixed(2)}');
    }
    if (widget.resourceName == 'daily_metrics' && row['steps'] != null) {
      parts.add('步数 ${row['steps']}');
    }
    for (final entry in cfg.fields.entries) {
      if (entry.key == cfg.displayField) continue;
      if (widget.resourceName == 'daily_metrics' && entry.key == 'steps') continue;
      final f = entry.value;
      if (f.type == 'boolean' || f.type == 'json' || f.type == 'textarea') continue;
      var val = row[entry.key];
      if (val == null || val.toString().isEmpty) continue;
      if (f.type == 'fk') val = AppState.fkLabel(f.fkResource!, val);
      if (f.type == 'select' && f.options != null) val = f.options![val.toString()] ?? val;
      if (f.type == 'time' || f.type == 'datetime') val = _formatTimeLike(val.toString());
      parts.add(val.toString());
      if (parts.length >= 3) break;
    }
    return parts.join(' · ');
  }

  String _formatTimeLike(String val) {
    if (val.contains('T') || val.contains(' ') || val.contains('+') || val.contains('Z')) {
      final parsed = DateTime.tryParse(val);
      if (parsed != null) return DateFormat('yyyy-MM-dd HH:mm').format(parsed.toLocal());
    }
    return val.length >= 5 ? val.substring(0, 5) : val;
  }

  Future<void> _pickDate(String key) async {
    final current = _filterValues[key];
    DateTime initial = DateTime.now();
    if (current != null && current.isNotEmpty) {
      initial = DateTime.tryParse(current) ?? initial;
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      _filterValues[key] = DateFormat('yyyy-MM-dd').format(picked);
      _filterValues['_period'] = '';
    });
    reload();
  }

  Widget _filterControl(FilterSpec f) {
    if (f.type == 'period') {
      return DropdownButtonFormField<String>(
        value: (_filterValues[f.field] ?? 'week').isEmpty ? '' : (_filterValues[f.field] ?? 'week'),
        isExpanded: true,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
        items: const [
          DropdownMenuItem(value: 'week', child: Text('最近一周')),
          DropdownMenuItem(value: 'month', child: Text('本月')),
          DropdownMenuItem(value: '', child: Text('全部')),
        ],
        onChanged: (v) {
          setState(() => _filterValues[f.field] = v ?? '');
          reload();
        },
      );
    }
    final fieldCfg = cfg.fields[f.field];
    if (fieldCfg == null) return const SizedBox.shrink();

    InputDecoration deco(String hint) => InputDecoration(
          hintText: hint,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        );

    if (f.type == 'month') {
      final year = DateTime.now().year;
      final years = [for (var y = year - 3; y <= year + 1; y++) y.toString()];
      return Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: (_filterValues['${f.field}:year'] ?? '').isEmpty ? '' : _filterValues['${f.field}:year'],
              isExpanded: true,
              decoration: deco('年份'),
              items: [
                const DropdownMenuItem(value: '', child: Text('全部年份')),
                ...years.map((y) => DropdownMenuItem(value: y, child: Text(y))),
              ],
              onChanged: (v) {
                setState(() => _filterValues['${f.field}:year'] = v ?? '');
                reload();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: (_filterValues['${f.field}:month'] ?? '').isEmpty ? '' : _filterValues['${f.field}:month'],
              isExpanded: true,
              decoration: deco('月份'),
              items: [
                const DropdownMenuItem(value: '', child: Text('全部月份')),
                ...List.generate(12, (i) => DropdownMenuItem(value: '${i + 1}', child: Text('${i + 1}月'))),
              ],
              onChanged: (v) {
                setState(() => _filterValues['${f.field}:month'] = v ?? '');
                reload();
              },
            ),
          ),
        ],
      );
    }

    if (f.type == 'daterange') {
      final from = _filterValues['${f.field}:from'] ?? '';
      final to = _filterValues['${f.field}:to'] ?? '';
      return Row(
        children: [
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44), alignment: Alignment.centerLeft),
              onPressed: () => _pickDate('${f.field}:from'),
              child: Text(from.isEmpty ? '从日期' : from, style: TextStyle(color: from.isEmpty ? AppColors.textMuted : AppColors.text)),
            ),
          ),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('至', style: TextStyle(color: AppColors.textMuted))),
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44), alignment: Alignment.centerLeft),
              onPressed: () => _pickDate('${f.field}:to'),
              child: Text(to.isEmpty ? '到日期' : to, style: TextStyle(color: to.isEmpty ? AppColors.textMuted : AppColors.text)),
            ),
          ),
        ],
      );
    }

    if (f.type == 'select') {
      final opts = fieldCfg.options ?? {};
      return DropdownButtonFormField<String>(
        value: (_filterValues[f.field] ?? '').isEmpty ? '' : _filterValues[f.field],
        isExpanded: true,
        decoration: deco('全部${fieldCfg.label}'),
        items: [
          DropdownMenuItem(value: '', child: Text('全部${fieldCfg.label}')),
          ...opts.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))),
        ],
        onChanged: (v) {
          setState(() => _filterValues[f.field] = v ?? '');
          reload();
        },
      );
    }

    if (f.type == 'fk_select' && fieldCfg.fkResource != null) {
      var rows = List<dynamic>.from(AppState.fkCache[fieldCfg.fkResource!] ?? []);
      if (fieldCfg.fkFilter != null) {
        rows = rows.where((r) => fieldCfg.fkFilter!.entries.every((e) => r[e.key]?.toString() == e.value?.toString())).toList();
      }
      final display = AppState.resources[fieldCfg.fkResource!]?.displayField ?? 'id';
      return DropdownButtonFormField<String>(
        value: (_filterValues[f.field] ?? '').isEmpty ? '' : _filterValues[f.field],
        isExpanded: true,
        decoration: deco('全部${fieldCfg.label}'),
        items: [
          DropdownMenuItem(value: '', child: Text('全部${fieldCfg.label}')),
          ...rows.map((r) => DropdownMenuItem(value: r['id'].toString(), child: Text('${r[display] ?? r['id']}'))),
        ],
        onChanged: (v) {
          setState(() => _filterValues[f.field] = v ?? '');
          reload();
        },
      );
    }

    if (f.type == 'text_search' || f.type == 'tag_search') {
      return TextField(
        decoration: deco(f.type == 'tag_search' ? '按标签筛选' : '搜索${fieldCfg.label}'),
        onChanged: (v) {
          _filterValues[f.field] = v;
        },
        onSubmitted: (_) => reload(),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _filterBar() {
    if (cfg.filters.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          for (final f in cfg.filters) ...[
            _filterControl(f),
            const SizedBox(height: 8),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                setState(() => _filterValues.clear());
                reload();
              },
              child: const Text('清除筛选'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _skeleton() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 6,
      itemBuilder: (_, __) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        height: 56,
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Widget _rowTile(Map<String, dynamic> row) {
    final title = row[cfg.displayField]?.toString() ?? '#${row['id']}';
    final id = row['id'].toString();
    return ListTile(
      title: Text(widget.resourceName == 'daily_metrics' ? title : title),
      subtitle: Text(_subtitle(row)),
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ResourceFormScreen(resourceName: widget.resourceName, id: id),
          ),
        );
        reload();
      },
      trailing: widget.resourceName == 'tasks'
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.resourceName == 'subscriptions')
                  IconButton(
                    icon: const Icon(Icons.check_circle_outline, color: AppColors.success),
                    tooltip: '标记已扣费',
                    onPressed: () => _markSubscriptionPaid(id),
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                  onPressed: () async {
                    if (await _confirmDelete()) _delete(id);
                  },
                ),
              ],
            ),
    );
  }

  Widget _buildList() {
    if (_rows.isEmpty) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(24),
            child: Text('还没有数据', style: TextStyle(color: AppColors.textMuted)),
          ),
        ],
      );
    }

    if (widget.resourceName == 'tasks') {
      return ListView.separated(
        itemCount: _rows.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final row = _rows[index] as Map<String, dynamic>;
          final id = row['id'].toString();
          return Dismissible(
            key: ValueKey('task-$id'),
            background: Container(
              color: Colors.green,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: const Row(children: [Icon(Icons.check, color: Colors.white), SizedBox(width: 8), Text('完成', style: TextStyle(color: Colors.white))]),
            ),
            secondaryBackground: Container(
              color: Colors.red,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: const Row(mainAxisAlignment: MainAxisAlignment.end, children: [Text('删除', style: TextStyle(color: Colors.white)), SizedBox(width: 8), Icon(Icons.delete, color: Colors.white)]),
            ),
            confirmDismiss: (direction) async {
              if (direction == DismissDirection.startToEnd) {
                await _complete(id);
                return false;
              }
              return _confirmDelete();
            },
            onDismissed: (_) => _delete(id),
            child: _rowTile(row),
          );
        },
      );
    }

    return ListView.separated(
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) => _rowTile(_rows[index] as Map<String, dynamic>),
    );
  }

  Widget _stepsChart() {
    var last = _rows.whereType<Map>().toList();
    last.sort((a, b) => a['metric_date'].toString().compareTo(b['metric_date'].toString()));
    final range = _periodRange(_filterValues['_period'] ?? '');
    if (range != null) {
      final byDate = <String, num>{};
      for (final r in last) {
        final k = r['metric_date'].toString().substring(0, 10);
        final v = (r['steps'] is num) ? r['steps'] as num : num.tryParse('${r['steps']}') ?? 0;
        byDate[k] = v;
      }
      final filled = <Map>[];
      var d = DateTime.parse(range['from']!);
      final end = DateTime.parse(range['to']!);
      while (!d.isAfter(end)) {
        final k = _ymd(d);
        filled.add({'metric_date': k, 'steps': byDate[k] ?? 0});
        d = d.add(const Duration(days: 1));
      }
      last = filled;
    }
    if (last.isEmpty) return const SizedBox.shrink();
    double maxV = 1;
    for (final r in last) {
      final v = (r['steps'] is num) ? (r['steps'] as num).toDouble() : double.tryParse('${r['steps']}') ?? 0;
      if (v > maxV) maxV = v;
    }
    return Container(
      height: 210,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('🚶 步数走势', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                final barH = c.maxHeight - 28;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final r in last)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Builder(
                            builder: (_) {
                              final v = (r['steps'] is num) ? (r['steps'] as num).toDouble() : double.tryParse('${r['steps']}') ?? 0;
                              final h = (barH * (v / maxV)).clamp(4.0, barH);
                              final label = r['metric_date'].toString();
                              final md = label.length >= 10 ? label.substring(5, 10) : label;
                              return Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Text('${v.toInt()}', style: const TextStyle(fontSize: 9, color: AppColors.accent)),
                                  const SizedBox(height: 4),
                                  Container(
                                    height: h,
                                    width: 14,
                                    decoration: BoxDecoration(
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                                      gradient: const LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [Color(0xFF00F0FF), Color(0xFF00C2D1)],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(md, style: const TextStyle(fontSize: 9, color: AppColors.textMuted)),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _rows.isEmpty) return _skeleton();
    if (_error != null && _rows.isEmpty) return Center(child: Text('加载失败: $_error'));
    return Column(
      children: [
        _filterBar(),
        if (widget.resourceName == 'daily_metrics') _stepsChart(),
        Expanded(
          child: RefreshIndicator(onRefresh: reload, child: _buildList()),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final fab = cfg.allowCreate
        ? FloatingActionButton(
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ResourceFormScreen(resourceName: widget.resourceName, id: null)),
              );
              reload();
            },
            child: const Icon(Icons.add),
          )
        : null;

    if (widget.embedded) {
      return Stack(
        children: [
          _buildBody(),
          if (fab != null) Positioned(right: 16, bottom: 16, child: fab),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('${cfg.icon} ${cfg.label}')),
      body: _buildBody(),
      floatingActionButton: fab,
    );
  }
}
