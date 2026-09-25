# 个人生活 OS (personal_os)

一个 config-driven 的个人生活管理系统：任务/习惯/日记/财务记账/薪资+EPF/订阅/定期存款/报表汇总/联系人等，网站 + Flutter App 共用同一个 PHP API。多用户，登录后各自数据完全独立。

## 当前技术栈

- **网站前端**：纯 HTML + CSS + 原生 JavaScript（`index.html` / `css/style.css` / `js/app.js`），无框架、无打包工具，改完直接刷新页面
- **后端**：单一入口 `api.php`（PHP 8.3），所有请求都是 POST 打这一个文件，用 `{resource, action, ...}` 的 JSON body 区分要做什么
- **数据库**：本地 XAMPP 的 MariaDB，库名 `personal_os`，**端口 3307**（不是默认的 3306，这台机器同时装了两个 MySQL）
- **配置**：`config_resources.php` 是**唯一的真相来源**——每个资源（表）的字段/类型/标签/关联/筛选条件都在这里定义一次，网站前端靠 `api.php?action=meta` 读这份配置动态生成界面，Flutter App 同理
- **多用户**：`users` 表 + PHP session，`role` 字段区分 `admin`/`user`；`config_resources.php` 底部有一份 `user_scoped` 资源名单，凡是列在里面的表，通用 CRUD 引擎会自动帮它做 `WHERE user_id = 当前登录用户` 的隔离，新增资源只要把名字加进那份名单就自动有隔离，不用每个 action 自己记得加

## 本地开发环境

1. 启动 XAMPP 的 Apache 和 MySQL（**这两个都不会开机自动启动**，每次都要手动点，或跑 `C:\xampp\apache_start.bat` / `C:\xampp\mysql_start.bat`）
2. 网站：`http://localhost/personal_os/`
3. 数据库连线信息见 `db.php`（root / 空密码 / 端口 3307）
4. 改完 `js/app.js` 或 `css/style.css` 记得去 `index.html` 把对应的 `?v=xxx` 版本号往上加一位，不然浏览器可能吃到旧的缓存文件

## 功能一览（简版）

任务 / 项目 / 习惯打卡 / 日记 / 快速收件箱 / 联系人（含生日提醒）/ 链接收藏 / 标签管理 / 收支分类 / 银行账户与现金 / 财务记账（收入支出转账）/ 动态薪资 + EPF 自动供款（含三户口分配）/ 订阅管理（到期自动扣费）/ 定期存款（到期自动转入账户或自动展期钱滚钱）/ 报表汇总（周报月报年报）/ 通用提醒（含重复规则）/ 用户管理（仅管理员：新增编辑删除账号、全库备份）/ 备份与恢复

两份数据库结构文件保存在 `Downloads`（不在这个项目目录里）：
- `个人系统_schema_mysql.sql` —— 本地 MySQL 用，跟当前 `personal_os` 数据库结构应该随时保持一致
- `个人系统_schema_supabase.sql` —— 给 Supabase/PostgreSQL 用的对应版本（见下面的迁移指南）

---

## 🔄 如果要换成 Supabase 数据库，需要改什么？（详细步骤）

**先说结论**：这不是改一两行设定就能切换的事情，因为现在的后端是直接用 `mysqli` 写死 MySQL 语法。真的要换，是一次不小的后端改写工程。下面把需要动到的每一个地方列清楚，照顺序做。

### 第 0 步：先决定一个关键问题——登录系统要不要一起换

现在网站是**自己做的登录系统**（`users` 表存密码 hash，PHP session 记登录状态，`role` 字段分管理员/普通用户）。但 `个人系统_schema_supabase.sql` 里的 `profiles` 表，设计上是**配合 Supabase 自带的 Auth 系统**用的（`profiles.id` 直接引用 `auth.users(id)`，每张业务表的 RLS 权限规则也都是靠 `auth.uid()` 这个 Supabase Auth 才有的函数在判断"这是不是你自己的资料"）。

两条路，选一条：

- **方案 A（改动小，推荐先做这个）**：继续用现在自己做的登录系统（`login`/`register`/`change_password`/`admin_*` 这些 action 完全不动），后端改用 `service_role` 权限直接连 Postgres（等于是最高权限，会跳过 RLS），资料隔离继续靠 PHP 自己手动加 `WHERE user_id = ?`，跟现在做法一模一样，只是把 SQL 语法从 MySQL 换成 Postgres。RLS policy 在这个方案下形同虚设（因为压根不是用 `auth.uid()` 在连线的），但不影响功能，只是"多一层用不到的保险"。
- **方案 B（改动大，比较"标准"的 Supabase 用法）**：把登录整个换成 Supabase Auth（前端呼叫 Supabase 的 signup/login API 拿到 JWT，`api.php` 改成验证这个 JWT），这样 RLS policy 才会真的发挥作用，前端甚至可以考虑直接呼叫 Supabase 的 REST API（PostgREST）而不用自己的 `api.php` 中转。但这样今天才刚做好的注册/登录/用户管理功能等于要整个重做一次。

