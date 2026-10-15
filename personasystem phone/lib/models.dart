/// 对应网站端 config_resources.php 里字段的 `show_when` —— 某个字段要不要显示，
/// 取决于同一张表另一个字段现在的值 (比如 fixed_deposits.destination_account_id
/// 只在 maturity_action == 'transfer' 时才需要显示)。手机屏幕小，比网站更需要
/// 把"现在用不到的栏位"藏起来，不然表单会长到很难滑。
class ShowWhen {
  final String field;
  final String? value; // 等于这个值才显示
  final String? not; // 不等于这个值才显示 (跟 value 互斥，config 只会给其中一个)

  ShowWhen.fromJson(Map<String, dynamic> json)
      : field = json['field'] as String,
        value = json['value']?.toString(),
        not = json['not']?.toString();

  bool matches(dynamic currentValue) {
    final v = currentValue?.toString();
    if (value != null) return v == value;
    if (not != null) return v != not;
    return true;
  }
}

class FieldConfig {
  final String type;
  final String label;
  final bool required;
  final dynamic defaultValue;
  final bool defaultToday;
  final Map<String, String>? options;
  final String? fkResource;
  // fk_filter 没解析就会显示这个资源的全部行，不管 config 有没有限定 (比如 tags 按 module 分组)。
  final Map<String, dynamic>? fkFilter;
  final num? min;
  final num? max;
  final bool hidden;
  final bool readonly;
  final ShowWhen? showWhen;

  FieldConfig.fromJson(Map<String, dynamic> json)
      : type = json['type'] as String,
        label = json['label'] as String,
        required = json['required'] == true,
        defaultValue = json['default'],
        defaultToday = json['default_today'] == true,
        options = (json['options'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ),
        fkResource = json['fk_resource'] as String?,
        fkFilter = (json['fk_filter'] as Map?)?.cast<String, dynamic>(),
        min = json['min'] as num?,
        max = json['max'] as num?,
        hidden = json['hidden'] == true,
        readonly = json['readonly'] == true,
        showWhen = json['show_when'] is Map
            ? ShowWhen.fromJson(json['show_when'] as Map<String, dynamic>)
            : null;
}

class FilterSpec {
  final String field;
  final String type;

  FilterSpec.fromJson(Map<String, dynamic> json)
      : field = json['field'] as String,
        type = json['type'] as String;
}

class ResourceConfig {
  final String name;
  final String label;
  final String group;
  final String icon;
  final String displayField;
  final Map<String, FieldConfig> fields;
  final List<FilterSpec> filters;
  final bool allowCreate;

  ResourceConfig.fromJson(this.name, Map<String, dynamic> json)
      : label = json['label'] as String,
        group = json['group'] as String,
        icon = json['icon'] as String,
        displayField = json['display_field'] as String,
        fields = (json['fields'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, FieldConfig.fromJson(v as Map<String, dynamic>)),
        ),
        filters = ((json['filters'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => FilterSpec.fromJson(e.cast<String, dynamic>()))
            .toList(),
        allowCreate = json['allow_create'] != false;
}
