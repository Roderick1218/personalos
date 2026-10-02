# 安本（Anben）

给以后的自己、以及接手的 AI 看的**当前状态说明书**。读这一份即可，不必再把旧 changelog 当现状。

- 产品对外名称：**安本**（不再叫「个人生活 OS / 个人系统」）
- 网站：`C:\xampp\htdocs\personal_os\`
- App：`C:\Users\whb user\personasystem\`（短路径 `C:\Users\WHBUSE~1\personasystem`）
- 历史演进长文（v1～v4）：`project_personal_life_os.md` —— **已过时**，只查「为什么当年这样设计」时再打开，不要按里面的登录方式/架构改代码。

最后一次大更新：**2026-10-02**。

---

## 1. 现在的架构

```
浏览器  →  index.html + js/app.js + js/supabase_bridge.js  ──┐
                                                              ▼
手机 App →  Flutter (api_service.dart + supabase_bridge.dart) →  Supabase
                                                              (Postgres + Auth + RLS)
```

没有自己的 PHP 后端。`api.php` / `db.php` / `config_resources.php` 是死代码，只当参考。真正逻辑在两份桥接文件，必须**手动同步**（改 JS 不会自动改 Dart）。

数据隔离靠 **RLS**（`auth.uid() = user_id`）。前端只放 **anon key**，绝对不要放 `service_role`。管理员例外规则用 `public.is_admin()`。

网站 UI 文案不要写「多人共用 / 只看得到自己的东西」；技术上仍是多账号 + RLS。

---

## 2. 功能一览（用户能用到的）

任务 / 项目 / 习惯打卡 / 日记 / 收件箱 / 联系人（生日提醒）/ 链接 / 标签 / 收支分类 / 银行与现金 / 记账（收入、支出、转账，余额现算）/ 动态薪资 + EPF 三户口 / SOCSO、EIS / 订阅到期扣费 / 定期存款 / 周月年报 / 通用提醒 / 全局搜索 / 步数（仅 App）/ 本地通知（仅 App）

**账号：**

- 注册：名字 + 真实邮箱 + 密码 → **必须在网站/App 输入邮件里的全部数字验证码** 才算成功（通常 8 位，不要只输 6 位）
- 登录：邮箱 + 密码（未完成验证码的账号不能登录）
- 忘记密码：自己收验证码重设，**没有**管理员「重设为 123456」
- 界面显示 **名字（display_name）**，不显示邮箱；邮箱只在管理员「用户管理」里看
- 旧用户名登录：桥接层仍可能把不含 `@` 的标识转成 `xxx@personalos.local`（遗留账号）

**管理员「用户管理」：** 改名字 / 邮箱 / 角色；删除会清业务数据 + `profiles` + **`auth.users`**（邮箱可以再注册）。不能删自己，至少留一个 admin。

**备份：**

- 普通用户：「导出我的数据」= 当前账号业务表 INSERT
- 管理员：「导出全库备份」走 RPC `admin_export_full_sql()`：全部 public 表 + `auth.users` / `auth.identities`（含密码哈希）。**不含** CREATE TABLE / RLS / 函数。搬家：先跑 `个人系统_schema_supabase.sql`，再跑这份 SQL。文件当机密保管。

---

## 3. 文件地图

```
C:\xampp\htdocs\personal_os\
  index.html                 登录 + 主壳；script ?v= 必须 bump
  css/style.css              深色赛博风
  js/app.js                  全部 UI
  js/supabase_bridge.js      网站后端（Auth / CRUD / 仪表盘 / 备份）
  img/                       产品图标（来自用户 SVG）
  config_resources.json      资源配置
  个人系统_schema_supabase.sql   建表+RLS 参考（可能略旧，以线上库为准）
  README.md                  本文件（现状）
  project_personal_life_os.md  历史 changelog

C:\Users\whb user\personasystem\
  lib/main.dart, api_service.dart, supabase_bridge.dart, screens/, step_service.dart
  assets/logo.png, assets/config_resources.json
  android/.../ic_launcher*   桌面图标
```

网站当前缓存版本（改 JS/CSS 后请再 +1）：`supabase_bridge.js?v=19`，`app.js?v=20261002e`，`style.css?v=20261002a`。

---

## 4. 登录 / 邮箱（2026-10 现状）

### 4.1 产品流程

1. `signUp` 只寄 OTP，即使有 session 也立刻 `signOut`
2. `verifyOtp` type=`signup` 成功才写 profile 并进入系统
3. 登录若邮箱未确认则拒绝
4. 忘记密码：`resetPasswordForEmail` + `verifyOtp` type=`recovery` + `updateUser({password})`

邮件模板必须带 `{{ .Token }}`。**Confirm signup / Reset password 不要放可点击确认链接**，否则点链接会绕过「必须在页面输 OTP」。

### 4.2 Dashboard 必开项

- Authentication → Email → **Confirm email = ON**（`mailer_autoconfirm: false`）
- **Custom SMTP = ON**，当前 Brevo：

```
Host:     smtp-relay.brevo.com
Port:     587
Username: 以 Brevo「SMTP settings → Login」为准（曾从 bc2b62001 变成 bc2c82001，填错会 535）
Password: Standard SMTP key（xsmtpsib-…，不要 Short 15 位，不要 API key xkeysib-）
Sender:   必须是 Brevo 里已 Verified 的寄件人
          （现为 leeyongjun1218@e.newera.edu.my）
