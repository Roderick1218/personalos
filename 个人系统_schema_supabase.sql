-- =====================================================================
-- 个人生活 OS 系统 - 数据库 Schema (Supabase / Postgres 版)
-- 用途: 直接丢进 Supabase Dashboard -> SQL Editor 执行
-- 对应本地测试版: 个人系统_schema_mysql.sql
-- =====================================================================

-- 每张表都有 user_id，靠 auth.uid() 做 Row Level Security 隔离数据。
-- 就算你现在只有自己一个人用，也建议保留，安全性靠这个而不是"没人知道网址"。
--
-- v4.8 更新: 本地 MySQL/PHP 版本之前一直是单人用 (没有登录/隔离)，这份 Supabase 设计
-- 从一开始就假设了多用户 + RLS，算是"设计上领先本地实现"。v4.8 把本地版也补上了真正的
-- 多用户登录 + 隔离 (新增 users 表、api.php 用 PHP session 做认证、每个 action 按
-- user_id 过滤/盖章)，但只覆盖了 config_resources.php 里实际有在导航使用的 ~20 张表
-- (核心/财务/个人/工具/系统分组那些)，没有像这份 Supabase 设计一样覆盖全部 46 张表
-- (那些隐藏/未启用的模块本地版本还是不区分用户)。真正迁移到 Supabase 时，这份文件的
-- RLS 覆盖范围本来就比本地版本广，不用因为本地版本的范围而缩减这里的 policy 列表。

-- gen_random_uuid() 需要这个扩展；Supabase 新项目通常已经默认开了，这里保险起见显式加一次
-- (IF NOT EXISTS，已经开了也不会报错)。
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------
-- 通用: updated_at 自动更新 trigger function
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================================================
-- S 级：每天都会用
-- =====================================================================

-- v2: 项目分类 (独立于收支用的 categories 表)
CREATE TABLE project_categories (
  id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name    VARCHAR(100) NOT NULL,
  color   VARCHAR(20)
);

