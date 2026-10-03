import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';

class ResourceFormScreen extends StatefulWidget {
  final String resourceName;
  final String? id;
  const ResourceFormScreen({super.key, required this.resourceName, required this.id});

  @override
  State<ResourceFormScreen> createState() => _ResourceFormScreenState();
}

class _ResourceFormScreenState extends State<ResourceFormScreen> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, dynamic> _values = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  ResourceConfig get cfg => AppState.resources[widget.resourceName]!;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _parseTags(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) return raw.map((e) => e.toString()).toList();
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded.map((e) => e.toString()).toList();
      } catch (_) {}
    }
    return [];
  }

  Future<void> _init() async {
    try {
      for (final f in cfg.fields.values) {
        if (f.type == 'fk' && f.fkResource != null) {
          await AppState.loadFk(f.fkResource!);
        }
      }
      Map<String, dynamic> record = {};
      if (widget.id != null) {
        record = await ApiService.get(widget.resourceName, widget.id!) ?? {};
      }
      for (final entry in cfg.fields.entries) {
        final key = entry.key;
        final f = entry.value;
        dynamic val = record[key];
        if (val == null) {
          if (f.defaultToday && widget.id == null) {
            val = DateTime.now().toIso8601String().substring(0, 10);
          } else if (f.defaultValue != null) {
            val = f.defaultValue;
          }
        }
        switch (f.type) {
          case 'boolean':
            _values[key] = (val == true || val == 1 || val.toString() == '1');
            break;
          case 'select':
          case 'fk':
          case 'date':
          case 'time':
          case 'datetime':
          case 'color':
            _values[key] = val?.toString();
            break;
          case 'tags':
            _controllers[key] = TextEditingController(text: _parseTags(val).join(', '));
            break;
          case 'json':
            // jsonb 栏位从 Supabase 回传时已经是解析好的 Map/List，不是字符串——
            // 直接 .toString() 会得到 Dart 的 "{key: value}" 格式而不是合法 JSON，
            // 存回去时会存进一段坏掉的 JSON。是 Map/List 就重新编码成正规 JSON 字符串。
            _controllers[key] = TextEditingController(
              text: (val is Map || val is List) ? jsonEncode(val) : (val?.toString() ?? ''),
            );
            break;
          default:
            _controllers[key] = TextEditingController(text: val?.toString() ?? '');
        }
      }
      setState(() {
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // 字段现在该不该显示 (config 的 show_when: 依赖同一张表另一个字段现在的值)。
  // 隐藏起来的必填字段不该挡住保存 —— 比如定存"到期处理方式"选"自动展期"时，
  // "到期转入账户"根本就不会显示，不能因为它没填就不给保存。
  bool _isFieldVisible(FieldConfig f) {
    if (f.showWhen == null) return true;
    return f.showWhen!.matches(_values[f.showWhen!.field]);
  }

  Future<void> _submit() async {
    final data = <String, dynamic>{};
    for (final entry in cfg.fields.entries) {
      final key = entry.key;
      final f = entry.value;
      if (f.readonly) continue;
      if (f.type == 'boolean') {
        data[key] = _values[key] == true;
      } else if (['select', 'fk', 'date', 'time', 'datetime', 'color'].contains(f.type)) {
        data[key] = _values[key];
      } else {
        data[key] = _controllers[key]?.text ?? '';
      }
    }
    for (final entry in cfg.fields.entries) {
      final f = entry.value;
      if (!_isFieldVisible(f)) continue; // 藏起来的字段不用管有没有填
      if (f.readonly) continue;
      if (f.required && f.type != 'boolean') {
        final v = data[entry.key];
        if (v == null || v.toString().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('请填写：${f.label}')));
          return;
        }
      }
    }
    setState(() => _saving = true);
    try {
      if (widget.id != null) {
        await ApiService.update(widget.resourceName, widget.id!, data);
      } else {
        await ApiService.create(widget.resourceName, data);
      }
      // 新增/编辑之后要把这个 resource 的 fk 缓存清掉，不然别的表单 (比如刚建了新标签之后回去
      // 联系人表单) 下拉还是看到旧的——跟网站端 invalidateFkCache() 同一个道理。
      AppState.invalidateFk(widget.resourceName);
      // 提醒不用在这里手动重新排程——step_service.dart 的背景服务每 30 秒会自己查一次
      // 有没有到期的提醒，新建/改时间之后最多 30 秒内就会被那边接手，不用在保存这一刻特别处理。
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.id != null ? "编辑" : "新增"} · ${cfg.label}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('加载失败: $_error'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: cfg.fields.entries
                      .where((e) => !e.value.hidden && _isFieldVisible(e.value))
                      .map((e) => Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: _buildField(e.key, e.value),
                          ))
                      .toList(),
                ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('保存'),
          ),
        ),
      ),
    );
  }

  Widget _buildField(String key, FieldConfig f) {
    final labelText = f.label + (f.required ? ' *' : '');
    switch (f.type) {
      case 'textarea':
      case 'json':
        return TextFormField(
          controller: _controllers[key],
          maxLines: f.type == 'json' ? 5 : 4,
          style: f.type == 'json' ? const TextStyle(fontFamily: 'monospace') : null,
          decoration: InputDecoration(labelText: labelText, border: const OutlineInputBorder()),
        );

      case 'select': {
        final value = _values[key] as String?;
        return DropdownButtonFormField<String>(
          initialValue: (value != null && f.options!.containsKey(value)) ? value : null,
          decoration: InputDecoration(labelText: labelText, border: const OutlineInputBorder()),
          items: f.options!.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: (v) => setState(() => _values[key] = v),
        );
      }

      case 'fk': {
        var rows = AppState.fkCache[f.fkResource] ?? [];
        if (f.fkFilter != null) {
          rows = rows.where((r) => f.fkFilter!.entries.every((e) => r[e.key]?.toString() == e.value?.toString())).toList();
        }
        final displayField = AppState.resources[f.fkResource]?.displayField ?? 'id';
        final value = _values[key]?.toString();
        final validIds = rows.map((r) => r['id'].toString()).toSet();
        return DropdownButtonFormField<String>(
          initialValue: (value != null && validIds.contains(value)) ? value : null,
          decoration: InputDecoration(labelText: labelText, border: const OutlineInputBorder()),
          items: rows
              .map<DropdownMenuItem<String>>((r) => DropdownMenuItem(
                    value: r['id'].toString(),
                    child: Text(r[displayField]?.toString() ?? '#${r['id']}'),
                  ))
              .toList(),
          onChanged: (v) => setState(() => _values[key] = v),
        );
      }

      case 'boolean':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(f.label),
          value: _values[key] == true,
          onChanged: (v) => setState(() => _values[key] = v),
        );

      case 'number':
        return TextFormField(
          controller: _controllers[key],
          readOnly: f.readonly,
          enabled: !f.readonly,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: labelText,
            helperText: f.readonly ? '由 App 根据走路自动记录，不能手动改' : null,
            border: const OutlineInputBorder(),
          ),
        );

      case 'decimal':
        return TextFormField(
          controller: _controllers[key],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: labelText, border: const OutlineInputBorder()),
        );

      case 'color': {
        final current = (_values[key] as String?) ?? '';
        return _ColorSwatchPicker(
          label: labelText,
          value: current,
          onChanged: (v) => setState(() => _values[key] = v),
        );
      }

      case 'date': {
        final val = _values[key] as String?;
        return ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
          title: Text(labelText),
          subtitle: Text(val ?? '未选择'),
          trailing: const Icon(Icons.calendar_today, size: 18),
          onTap: () async {
            final initial = val != null ? (DateTime.tryParse(val) ?? DateTime.now()) : DateTime.now();
            final picked = await showDatePicker(
              context: context, initialDate: initial, firstDate: DateTime(2000), lastDate: DateTime(2100),
            );
            if (picked != null) setState(() => _values[key] = DateFormat('yyyy-MM-dd').format(picked));
          },
        );
      }

      case 'time': {
        final val = _values[key] as String?;
        // 存的值可能是纯时间 (如 time_blocks."14:30:00"，没有时区概念，原样显示就好) 也可能是
        // 完整带时区的日期时间 (如 reminders.remind_at "2026-09-30T09:18:00+00:00"，这是 UTC)——
        // 后者一定要先转成本地时间 (.toLocal()) 再取 HH:MM，不然编辑既有提醒时，时间栏位显示的
        // 会是 UTC 时间而不是用户当初选的马来西亚本地时间，看起来像是"存错了"。
        final timePart = () {
          if (val == null) return null;
          final looksLikeFullTimestamp = val.contains('T') || RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(val) || val.endsWith('Z');
          if (looksLikeFullTimestamp) {
            final parsed = DateTime.tryParse(val);
            if (parsed != null) {
              final local = parsed.toLocal();
              return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
            }
          }
          final sepIndex = val.contains(' ') ? val.indexOf(' ') : -1;
          final t = sepIndex >= 0 ? val.substring(sepIndex + 1) : val;
          return t.length >= 5 ? t.substring(0, 5) : t;
        }();
        return ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
          title: Text(labelText),
          subtitle: Text(timePart ?? '未选择'),
          trailing: const Icon(Icons.access_time, size: 18),
          onTap: () async {
            TimeOfDay initial = TimeOfDay.now();
            if (timePart != null) {
              final parts = timePart.split(':');
              initial = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
            }
            final picked = await showTimePicker(context: context, initialTime: initial);
            if (picked != null) {
              final hh = picked.hour.toString().padLeft(2, '0');
              final mm = picked.minute.toString().padLeft(2, '0');
              // 临时诊断: 直接显示"选择器刚刚回传的值"，用来确认到底是选择器本身给错、
              // 还是后面的处理逻辑把值改掉了——问题定位到之后这段要拿掉。改成弹窗 (不会自己消失)，
              // 之前用 SnackBar 只显示 4 秒，还没来得及看/截图就不见了。
              if (mounted) {
                await showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('时间选择器诊断'),
                    content: Text('选择器刚刚回传: $hh:$mm\n(picked.hour=${picked.hour}, picked.minute=${picked.minute})'),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
                  ),
                );
              }
              // 只存 "HH:MM" (不带秒)，跟网站端 <input type="time"> 给出来的格式一致——
              // reminders.remind_at 那个特殊规则 (只填"几点"，日期由程序自动拼) 是用严格的
              // /^\d{2}:\d{2}$/ 认出这种输入，多了 ":00" 就认不出来，会把这串没有日期的
              // "HH:MM:00" 直接当 timestamptz 存进去，数据库会报错创建失败。
              setState(() => _values[key] = '$hh:$mm');
            }
          },
        );
      }

      case 'datetime': {
        final val = _values[key] as String?;
        DateTime? parsed;
        if (val != null) {
          parsed = DateTime.tryParse(val.replaceFirst(' ', 'T'));
        }
        return ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
          title: Text(labelText),
          subtitle: Text(parsed != null ? DateFormat('yyyy-MM-dd HH:mm').format(parsed) : '未选择'),
          trailing: const Icon(Icons.event, size: 18),
          onTap: () async {
            final datePicked = await showDatePicker(
              context: context, initialDate: parsed ?? DateTime.now(), firstDate: DateTime(2000), lastDate: DateTime(2100),
            );
            if (datePicked == null || !mounted) return;
            final timePicked = await showTimePicker(
              context: context, initialTime: parsed != null ? TimeOfDay.fromDateTime(parsed) : TimeOfDay.now(),
            );
            if (timePicked == null) return;
            final combined = DateTime(datePicked.year, datePicked.month, datePicked.day, timePicked.hour, timePicked.minute);
            setState(() => _values[key] = DateFormat('yyyy-MM-dd HH:mm:ss').format(combined));
          },
        );
      }

      case 'tags':
        return TextFormField(
          controller: _controllers[key],
          decoration: InputDecoration(
            labelText: labelText,
            hintText: '逗号分隔，如：读书, 效率',
            border: const OutlineInputBorder(),
          ),
        );

      case 'url':
        return TextFormField(
          controller: _controllers[key],
          keyboardType: TextInputType.url,
          decoration: InputDecoration(labelText: labelText, hintText: 'https://...', border: const OutlineInputBorder()),
        );

      default:
        return TextFormField(
          controller: _controllers[key],
          decoration: InputDecoration(labelText: labelText, border: const OutlineInputBorder()),
        );
    }
  }
}

