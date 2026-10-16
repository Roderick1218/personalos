# Anben (安本)

Anben is a personal life-management app — tasks, habits, a daily journal/memo, contacts, money (accounts, transactions, salary, EPF/SOCSO/EIS, subscriptions, fixed deposits), reports, and reminders. It has a website and an Android app, both talking straight to the same Supabase backend, so the data is always the same place.

This file covers how it's built and how to run/change it. English first, 中文 in the second half below.

---

## English

### Screenshots

| Dashboard | Tasks (auto created/completed time) |
|---|---|
| ![Dashboard](screenshots/dashboard.png) | ![Tasks](screenshots/tasks.png) |

| Transactions | Bank accounts (delete protection) |
|---|---|
| ![Transactions](screenshots/transactions.png) | ![Bank accounts](screenshots/bank_accounts.png) |

| Memos (used to be called "Journal") |
|---|
| ![Memos](screenshots/memos.png) |

### What's in it

Tasks (with created/completed timestamps), projects, habit check-ins, memos, a quick inbox, contacts with birthday reminders, links, tags scoped per module, expense categories, bank/cash accounts, transactions with live balances, salary with EPF's 3 sub-accounts plus SOCSO and EIS, subscription renewal reminders, fixed deposits, weekly/monthly/yearly reports, general reminders, global search, and on the app: background step tracking and local notifications.

Sign-up needs a real email and the OTP code sent to it (8 digits, not the usual 6). Forgot-password is self-service through a fresh OTP — there's no admin reset. The UI shows your display name, never the email; only an admin can see emails, under User Management. Deleting a user from there wipes their data and their login entirely.

Backup: a regular user can export their own data. An admin can export everything, including auth records with password hashes — that export is as sensitive as a password itself.

### How it's built

```
Browser  →  index.html + js/app.js + js/supabase_bridge.js  ──┐
                                                                ▼
Phone app →  Flutter (api_service.dart + supabase_bridge.dart) →  Supabase
                                                                (Postgres + Auth + RLS)
```