Sender name: 安本
```

不要开启 Brevo「Block unauthorized IP for SMTP keys」。

发信失败常见原因：Username 和 Brevo Login 不一致、SMTP key 认证失败、Sender 未验证。Confirm email 打开后才会真正发注册信。

### 4.3 相关数据库对象

- `handle_new_user()`：signup 后写 `profiles`（display_name / email / role），**已无** `must_change_password`
- `admin_update_user_email(uuid, text)`
- `admin_delete_auth_user(uuid)`：删 `auth.identities` + `auth.users`
- `admin_export_full_sql()`：完整数据 SQL（仅 admin）
- **已删除：** `admin_reset_user_password`、`profiles.must_change_password`

管理员删用户后若仍提示邮箱已注册：多半是旧 bug 留下的孤儿 `auth.users`。应用现在会 RPC 删 Auth。

---

## 5. 管理员与 RLS（线上已有，换项目要补）

```sql
CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean
LANGUAGE sql SECURITY DEFINER STABLE
AS $$
  SELECT COALESCE((SELECT role = 'admin' FROM public.profiles WHERE id = auth.uid()), false);
$$;
```

`profiles`：自己能看自己；admin 可 SELECT/INSERT/UPDATE/DELETE 全部。  
带 `user_id` 的业务表：自己的行；admin 可读（全库备份）。  
**业务列表查询仍要 `.eq('user_id', 当前用户)`**，避免管理员在普通模块里看到别人的数据；别人的数据只应出现在「用户管理」。

前端 **不要** 用 service_role。Admin 建号：让对方自己注册，再改 `profiles.role`。

---

## 6. 搬家 / 备份

1. 新 Supabase 跑最新 schema（表、RLS、函数；以线上为准）
2. 配 SMTP + Confirm email + 邮件模板 Token
3. 管理员下载全库 SQL，先 schema 后数据
4. 另备份网站+App 源码、`config_resources.json`
5. SMTP / Brevo 不会进 SQL，要单独记

全库 SQL 含密码哈希，**当机密**。不含网站 UI。

---

## 7. 日常改功能

1. 改字段：`config_resources.php` → 生成 `config_resources.json` → 复制到 App `assets/` → 网站 bump `?v=` → App 重编 APK
2. 新表：Supabase 建表 + RLS + admin policy + php 配置 + 两边桥接若有特殊逻辑
3. 网站：本机 `C:\xampp\htdocs\personal_os` 可能自动同步 InfinityFree。网址：`https://personalos.infinityfree.me`
4. App：

```
cd /d C:\Users\WHBUSE~1\personasystem
flutter build apk --release
flutter install -d <设备ID>
```

测试机曾用：`10AG2S0S2U001S0`（V2553）。改完 JS 看不到：99% 是没 bump `index.html` 的 `?v=`。

---

## 8. 已知限制

- 网站提醒不是 24h 后台；App 有前台步数服务 + 打开时同步通知，不是医疗级计步
- 全库备份不含 schema；schema 文件可能比线上旧
- 点邮件魔法链接仍可能确认邮箱——靠模板去掉链接
- 同一邮箱未验证又再注册，Supabase 可能返回空 identities
- `personal_os\personal_os\` 子目录是旧副本，不要当生产文件改
- InfinityFree 不能跑 PHP 连 Postgres，也不能给 App 当 API（Website Guard）

---

## 9. 连线（给维护脚本，勿写进前端）

- Project：`xpbtyfattbqsaasmokoy`  
  `https://xpbtyfattbqsaasmokoy.supabase.co`
- anon：`js/supabase_bridge.js` / App `main.dart` 顶部（可公开）
- Pooler：`aws-0-ap-southeast-2.pooler.supabase.com:6543`  
  user `postgres.xpbtyfattbqsaasmokoy`，密码见本机 `Downloads\supabase password.txt`  
  直连 IPv6 主机这台电脑不通，必须 pooler
- 本机网站：`http://localhost/personal_os/`（Apache：`C:\xampp\apache_start.bat`）
- PHP：`C:\php83\php.exe`

---

## 10. 给 AI 的硬规则

1. 网站和 App 功能保持一致；改桥接改两边。
2. 侧栏/登录显示 **display_name**，不要把邮箱当昵称。
3. 普通 CRUD 必须过滤当前 `user_id`，即使用户是 admin。
4. 不要恢复「密码重设为 123456」。
5. 不要把产品文案改回「多人共用」。
6. 不要把 service_role 放进 JS/Dart。
7. 改 `app.js` / `supabase_bridge.js` / `style.css` 必须 bump `index.html` 版本号。
8. 图标：用户 SVG → 网站 `img/`、App `assets/logo.png` 与 Android mipmap。
9. **现状以本 README 为准**；`project_personal_life_os.md` 只是考古。