下面第 1～6 步是照**方案 A** 写的（改动最小、风险最低）。如果要走方案 B，第 4、5 步会不一样，需要另外规划。

### 第 1 步：确认 Supabase 项目本身已经就绪

这个项目已经做过了（截至 2026-09-25）：
- Supabase 专案：`xpbtyfattbqsaasmokoy`
- `个人系统_schema_supabase.sql` 已经完整跑过，46+ 张表、RLS、policy 全部正确建好，且跟本地 MySQL 结构保持同步
- 如果之后本地 `config_resources.php` 又加了新栏位/新表，记得同时更新 `个人系统_schema_supabase.sql` 并在 Supabase SQL Editor 补跑对应的 `ALTER TABLE`/`CREATE TABLE`（不需要整个重跑，参考 `个人系统_supabase_删除所有表.sql` 的说明——那份是"整个重来"用的，平常增量更新不需要用到它）

### 第 2 步：打开这台机器 PHP 的 PostgreSQL 支持

这台机器的 Apache 现在用的是 `C:\php83`（在 `httpd-xampp.conf` 里设定的），**已经确认**这个 PHP build 里 `ext\php_pgsql.dll` 和 `ext\php_pdo_pgsql.dll` 这两个扩充文件都在，只是没启用。步骤：

1. 打开 `C:\php83\php.ini`
2. 找到这两行（目前前面有分号 `;` 表示停用）：
   ```ini
   ;extension=pdo_pgsql
   ;extension=pgsql
   ```
3. 把分号删掉变成：
   ```ini
   extension=pdo_pgsql
   extension=pgsql
   ```
4. 重启 Apache（XAMPP 控制面板点 Stop 再 Start，或跑 `C:\xampp\apache_stop.bat` + `apache_start.bat`）
5. 跑 `C:\php83\php.exe -m` 确认列表里出现 `pgsql` 和 `pdo_pgsql`

### 第 3 步：改 `db.php`——连线方式要换

现在 `db.php` 是这样（连本地 MySQL）：
```php
function get_db(): mysqli {
    static $conn = null;
    if ($conn === null) {
        $conn = new mysqli('127.0.0.1', 'root', '', 'personal_os', 3307);
        ...
    }
    return $conn;
}
```

要换成用 PDO 连 Supabase 的 Postgres。**重要**：这台机器直接连 Supabase 官方推荐的连线方式（`db.<project-ref>.supabase.co:5432`）会失败，因为那个网址只有 IPv6 记录，而这台机器完全没有 IPv6 路由。必须改用 Supabase 的 **Supavisor pooler**：

```php
function get_db(): PDO {
    static $conn = null;
    if ($conn === null) {
        $host = 'aws-0-ap-southeast-2.pooler.supabase.com'; // 这个专案确认可用的 region
        $port = 6543;
        $user = 'postgres.xpbtyfattbqsaasmokoy';
        $password = '...'; // 见 Downloads\supabase password.txt，不要写死在代码里，改用环境变量
        $dbname = 'postgres';
        $conn = new PDO(
            "pgsql:host=$host;port=$port;dbname=$dbname;sslmode=require",
            $user,
            $password,
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
        );
    }
    return $conn;
}
```

密码不要直接写进 `db.php`——改成从环境变量或一个不进版本控制的独立设定文件读取，避免密码跟着代码到处跑。

### 第 4 步：改 `api.php`——工程量最大的一步

`api.php` 现在全部是 `mysqli` 语法，要逐一改成 PDO + PostgreSQL 语法。主要几类改动：

1. **查询语法本身**：
   - `` $db->prepare("... `字段` ...") `` 的反引号 → Postgres 用双引号 `"字段"`，或者大部分情况下字段名是小写就不需要引号，直接拿掉反引号即可
   - `$stmt->bind_param('iss', $a, $b, $c); $stmt->execute();` → PDO 是 `$stmt->execute([$a, $b, $c]);`，不需要那串类型字符（`i`/`s`/`d`）
   - `$stmt->get_result()->fetch_assoc()` → PDO 是 `$stmt->fetch(PDO::FETCH_ASSOC)`
   - `$stmt->get_result()->fetch_all(MYSQLI_ASSOC)` → PDO 是 `$stmt->fetchAll(PDO::FETCH_ASSOC)`
   - `$stmt->insert_id`（拿刚新增那笔的 id）→ Postgres 没有这个属性，要在 INSERT 语句后面加 `RETURNING id`，然后 `fetch()` 拿那个值