No custom backend server — an earlier MySQL-based version had one (`api.php`/`db.php`), both removed once everything moved to Supabase. `config_resources.php` is still very much alive — it's where every field/label/dropdown is defined — but it isn't run live; after editing it you regenerate a `config_resources.json` that the website and app actually read (see "Making a change" below, this one's easy to forget and ship nothing).

The real logic lives in two files that mirror each other: `js/supabase_bridge.js` for the website, `lib/supabase_bridge.dart` for the app. Editing one doesn't touch the other — keep them in sync by hand.

Data isolation is Postgres RLS (`auth.uid() = user_id`), not app code. The client only ever holds the anon key.

### Making a change

Changing a field: edit `config_resources.php`, regenerate the JSON, copy it to the app's `assets/`, bump the website's `?v=`, rebuild the APK.

```php
<?php
$config = require "C:\\xampp\\htdocs\\personal_os\\config_resources.php";
file_put_contents("C:\\xampp\\htdocs\\personal_os\\config_resources.json", json_encode($config, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
```

The JSON's top level is that array itself — don't wrap it in anything. Skip the copy-to-app step and the app keeps using the old config even after a rebuild; that's bitten me before.

```
cd /d C:\Users\WHBUSE~1\personasystem
flutter build apk --release
flutter install -d <device-id>
```

If a JS/CSS change "doesn't show up" on the website, it's almost always a forgotten `?v=` bump in `index.html`.

### Known limitations

The website's reminders aren't a real background process — close the tab and they stop. The app does have a real foreground step-tracking service, but it's not medical-grade. Full-database backups don't include the schema, so restoring somewhere new means running the schema file first. Re-registering an email that was never verified can occasionally return odd results from Supabase.

---

## 中文

### 截图

| 仪表盘 | 任务 (自动记创建/完成时间) |
|---|---|
| ![仪表盘](screenshots/dashboard.png) | ![任务](screenshots/tasks.png) |

| 财务记账 | 银行账户 (删除保护) |
|---|---|
| ![财务记账](screenshots/transactions.png) | ![银行账户](screenshots/bank_accounts.png) |

| 备忘录 (以前叫「日记」) |
|---|
| ![备忘录](screenshots/memos.png) |

### 这是什么

安本是我自己在用的个人生活管理系统：任务、习惯、备忘录、联系人、财务（账户、记账、薪资、EPF/SOCSO/EIS、订阅、定存）、报表、提醒。有网站和安卓 App 两个入口，两边都直接连同一个 Supabase，数据是一份。

### 功能

任务（带创建/完成时间）、项目、习惯打卡、备忘录、快速收件箱、联系人（生日提醒）、链接、按模块分类的标签、收支分类、银行/现金账户、带实时余额的记账、含 EPF 三户口的薪资加 SOCSO、EIS、订阅续费提醒、定存、周/月/年报表、通用提醒、全局搜索，App 上还有背景步数记录和本地通知。

注册要填真实邮箱，收一组验证码（8 位，不是常见的 6 位）。忘记密码走同样的验证码流程，没有管理员帮你重设这回事。界面上看到的是名字，不是邮箱，只有管理员在用户管理里才看得到邮箱；在那边删一个账号，连数据带登入一起清掉。

备份：普通用户能导出自己的数据；管理员能导出全部，包含登入密码的哈希值，这份导出文件要当密码一样小心保管。

### 怎么搭的

```
浏览器  →  index.html + js/app.js + js/supabase_bridge.js  ──┐
                                                              ▼
手机 App →  Flutter (api_service.dart + supabase_bridge.dart) →  Supabase
                                                              (Postgres + Auth + RLS)
```

没有自己的后端服务器——早期用 MySQL 时有过一个（`api.php`/`db.php`），全部搬去 Supabase 之后两个文件都删掉了。`config_resources.php` 还是活的，所有字段、标签、下拉选项都定义在这里，只是它不会被即时执行——改完要重新生成一份 `config_resources.json`，网站和 App 读的是这份 JSON（见下面"要改东西的话"，这一步很容易忘，忘了就等于白改）。

真正的逻辑在两份互相对应的文件里：网站是 `js/supabase_bridge.js`，App 是 `lib/supabase_bridge.dart`。改一边不会自动改另一边，要手动同步。

数据隔离靠 Postgres 的 RLS (`auth.uid() = user_id`)，不是靠代码挡，前端只拿得到 anon key。

### 要改东西的话

改字段：改 `config_resources.php`，重新生成 JSON，复制到 App 的 `assets/`，网站的 `?v=` 加一，重新编译 APK。

```php
<?php
$config = require "C:\\xampp\\htdocs\\personal_os\\config_resources.php";
file_put_contents("C:\\xampp\\htdocs\\personal_os\\config_resources.json", json_encode($config, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
```

JSON 顶层就是这个数组本身，不要包别的东西。漏了复制到 App 这一步，App 重新编译之后用的还是旧配置——这个坑踩过。

```
cd /d C:\Users\WHBUSE~1\personasystem
flutter build apk --release
flutter install -d <设备ID>
```

网站改了 JS/CSS 却看不到效果，十次有九次是忘了在 `index.html` 里把 `?v=` 加一。

### 已知的限制

网站的提醒不是真的背景常驻，分页关掉就不会弹了。App 有真正的前台步数服务，但不是医疗级精准度。全库备份不含建表结构，搬到新环境要先跑一次建表 SQL。同一个邮箱没验证完又拿去重新注册，Supabase 有时候会返回奇怪的结果。

---

## 维护备忘 / Maintenance notes

这部分比较杂，中英文混着记，怎么顺手怎么来。/ This section is maintenance detail, mixed languages, whatever's faster to write.

**登录/邮箱设置** — Supabase Dashboard 要开 Authentication → Email → Confirm email = ON，并且设 Custom SMTP（目前用 Brevo: `smtp-relay.brevo.com:587`，账号密码看 Brevo 后台「SMTP settings」，寄件人要是已验证的地址）。邮件模板要带 `{{ .Token }}`，Confirm signup / Reset password 的模板**不要放可点击的确认链接**，不然会跳过「必须在页面输入验证码」这一步。发信失败多半是 SMTP 账密不对或寄件人没验证。

**RLS 规则**（线上已经设好，换新项目要重建）：
```sql
CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean
LANGUAGE sql SECURITY DEFINER STABLE
AS $$
  SELECT COALESCE((SELECT role = 'admin' FROM public.profiles WHERE id = auth.uid()), false);
$$;
```
`profiles` 自己能看自己，admin 能看全部；其他业务表也是自己的行自己看，admin 能读全部（给全库备份用）。业务列表查询还是要自己带 `.eq('user_id', ...)`，不要指望只靠 RLS，不然 admin 在一般页面也会看到别人的东西。

**搬家步骤**：新 Supabase 项目先跑一次建表 SQL，配好 SMTP 和邮件模板，再导出旧项目的全库数据跑进去。SMTP 这些第三方设置不会出现在 SQL 里，要另外记一份。

**文件在哪**：
```
C:\xampp\htdocs\personal_os\          网站
C:\Users\whb user\personasystem\      App 源码（真正在改的那份）
personasystem phone/                   这个 git 仓库里存的 App 源码副本，推送前要先同步
anben-app.apk                          打包好的安装包
anben_app_source.zip                   App 源码打包
个人系统_schema_supabase.sql            建表 SQL 参考，可能比线上旧
```

**连线信息**（不要写进前端代码）：Supabase project `xpbtyfattbqsaasmokoy`，pooler 是 `aws-0-ap-southeast-2.pooler.supabase.com:6543`（这台电脑连不了 IPv6，必须走 pooler），密码在本机 `Downloads\supabase password.txt`。

**写代码时留意**：网站和 App 功能要对齐，改一边记得改另一边；侧栏显示名字不要显示邮箱；业务查询一律带上 user_id 过滤；不要把 service_role key 放进前端代码；改了 `app.js`/`supabase_bridge.js`/`style.css` 记得 bump `index.html` 的版本号；改了 `config_resources.php` 记得照上面的步骤重新生成 JSON。