// 跟网站端 (js/app.js 的 COLOR_PALETTE + color-swatch-picker) 同一套设计：
// 预设色板点选 + 一个自定义颜色轮，不用自己手打色号。
const List<String> kColorPalette = [
  '#3B82F6', '#EF4444', '#16A34A', '#F59E0B', '#7C3AED', '#EC4899',
  '#06B6D4', '#84CC16', '#F97316', '#6366F1', '#14B8A6', '#64748B',
];

Color _hexToColor(String hex) {
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  return Color(int.parse(h, radix: 16));
}

class _ColorSwatchPicker extends StatelessWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  const _ColorSwatchPicker({required this.label, required this.value, required this.onChanged});

  Future<void> _pickCustom(BuildContext context) async {
    String draft = value.isNotEmpty ? value : '#9CA3AF';
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义颜色 (Hex)'),
        content: TextFormField(
          initialValue: draft,
          decoration: const InputDecoration(hintText: '#RRGGBB', border: OutlineInputBorder()),
          onChanged: (v) => draft = v,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, draft), child: const Text('确定')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) onChanged(result);
  }

  @override
  Widget build(BuildContext context) {
    final current = value.toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            ...kColorPalette.map((c) {
              final selected = current == c.toLowerCase();
              return GestureDetector(
                onTap: () => onChanged(c),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _hexToColor(c),
                    shape: BoxShape.circle,
                    border: selected ? Border.all(color: AppColors.text, width: 3) : null,
                  ),
                ),
              );
            }),
            GestureDetector(
              onTap: () => _pickCustom(context),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: value.isNotEmpty && !kColorPalette.map((c) => c.toLowerCase()).contains(current)
                      ? _hexToColor(value)
                      : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.border, width: 1.5),
                ),
                child: const Icon(Icons.colorize, size: 16, color: AppColors.textMuted),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
