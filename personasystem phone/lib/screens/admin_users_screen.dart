import 'package:flutter/material.dart';
import '../api_service.dart';
import '../app_state.dart';
import '../theme.dart';

const Map<String, String> _kRoleLabel = {'admin': '管理员', 'user': '普通用户'};

/// 用户管理 (仅 role=admin) —— 跟网站端 renderAdminUsersPage() 对应，手机版用一个列表 +
/// 底部弹出表单，而不是网站那种表格 + modal。
class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  List<dynamic> _users = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final rows = await ApiService.adminListUsers();
      setState(() { _users = rows; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _delete(Map<String, dynamic> user) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('删除用户「${user['display_name'] ?? user['username']}」'),
        content: const Text('这会永久删除这个账号名下所有模块的所有数据 (任务/交易/备忘录...全部)，不是只删账号本身，不能恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除', style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ApiService.adminDeleteUser(user['id'].toString());
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _openForm({Map<String, dynamic>? user}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceAlt,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _UserFormSheet(user: user),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🛡️ 用户管理')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('加载失败: $_error'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(14),
                          child: Text(
                            '💡 系统至少要留一个管理员，不能把最后一个降级或删除。新增用户请填名字、邮箱和密码。',
                            style: TextStyle(color: AppColors.accent, fontSize: 13),
                          ),
                        ),
                      ),
                      for (final u in _users)
                        Card(
                          child: ListTile(
                            title: Row(
                              children: [
                                Text((u['display_name'] ?? u['username'] ?? '').toString()),
                                if (u['id'].toString() == AppState.currentUser?['id'].toString())
                                  const Padding(
                                    padding: EdgeInsets.only(left: 6),
                                    child: Text('(我)', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                                  ),
                              ],
                            ),
                            subtitle: Text('${u['email'] ?? ''} · ${u['created_at']}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  margin: const EdgeInsets.only(right: 4),
                                  decoration: BoxDecoration(
                                    color: (u['role'] == 'admin' ? AppColors.accent : Colors.white)
                                        .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    _kRoleLabel[u['role']] ?? u['role'].toString(),
                                    style: TextStyle(fontSize: 11, color: u['role'] == 'admin' ? AppColors.accent : AppColors.textMuted),
                                  ),
                                ),
                                IconButton(icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _openForm(user: u as Map<String, dynamic>)),
                                if (u['id'].toString() != AppState.currentUser?['id'].toString())
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 20, color: AppColors.danger),
                                    onPressed: () => _delete(u),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}

class _UserFormSheet extends StatefulWidget {
  final Map<String, dynamic>? user;
  const _UserFormSheet({this.user});

  @override
  State<_UserFormSheet> createState() => _UserFormSheetState();
}

class _UserFormSheetState extends State<_UserFormSheet> {
  late final TextEditingController _displayName = TextEditingController(text: widget.user?['display_name']?.toString() ?? '');
  late final TextEditingController _email = TextEditingController(text: widget.user?['email']?.toString() ?? '');
  final TextEditingController _password = TextEditingController();
  late String _role = widget.user?['role']?.toString() ?? 'user';
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.user != null;

  Future<void> _submit() async {
    setState(() { _error = null; });
    if (_displayName.text.trim().isEmpty) {
      setState(() => _error = '请填写名字');
      return;
    }
    if (!_isEdit && _email.text.trim().isEmpty) {
      setState(() => _error = '请填写邮箱');
      return;
    }
    if (!_isEdit && _password.text.length < 6) {
      setState(() => _error = '密码至少要 6 位');
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isEdit) {
        await ApiService.adminUpdateUser(
          id: widget.user!['id'].toString(),
          displayName: _displayName.text.trim(),
          role: _role,
          email: _email.text.trim(),
        );
      } else {
        await ApiService.adminCreateUser(
          email: _email.text.trim(),
          password: _password.text,
          displayName: _displayName.text.trim(),
          role: _role,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_isEdit ? '编辑用户' : '新增用户', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(controller: _displayName, decoration: const InputDecoration(labelText: '名字')),
            const SizedBox(height: 12),
            TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: '邮箱')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _role,
              decoration: const InputDecoration(labelText: '角色'),
              items: _kRoleLabel.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => setState(() => _role = v!),
            ),
            if (!_isEdit) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码 (至少 6 位)'),
              ),
            ] else ...[
              const SizedBox(height: 8),
              const Text('密码由使用者自己在登录页点「忘记密码」、用邮箱验证码重设。',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving ? const Text('保存中...') : const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}
