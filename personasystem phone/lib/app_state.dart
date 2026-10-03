import 'api_service.dart';
import 'models.dart';

/// 全局缓存: resource 配置 (从 api.php?action=meta 拉一次) + FK 下拉选项的数据。
/// 网站那边(app.js)也是同一份配置驱动的，改配置(config_resources.php)两边界面都会跟着变。
class AppState {
  static Map<String, ResourceConfig> resources = {};
  static final Map<String, List<dynamic>> fkCache = {};

  /// 当前登录用户 {id, username, display_name, role} —— 登录/注册成功后由 main.dart 写入，
  /// 登出时清空。role=='admin' 才能看到"用户管理"入口 (真正的权限判断在后端，这里只是决定
  /// 要不要显示那个入口，跟网站端 CURRENT_USER 是同一个用途)。
  static Map<String, dynamic>? currentUser;

  static bool get isAdmin => currentUser?['role'] == 'admin';

  static void reset() {
    resources = {};
    fkCache.clear();
    currentUser = null;
  }

  static Future<void> loadMeta() async {
    final res = await ApiService.meta();
    final map = res['resources'] as Map<String, dynamic>;
    resources = map.map(
      (k, v) => MapEntry(k, ResourceConfig.fromJson(k, v as Map<String, dynamic>)),
    );
  }

  static Future<List<dynamic>> loadFk(String resource) async {
    if (fkCache.containsKey(resource)) return fkCache[resource]!;
    final data = await ApiService.list(resource);
    fkCache[resource] = data;
    return data;
  }

  // 2026-09-30: 跟网站端 app.js 的 invalidateFkCache() 是同一个用途——新增/编辑/删除一笔资料后，
  // 要把这个 resource 的 fk 缓存清掉，不然别的表单的下拉框还是拿旧的那份 (比如在"标签管理"新建了
  // 一个标签，"联系人"表单的标签下拉却还是看不到，因为 fkCache['tags'] 从第一次读过就没再更新过)。
  // 这个 Flutter 版本之前完全没有做这件事，是这次才发现的漏洞——网站那边一直都有做。
  static void invalidateFk(String resource) {
    fkCache.remove(resource);
  }

  static String fkLabel(String resource, dynamic id) {
    if (id == null || id.toString().isEmpty) return '';
    final rows = fkCache[resource] ?? [];
    Map<String, dynamic>? row;
    for (final r in rows) {
      if (r['id'].toString() == id.toString()) {
        row = r as Map<String, dynamic>;
        break;
      }
    }
    if (row == null) return '#$id';
    final displayField = resources[resource]?.displayField ?? 'id';
    return row[displayField]?.toString() ?? '#$id';
  }
}