2. **generic create/update 引擎里的 `ON DUPLICATE KEY UPDATE`**（`case 'create'` 那段）→ Postgres 对应写法是 `ON CONFLICT (id) DO UPDATE SET ...`
3. **`export_sql`/`admin_export_full_sql` 这两个备份功能用到的 MySQL 专属指令**：
   - `SHOW TABLES` → 改查 `SELECT tablename FROM pg_tables WHERE schemaname = 'public'`
   - `SHOW COLUMNS FROM 表 LIKE 'user_id'`（`export_sql` 用来判断这张表是不是个人资料表）→ 改查 `information_schema.columns`
   - `SHOW CREATE TABLE`（`admin_export_full_sql` 用来拿建表语句做完整备份）→ **Postgres 没有对应指令**，这是最麻烦的一个，需要另外写一段用 `information_schema` 手动拼出等价的 `CREATE TABLE` 语句，或者干脆呼叫系统的 `pg_dump` 命令行工具来产生备份（如果这台机器/服务器上有装的话）
4. **ID 从整数变成 UUID**：Supabase schema 里所有表的 `id` 都是 `UUID`（`gen_random_uuid()`），不是本地这种 `int auto_increment`。`api.php` 里目前所有 `(int)($body['id'] ?? 0)` 这种把 id 强制转成整数的地方都要拿掉，UUID 全程当字符串处理；前端 `app.js` 里如果有拿 id 做严格数字比较的地方（比如"用户管理"页面判断"是不是我自己"用的 `u.id === CURRENT_USER.id`）也要检查一遍，字符串比较通常没问题，但混用数字和字符串比较（`1 === '1'` 在 JS 是 `false`）就会出 bug
5. **不用改的部分**：`strtotime()`/`date()`/`round()` 这些都是 PHP 自己的函数，跟数据库无关，`sync_fixed_deposit_open()`/`auto_generate_due_subscriptions()` 这些自动化函数的判断逻辑本身不用改，只有里面呼叫数据库的那几行需要照上面的规则转换语法

### 第 5 步：资料隔离逻辑——方案 A 下要保留，不能偷懒

因为方案 A 是用 `service_role`/`postgres` 权限直连（等于是拿到最高权限，会绕过所有 RLS policy），**`config_resources.php` 里 `user_scoped` 那份名单 + `api.php` 通用 CRUD 引擎自动加 `WHERE user_id = ?` 的机制必须原封不动保留**，不能想说"反正 Supabase 有 RLS 帮忙挡"就把这段拿掉——RLS 在这个连线方式下根本不会生效，拿掉的话就等于所有人能看到所有人的资料，是个真实的安全漏洞。

### 第 6 步：测试

改完不要直接对着正式网站/正式数据测，建议：

1. 先在 Supabase 建一个测试用的资料（或者用现在这个空的 Supabase 专案本身，反正还没有真实资料）
2. 照下面这份清单一项一项手动测过一遍，确认功能都正常：
   - 注册新账号 / 登录 / 修改密码
   - 财务记账（收入/支出/转账三种类型都测）+ 银行账户余额计算对不对
   - 薪资档案 → 到发薪日自动生成发薪记录 + EPF 三户口自动分配
   - 订阅到期自动扣费（包含"补齐好几期没打开网站"的追赶逻辑）
   - 定期存款到期自动处理（"转入账户"跟"自动展期钱滚钱"两种都要测）
   - 报表汇总能不能正常生成
   - 用户管理（仅 admin）：新增/编辑/删除账号，删除时资料有没有正确一起清掉，"不能删最后一个管理员"这个保护有没有还在
   - 全库备份能不能正常导出
3. 全部过了才把正式网站指向新的连线设定

### 第 7 步：前端基本不用大改

`app.js`/`index.html` 当初设计的时候就是照着"以后要换 Supabase"这个前提做的——只要 `api.php` 回传的 JSON 形状（`meta`/`dashboard`/`list`/`create`/`update`/`delete` 这些 action 回什么格式）维持不变，前端理论上完全不用改。真正要检查的地方只有第 4 步提到的"ID 从数字变字符串"这个细节可能牵连到的严格比较逻辑。

### 现成的连线资讯

- Supabase 专案：`xpbtyfattbqsaasmokoy`（`https://xpbtyfattbqsaasmokoy.supabase.co`）
- **直连方式在这台机器上连不通**（`db.xpbtyfattbqsaasmokoy.supabase.co:5432` 只有 IPv6 记录，这台机器没有 IPv6 路由）
- 改用 pooler：host `aws-0-ap-southeast-2.pooler.supabase.com`，port `6543`，user `postgres.xpbtyfattbqsaasmokoy`，database `postgres`
- 密码见 `Downloads\supabase password.txt`（这份文件是明文密码，请自行妥善保管/之后考虑删除或换个更安全的地方存放）
