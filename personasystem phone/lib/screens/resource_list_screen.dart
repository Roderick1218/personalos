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

  ResourceConfig get cfg => AppState.resources[widget.resourceName]!;

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
      for (final f in cfg.fields.values) {
        if (f.type == 'fk' && f.fkResource != null) {
          await AppState.loadFk(f.fkResource!);
        }
      }
      final rows = await ApiService.list(widget.resourceName);
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
    // 删掉的提醒如果之前已经排过系统闹钟，要一并取消，不然系统到点还是会照排好的时间弹一条
    // 指向一笔已经不存在的记录 (点开确认画面会找不到资料)。
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
    // 当前余额是靠交易记录算出来的，不是 config 里的一个表单字段，走通用逻辑显示不出来，
    // 这里跟网站端 (app.js 的 extraCols) 一样单独补上。
    if (widget.resourceName == 'bank_accounts' && row['current_balance'] != null) {
      parts.add('当前余额 RM ${(row['current_balance'] as num).toStringAsFixed(2)}');
    }
    for (final entry in cfg.fields.entries) {
      if (entry.key == cfg.displayField) continue;
      final f = entry.value;
      if (f.type == 'boolean' || f.type == 'json' || f.type == 'textarea') continue;
      var val = row[entry.key];
      if (val == null || val.toString().isEmpty) continue;
      if (f.type == 'fk') val = AppState.fkLabel(f.fkResource!, val);
      if (f.type == 'select' && f.options != null) val = f.options![val.toString()] ?? val;
      if (f.type == 'time' || f.type == 'datetime') val = _formatTimeLike(val.toString());
      parts.add(val.toString());
      if (parts.length >= 2) break;
    }
    return parts.join(' · ');
  }

  // 2026-09-29: 之前直接把原始值 (比如 reminders.remind_at 的 "2026-09-29T09:18:00+00:00")
  // 显示在列表上，用户看到的是 UTC 时间，跟自己选的马来西亚本地时间对不上，会误以为存错了——
  // 其实数据本身是对的，只是没换算成本地时间显示。这里统一处理:
  // 带时区/日期的完整时间戳 -> 换算成本地时间显示；纯时间 (无日期，如 time_blocks) -> 只是去掉秒数。
  String _formatTimeLike(String val) {
    if (val.contains('T') || val.contains(' ') || val.contains('+') || val.contains('Z')) {
      final parsed = DateTime.tryParse(val);
      if (parsed != null) return DateFormat('yyyy-MM-dd HH:mm').format(parsed.toLocal());
    }
    return val.length >= 5 ? val.substring(0, 5) : val;
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
      title: Text(title),
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

    // 任务列表支持手势：右滑完成，左滑删除。其他资源保留普通删除按钮。
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
                return false; // 完成后刷新列表本身移走该行，不需要 Dismissible 再帮忙移除
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

  Widget _buildBody() {
    if (_loading) return _skeleton();
    if (_error != null) return Center(child: Text('加载失败: $_error'));
    return RefreshIndicator(onRefresh: reload, child: _buildList());
  }

  @override
  Widget build(BuildContext context) {
    final fab = FloatingActionButton(
      onPressed: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ResourceFormScreen(resourceName: widget.resourceName, id: null)),
        );
        reload();
      },
      child: const Icon(Icons.add),
    );

    if (widget.embedded) {
      return Stack(
        children: [
          _buildBody(),
          Positioned(right: 16, bottom: 16, child: fab),
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
