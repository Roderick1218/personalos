# 个人生活 OS (personal_os)

一个 config-driven 的个人生活管理系统：任务 / 习惯 / 日记 / 财务记账 / 动态薪资+EPF / 订阅 / 定期存款 / 报表汇总 / 联系人 / 提醒 等。**网站 + Flutter App 现在都直接连 Supabase**（不再经过任何 PHP 后端），真正的多用户系统（Supabase Auth + RLS），登录后各自数据完全独立。

> **给以后的自己 / 给接手的 AI 看**：这份 README 写得比一般项目详细，因为这个系统换过一次架构（本机 PHP+MySQL → 直连 Supabase），过程中踩过不少坑。看完这份文件应该就能看懂现在整个系统是怎么运作的、以后要加功能/换环境要动哪里。

---

## 目录

1. [现在的架构（一定要先看这段）](#1-现在的架构一定要先看这段)
2. [项目文件结构](#2-项目文件结构)
3. [功能一览](#3-功能一览)
4. [Supabase 设置（从零开始 / 换新专案时怎么做）](#4-supabase-设置从零开始--换新专案时怎么做)
5. [日常开发：我改了功能，要怎么让网站和 App 都更新？](#5-日常开发我改了功能要怎么让网站和-app-都更新)
6. [InfinityFree 的故事（为什么网站在这上面，App 不行）](#6-infinityfree-的故事为什么网站在这上面app-不行)
7. [本地开发环境（这台电脑专属）](#7-本地开发环境这台电脑专属)
8. [已知限制](#8-已知限制)
9. [连线资讯速查表](#9-连线资讯速查表)

---

## 1. 现在的架构（一定要先看这段）

```
                      ┌─────────────────────┐
   浏览器打开网站  ──▶ │  index.html/app.js   │
                      │  supabase_bridge.js  │──┐
                      └─────────────────────┘  │
                                                ▼
   手机 App        ──▶ ┌─────────────────────┐  Supabase
                      │  Flutter App          │  (Postgres 数据库
                      │  supabase_bridge.dart │  + Auth 登录系统
                      └─────────────────────┘  + RLS 权限规则)
                                                ▲
                                                │
                      （没有中间的 PHP 服务器了）
```

**关键决定，一定要理解**：这个系统本来是"网站/App → 打 `api.php` (PHP) → 连 MySQL/本地"，2026-09-28 这一天整个换掉了，改成"网站/App 都直接打 Supabase，不经过任何自己写的后端"。原因是找 PHP 主机放 `api.php` 一直踩坑（见第 6 节 InfinityFree 的故事），干脆放弃"自己养一个后端服务器"这件事，让 Supabase 自己当后端。

这个决定的直接后果：

- **`api.php` / `db.php` / `config_resources.php` 这三个 PHP 文件现在是"死代码"，网站和 App 都不会呼叫它们了**——保留在项目里只是当参考/还没删掉，哪天确定完全用不到了可以整个删掉这三个文件（连同 `个人系统_schema_mysql.sql`，那份是本地 MySQL 用的，现在也用不到了）。
- **真正在跑的逻辑，全部写在两个"桥接文件"里**（下面会细讲）：
  - 网站：`js/supabase_bridge.js`
  - App：`lib/supabase_bridge.dart`
- **数据隔离（"每个人只能看到自己的东西"）现在是 Supabase 的 RLS（Row Level Security）在做**，不是 PHP 手动加 `WHERE user_id = ?` 了。这个很重要：以后**不能**在网站/App 里放一把"万能钥匙"能看到所有人的数据（比如 Supabase 的 `service_role` key），只能放 `anon` key（公开的，本来就设计成可以放在前端），安全性完全靠 RLS 规则本身写得对不对。

### 1.1 为什么两份桥接文件长得几乎一样

`js/supabase_bridge.js`（网站，浏览器 JS）和 `lib/supabase_bridge.dart`（App，Dart）做的是**同一件事，逐句对应翻译**：把原本 `api.php` 里的每一个 `action`（`login`/`list`/`create`/`dashboard`/`generate_report`/...）重新实现一遍，改成直接呼叫 Supabase 的 API，但**回传的资料形状（JSON 结构）刻意维持跟以前 `api.php`一模一样**——这样上层的 UI 代码（网站的 `app.js`、App 的每个 screen）完全不用大改，只要把"怎么打后端"这一层换掉就好。

这个"维持相同呼叫方式，只换内部实现"的做法，就是这个项目从头到尾一直在用的模式（`db.php` 当年从 MySQL 换 Postgres 也是这样做的）。**以后如果又要换后端（比如哪天想换掉 Supabase），一样照这个模式做：写一个新的桥接文件，实现相同的方法签名，内部换成打新后端。**

**重要维护提醒**：这两份桥接文件是**手动保持同步的，没有共用代码**——JS 改了逻辑，Dart 不会自动跟着改，反之亦然。以后新增/修改任何自动化逻辑（比如"薪资自动生成""订阅自动扣费"这类），**两个文件都要改**，改完最好都测一遍，不要预设"改一边另一边会跟着动"。

### 1.2 为什么可以放心把业务逻辑搬到前端 JS/Dart 里做（以前不敢这样做）

以前 `api.php` 时代，"计算仪表盘数据""判断该不该自动生成薪资记录"这些逻辑一定要写在服务器端（PHP），因为客户端（浏览器/App）不可信——如果把"只能看自己的资料"这条规则的判断逻辑放在前端，任何人打开浏览器开发者工具就能绕过去看别人的数据。

现在不一样了：**RLS 是数据库自己在执行的规则，不管前端的 JS/Dart 代码怎么问、问什么，Postgres 都只会回传"这个登录身份被允许看到的那些行"**。所以现在把 `build_dashboard()`、`auto_generate_due_salary_payments()` 这些原本在 PHP 里的函数整个搬到 JS/Dart 里跑，是安全的——反正不管前端怎么查，Supabase 后台都只会让它看到自己的资料。这是这次架构转换里最关键的一个认知转变，以后加新功能时也要用这个思路想：**"这段逻辑要不要在乎'不能看到别人的东西'？如果只是在乎'这个使用者自己的数据要怎么算/怎么显示'，可以放心写在前端。"**

---

## 2. 项目文件结构

```
personal_os/
├── index.html                      网站首页 (登录页 + 主要 UI 的容器)
├── css/style.css                   网站样式 (深色赛博朋克风格)
├── js/
│   ├── app.js                      网站全部 UI 逻辑 (路由/渲染/表单/仪表盘等)——不打 Supabase，
│   │                                只呼叫下面这个文件暴露出来的 api()/rawApi()
│   └── supabase_bridge.js          【真正的后端逻辑】直接连 Supabase，取代了以前的 api.php
├── config_resources.json           config_resources.php 的静态 JSON 快照，网站/App 的 meta
│                                    action 就是读这份文件 (不再需要 PHP 动态产生)
├── config_resources.php            【已弃用，留着当参考】以前唯一的资源配置来源，现在只是用来
│                                    "生成 config_resources.json" 的原始素材 (见第 5.1 节)
├── api.php / db.php                【已弃用，网站/App 都不再呼叫】当年 PHP 后端的完整实现，
│                                    留着方便回顾旧逻辑 (比如查一个字段以前的验证规则是什么)
├── 个人系统_schema_mysql.sql         【已弃用】本地 MySQL 用的建表语句，现在没有任何东西连本地 MySQL 了
├── 个人系统_schema_supabase.sql      Supabase 用的建表语句 (Postgres 语法) —— 这份还有用，
│                                    换新 Supabase 专案/查表结构时会用到，见第 4 节
└── 个人系统_supabase_删除所有表.sql   "整个重来"用的清空脚本，平常用不到

C:\Users\WHB User\personasystem\    Flutter App 专案 (跟网站是分开的两个 codebase)
├── lib/
│   ├── main.dart                   App 入口，Supabase.initialize() 在这里
│   ├── api_service.dart            对外的方法签名 (跟以前 api.php 时代一模一样)，
│   │                                内部全部转呼叫下面这个文件
│   ├── supabase_bridge.dart        【真正的后端逻辑】js/supabase_bridge.js 的 Dart 翻译版
│   ├── app_state.dart / models.dart  全局状态 + config JSON 的资料模型
│   └── screens/                    各个页面
├── assets/
│   ├── config_resources.json       网站那份的复制品 (App 没有 PHP 可以读，改用打包进 APK 的静态文件)
│   └── compass_icon.png            App 图标原始素材 (1024x1024，指南针+黑底)
└── pubspec.yaml                    含 supabase_flutter / flutter_launcher_icons 等依赖
```

---

## 3. 功能一览

任务 / 项目 / 习惯打卡 / 日记 / 快速收件箱 / 联系人（含生日提醒）/ 链接收藏 / 标签管理 / 收支分类 / 银行账户与现金 / 财务记账（收入支出转账三种类型，自动算各账户余额）/ 动态薪资 + EPF 自动供款（到发薪日自动生成、EPF 三户口 Akaun Persaraan/Sejahtera/Fleksibel 自动按比例分配）/ 订阅管理（到期自动扣费，支持"好几期没打开网站/App 一次性追上"）/ 定期存款（到期自动转入账户或自动展期钱滚钱）/ 报表汇总（周报月报年报）/ 通用提醒（含每天/每周/自订间隔的重复规则）/ 全局搜索 / 用户管理（仅管理员：编辑角色、删除账号数据、全库数据备份）/ 导出我的数据（CSV / SQL）

---

## 4. Supabase 设置（从零开始 / 换新专案时怎么做）

**现在用的专案**：`xpbtyfattbqsaasmokoy`（`https://xpbtyfattbqsaasmokoy.supabase.co`），已经设好了，不用重做。这一节是写给"哪天要整个搬到一个新的 Supabase 专案"用的（比如旧专案被删了、或想拆成另一个独立环境）。

### 4.1 建表结构

1. 到 Supabase 后台 → SQL Editor
2. 整份贴上 `个人系统_schema_supabase.sql` 的内容跑一次——这会建好全部 46+ 张表，并且**已经内建 RLS policy**（`auth.uid() = user_id` 这种"自己只能看自己"的规则），不用另外再设一次。

### 4.2 建立 `is_admin()` 函数 + 管理员可以看全部资料的规则

这个不在上面那份 schema 文件里（是这次架构转换才加的），要另外在 SQL Editor 跑：

```sql
-- 管理员判断: 用 SECURITY DEFINER 包起来，查的是"当前登录者自己的 profiles.role"，
-- 不会有 RLS 递归问题 (因为查的就是自己那一行，"own profile only" 政策本来就允许)。
CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean
LANGUAGE sql SECURITY DEFINER STABLE
AS $$
  SELECT COALESCE((SELECT role = 'admin' FROM public.profiles WHERE id = auth.uid()), false);
$$;

-- profiles 表: 管理员可以看到 / 编辑所有人的 profile (用户管理页面要用)
CREATE POLICY "admin can view all" ON profiles FOR SELECT USING (public.is_admin());
CREATE POLICY "admin can update all" ON profiles FOR UPDATE USING (public.is_admin());
```

然后**对每一张 user_scoped 的表**（`config_resources.php` 底部那份名单，目前 22 张：`project_categories`/`projects`/`tasks`/`habits`/`habit_logs`/`inbox_items`/`categories`/`banks`/`bank_accounts`/`tags`/`salary_profiles`/`salary_payments`/`epf_contributions`/`transactions`/`subscriptions`/`bookmarks`/`contacts`/`journal_entries`/`reminders`/`reports`/`fixed_deposits`/`daily_metrics`）都要加一条"admin 可以看全部"的规则（管理员的"全库备份"功能要用），照这个模式跑（把 `<表名>` 换掉）：

```sql
CREATE POLICY "admin can view all" ON "<表名>" FOR SELECT USING (public.is_admin());
```

嫌一张一张跑太麻烦的话，用 `Downloads\supabase password.txt` 里的 pooler 连线资讯写一支小脚本跑一次全部表（这个专案之前就是这样批次做的，参考本机 `C:\Users\WHBUSE~1\AppData\Local\Temp\claude\...\scratchpad\add_admin_readall_policies.php` 这类脚本的写法，用 PDO 查 `information_schema` 抓出全部有 `user_id` 外键的表名，跑一个循环）。

### 4.3 建立真正的登录账号

**这个系统的登录方式**：用户名 + 密码，但 Supabase Auth 本身只认 email 格式。做法是把用户名转成一个"假 email"：

```
真实登录用的 email = 用户名(全部转小写) + "@personalos.local"
```

新账号有两种建法：

- **自助注册（推荐，一般用户）**：打开网站/App，点"点这里注册"，正常填用户名密码——这条路走的是 Supabase Auth 的公开 `signUp` API，前端就能做，不需要任何特殊权限。
- **手动帮别人建账号（只有你自己在 Supabase 后台操作才能做，App/网站都做不到）**：因为建新的登录账号需要 `service_role` 权限（不能放进前端代码，见 8.1 已知限制），只能这样做二选一：
  1. 让对方自己走上面的自助注册，你事后在"用户管理"页面把他的角色改成 `admin`（这个可以在前端做，`profiles.role` 有开放 admin 更新权限）；
  2. 或者你自己去 Supabase 后台 → Authentication → Users → Add User，手动建一个（这样建出来的账号，`profiles` 表要自己另外补一行，见下面 SQL）：
     ```sql
     INSERT INTO profiles (id, display_name, role) VALUES ('<刚建好那个用户的 UUID>', '显示名称', 'user');
     ```

### 4.4 拿到 anon key（网站/App 都要用这把）

Supabase 后台 → Project Settings → API → 复制 **`anon` `public`** 那把 key（一长串 JWT）。这把 key 是**设计成可以公开放在前端代码里的**，不是密码，不用藏起来——安全性完全靠 RLS 规则，不是靠藏这把 key。**千万不要用 `service_role` 那把**（那把是万能钥匙，会跳过所有 RLS，只能在真正的服务器端环境用，绝对不能出现在网站/App 的代码里）。

拿到之后要改两个地方（现在这个专案的 key 已经填好了，换新专案才需要改）：
- `js/supabase_bridge.js` 顶部的 `SUPABASE_URL` / `SUPABASE_ANON_KEY`
- `lib/main.dart` 顶部的 `kSupabaseUrl` / `kSupabaseAnonKey`

### 4.5 迁移既有数据（如果是从别的地方搬旧资料过来，不是全新开始）

如果手上有旧的 MySQL 资料要搬进新专案，做法（这个专案实际做过一次，参考用）：
1. 用 `mysql2`（Node.js）或 PHP 的 mysqli 连旧的 MySQL，`pg`（Node.js）或 PDO pgsql 连新 Supabase
2. 每张表：查出旧资料，对每一行**产生一个新的 UUID**（`crypto.randomUUID()` 或 `gen_random_uuid()`）取代旧的数字 id，同时维护一份 `旧 id → 新 UUID` 的对照表
3. 有外键关联的栏位（比如 `transactions.bank_account_id` 指向 `bank_accounts.id`），插入时要用对照表把旧的数字 id 换成新的 UUID
4. 用户账号本身如果也要保留登录，UUID 可以直接沿用（Auth 账号建的时候指定 `id` 为这个 UUID 即可，不用另外对照）

---

## 5. 日常开发：我改了功能，要怎么让网站和 App 都更新？

### 5.1 加一个新字段到既有的资源（比如"交易"多一个"备注图片网址"字段）

1. 改 `config_resources.php`，在对应资源的 `fields` 里加一条
2. 如果这张表在 Supabase 里还没有这个栏位，去 SQL Editor 跑 `ALTER TABLE <表名> ADD COLUMN <字段名> <类型>;`
3. **重新产生 `config_resources.json`**（这一步最容易忘记）：
   ```powershell
   & "C:\php83\php.exe" -r "$c = require 'C:\xampp\htdocs\personal_os\config_resources.php'; file_put_contents('C:\xampp\htdocs\personal_os\config_resources.json', json_encode($c, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));"
   ```
   （实际操作时这行在 PowerShell 里直接用 `-r` 常常会因为引号跳脱出问题，简单做法是写一个小 `.php` 文件跑 `php 那个文件.php` 会比较稳）
4. 把新产生的 `config_resources.json` 复制一份到 `C:\Users\WHB User\personasystem\assets\config_resources.json`（App 是打包进 APK 的，不会自动读到网站那份）
5. 网站：`index.html` 里 `js/app.js` 和 `js/supabase_bridge.js` 的 `?v=xxx` 版本号都要往上加一位（不然浏览器不会重新抓文件，这是这个项目**最常踩的坑**，`.htaccess` 只对 `.html`/`.php` 强制不缓存，`.js` 完全靠这个版本号机制）
6. App：因为 config 是打包进 APK 的，**光复制新的 json 文件不会生效，一定要重新 `flutter build apk --release` + 重新安装**才会读到新版本

### 5.2 加一张全新的表/资源

1. Supabase SQL Editor 建表，记得：
   - `user_id UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid()`（这样前端 insert 时不用自己带 `user_id`，会自动填成"当前登录的人"）
   - 打开 RLS：`ALTER TABLE <表名> ENABLE ROW LEVEL SECURITY;`
   - 加"自己只能看自己"规则：`CREATE POLICY "own rows only" ON <表名> FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);`
   - 加"admin 可以看全部"规则（见 4.2）
2. `config_resources.php` 里加这个资源的定义（`label`/`icon`/`fields`/`display_field`），如果是"每个人自己一份"的资料，记得把资源名字加进文件最底部那份 `user_scoped` 名单
3. 照 5.1 的第 3～6 步重新产生 JSON、更新 App 的 assets、bump 版本号、重新编译 App
4. 如果这个新资源需要特殊逻辑（不是单纯的增删改查，比如像"薪资档案"那样存的时候要自动生一笔交易），要在**两个桥接文件都各写一次**（见 1.1 节的提醒）

### 5.3 加一个新的自动化逻辑（比如"新的提醒方式"）

这类东西目前都写在两个桥接文件里，用 `api.php` 里对应的旧函数当参考（虽然那个文件不再执行了，但逻辑读起来还是有用的，改动前建议先去 `api.php` 找找看以前有没有类似的写法）：
- `js/supabase_bridge.js`：找到对应的 `async function xxx()`，照同样风格加
- `lib/supabase_bridge.dart`：一样的逻辑翻译成 Dart

改完两边都要各自测一次（网站开浏览器测、App 重新编译装到手机测），不要预设两边行为一致——这个项目已经发生过一次"JS 修好了、Dart 忘记改，App 还是有旧的 bug"这种情况（比如 2026-09-28 那次"表单留空日期栏位导致 invalid input syntax for type date"的 bug，一开始修 JS 时也漏了同步到 Dart，是靠使用者反馈"App 可以但网页不行"才发现顺序反过来的另一次快取问题）。

### 5.4 网站文件改完要怎么真正"发布"出去？

目前发现这台电脑的 `C:\xampp\htdocs\personal_os` 文件夹**会自动同步到 InfinityFree 的 FTP 空间**（怎么同步的机制不完全确定，可能是背景跑着某个 FTP 同步工具，也可能是别的方式）——实际操作时改完本机文件，过一阵子去 InfinityFree 那边检查，文件内容通常已经是最新的了。**如果哪次改完网站发现 InfinityFree 上没有更新，要检查这个自动同步是不是还在跑，不要预设它一定持续有效**，必要时退回手动 FTP 上传（用第 9 节的 FTP 连线资讯）。

网站本身的网址：`https://personalos.infinityfree.me`（用真正的浏览器打开才能用，见第 6 节的原因）。

### 5.5 App 改完要怎么真正装到手机上？

```powershell
cd "C:\Users\WHB User\personasystem"
flutter build apk --release
& "C:\Android\sdk\platform-tools\adb.exe" devices          # 确认手机有连线 (USB)
& "C:\Android\sdk\platform-tools\adb.exe" install -r "build\app\outputs\flutter-apk\app-release.apk"
```

`adb.exe` 不在系统 PATH 里，路径固定是 `C:\Android\sdk\platform-tools\adb.exe`。如果手机没接电脑，只能把 APK 文件传给使用者自己在手机上安装（Android 需要先开启"允许安装未知来源应用"）。

---

## 6. InfinityFree 的故事（为什么网站在这上面，App 不行）

2026-09-28 这天原本想找一个免费的、24 小时开着的 PHP 主机放 `api.php`，试了 InfinityFree，结果发现两个绕不过去的死结，**这两个结论都已经实测确认过，不用再重新调查一次**：

1. **InfinityFree 的免费方案没有 `pdo_pgsql` 扩充**——它的 PHP 环境本来就是针对 MySQL 设计的，连 Postgres/Supabase 的驱动根本没有，`db.php` 换成连 Supabase 会直接报 "could not find driver"。
2. **InfinityFree 有一个强制的反机器人/反爬虫验证（"Website Guard"）**，会挡下所有不是"真正浏览器"发出的请求——包括 `curl`、Dart 的 `http` 套件——这些都拿不到真正的回应，只会拿到一段要求跑 JavaScript 的验证页面。这个验证**官方论坛证实无法关闭**（免费方案强制开启）。手机 App 用的 HTTP 请求正好就是这种"不是真正浏览器"的请求，永远过不了这关。

**结论**：InfinityFree 只适合放纯静态文件（HTML/CSS/JS），给"真正的浏览器"访问——这也是为什么最后决定"整个不要 PHP 后端了，网站前端的 JS 直接连 Supabase"，因为浏览器本身就是"真正的浏览器"，不会被挡；但如果哪天又想找个地方放一个真正的后端程序（不管是 PHP 还是别的），InfinityFree 的免费方案不能用，这两个结论已经不用再测一次了。

App 现在也不需要这个了——直接连 Supabase，跟浏览器打的是同一个 Supabase API（PostgREST），这个 API 本来就是设计给程序呼叫的，不会被反机器人机制挡。

---

## 7. 本地开发环境（这台电脑专属）

1. 网站的静态文件还是用这台电脑的 XAMPP Apache 在跑（**Apache 不会开机自动启动，每次要手动点，或跑 `C:\xampp\apache_start.bat`**）——但这只是给本机测试用，注意：**本机的 MySQL/MariaDB 现在完全没有任何东西在连了**（`db.php`/`api.php` 都是死代码），不用再管它有没有启动。
2. 本机网址：`http://localhost/personal_os/`
3. 改完 `js/app.js` 或 `js/supabase_bridge.js` 或 `css/style.css`，记得去 `index.html` 把对应的 `?v=xxx` 版本号往上加一位（见 5.1 节，这是整个项目最常见的一个"改了看不到效果"的坑）
4. Flutter App 专案在另一个路径：`C:\Users\WHB User\personasystem`（不是这个网站的子目录，是完全分开的一个 codebase）

---

## 8. 已知限制

### 8.1 管理员没办法直接建新账号

`admin_create_user` 这个功能做不到——建立一个新的登录账号需要 Supabase 的 `service_role` 权限，这把 key 是万能钥匙，绝对不能放进网站/App 的前端代码里（放进去等于任何人打开开发者工具都能拿到，看到所有人的所有数据）。目前的解法：让对方自己走"点这里注册"，注册完 admin 再把他的角色改成 `admin`（这个可以做，`profiles.role` 有开放管理员更新权限，见 4.2/4.3）。

真的很需要"直接建账号"这个功能的话，正规做法是写一个 Supabase Edge Function（跑在 Supabase 自己的服务器上，`service_role` key 放在那里面是安全的，因为那是服务器端环境，不是前端），前端呼叫这个 Edge Function 而不是直接呼叫 Auth Admin API——这个专案目前还没有做 Edge Function 这一步。

### 8.2 管理员"全库备份"是纯数据，不含表结构

`admin_export_full_sql` 现在只会导出 `INSERT` 语句（所有人的所有资料），不会重建 `CREATE TABLE`——要连表结构一起备份/还原，请另外用 `个人系统_schema_supabase.sql` 建表，这份导出的 SQL 只负责把资料灌回去。

### 8.3 提醒事项的"自动通知"不是真的背景服务

不管是网站还是 App，"到点该跳提醒"这件事都是**打开对应页面时顺手检查一次**（比如打开"通用提醒"列表页），不是真的有一个 24 小时在背景运作的服务在监控时间——如果好几天没打开网站/App，欠的提醒会在下次打开时一次性追上，但"精准在那个时间点跳通知"这件事目前做不到。

---

## 9. 连线资讯速查表

**Supabase**
- Project ref：`xpbtyfattbqsaasmokoy`
- URL：`https://xpbtyfattbqsaasmokoy.supabase.co`
- `anon` key：见 `js/supabase_bridge.js` 或 `lib/main.dart` 顶部（这把是设计成公开的，不是密密）
- Pooler（写维护脚本、直接用 PDO/pg 连线时用）：host `aws-0-ap-southeast-2.pooler.supabase.com`，port `6543`，user `postgres.xpbtyfattbqsaasmokoy`，database `postgres`，密码见 `Downloads\supabase password.txt`
- 直连方式（`db.xpbtyfattbqsaasmokoy.supabase.co:5432`）在这台机器上连不通（只有 IPv6 记录，这台机器没有 IPv6 路由），一定要用上面的 pooler

**InfinityFree**（目前只拿来放网站的静态文件，见第 6 节）
- 网站网址：`https://personalos.infinityfree.me`
- FTP：host `ftpupload.net`，port `21`，user `if0_43029692`，密码见账号自己的 InfinityFree 后台
- MySQL（目前没有任何东西在用，纯参考）：host `sql304.infinityfree.com`，port `3306`，database `if0_43029692_personal_os`，user `if0_43029692`

**测试账号**（本机开发用，密码请勿外传）
- `Roderick`（管理员）/ `Roderick12`（普通用户），密码都是 `123456`（登录时输入用户名，系统内部会转成 `用户名@personalos.local` 去 Supabase Auth 验证）
