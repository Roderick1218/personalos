-- =====================================================================
-- 个人生活 OS 系统 - 数据库 Schema (Supabase / Postgres 版)
-- 用途: 直接丢进 Supabase Dashboard -> SQL Editor 执行
-- 对应本地测试版: 个人系统_schema_mysql.sql
-- =====================================================================

-- 每张表都有 user_id，靠 auth.uid() 做 Row Level Security 隔离数据。
-- 就算你现在只有自己一个人用，也建议保留，安全性靠这个而不是"没人知道网址"。

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
  module  TEXT NOT NULL CHECK (module IN ('finance','task','link'))
);

CREATE TABLE tasks (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  project_id   UUID REFERENCES projects(id) ON DELETE SET NULL,
  tag_id       UUID REFERENCES tags(id) ON DELETE SET NULL, -- v3
  title        VARCHAR(255) NOT NULL,
  description  TEXT,
  status       TEXT NOT NULL DEFAULT 'inbox' CHECK (status IN ('inbox','today','upcoming','done')),
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
  tags       JSONB,
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
CREATE TABLE epf_contributions (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                  UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  salary_payment_id        UUID REFERENCES salary_payments(id) ON DELETE CASCADE,
  contribution_date        DATE NOT NULL,
  employee_contribution    NUMERIC(12,2) NOT NULL DEFAULT 0,
  employer_contribution    NUMERIC(12,2) NOT NULL DEFAULT 0,
  additional_contribution  NUMERIC(12,2) NOT NULL DEFAULT 0,
  notes                    VARCHAR(255),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now()
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

CREATE TABLE budgets (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  category_id UUID REFERENCES categories(id) ON DELETE CASCADE,
  month       DATE NOT NULL,
  amount      NUMERIC(12,2) NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (category_id, month)
);

CREATE TABLE subscriptions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  name              VARCHAR(100) NOT NULL,
  cost              NUMERIC(10,2) NOT NULL,
  billing_cycle     TEXT NOT NULL DEFAULT 'monthly' CHECK (billing_cycle IN ('monthly','yearly')),
  next_billing_date DATE,
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
  tags              JSONB, -- v2: 合并联系人与生日模块的标签 (如 大学朋友/同事)
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

CREATE TABLE reports (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  report_type  TEXT NOT NULL CHECK (report_type IN ('weekly','monthly')),
  period_start DATE NOT NULL,
  period_end   DATE NOT NULL,
  content      JSONB NOT NULL,
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, report_type, period_start)
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

CREATE TABLE profiles (
  id           UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name VARCHAR(100),
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
-- related_note 是 related_type='custom' 时的自由文字说明，related_id 对 custom 类型没有意义。
CREATE TABLE reminders (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
  related_type     TEXT NOT NULL CHECK (related_type IN ('task','habit','subscription','custom')),
  related_id       UUID,
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

DO $$
DECLARE
  t TEXT;
BEGIN
  FOR t IN
    SELECT unnest(ARRAY[
      'project_categories','projects','tasks','habits','habit_logs','journal_entries','inbox_items',
      'bank_accounts','banks','tags','salary_profiles','salary_payments','epf_contributions',
      'categories','transactions','budgets','subscriptions','daily_metrics',
      'exercises','workouts','workout_sets','media_entries','reading_logs',
      'bookmarks','goals','key_results','time_blocks',
      'contacts','interactions','pantry_items','recipes','shopping_list',
      'trips','trip_items','skills','learning_logs','reports',
      'ai_conversations','ai_messages','automations','webhook_logs',
      'profiles','settings','reminders','templates','recurrence_rules'
    ])
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format(
      'CREATE POLICY "own rows only" ON %I FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);',
      t
    );
  END LOOP;

  -- profiles 表主键就是 user_id (=id)，policy 条件不同
  EXECUTE 'DROP POLICY "own rows only" ON profiles;';
  EXECUTE 'CREATE POLICY "own profile only" ON profiles FOR ALL USING (auth.uid() = id) WITH CHECK (auth.uid() = id);';
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
