import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import '../app_state.dart';
import '../theme.dart';

/// 备份与恢复 —— 跟网站端 renderBackupPage() 对应。手机上没有浏览器那种"下载文件"的概念，
/// 这里改成拉到 SQL 内容后直接复制到剪贴板 (Flutter 内建的 Clipboard，不用额外加套件)，
/// 用户自己贴到备忘录/邮件/Google Drive 之类的地方保存。如果之后发现常常要用手机做这件事，
/// 值得加 share_plus + path_provider 做成真正的"分享/存档"，这里先用最简单能用的版本。
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool _exportingMine = false;
  bool _exportingFull = false;

  Future<void> _export({required bool full}) async {
    setState(() {
      if (full) { _exportingFull = true; } else { _exportingMine = true; }
    });
    try {
      final res = full ? await ApiService.adminExportFullSql() : await ApiService.exportSql();
      final sql = res['sql'] as String;
      await Clipboard.setData(ClipboardData(text: sql));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已复制到剪贴板 (${(sql.length / 1024).toStringAsFixed(1)} KB)，贴到备忘录/邮件里保存')),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $e')));
    } finally {
      if (mounted) {
        setState(() {
          if (full) { _exportingFull = false; } else { _exportingMine = false; }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('💾 备份与恢复')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('导出我的数据', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 8),
                  const Text(
                    '导出当前账号的数据，格式是一串 INSERT 语句。请定期保存。',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: _exportingMine ? null : () => _export(full: false),
                    child: Text(_exportingMine ? '导出中...' : '📦 导出我的数据'),
                  ),
                ],
              ),
            ),
          ),
          if (AppState.isAdmin)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('🛡️ 全库备份 (管理员)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    const SizedBox(height: 8),
                    const Text(
                      '导出全部登录资料与业务数据。请妥善保管这份文件。',
                      style: TextStyle(color: AppColors.danger, fontSize: 13),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: AppColors.danger, foregroundColor: Colors.white),
                      onPressed: _exportingFull ? null : () => _export(full: true),
                      child: Text(_exportingFull ? '导出中...' : '🛡️ 导出全库备份'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
