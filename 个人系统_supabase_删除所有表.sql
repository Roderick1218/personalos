-- ============================================================
-- ⚠️ 删除所有表 (Supabase / PostgreSQL 专用) ⚠️
-- ============================================================
-- 这份文件的作用: 把 Supabase 项目里 public schema 底下"所有的表"整个删光，
-- 恢复成一个全新、空白的数据库 —— 相当于把 个人系统_schema_supabase.sql
-- 建出来的东西全部撤销。
--
-- 用途: 想要整个重来一次 (比如 schema 改了很多、懒得一张一张对照更新)，
-- 先跑这份文件清空，再重新贴一次最新版的 个人系统_schema_supabase.sql。
--
-- ⚠️ 警告 ⚠️
-- 1. 这个操作不可逆 — 没有"垃圾桶"、没有撤销，跑了就是真的删掉了。
-- 2. 会删掉"所有数据"，不是只删表结构 — 如果 public schema 里已经有真实数据，
--    请先备份 (比如用网站"用户管理"页面的"全库备份"功能，或在 Supabase
--    Table Editor 手动导出 CSV)，备份好了才跑这个文件。
-- 3. 只会清空 public schema (你自己建的那些表)，不会动到 Supabase 自己的
--    auth.users / auth.* 这些系统表 — 已注册的登入账号不会被删。
--
-- 使用方式: 打开 Supabase 项目 -> SQL Editor -> 新建一个查询 -> 把下面全部内容
-- 贴进去 -> Run。
-- ============================================================

-- 第一步: 把 public schema 整个炸掉再重建一个空的 (CASCADE 会自动一并处理
-- 表跟表之间的外键关联，不用自己一张一张按顺序删)
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;

-- 第二步: 重新授权 —— 这一步很重要，很多人漏掉这步导致"表删了但网站/API 打不通"。
-- Supabase 的 REST API (PostgREST) 跟 anon/authenticated 这些角色，权限是
-- 挂在 public schema 上的；schema 整个重建之后，这些默认权限会一起消失，
-- 不重新授权的话，就算之后重新建好表，Supabase 的 API 也读不到。
GRANT USAGE ON SCHEMA public TO postgres, anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT ALL ON ROUTINES TO postgres, anon, authenticated, service_role;

-- 跑完这份文件之后: public schema 是全新空白的，且权限已经恢复正常，
-- 可以直接把 个人系统_schema_supabase.sql 的内容贴进同一个 SQL Editor 重新建表。