CREATE TABLE projects (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name        VARCHAR(100) NOT NULL,
  description TEXT,
  category_id UUID REFERENCES project_categories(id) ON DELETE SET NULL, -- v2
  link        VARCHAR(500), -- v2: 项目链接 (GitHub / 游戏官网等)
  status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','completed','archived')),
  color       VARCHAR(20),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_projects_updated_at BEFORE UPDATE ON projects
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- v3: 统一标签系统 (财务/任务/链接 三个模块共用，可管理颜色)
CREATE TABLE tags (
  id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name    VARCHAR(100) NOT NULL,
  color   VARCHAR(20),
  module  TEXT NOT NULL CHECK (module IN ('finance','task','link','reminder','journal','contact'))
);

CREATE TABLE tasks (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  project_id   UUID REFERENCES projects(id) ON DELETE SET NULL,
  tag_id       UUID REFERENCES tags(id) ON DELETE SET NULL, -- v3
  title        VARCHAR(255) NOT NULL,
  description  TEXT,
  status       TEXT NOT NULL DEFAULT 'todo' CHECK (status IN ('todo','done')), -- 2026-09-29: 简化成只有未完成/已完成两种 (原本 inbox/today/upcoming/done 四种是旧版)
  priority     TEXT NOT NULL DEFAULT 'medium' CHECK (priority IN ('low','medium','high','urgent')),
  due_date     DATE,
  completed_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_tasks_updated_at BEFORE UPDATE ON tasks
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE habits (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name            VARCHAR(100) NOT NULL,
  description     TEXT,
  frequency       TEXT NOT NULL DEFAULT 'daily' CHECK (frequency IN ('daily','weekly','custom')),
  target_per_week INT,
  color           VARCHAR(20),
  is_active       BOOLEAN NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE habit_logs (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  habit_id   UUID NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
  log_date   DATE NOT NULL,
  completed  BOOLEAN NOT NULL DEFAULT true,
  note       VARCHAR(255),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (habit_id, log_date)
);

CREATE TABLE journal_entries (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  entry_date DATE NOT NULL,
  content    TEXT,
  mood       SMALLINT CHECK (mood BETWEEN 1 AND 5),
  tag_id     UUID REFERENCES tags(id) ON DELETE SET NULL, -- 2026-09-30: 原本自由文字 tags (JSONB)
                                                            -- 改成跟其他模块一样的单一标签外键
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, entry_date)
);
CREATE TRIGGER trg_journal_updated_at BEFORE UPDATE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE inbox_items (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  content      VARCHAR(500) NOT NULL,
  item_type    TEXT NOT NULL DEFAULT 'note' CHECK (item_type IN ('task','idea','note')),
  is_processed BOOLEAN NOT NULL DEFAULT false,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- A 级：每周会用
-- =====================================================================

CREATE TABLE categories (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name       VARCHAR(100) NOT NULL,
  type       TEXT NOT NULL CHECK (type IN ('income','expense')),
  color      VARCHAR(20),
  icon       VARCHAR(50),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- v3: 银行账户 (含期初余额；当前余额靠交易记录算出来，不落地存)
-- v3.2: 用户自己维护的银行列表 (下拉可选，可自行新增，取代原来自由输入的 bank_name)
CREATE TABLE banks (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name       VARCHAR(100) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE bank_accounts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  account_kind    TEXT NOT NULL DEFAULT 'bank' CHECK (account_kind IN ('bank','cash','ewallet')), -- v3.1: 银行/现金/电子钱包
  bank_id         UUID REFERENCES banks(id) ON DELETE SET NULL, -- v3.2: 从 banks 表选，现金/电子钱包可留空
  bank_name       VARCHAR(100), -- 旧字段，v3.2 之后表单不再用这个，保留只是不丢历史数据
  nickname        VARCHAR(100) NOT NULL,
  account_type    VARCHAR(50),
  account_number  VARCHAR(50), -- 界面只显示末 4 位，完整号码只存在这里
  opening_balance NUMERIC(12,2) NOT NULL DEFAULT 0,
  is_active       BOOLEAN NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE transactions (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                 UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  category_id             UUID REFERENCES categories(id) ON DELETE SET NULL,
  bank_account_id         UUID REFERENCES bank_accounts(id) ON DELETE SET NULL, -- v3; v3.1: required at the app layer (not a DB NOT NULL, to stay migration-safe) - every income/expense/transfer should be attributed to a bank/cash account so per-account balances stay accurate
  transfer_to_account_id  UUID REFERENCES bank_accounts(id) ON DELETE SET NULL, -- v3: type='transfer' 专用
  tag_id                  UUID REFERENCES tags(id) ON DELETE SET NULL, -- v3
  type                    TEXT NOT NULL CHECK (type IN ('income','expense','transfer')),
  amount                  NUMERIC(12,2) NOT NULL,
  currency                VARCHAR(10) NOT NULL DEFAULT 'MYR',
  description             VARCHAR(255),
  transaction_date        DATE NOT NULL,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- v3 备注: 'transfer' 类型的交易不计入收入/支出统计(自己账户间转账)，
-- 账户余额 = opening_balance + income - expense - transfer(出) + transfer(入到 transfer_to_account_id)。
-- 在 Postgres 端建议用一个 VIEW 或 RPC function 算这个，而不是每次查询都用子查询(参考 api.php 的 compute_bank_balances 逻辑迁移过来)。

-- =====================================================================
-- v4.9.5: 定期存款 (Fixed Deposits) —— 用户可选到期后"转入账户"或"自动展期(钱滚钱)"
-- =====================================================================
-- 这台机器的 api.php 有 sync_fixed_deposit_open()/auto_generate_due_fixed_deposits() 两个函数，
-- 纯应用层逻辑，不是数据库触发器，迁移到 Supabase 时务必搬成 Postgres trigger/Edge Function，否则:
-- ① 新增定存时不会自动从 source_account_id 扣本金 (记一笔支出)；
-- ② 到期不会自动处理 —— "转入账户"不会把本金+利息存进 destination_account_id (记一笔收入)，
--    "自动展期"不会把本金+利息开一张新的定存记录 (renewed_from_id 指回上一期，旧的标记 matured)。
-- 利息用单利算: 本金 × 年利率% × (期限月数/12)。
CREATE TABLE fixed_deposits (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                 UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  bank_id                 UUID REFERENCES banks(id) ON DELETE SET NULL,
  principal               NUMERIC(12,2) NOT NULL,
  interest_rate           NUMERIC(5,2) NOT NULL,
  tenure_months           INT NOT NULL DEFAULT 3,
  source_account_id       UUID REFERENCES bank_accounts(id) ON DELETE SET NULL,
  opening_transaction_id  UUID REFERENCES transactions(id) ON DELETE SET NULL,
  start_date              DATE NOT NULL,
  maturity_date           DATE,
  maturity_action         TEXT NOT NULL DEFAULT 'transfer' CHECK (maturity_action IN ('transfer','renew')),
  destination_account_id  UUID REFERENCES bank_accounts(id) ON DELETE SET NULL,
  status                  TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','matured','withdrawn')),
  renewed_from_id         UUID REFERENCES fixed_deposits(id) ON DELETE SET NULL,
  notes                   TEXT,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- v3.3: 动态薪资 + EPF 系统 (收入不固定，支持自由职业/佣金/花红/没有薪水的月份)
-- =====================================================================

-- 薪资档案 = 模板/预设，不是历史记录。改了档案不会动到过去的发薪记录。
CREATE TABLE salary_profiles (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  company_name          VARCHAR(150) NOT NULL,
  position              VARCHAR(150),
  basic_salary          NUMERIC(12,2) NOT NULL DEFAULT 0,
  salary_frequency      TEXT NOT NULL DEFAULT 'monthly' CHECK (salary_frequency IN ('monthly','biweekly','weekly','custom')),
  salary_payment_day    SMALLINT CHECK (salary_payment_day BETWEEN 1 AND 31),
  bank_account_id       UUID REFERENCES bank_accounts(id) ON DELETE SET NULL,
  employee_epf_percent  NUMERIC(5,2) NOT NULL DEFAULT 11,
  employer_epf_percent  NUMERIC(5,2) NOT NULL DEFAULT 13,
  prorate_basis         TEXT NOT NULL DEFAULT 'current_month' CHECK (prorate_basis IN ('current_month','previous_month')), -- v4.9.8: 不满整月时，按当月天数还是上个月天数算比例
  enable_epf            BOOLEAN NOT NULL DEFAULT true, -- v4.9.8: 这个雇主要不要算 EPF
  enable_socso          BOOLEAN NOT NULL DEFAULT false, -- v4.9.8: 这个雇主要不要算 SOCSO
  employee_socso_percent NUMERIC(6,3),
  employer_socso_percent NUMERIC(6,3),
  enable_eis            BOOLEAN NOT NULL DEFAULT false, -- v4.9.9: 这个雇主要不要算 EIS
  employee_eis_percent  NUMERIC(6,3),
  employer_eis_percent  NUMERIC(6,3),
  start_date            DATE NOT NULL,
  end_date              DATE,
  status                TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
  notes                 TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_salary_profiles_updated_at BEFORE UPDATE ON salary_profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 实际发薪记录 = 历史事实，永久保存。档案停用/改了默认 EPF% 都不会追溯改到这里已经存的数字。
CREATE TABLE salary_payments (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  salary_profile_id      UUID REFERENCES salary_profiles(id) ON DELETE SET NULL, -- 没挂档案 = 自由收入
  payment_date           DATE NOT NULL,
  period_label           VARCHAR(50) NOT NULL,
  period_start           DATE, -- v3.4: 入职/离职当月不足整月时填，配合 period_end 按比例算 basic_salary (前端算好才存，不是数据库算)
  period_end             DATE,
  basic_salary           NUMERIC(12,2) NOT NULL DEFAULT 0,
  allowance              NUMERIC(12,2) NOT NULL DEFAULT 0,
  bonus                  NUMERIC(12,2) NOT NULL DEFAULT 0,
  commission             NUMERIC(12,2) NOT NULL DEFAULT 0,
  other_addition         NUMERIC(12,2) NOT NULL DEFAULT 0,
  employee_epf_percent   NUMERIC(5,2) NOT NULL DEFAULT 0, -- 这笔当时用的百分比快照，之后改默认值不影响这里(见 v3.3 备注)
  employee_epf_amount    NUMERIC(12,2) NOT NULL DEFAULT 0,
  employer_epf_percent   NUMERIC(5,2) NOT NULL DEFAULT 0,
  employer_epf_amount    NUMERIC(12,2) NOT NULL DEFAULT 0,
  employee_socso_percent NUMERIC(6,3),
  employee_socso_amount  NUMERIC(12,2),
  employer_socso_percent NUMERIC(6,3),
  employer_socso_amount  NUMERIC(12,2),
  employee_eis_percent   NUMERIC(6,3),
  employee_eis_amount    NUMERIC(12,2),
  employer_eis_percent   NUMERIC(6,3),
  employer_eis_amount    NUMERIC(12,2),
  other_deductions       NUMERIC(12,2) NOT NULL DEFAULT 0,
  net_salary             NUMERIC(12,2) NOT NULL, -- 实际入账金额
  bank_account_id        UUID NOT NULL REFERENCES bank_accounts(id) ON DELETE RESTRICT,
  status                 TEXT NOT NULL DEFAULT 'paid' CHECK (status IN ('draft','pending','paid','cancelled')), -- v4: 只有 paid 才计入 transactions/epf_contributions
  transaction_id         UUID REFERENCES transactions(id) ON DELETE SET NULL, -- 自动生成的那笔收入交易
  notes                  TEXT,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- EPF 供款历史，大部分从 salary_payments 自动产生 (1 笔发薪 = 最多 1 笔供款记录，用 salary_payment_id 当 upsert key)，
-- 也支持手动补一笔额外/自愿供款 (salary_payment_id 留空)。
-- v4.9: 2024 年 KWSP 新制度把账户拆成 Akaun Persaraan (退休) / Akaun Sejahtera (安康) /
-- Akaun Fleksibel (灵活) 三户口，每笔供款按比例分进三个户口。percent 默认 75/15/10 是我所知的
-- 官方默认值，不是 100% 保证跟实际账户一致，每一笔都可以各自调整 (跟 salary_payments 的
-- EPF% 快照一样是"存当时用的比例"，不是全局设置，改了默认值不会追溯改到已存的历史记录)。
-- amount 字段是 percent × 当笔总供款 算出来的金额，自动生成路径 (sync_salary_payment()) 用
-- 默认比例，手动新增/编辑时前端会自动算但可以手动覆盖。
CREATE TABLE epf_contributions (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                  UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  salary_payment_id        UUID REFERENCES salary_payments(id) ON DELETE CASCADE,
  contribution_date        DATE NOT NULL,
  employee_contribution    NUMERIC(12,2) NOT NULL DEFAULT 0,
  employer_contribution    NUMERIC(12,2) NOT NULL DEFAULT 0,
  additional_contribution  NUMERIC(12,2) NOT NULL DEFAULT 0,
  persaraan_percent        NUMERIC(5,2) NOT NULL DEFAULT 75,
  sejahtera_percent        NUMERIC(5,2) NOT NULL DEFAULT 15,
  fleksibel_percent        NUMERIC(5,2) NOT NULL DEFAULT 10,
  persaraan_amount         NUMERIC(12,2) NOT NULL DEFAULT 0,
  sejahtera_amount         NUMERIC(12,2) NOT NULL DEFAULT 0,
  fleksibel_amount         NUMERIC(12,2) NOT NULL DEFAULT 0,
  notes                    VARCHAR(255),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- v4.9.9: SOCSO/EIS 供款历史，跟 epf_contributions 同一个套路 (从 salary_payments 自动产生，
-- salary_payment_id 当 upsert key)，但没有 EPF 那种 Akaun 三户口拆分，就是单纯员工+雇主两个数字。
CREATE TABLE socso_contributions (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  salary_payment_id      UUID REFERENCES salary_payments(id) ON DELETE CASCADE,
  contribution_date      DATE NOT NULL,
  employee_contribution  NUMERIC(12,2) NOT NULL DEFAULT 0,
  employer_contribution  NUMERIC(12,2) NOT NULL DEFAULT 0,
  notes                  VARCHAR(255),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE eis_contributions (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  salary_payment_id      UUID REFERENCES salary_payments(id) ON DELETE CASCADE,
  contribution_date      DATE NOT NULL,
  employee_contribution  NUMERIC(12,2) NOT NULL DEFAULT 0,
  employer_contribution  NUMERIC(12,2) NOT NULL DEFAULT 0,
  notes                  VARCHAR(255),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- v3.3 备注 (重要，迁移到 Supabase 时不要漏掉): 这台机器的 api.php 里有一个
-- sync_salary_payment() 函数，在 salary_payments 的 create/update/delete 时会自动
-- 同步生成/更新/删除对应的 transactions 一笔收入记录 + epf_contributions 一笔供款记录
-- (逻辑: net_salary 生成收入交易，employee/employer_epf_amount 生成供款记录，
-- 用 transaction_id / salary_payment_id 互相关联，避免金额重复计两次)。
-- 迁移到 Supabase 后，这段"写入时联动"的逻辑要么搬到一个 Postgres trigger function
-- (AFTER INSERT/UPDATE/DELETE ON salary_payments)，要么搬到一个 Edge Function 里，
-- 不能只是把表结构建起来就当作完工 —— 没有这段联动逻辑，发薪记录不会反映到财务记账
-- 和 EPF 供款历史里。
-- v4 补充: status 字段加入后，联动逻辑要先判断 status = 'paid' 才生成/保留 transaction 和
-- epf_contributions；status 变成 draft/pending/cancelled 时要把已生成的那两条记录撤掉
-- (删除 transaction + 清空 transaction_id + 删除 epf_contributions)，而不是留着孤儿记录。
-- v4.9 补充: 自动生成 epf_contributions 那笔时，同时要按默认比例 (75/15/10) 算好
-- persaraan_amount/sejahtera_amount/fleksibel_amount 三个字段存进去，不能只存 employee/employer
-- 供款金额就当完工——仪表盘的 EPF 户口占比饼图靠这三个字段加总，漏了这段本地版本踩过一次
-- bug (mysqli bind_param 参数个数手动数错，导致这段 INSERT 直接被跳过，教训: 参数多的时候
-- 用工具数字符串长度，不要用肉眼数)。

CREATE TABLE budgets (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  category_id UUID REFERENCES categories(id) ON DELETE CASCADE,
  month       DATE NOT NULL,
  amount      NUMERIC(12,2) NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (category_id, month)
);

-- v4.9.2/v4.9.3 备注 (同上面 salary_payments 那条，迁移到 Supabase 时不要漏掉): 这台机器的
-- api.php 里有一个 auto_generate_due_subscriptions() 函数，每次看仪表盘/订阅列表都会跑一次——
-- 对每个"使用中"的订阅，只要 next_billing_date (没有就用 start_date) 已经到期，就自动生成一笔
-- expense 交易，并循环往后推进直到追上今天为止 (一次能补齐好几期没打开网站累积的欠账，上限 120 期)。
-- 纯应用层逻辑，不是数据库触发器/约束 —— 只建表不迁移这段逻辑的话，订阅到期不会自动产生支出记录，
-- 只能靠手动记账。
CREATE TABLE subscriptions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name              VARCHAR(100) NOT NULL,
  cost              NUMERIC(10,2) NOT NULL,
  bank_account_id   UUID REFERENCES bank_accounts(id) ON DELETE SET NULL, -- v4.9.2: 自动扣款账户
  start_date        DATE, -- v4.9.3: 购买/开始日期，自动生成扣费记录的起算点
  billing_cycle     TEXT NOT NULL DEFAULT 'monthly' CHECK (billing_cycle IN ('monthly','yearly')),
  next_billing_date DATE, -- v4.9.3: 系统自动往前推算的下次扣费日 (见 auto_generate_due_subscriptions() 的移植提醒)
  remind_days_before INT NOT NULL DEFAULT 3, -- v2: 提前几天提醒续费
  category          VARCHAR(50),
  is_active         BOOLEAN NOT NULL DEFAULT true,
  notes             TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE daily_metrics (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  metric_date DATE NOT NULL,
  weight_kg   NUMERIC(5,2),
  sleep_hours NUMERIC(4,2),
  water_ml    INT,
  mood        SMALLINT CHECK (mood BETWEEN 1 AND 5),
  steps       INT,
  notes       VARCHAR(255),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, metric_date)
);

CREATE TABLE exercises (
  id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id  UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name     VARCHAR(100) NOT NULL,
  category VARCHAR(50),
  notes    TEXT
);

CREATE TABLE workouts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  workout_date DATE NOT NULL,
  name         VARCHAR(100),
  notes        TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE workout_sets (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  workout_id   UUID NOT NULL REFERENCES workouts(id) ON DELETE CASCADE,
  exercise_id  UUID NOT NULL REFERENCES exercises(id) ON DELETE RESTRICT,
  set_number   INT NOT NULL,
  reps         INT,
  weight_kg    NUMERIC(6,2),
  rest_seconds INT,
  notes        VARCHAR(255)
);

CREATE TABLE media_entries (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  title       VARCHAR(255) NOT NULL,
  media_type  TEXT NOT NULL CHECK (media_type IN ('book','movie','tv','game')),
  status      TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned','in_progress','completed','dropped')),
  rating      SMALLINT CHECK (rating BETWEEN 1 AND 10),
  started_at  DATE,
  finished_at DATE,
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE reading_logs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  media_entry_id  UUID NOT NULL REFERENCES media_entries(id) ON DELETE CASCADE,
  log_date        DATE NOT NULL,
  progress_note   VARCHAR(255),
  progress_amount INT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- v3: bookmarks 正式作为 "链接(Links)" 模块
CREATE TABLE bookmarks (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  url         VARCHAR(1000) NOT NULL,
  title       VARCHAR(255),
  tag_id      UUID REFERENCES tags(id) ON DELETE SET NULL, -- v3 (取代下面这个自由文本 tags)
  tags        JSONB,
  is_favorite BOOLEAN NOT NULL DEFAULT false, -- v3
  is_archived BOOLEAN NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE goals (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  title        VARCHAR(255) NOT NULL,
  description  TEXT,
  period_type  TEXT NOT NULL CHECK (period_type IN ('year','quarter','month')),
  period_value VARCHAR(20) NOT NULL,
  status       TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','completed','abandoned')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE key_results (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  goal_id       UUID NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
  title         VARCHAR(255) NOT NULL,
  target_value  NUMERIC(12,2),
  current_value NUMERIC(12,2) NOT NULL DEFAULT 0,
  unit          VARCHAR(30),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE time_blocks (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  block_date  DATE NOT NULL,
  start_time  TIME NOT NULL,
  end_time    TIME NOT NULL,
  title       VARCHAR(255) NOT NULL,
  task_id     UUID REFERENCES tasks(id) ON DELETE SET NULL,
  planned     BOOLEAN NOT NULL DEFAULT true,
  actual_note VARCHAR(255),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- B 级：按需扩展
-- =====================================================================

CREATE TABLE contacts (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name              VARCHAR(100) NOT NULL,
  birthday          DATE,
  remind_days_before INT NOT NULL DEFAULT 3, -- v2: 生日提前几天提醒
  phone             VARCHAR(30),
  email             VARCHAR(255),
  notes             TEXT,
  tag_id            UUID REFERENCES tags(id) ON DELETE SET NULL, -- 2026-09-30: 原本自由文字 tags
                                                                  -- (JSONB) 改成单一标签外键
  last_contact_date DATE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE interactions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  contact_id       UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  interaction_date DATE NOT NULL,
  interaction_type TEXT NOT NULL DEFAULT 'other' CHECK (interaction_type IN ('call','meet','message','gift','other')),
  notes            TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE pantry_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name        VARCHAR(100) NOT NULL,
  quantity    NUMERIC(10,2),
  unit        VARCHAR(20),
  expiry_date DATE,
  notes       VARCHAR(255),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE recipes (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  title        VARCHAR(255) NOT NULL,
  ingredients  TEXT,
  instructions TEXT,
  tags         JSONB,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE shopping_list (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  item_name    VARCHAR(100) NOT NULL,
  quantity     VARCHAR(50),
  is_purchased BOOLEAN NOT NULL DEFAULT false,
  notes        VARCHAR(255),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE trips (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  title       VARCHAR(255) NOT NULL,
  destination VARCHAR(255),
  start_date  DATE,
  end_date    DATE,
  budget      NUMERIC(12,2),
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE trip_items (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  trip_id    UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  item_type  TEXT NOT NULL CHECK (item_type IN ('itinerary','expense','checklist')),
  title      VARCHAR(255) NOT NULL,
  item_date  DATE,
  amount     NUMERIC(12,2),
  is_done    BOOLEAN NOT NULL DEFAULT false,
  notes      VARCHAR(255),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE skills (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name          VARCHAR(100) NOT NULL,
  category      VARCHAR(50),
  target_hours  NUMERIC(8,2),
  current_hours NUMERIC(8,2) NOT NULL DEFAULT 0,
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE learning_logs (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  skill_id         UUID NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
  log_date         DATE NOT NULL,
  duration_minutes INT NOT NULL,
  notes            VARCHAR(255),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- v4.9.4 备注 (跟 salary_payments/subscriptions 那两条一样，迁移到 Supabase 时不要漏掉): 这台机器的
-- api.php 里有一个 generate_report()/build_report_content() 路径 (top-level action generate_report)，
-- 每次生成报表时按 user_id+report_type+period_start+period_end 判断"这个区间是不是已经生成过"，
-- 有就 UPDATE 覆盖、没有就 INSERT，content 字段是服务器算好的汇总 JSON 快照，不是用户手填的 ——
-- 纯应用层逻辑，不是数据库触发器，只建表不迁移这段逻辑的话，报表页面点"生成"不会真的填出内容。
CREATE TABLE reports (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  report_type  TEXT NOT NULL CHECK (report_type IN ('weekly','monthly','yearly')),
  period_start DATE NOT NULL,
  period_end   DATE NOT NULL,
  content      JSONB NOT NULL,
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, report_type, period_start, period_end)
);

CREATE TABLE ai_conversations (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  title      VARCHAR(255),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE ai_messages (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  conversation_id UUID NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,
  role            TEXT NOT NULL CHECK (role IN ('user','assistant')),
  content         TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE automations (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name           VARCHAR(100) NOT NULL,
  trigger_type   VARCHAR(50) NOT NULL,
  trigger_config JSONB,
  action_type    VARCHAR(50) NOT NULL,
  action_config  JSONB,
  is_active      BOOLEAN NOT NULL DEFAULT true,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE webhook_logs (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  automation_id UUID REFERENCES automations(id) ON DELETE SET NULL,
  payload       JSONB,
  status        TEXT NOT NULL CHECK (status IN ('success','failed')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- v4.9.7 备注: 本地 MySQL 版新增了 role ('admin'/'user') 做管理员功能 (CRUD 其他用户 + 全库备份)，
-- 这里的 profiles 也加上对应字段做对齐 —— 但本地版是自建 users 表+密码判断，这里是 Supabase Auth
-- (auth.users)，管理员相关的几个 action (admin_list_users/admin_create_user/admin_update_user/
-- admin_delete_user/admin_export_full_sql) 迁移时要重新实现成 Postgres function 或用
-- service_role key 绕过 RLS 才能跨用户操作，不能直接照搬本地 PHP 的写法。
CREATE TABLE profiles (
  id           UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name VARCHAR(100),
  role         TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin','user')),
  timezone     VARCHAR(50) DEFAULT 'Asia/Kuala_Lumpur',
  locale       VARCHAR(10) DEFAULT 'zh-CN',
  avatar_text  VARCHAR(10),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_profiles_updated_at BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 新用户注册时自动建一行 profile
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, display_name) VALUES (NEW.id, NEW.email);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- 补回既有账号的 profile: 上面那个 trigger 只对"以后新注册"的账号生效 —— 如果是清空重建
-- public schema (跑 个人系统_supabase_删除所有表.sql 那份)，auth.users 不会被动到，
-- 里面本来就有的账号不会触发 INSERT，profiles 会变空，导致明明密码对却登不进去
-- (登入第一步 auth 验证会过，第二步去 profiles 找不到资料就报错)。这段就是补这个洞:
-- 每次重跑这份 schema 文件，都会把 auth.users 里"当下已经存在"的账号自动补一行 profile 回去。
INSERT INTO profiles (id, display_name)
SELECT id, split_part(email, '@', 1) FROM auth.users
ON CONFLICT (id) DO NOTHING;

-- 这个系统目前固定 Roderick 是管理员，重建后一律把他设回 admin (其余账号维持默认的 user)。
UPDATE profiles SET role = 'admin' WHERE id = 'fcab6bfd-882c-45db-b153-dabd2e35de92';

-- is_admin(): 给 RLS policy 判断"目前登入的这个人是不是 admin" 用。
-- SECURITY DEFINER 表示这个函数用建立者的权限跑 (能读 profiles 判断角色)，
-- 不受呼叫者当下的 RLS 限制，不然会变成"要先能读 profiles 才能判断能不能读 profiles"的死循环。
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT COALESCE((SELECT role = 'admin' FROM public.profiles WHERE id = auth.uid()), false);
$$;

CREATE TABLE settings (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  setting_key  VARCHAR(100) NOT NULL,
  value        JSONB,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, setting_key)
);
CREATE TRIGGER trg_settings_updated_at BEFORE UPDATE ON settings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- v4.5: repeat_rule != 'none' 的提醒，标记 is_sent 或者时间过了没处理时，api.php 会自动把 remind_at
-- 推到下一次并把 is_sent 重设回 false —— 这段"自动往后推"的逻辑跟 sync_salary_payment() 一样是
-- 应用层实现，不是数据库触发器；迁移到 Supabase 时同样要搬成 Postgres trigger/Edge Function。
-- v4.6: 网站表单只填"几点" (HH:MM)，日期由 api.php 自动算好拼成完整 remind_at 再存进来
-- (新增用今天/明天，编辑保留原本的日期只换时间) —— 这段逻辑同样是应用层，不是数据库层面的行为。
-- 2026-09-30: 原本用 related_type (task/habit/subscription/custom 固定枚举) + related_id
-- 这一对字段来分类/关联提醒，用户实际用起来发现不好用 (related_id 只是个裸的 UUID 输入框，
-- 不知道要填什么)，改成跟 transactions/tasks/bookmarks 一样的"标签"分类方式 (tag_id 外键连去
-- tags 表，tags.module='reminder' 这个分类下的标签)。related_note 保留当成自由备注用。
CREATE TABLE reminders (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  tag_id           UUID REFERENCES tags(id) ON DELETE SET NULL,
  related_note     VARCHAR(255),
  remind_at        TIMESTAMPTZ NOT NULL,
  message          VARCHAR(255) NOT NULL,
  is_sent          BOOLEAN NOT NULL DEFAULT false,
  repeat_rule      TEXT NOT NULL DEFAULT 'none' CHECK (repeat_rule IN ('none','daily','weekly','biweekly','monthly','yearly','custom')),
  repeat_interval  INT,
  repeat_unit      TEXT CHECK (repeat_unit IN ('day','week','month','year')),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE templates (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  template_type TEXT NOT NULL CHECK (template_type IN ('task','habit','journal')),
  name          VARCHAR(100) NOT NULL,
  content       JSONB NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE recurrence_rules (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  template_id  UUID REFERENCES templates(id) ON DELETE SET NULL,
  related_type TEXT NOT NULL CHECK (related_type IN ('task','habit','journal','custom')),
  related_id   UUID,
  rule         JSONB NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- Row Level Security: 对每张业务表开启 RLS 并加 policy
-- =====================================================================

-- profiles 不在下面这个通用循环里: 它的主键 id 本身就是 auth.users.id，没有独立的 user_id 列，
-- 用循环里那句通用 policy 模板 (USING (auth.uid() = user_id)) 会直接报错 "column user_id does not
-- exist" 而中断整个脚本 —— 这是之前这份文件真正跑不起来的原因，profiles 单独处理，其余表照旧。
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own profile only" ON profiles FOR ALL USING (auth.uid() = id) WITH CHECK (auth.uid() = id);
-- admin 账号额外可以看到"所有人"的 profile (自己管理面板/全库备份功能要用)，
-- 一般账号不受影响 —— 上面那条 policy 还在，两条 policy 是 OR 关系，多加这条只会放宽、不会收紧权限。
CREATE POLICY "admin can view all" ON profiles FOR SELECT USING (public.is_admin());

DO $$
DECLARE
  t TEXT;
BEGIN
  FOR t IN
    SELECT unnest(ARRAY[
      'project_categories','projects','tasks','habits','habit_logs','journal_entries','inbox_items',
      'bank_accounts','banks','tags','salary_profiles','salary_payments','epf_contributions',
      'socso_contributions','eis_contributions',
      'categories','transactions','budgets','subscriptions','daily_metrics','fixed_deposits',
      'exercises','workouts','workout_sets','media_entries','reading_logs',
      'bookmarks','goals','key_results','time_blocks',
      'contacts','interactions','pantry_items','recipes','shopping_list',
      'trips','trip_items','skills','learning_logs','reports',
      'ai_conversations','ai_messages','automations','webhook_logs',
      'settings','reminders','templates','recurrence_rules'
    ])
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format(
      'CREATE POLICY "own rows only" ON %I FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);',
      t
    );
    -- 同上面 profiles 那条：admin 额外可以看到所有人的资料，一般账号不受影响。
    EXECUTE format(
      'CREATE POLICY "admin can view all" ON %I FOR SELECT USING (public.is_admin());',
      t
    );
  END LOOP;
END $$;

-- =====================================================================
-- 种子数据: 建好账号、跑一次 Supabase Auth 注册后，把下面的 user_id 换成你的
-- 真实 auth.users.id (Dashboard -> Authentication -> Users 里能看到), 再执行
-- =====================================================================

-- INSERT INTO categories (user_id, name, type, color) VALUES
--   ('替换成你的-user-id', '薪水', 'income', '#22c55e'),
--   ('替换成你的-user-id', '餐饮', 'expense', '#ef4444'),
--   ('替换成你的-user-id', '交通', 'expense', '#f59e0b'),
--   ('替换成你的-user-id', '娱乐', 'expense', '#8b5cf6');
