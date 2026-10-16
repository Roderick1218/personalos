// 网站不再打 api.php，直接连 Supabase。登入走 Supabase Auth，数据隔离靠 RLS
// (auth.uid() = user_id)，数据库自己挡，不用每个查询手动加 WHERE user_id = ?。
//
// 这个文件只做一件事: 提供跟原本 api()/rawApi() 完全一样的呼叫方式 (同样的
// {resource, action, ...} 参数形状，同样回传 {ok, data/...}) 但内部改成呼叫 Supabase，
// 这样 app.js 里几千行 UI 逻辑完全不用大改，只要把 api()/rawApi() 两个函数体
// 换成呼叫这里的 SupabaseBridge.call()/rawCall() 就行。

const SUPABASE_URL = 'https://xpbtyfattbqsaasmokoy.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhwYnR5ZmF0dGJxc2Fhc21va295Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAyMzQ3MzEsImV4cCI6MjEwNTgxMDczMX0.wzP8YkevvVGi4aEtyMg7TKyzfEsjJPLieyh2wTICt6U';

const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// 新账号用真实邮箱注册登录；旧账号是用户名拼假邮箱，登录时输入不含 @ 的用户名会自动回退。
const USER_EMAIL_DOMAIN = '@personalos.app';
const LEGACY_USER_EMAIL_DOMAIN = '@personalos.local';

function looksLikeEmail(value) {
  return /.+@.+\..+/.test(String(value || '').trim());
}

function usernameToEmail(username, domain) {
  return String(username || '').trim().toLowerCase() + (domain || USER_EMAIL_DOMAIN);
}

function stripEmailDomain(email) {
  const s = String(email || '').trim();
  if (/@personalos\.(app|local)$/i.test(s)) return s.replace(/@personalos\.(app|local)$/i, '');
  return s;
}

async function signInWithIdentifier(identifier, password) {
  const raw = String(identifier || '').trim();
  if (!raw) return { data: null, error: { message: '请填写邮箱' } };
  if (looksLikeEmail(raw)) {
    return sb.auth.signInWithPassword({ email: raw.toLowerCase(), password });
  }
  let result = await sb.auth.signInWithPassword({ email: usernameToEmail(raw), password });
  if (result.error) {
    result = await sb.auth.signInWithPassword({
      email: usernameToEmail(raw, LEGACY_USER_EMAIL_DOMAIN), password,
    });
  }
  return result;
}

let META_CACHE = null;
async function loadMetaConfig() {
  if (META_CACHE) return META_CACHE;
  // config_resources.json 不像 app.js/supabase_bridge.js 那样有 ?v=xxx 版本号可以手动 bump
  // (.htaccess 的强制不缓存规则也只套用在 .html/.php，不含 .json) —— 每次改完
  // config_resources.php 重新产生这份 json，浏览器都可能还在用旧的缓存版本，导致"改了但看起来
  // 没生效"。这里直接用 cache:'no-store' 让浏览器每次都真的重新问服务器要最新的，
  // 一劳永逸，不用再靠人記得手动加版本号。
  const res = await fetch('config_resources.json', { cache: 'no-store' });
  META_CACHE = await res.json();
  return META_CACHE;
}

function publicUserFrom(profile, email) {
  const mail = email || '';
  return {
    id: profile.id,
    username: profile.display_name || stripEmailDomain(mail),
    email: mail,
    display_name: profile.display_name || stripEmailDomain(mail),
    role: profile.role,
  };
}

async function fetchProfile(userId) {
  const { data, error } = await sb.from('profiles').select('id, display_name, email, role').eq('id', userId).maybeSingle();
  if (data) return data;
  const { data: inserted } = await sb.from('profiles').insert({ id: userId, display_name: 'User', role: 'user' }).select().single();
  if (inserted) return inserted;
  if (error) throw error;
  return { id: userId, display_name: 'User', role: 'user' };
}

async function requireAdmin() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error('请先登录');
  const profile = await fetchProfile(session.user.id);
  if (profile.role !== 'admin') throw new Error('只有管理员能做这个操作');
  return profile;
}

async function wouldRemoveLastAdmin(targetId) {
  const { data: admins, error } = await sb.from('profiles').select('id').eq('role', 'admin');
  if (error) throw error;
  const remaining = (admins || []).filter(a => a.id !== targetId);
  return remaining.length === 0;
}

// 把旧版 filters (两种格式: {field: value} 或 [{field, op, value}, ...]) 套用到
// supabase-js 的 query builder 上，等价于原本 api.php list action 的过滤逻辑。
function applyFilters(query, filters) {
  if (!filters) return query;
  const list = Array.isArray(filters)
    ? filters
    : Object.entries(filters).map(([field, value]) => ({ field, op: 'eq', value }));
  for (const f of list) {
    if (f.value === null || f.value === undefined || f.value === '') continue;
    switch (f.op) {
      case 'gte': query = query.gte(f.field, f.value); break;
      case 'lte': query = query.lte(f.field, f.value); break;
      case 'like': query = query.ilike(f.field, `%${f.value}%`); break;
      default: query = query.eq(f.field, f.value);
    }
  }
  return query;
}

// 跟 api.php 原本的 normalize_value() 逐句对应 —— 最关键的一条: 表单里没填的欄位
// (日期/数字/fk下拉都可能是空字串) 一律转成 null，不能让空字串 '' 直接传给 date/uuid/numeric
// 栏位 (Postgres 会报 "invalid input syntax for type date" 这类错误，MySQL 反而不会挡，
// 这是这次从 api.php 搬到直连 Supabase 之后才冒出来的坑，MySQL 时代从来没发现)。
function normalizeValue(meta, value) {
  if (value === null || value === undefined || value === '') {
    return meta.type === 'boolean' ? false : null;
  }
  switch (meta.type) {
    case 'boolean':
      return value === true || value === 1 || value === '1' || value === 'true';
    case 'tags': {
      const trimmed = String(value).trim();
      if (trimmed === '') return '[]';
      if (trimmed[0] === '[') {
        try { JSON.parse(trimmed); return trimmed; } catch (_) { /* fall through */ }
      }
      const parts = trimmed.split(',').map(p => p.trim()).filter(p => p !== '');
      return JSON.stringify(parts);
    }
    case 'json':
      try { JSON.parse(value); return value; } catch (_) { return undefined; }
    case 'url': {
      let v = String(value).trim();
      if (!/^https?:\/\//i.test(v)) v = 'https://' + v;
      try { new URL(v); return v; } catch (_) { return undefined; }
    }
    default:
      return value;
  }
}

// 对整份表单资料套用 normalizeValue —— undefined 表示这个值不合法 (json/url 格式错误)，
// 呼叫端要检查有没有 undefined 并挡下来，不能就这样送进数据库。
function normalizeData(resource, data, config) {
  const fields = (config[resource] || {}).fields || {};
  const out = {};
  for (const [col, value] of Object.entries(data)) {
    const meta = fields[col];
    out[col] = meta ? normalizeValue(meta, value) : value;
  }
  return out;
}

// 删除前的"还有别的记录在用这个"保护 —— 原本是 api.php 的 $usageChecks 那段，
// 挪到前端做 (RLS 已经保证只会算到自己的资料，安全性没问题)。
const USAGE_CHECKS = {
  tags: [['transactions', 'tag_id'], ['tasks', 'tag_id'], ['bookmarks', 'tag_id']],
  bank_accounts: [['transactions', 'bank_account_id']],
  banks: [['bank_accounts', 'bank_id']],
};
async function checkInUse(resource, id) {
  const checks = USAGE_CHECKS[resource];
  if (!checks) return 0;
  for (const [refTable, refCol] of checks) {
    const { count, error } = await sb.from(refTable).select('id', { count: 'exact', head: true }).eq(refCol, id);
    if (error) throw error;
    if (count > 0) return count;
  }
  return 0;
}

// ---------------- 薪资/EPF/订阅/定存 自动化逻辑 ----------------
// 这几个函数是把 api.php 里同名 PHP 函数逐句翻译过来的 (SQL 查询换成 supabase-js 呼叫)，
// 算法完全照搬，注释也保留原本的意思。搬得动是因为 RLS 已经把"只能动自己的资料"这件事
// 挡在数据库那一层了，前端算这些东西不会有安全问题 (跟以前"必须在服务器算"的理由不一样了)。

function todayStr() { return new Date().toISOString().slice(0, 10); }
function ymStr(d) { return d.toISOString().slice(0, 7); }
function addDays(dateStr, days) {
  const d = new Date(dateStr + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}
function addMonths(dateStr, months) {
  const d = new Date(dateStr + 'T00:00:00Z');
  d.setUTCMonth(d.getUTCMonth() + months);
  return d.toISOString().slice(0, 10);
}
function daysBetween(a, b) {
  return Math.round((new Date(b + 'T00:00:00Z') - new Date(a + 'T00:00:00Z')) / 86400000);
}

async function getSalaryCategoryId(userId) {
  const { data } = await sb.from('categories').select('id').eq('type', 'income').eq('name', '薪水').eq('user_id', userId).limit(1).maybeSingle();
  return data ? data.id : null;
}

async function syncSalaryPayment(paymentId) {
  const { data: sp } = await sb.from('salary_payments').select('*').eq('id', paymentId).maybeSingle();
  if (!sp) return;

  if ((sp.status || 'paid') !== 'paid') {
    if (sp.transaction_id) {
      await sb.from('transactions').delete().eq('id', sp.transaction_id);
      await sb.from('salary_payments').update({ transaction_id: null }).eq('id', paymentId);
    }
    await sb.from('epf_contributions').delete().eq('salary_payment_id', paymentId);
    await sb.from('socso_contributions').delete().eq('salary_payment_id', paymentId);
    await sb.from('eis_contributions').delete().eq('salary_payment_id', paymentId);
    return;
  }

  const description = sp.period_label + ' 薪资';
  const categoryId = await getSalaryCategoryId(sp.user_id);

  if (sp.transaction_id) {
    await sb.from('transactions').update({
      category_id: categoryId, bank_account_id: sp.bank_account_id, amount: sp.net_salary,
      transaction_date: sp.payment_date, description,
    }).eq('id', sp.transaction_id);
  } else {
    const { data: txn } = await sb.from('transactions').insert({
      user_id: sp.user_id, category_id: categoryId, bank_account_id: sp.bank_account_id,
      type: 'income', amount: sp.net_salary, currency: 'MYR', description, transaction_date: sp.payment_date,
    }).select().single();
    await sb.from('salary_payments').update({ transaction_id: txn.id }).eq('id', paymentId);
  }

  const totalEpf = Number(sp.employee_epf_amount) + Number(sp.employer_epf_amount);
  const { data: existingRow } = await sb.from('epf_contributions').select('id').eq('salary_payment_id', paymentId).maybeSingle();

  if (totalEpf > 0) {
    const persaraanAmt = Math.round(totalEpf * 0.75 * 100) / 100;
    const sejahteraAmt = Math.round(totalEpf * 0.15 * 100) / 100;
    const fleksibelAmt = Math.round(totalEpf * 0.10 * 100) / 100;
    if (existingRow) {
      await sb.from('epf_contributions').update({
        contribution_date: sp.payment_date, employee_contribution: sp.employee_epf_amount,
        employer_contribution: sp.employer_epf_amount, persaraan_amount: persaraanAmt,
        sejahtera_amount: sejahteraAmt, fleksibel_amount: fleksibelAmt,
      }).eq('id', existingRow.id);
    } else {
      await sb.from('epf_contributions').insert({
        user_id: sp.user_id, salary_payment_id: paymentId, contribution_date: sp.payment_date,
        employee_contribution: sp.employee_epf_amount, employer_contribution: sp.employer_epf_amount,
        persaraan_percent: 75.0, sejahtera_percent: 15.0, fleksibel_percent: 10.0,
        persaraan_amount: persaraanAmt, sejahtera_amount: sejahteraAmt, fleksibel_amount: fleksibelAmt,
      });
    }
  } else if (existingRow) {
    await sb.from('epf_contributions').delete().eq('id', existingRow.id);
  }

  await syncSimpleContribution('socso_contributions', sp, paymentId, sp.employee_socso_amount, sp.employer_socso_amount);
  await syncSimpleContribution('eis_contributions', sp, paymentId, sp.employee_eis_amount, sp.employer_eis_amount);
}

// SOCSO/EIS 供款记录不像 EPF 有 Akaun 三户口要拆分，就是单纯"员工供款 + 雇主供款"两个数字，
// 跟 epf_contributions 那段一样按 salary_payment_id 当 upsert key，金额为 0 就当作没开启，删掉这笔。
async function syncSimpleContribution(table, sp, paymentId, employeeAmount, employerAmount) {
  const total = Number(employeeAmount || 0) + Number(employerAmount || 0);
  const { data: existingRow } = await sb.from(table).select('id').eq('salary_payment_id', paymentId).maybeSingle();
  if (total > 0) {
    if (existingRow) {
      await sb.from(table).update({
        contribution_date: sp.payment_date, employee_contribution: employeeAmount, employer_contribution: employerAmount,
      }).eq('id', existingRow.id);
    } else {
      await sb.from(table).insert({
        user_id: sp.user_id, salary_payment_id: paymentId, contribution_date: sp.payment_date,
        employee_contribution: employeeAmount, employer_contribution: employerAmount,
      });
    }
  } else if (existingRow) {
    await sb.from(table).delete().eq('id', existingRow.id);
  }
}

async function autoGenerateDueSalaryPayments(userId) {
  const generated = [], skipped = [];
  const today = todayStr();
  const monthStart = today.slice(0, 7) + '-01';
  const daysInMonth = new Date(Date.UTC(Number(today.slice(0, 4)), Number(today.slice(5, 7)), 0)).getUTCDate();
  // 有些公司发薪日虽然是这个月，但按比例算基本薪资时是拿"上个月"的天数当分母，不是这个月的
  // (跟发薪日对齐的周期本来就常常横跨月份，各家公司算法不完全一样，让每个薪资档案自己选)。
  const daysInPrevMonth = new Date(Date.UTC(Number(today.slice(0, 4)), Number(today.slice(5, 7)) - 1, 0)).getUTCDate();
  const periodLabel = today.slice(0, 7);

  const { data: profiles } = await sb.from('salary_profiles').select('*')
    .eq('user_id', userId).eq('status', 'active').eq('salary_frequency', 'monthly').not('salary_payment_day', 'is', null);

  for (const p of (profiles || [])) {
    const paymentDay = Math.min(p.salary_payment_day, daysInMonth);
    const paymentDate = today.slice(0, 8) + String(paymentDay).padStart(2, '0');
    if (paymentDate > today) continue;
    if (!p.bank_account_id) { skipped.push({ company_name: p.company_name, reason: '没有设置"入账账户"' }); continue; }
    if (p.end_date && p.end_date < monthStart) continue;
    if (p.start_date && p.start_date > paymentDate) continue;

    const { data: dup1 } = await sb.from('salary_payments').select('id').eq('user_id', userId).eq('period_label', periodLabel).eq('salary_profile_id', p.id).maybeSingle();
    if (dup1) continue;
    const { data: dup2 } = await sb.from('salary_payments').select('id').eq('user_id', userId).eq('period_label', periodLabel)
      .is('salary_profile_id', null).eq('bank_account_id', p.bank_account_id).like('notes', '系统根据薪资档案自动生成%').maybeSingle();
    if (dup2) continue;

    const monthEnd = new Date(Date.UTC(Number(today.slice(0, 4)), Number(today.slice(5, 7)), 0)).toISOString().slice(0, 10);
    const hasPartialStart = !!p.start_date && p.start_date > monthStart;
    const hasPartialEnd = !!p.end_date && p.end_date < monthEnd;
    const isFullMonth = !hasPartialStart && !hasPartialEnd;
    const periodStart = hasPartialStart ? p.start_date : monthStart;
    const periodEnd = hasPartialEnd ? p.end_date : paymentDate;

    let basicSalary = Number(p.basic_salary);
    if (!isFullMonth) {
      const daysWorked = daysBetween(periodStart, periodEnd) + 1;
      const proDivisor = p.prorate_basis === 'previous_month' ? daysInPrevMonth : daysInMonth;
      basicSalary = Math.round(basicSalary * daysWorked / proDivisor * 100) / 100;
    }
    const enableEpf = p.enable_epf !== false; // 旧资料没这个栏位时预设当作 true (维持原本一直都有算 EPF 的行为)
    const enableSocso = p.enable_socso === true;
    const empEpfPct = enableEpf ? Number(p.employee_epf_percent) : 0;
    const emprEpfPct = enableEpf ? Number(p.employer_epf_percent) : 0;
    const empEpfAmt = enableEpf ? Math.round(basicSalary * empEpfPct / 100 * 100) / 100 : 0;
    const emprEpfAmt = enableEpf ? Math.round(basicSalary * emprEpfPct / 100 * 100) / 100 : 0;
    const empSocsoPct = enableSocso ? Number(p.employee_socso_percent) : 0;
    const emprSocsoPct = enableSocso ? Number(p.employer_socso_percent) : 0;
    const empSocsoAmt = enableSocso ? Math.round(basicSalary * empSocsoPct / 100 * 100) / 100 : 0;
    const emprSocsoAmt = enableSocso ? Math.round(basicSalary * emprSocsoPct / 100 * 100) / 100 : 0;
    const enableEis = p.enable_eis === true;
    const empEisPct = enableEis ? Number(p.employee_eis_percent) : 0;
    const emprEisPct = enableEis ? Number(p.employer_eis_percent) : 0;
    const empEisAmt = enableEis ? Math.round(basicSalary * empEisPct / 100 * 100) / 100 : 0;
    const emprEisAmt = enableEis ? Math.round(basicSalary * emprEisPct / 100 * 100) / 100 : 0;
    // SOCSO/EIS 员工那一份也是从实收里扣的 (跟 EPF 员工那份一样，都会让到手的钱变少)
    const netSalary = Math.round((basicSalary - empEpfAmt - empSocsoAmt - empEisAmt) * 100) / 100;
    const notes = `系统根据薪资档案自动生成 (${new Date().toISOString().slice(0, 16).replace('T', ' ')})。如这个月有花红/津贴等额外收入，可以编辑这笔补上。`;

    const { data: ins } = await sb.from('salary_payments').insert({
      user_id: userId, salary_profile_id: p.id, payment_date: paymentDate, period_label: periodLabel,
      period_start: isFullMonth ? null : periodStart, period_end: isFullMonth ? null : periodEnd,
      basic_salary: basicSalary, employee_epf_percent: empEpfPct, employee_epf_amount: empEpfAmt,
      employer_epf_percent: emprEpfPct, employer_epf_amount: emprEpfAmt,
      employee_socso_percent: empSocsoPct, employee_socso_amount: empSocsoAmt,
      employer_socso_percent: emprSocsoPct, employer_socso_amount: emprSocsoAmt,
      employee_eis_percent: empEisPct, employee_eis_amount: empEisAmt,
      employer_eis_percent: emprEisPct, employer_eis_amount: emprEisAmt,
      net_salary: netSalary, bank_account_id: p.bank_account_id, status: 'paid', notes,
    }).select().single();
    await syncSalaryPayment(ins.id);
    generated.push({ salary_payment_id: ins.id, company_name: p.company_name, period_label: periodLabel, net_salary: netSalary });
  }
  return { generated, skipped };
}

async function autoGenerateDueSubscriptions(userId) {
  const generated = [], skipped = [];
  const today = todayStr();
  const { data: subs } = await sb.from('subscriptions').select('*').eq('user_id', userId).eq('is_active', true);

  for (const s of (subs || [])) {
    let due = s.next_billing_date || s.start_date;
    if (!due) continue;
    if (!s.bank_account_id) {
      if (due <= today) skipped.push({ name: s.name, reason: '没有设置"自动扣款账户"' });
      continue;
    }
    const originalDue = due;
    let guard = 0;
    while (due <= today && guard < 120) {
      await sb.from('transactions').insert({
        user_id: userId, type: 'expense', amount: s.cost, transaction_date: due,
        bank_account_id: s.bank_account_id, description: '订阅扣费: ' + s.name, currency: 'MYR',
      });
      generated.push({ subscription_id: s.id, name: s.name, amount: Number(s.cost), date: due });
      due = s.billing_cycle === 'yearly' ? addMonths(due, 12) : addMonths(due, 1);
      guard++;
    }
    if (due !== originalDue) {
      await sb.from('subscriptions').update({ next_billing_date: due }).eq('id', s.id);
    }
  }
  return { generated, skipped };
}

function nextReminderTime(fromDateTime, rule, interval, unit) {
  const d = new Date(fromDateTime.replace(' ', 'T') + (fromDateTime.length <= 10 ? 'T00:00:00' : ''));
  switch (rule) {
    case 'daily': d.setUTCDate(d.getUTCDate() + 1); break;
    case 'weekly': d.setUTCDate(d.getUTCDate() + 7); break;
    case 'biweekly': d.setUTCDate(d.getUTCDate() + 14); break;
    case 'monthly': d.setUTCMonth(d.getUTCMonth() + 1); break;
    case 'yearly': d.setUTCFullYear(d.getUTCFullYear() + 1); break;
    case 'custom': {
      const n = Math.max(1, Number(interval) || 1);
      if (unit === 'week') d.setUTCDate(d.getUTCDate() + n * 7);
      else if (unit === 'month') d.setUTCMonth(d.getUTCMonth() + n);
      else if (unit === 'year') d.setUTCFullYear(d.getUTCFullYear() + n);
      else d.setUTCDate(d.getUTCDate() + n);
      break;
    }
    default: break;
  }
  return d.toISOString().slice(0, 19).replace('T', ' ');
}

// reminders 特殊规则: 表单只填"几点" (HH:MM)，这里自动算好拼回完整的 remind_at。
// 新增: 这个点今天还没过就用今天，过了就用明天。编辑: 保留原本这条记录的日期，只换时间。
// 字串一定要带 +08:00，不然 Postgres 会当 UTC 存，提醒会晚 8 小时才触发。
async function applyReminderTimeRule(resource, action, id, data) {
  if (resource !== 'reminders' || !data || !/^\d{2}:\d{2}$/.test(String(data.remind_at || ''))) return data;
  const time = data.remind_at;
  let datePart;
  if (action === 'update') {
    const { data: ex } = await sb.from('reminders').select('remind_at').eq('id', id).maybeSingle();
    datePart = ex ? ex.remind_at.slice(0, 10) : todayStr();
  } else {
    datePart = todayStr();
    const candidateMs = new Date(`${datePart}T${time}:00+08:00`).getTime();
    if (candidateMs <= Date.now()) datePart = addDays(datePart, 1);
  }
  return { ...data, remind_at: `${datePart} ${time}:00+08:00` };
}

async function maybeAdvanceRecurringReminder(id) {
  const { data: r } = await sb.from('reminders').select('*').eq('id', id).maybeSingle();
  if (!r || !r.is_sent) return;
  if (!r.repeat_rule || r.repeat_rule === 'none') return;
  const next = nextReminderTime(r.remind_at, r.repeat_rule, r.repeat_interval, r.repeat_unit);
  await sb.from('reminders').update({ remind_at: next, is_sent: false }).eq('id', id);
}

async function advanceDueReminders(userId) {
  const now = new Date().toISOString().slice(0, 19).replace('T', ' ');
  const { data: rows } = await sb.from('reminders').select('*').eq('user_id', userId).not('repeat_rule', 'is', null).neq('repeat_rule', 'none').eq('is_sent', false).lte('remind_at', now);
  for (const r of (rows || [])) {
    let next = r.remind_at, guard = 0;
    while (next <= now && guard < 1000) {
      next = nextReminderTime(next, r.repeat_rule, r.repeat_interval, r.repeat_unit);
      guard++;
    }
    if (next !== r.remind_at) await sb.from('reminders').update({ remind_at: next }).eq('id', r.id);
  }
}

async function syncFixedDepositOpen(fdId) {
  const { data: fd } = await sb.from('fixed_deposits').select('*').eq('id', fdId).maybeSingle();
  if (!fd || !fd.source_account_id) return;
  const desc = `定存: 存入 (${fd.tenure_months}个月, 到期 ${fd.maturity_date})`;
  const { data: txn } = await sb.from('transactions').insert({
    user_id: fd.user_id, type: 'expense', amount: fd.principal, transaction_date: fd.start_date,
    bank_account_id: fd.source_account_id, description: desc, currency: 'MYR',
  }).select().single();
  await sb.from('fixed_deposits').update({ opening_transaction_id: txn.id }).eq('id', fdId);
}

// 编辑既有定存改了本金 (比如追加存入更多钱)，不该悄悄把当初开户那笔历史交易的金额改掉——
// 那是"那天真的发生过的事"，应该保留。这里改成另外补一笔"差额"交易，日期算今天 (改动发生的这一刻)，
// 反映"今天又多存了/取回了多少"这个新事实，账户余额才会正确跟着变动。
async function syncFixedDepositPrincipalChange(fdId, previousPrincipal) {
  const { data: fd } = await sb.from('fixed_deposits').select('*').eq('id', fdId).maybeSingle();
  if (!fd || !fd.source_account_id) return;
  const delta = Math.round((Number(fd.principal) - previousPrincipal) * 100) / 100;
  if (delta === 0) return;
  const today = todayStr();
  if (delta > 0) {
    await sb.from('transactions').insert({
      user_id: fd.user_id, type: 'expense', amount: delta, transaction_date: today,
      bank_account_id: fd.source_account_id,
      description: `定存追加本金 (RM ${previousPrincipal.toFixed(2)} → RM ${Number(fd.principal).toFixed(2)})`, currency: 'MYR',
    });
  } else {
    await sb.from('transactions').insert({
      user_id: fd.user_id, type: 'income', amount: Math.abs(delta), transaction_date: today,
      bank_account_id: fd.source_account_id,
      description: `定存减少本金退回账户 (RM ${previousPrincipal.toFixed(2)} → RM ${Number(fd.principal).toFixed(2)})`, currency: 'MYR',
    });
  }
}

async function autoGenerateDueFixedDeposits(userId) {
  const matured = [], skipped = [];
  const today = todayStr();
  const { data: fds } = await sb.from('fixed_deposits').select('*').eq('user_id', userId).eq('status', 'active');

  for (const fd of (fds || [])) {
    let current = fd, currentId = fd.id, guard = 0;
    while (current.maturity_date && current.maturity_date <= today && guard < 60) {
      const principal = Number(current.principal), rate = Number(current.interest_rate), months = Number(current.tenure_months);
      const interest = Math.round(principal * rate / 100 * months / 12 * 100) / 100;
      const maturityAmount = Math.round((principal + interest) * 100) / 100;

      if (current.maturity_action === 'renew') {
        const newStart = current.maturity_date;
        const newMaturity = addMonths(newStart, months);
        const { data: ins } = await sb.from('fixed_deposits').insert({
          user_id: userId, bank_id: current.bank_id, principal: maturityAmount, interest_rate: rate,
          tenure_months: months, start_date: newStart, maturity_date: newMaturity,
          maturity_action: current.maturity_action, destination_account_id: current.destination_account_id,
          status: 'active', renewed_from_id: currentId,
        }).select().single();
        await sb.from('fixed_deposits').update({ status: 'matured' }).eq('id', currentId);
        matured.push({ id: currentId, action: 'renew', principal, interest, new_id: ins.id, new_maturity_date: newMaturity });
        current = { id: ins.id, bank_id: current.bank_id, principal: maturityAmount, interest_rate: rate, tenure_months: months,
          start_date: newStart, maturity_date: newMaturity, maturity_action: current.maturity_action,
          destination_account_id: current.destination_account_id };
        currentId = ins.id;
      } else {
        if (!current.destination_account_id) { skipped.push({ id: currentId, reason: '没有设置"到期转入账户"' }); break; }
        const desc = `定存到期: 本金 RM ${principal.toFixed(2)} + 利息 RM ${interest.toFixed(2)}`;
        await sb.from('transactions').insert({
          user_id: userId, type: 'income', amount: maturityAmount, transaction_date: current.maturity_date,
          bank_account_id: current.destination_account_id, description: desc, currency: 'MYR',
        });
        await sb.from('fixed_deposits').update({ status: 'matured' }).eq('id', currentId);
        matured.push({ id: currentId, action: 'transfer', principal, interest, total: maturityAmount });
        break;
      }
      guard++;
    }
  }
  return { matured, skipped };
}

async function computeBankBalances(userId) {
  const { data: accounts } = await sb.from('bank_accounts').select('*').eq('user_id', userId).eq('is_active', true).order('id');
  const result = [];
  for (const a of (accounts || [])) {
    const { data: txns } = await sb.from('transactions').select('type,amount,bank_account_id,transfer_to_account_id').eq('user_id', userId);
    let income = 0, expense = 0, transferOut = 0, transferIn = 0;
    for (const t of (txns || [])) {
      const amt = Number(t.amount);
      if (t.type === 'income' && t.bank_account_id === a.id) income += amt;
      else if (t.type === 'expense' && t.bank_account_id === a.id) expense += amt;
      else if (t.type === 'transfer' && t.bank_account_id === a.id) transferOut += amt;
      else if (t.type === 'transfer' && t.transfer_to_account_id === a.id) transferIn += amt;
    }
    const current_balance = Math.round((Number(a.opening_balance) + income - expense - transferOut + transferIn) * 100) / 100;
    result.push({ ...a, current_balance, account_number_masked: a.account_number ? '**** ' + a.account_number.slice(-4) : null });
  }
  return result;
}

async function buildDashboard(userId) {
  const today = todayStr();
  const out = { ok: true, date: today };

  const salaryAuto = await autoGenerateDueSalaryPayments(userId);
  out.auto_generated_salary = salaryAuto.generated;
  out.auto_generate_skipped_salary = salaryAuto.skipped;
  const subAuto = await autoGenerateDueSubscriptions(userId);
  out.auto_generated_subscriptions = subAuto.generated;
  out.auto_generate_skipped_subscriptions = subAuto.skipped;
  const fdAuto = await autoGenerateDueFixedDeposits(userId);
  out.auto_matured_fixed_deposits = fdAuto.matured;
  out.auto_generate_skipped_fixed_deposits = fdAuto.skipped;

  // 状态只有 todo/done 两种，仪表盘显示全部未完成任务，不挑"今天"的。
  const { data: tasksToday } = await sb.from('tasks').select('*').eq('user_id', userId).eq('status', 'todo').order('priority', { ascending: false }).order('id', { ascending: false });
  out.tasks_today = tasksToday || [];

  const { data: habits } = await sb.from('habits').select('*').eq('user_id', userId).eq('is_active', true).order('id');
  const { data: logs } = await sb.from('habit_logs').select('habit_id,completed').eq('user_id', userId).eq('log_date', today);
  const logMap = {};
  for (const l of (logs || [])) logMap[l.habit_id] = !!l.completed;
  out.habits = (habits || []).map(h => ({ ...h, checked_today: logMap[h.id] || false }));

  // 备忘录现在一天能写多条，不能再用 maybeSingle (超过一条会报错)，改成拿当天最新一条 + 总数。
  const { data: journalRows } = await sb.from('journal_entries').select('*').eq('user_id', userId).eq('entry_date', today).order('created_at', { ascending: false });
  out.journal_today = (journalRows && journalRows[0]) || null;
  out.journal_today_count = (journalRows || []).length;

  const { data: txnsToday } = await sb.from('transactions').select('*').eq('user_id', userId).eq('transaction_date', today).order('id', { ascending: false });
  out.transactions_today = txnsToday || [];
  out.income_today = (txnsToday || []).filter(r => r.type === 'income').reduce((s, r) => s + Number(r.amount), 0);
  out.expense_today = (txnsToday || []).filter(r => r.type === 'expense').reduce((s, r) => s + Number(r.amount), 0);

  const bankAccounts = await computeBankBalances(userId);
  out.bank_accounts = bankAccounts;
  out.total_balance = bankAccounts.reduce((s, a) => s + a.current_balance, 0);

  const { data: fdAgg } = await sb.from('fixed_deposits').select('principal').eq('user_id', userId).eq('status', 'active');
  out.fixed_deposits_total = (fdAgg || []).reduce((s, r) => s + Number(r.principal), 0);
  out.fixed_deposits_count = (fdAgg || []).length;

  const monthStart = today.slice(0, 7) + '-01';
  const monthEnd = new Date(Date.UTC(Number(today.slice(0, 4)), Number(today.slice(5, 7)), 0)).toISOString().slice(0, 10);
  const { data: monthRows } = await sb.from('transactions').select('*').eq('user_id', userId).gte('transaction_date', monthStart).lte('transaction_date', monthEnd);
  let monthIncome = 0, monthExpense = 0;
  const categoryTotals = {};
  for (const r of (monthRows || [])) {
    if (r.type === 'income') monthIncome += Number(r.amount);
    else if (r.type === 'expense') {
      monthExpense += Number(r.amount);
      const cid = r.category_id || 'none';
      categoryTotals[cid] = (categoryTotals[cid] || 0) + Number(r.amount);
    }
  }
  out.month_income = monthIncome;
  out.month_expense = monthExpense;

  const { data: categories } = await sb.from('categories').select('*').eq('user_id', userId);
  const categoryById = {};
  for (const c of (categories || [])) categoryById[c.id] = c;
  const breakdown = Object.entries(categoryTotals).map(([cid, amount]) => {
    const cat = categoryById[cid];
    return { label: cat ? cat.name : '未分类', color: cat ? cat.color : '#9CA3AF', amount: Math.round(amount * 100) / 100 };
  }).sort((a, b) => b.amount - a.amount);
  out.category_breakdown = breakdown;

  const { data: recentRows } = await sb.from('transactions').select('*').eq('user_id', userId).order('transaction_date', { ascending: false }).order('id', { ascending: false }).limit(5);
  out.recent_transactions = (recentRows || []).map(r => {
    const cat = categoryById[r.category_id];
    return { ...r, category_label: cat ? cat.name : '未分类', category_icon: cat ? cat.icon : '💳' };
  });

  const { data: activeProfiles } = await sb.from('salary_profiles').select('*').eq('user_id', userId).eq('status', 'active').eq('salary_frequency', 'monthly');
  out.expected_monthly_salary = (activeProfiles || []).reduce((s, p) => s + Number(p.basic_salary), 0);

  const { data: paidRows } = await sb.from('salary_payments').select('net_salary').eq('user_id', userId).eq('status', 'paid').gte('payment_date', monthStart).lte('payment_date', monthEnd);
  out.actual_monthly_salary = (paidRows || []).reduce((s, r) => s + Number(r.net_salary), 0);

  const { data: epfRows } = await sb.from('epf_contributions').select('employee_contribution,employer_contribution,additional_contribution,persaraan_amount,sejahtera_amount,fleksibel_amount').eq('user_id', userId);
  const epfSum = (epfRows || []).reduce((acc, r) => ({
    emp: acc.emp + Number(r.employee_contribution), empr: acc.empr + Number(r.employer_contribution),
    add: acc.add + Number(r.additional_contribution || 0), persaraan: acc.persaraan + Number(r.persaraan_amount || 0),
    sejahtera: acc.sejahtera + Number(r.sejahtera_amount || 0), fleksibel: acc.fleksibel + Number(r.fleksibel_amount || 0),
  }), { emp: 0, empr: 0, add: 0, persaraan: 0, sejahtera: 0, fleksibel: 0 });
  out.epf_cumulative = {
    employee: epfSum.emp, employer: epfSum.empr, additional: epfSum.add,
    total: epfSum.emp + epfSum.empr + epfSum.add, persaraan: epfSum.persaraan, sejahtera: epfSum.sejahtera, fleksibel: epfSum.fleksibel,
  };

  const { data: socsoRows } = await sb.from('socso_contributions').select('employee_contribution,employer_contribution').eq('user_id', userId);
  const socsoSum = (socsoRows || []).reduce((acc, r) => ({
    emp: acc.emp + Number(r.employee_contribution), empr: acc.empr + Number(r.employer_contribution),
  }), { emp: 0, empr: 0 });
  out.socso_cumulative = { employee: socsoSum.emp, employer: socsoSum.empr, total: socsoSum.emp + socsoSum.empr };

  const { data: eisRows } = await sb.from('eis_contributions').select('employee_contribution,employer_contribution').eq('user_id', userId);
  const eisSum = (eisRows || []).reduce((acc, r) => ({
    emp: acc.emp + Number(r.employee_contribution), empr: acc.empr + Number(r.employer_contribution),
  }), { emp: 0, empr: 0 });
  out.eis_cumulative = { employee: eisSum.emp, employer: eisSum.empr, total: eisSum.emp + eisSum.empr };

  const { data: metricToday } = await sb.from('daily_metrics').select('*').eq('user_id', userId).eq('metric_date', today).maybeSingle();
  out.metric_today = metricToday;

  const { data: inbox } = await sb.from('inbox_items').select('*').eq('user_id', userId).eq('is_processed', false).order('id', { ascending: false }).limit(10);
  out.inbox_unprocessed = inbox || [];

  const { data: subsActive } = await sb.from('subscriptions').select('*').eq('user_id', userId).eq('is_active', true).not('next_billing_date', 'is', null);
  const upcomingSubs = [];
  for (const s of (subsActive || [])) {
    const daysUntil = daysBetween(today, s.next_billing_date);
    if (daysUntil >= 0 && daysUntil <= s.remind_days_before) upcomingSubs.push({ ...s, days_until: daysUntil });
  }
  upcomingSubs.sort((a, b) => a.days_until - b.days_until);
  out.upcoming_subscriptions = upcomingSubs;

  const { data: contacts } = await sb.from('contacts').select('*').eq('user_id', userId).not('birthday', 'is', null);
  const upcomingBirthdays = [];
  const todayYear = Number(today.slice(0, 4));
  for (const c of (contacts || [])) {
    let next = todayYear + '-' + c.birthday.slice(5, 10);
    if (next < today) next = (todayYear + 1) + '-' + c.birthday.slice(5, 10);
    const daysUntil = daysBetween(today, next);
    if (daysUntil >= 0 && daysUntil <= c.remind_days_before) upcomingBirthdays.push({ ...c, days_until: daysUntil });
  }
  upcomingBirthdays.sort((a, b) => a.days_until - b.days_until);
  out.upcoming_birthdays = upcomingBirthdays;

  return out;
}

// ---------------- 搜索 / 报表 / 导出 ----------------

const SEARCH_TARGETS = {
  transactions: { cols: ['description'], title: r => r.description || '（无说明）', sub: r => 'RM ' + Number(r.amount).toFixed(2) + ' · ' + r.transaction_date },
  salary_payments: { cols: ['period_label', 'notes'], title: r => r.period_label, sub: r => 'RM ' + Number(r.net_salary).toFixed(2) + ' · ' + r.payment_date },
  tasks: { cols: ['title', 'description'], title: r => r.title, sub: r => r.status || '' },
  projects: { cols: ['name', 'description'], title: r => r.name, sub: r => r.status || '' },
  contacts: { cols: ['name', 'notes'], title: r => r.name, sub: r => r.phone || '' },
  bookmarks: { cols: ['title', 'url'], title: r => r.title || r.url, sub: r => r.url },
  journal_entries: { cols: ['content'], title: r => r.entry_date, sub: r => (r.content || '').slice(0, 40) },
  subscriptions: { cols: ['name', 'notes'], title: r => r.name, sub: r => 'RM ' + Number(r.cost).toFixed(2) },
  reminders: { cols: ['message'], title: r => r.message, sub: r => r.remind_at || '' },
};

async function runSearch(q) {
  q = (q || '').trim();
  if (!q) return { ok: true, results: [] };
  const config = await loadMetaConfig();
  const results = [];
  for (const [tbl, spec] of Object.entries(SEARCH_TARGETS)) {
    const orExpr = spec.cols.map(c => `${c}.ilike.%${q}%`).join(',');
    const { data } = await sb.from(tbl).select('*').or(orExpr).order('id', { ascending: false }).limit(8);
    for (const row of (data || [])) {
      results.push({
        resource: tbl, resource_label: (config[tbl] || {}).label || tbl, icon: (config[tbl] || {}).icon || '📄',
        id: row.id, title: String(spec.title(row)), sub: String(spec.sub(row)),
      });
    }
  }
  return { ok: true, results };
}

async function generateReport(reportType, periodStart, periodEnd) {
  const { data: { session } } = await sb.auth.getSession();
  const userId = session.user.id;
  const content = { period_start: periodStart, period_end: periodEnd };

  const { data: rows } = await sb.from('transactions').select('*').eq('user_id', userId).gte('transaction_date', periodStart).lte('transaction_date', periodEnd);
  const { data: categories } = await sb.from('categories').select('*').eq('user_id', userId);
  const categoryById = {};
  for (const c of (categories || [])) categoryById[c.id] = c;

  let income = 0, expense = 0;
  const categoryTotals = {};
  for (const r of (rows || [])) {
    if (r.type === 'income') income += Number(r.amount);
    else if (r.type === 'expense') {
      expense += Number(r.amount);
      const cid = r.category_id || 'none';
      categoryTotals[cid] = (categoryTotals[cid] || 0) + Number(r.amount);
    }
  }
  content.income_total = Math.round(income * 100) / 100;
  content.expense_total = Math.round(expense * 100) / 100;
  content.net = Math.round((income - expense) * 100) / 100;
  content.category_breakdown = Object.entries(categoryTotals).map(([cid, amount]) => {
    const cat = categoryById[cid];
    return { label: cat ? cat.name : '未分类', color: cat ? cat.color : '#9CA3AF', amount: Math.round(amount * 100) / 100 };
  }).sort((a, b) => b.amount - a.amount);

  const expenseRows = (rows || []).filter(r => r.type === 'expense').sort((a, b) => Number(b.amount) - Number(a.amount));
  content.top_expenses = expenseRows.slice(0, 5).map(r => {
    const cat = categoryById[r.category_id];
    return { description: r.description || (cat ? cat.name : '未分类'), amount: Number(r.amount), date: r.transaction_date, category_label: cat ? cat.name : '未分类' };
  });

  const { data: paidRows } = await sb.from('salary_payments').select('net_salary').eq('user_id', userId).eq('status', 'paid').gte('payment_date', periodStart).lte('payment_date', periodEnd);
  content.salary_received = (paidRows || []).reduce((s, r) => s + Number(r.net_salary), 0);

  const { data: epfRows } = await sb.from('epf_contributions').select('employee_contribution,employer_contribution,additional_contribution').eq('user_id', userId).gte('contribution_date', periodStart).lte('contribution_date', periodEnd);
  content.epf_contributed = (epfRows || []).reduce((acc, r) => ({
    employee: acc.employee + Number(r.employee_contribution), employer: acc.employer + Number(r.employer_contribution),
    additional: acc.additional + Number(r.additional_contribution || 0),
  }), { employee: 0, employer: 0, additional: 0 });

  let subCount = 0, subTotal = 0;
  for (const r of (rows || [])) {
    if (r.type === 'expense' && (r.description || '').startsWith('订阅扣费: ')) { subCount++; subTotal += Number(r.amount); }
  }
  content.subscriptions_charged = { count: subCount, total: Math.round(subTotal * 100) / 100 };

  const accountBalances = await computeBankBalancesAsOf(userId, periodEnd);
  content.account_balances = accountBalances.map(a => ({ nickname: a.nickname, kind: a.account_kind, balance: a.current_balance }));
  content.total_balance_at_period_end = Math.round(accountBalances.reduce((s, a) => s + a.current_balance, 0) * 100) / 100;

  const { data: habitLogs } = await sb.from('habit_logs').select('habit_id, habits(name)').eq('user_id', userId).eq('completed', true).gte('log_date', periodStart).lte('log_date', periodEnd);
  const habitCounts = {};
  for (const l of (habitLogs || [])) {
    const name = l.habits ? l.habits.name : '未知习惯';
    habitCounts[name] = (habitCounts[name] || 0) + 1;
  }
  content.habit_checkins = Object.entries(habitCounts).map(([name, cnt]) => ({ name, cnt })).sort((a, b) => b.cnt - a.cnt);

  const { count: journalCount } = await sb.from('journal_entries').select('id', { count: 'exact', head: true }).eq('user_id', userId).gte('entry_date', periodStart).lte('entry_date', periodEnd);
  content.journal_entry_count = journalCount || 0;

  const contentJson = content;
  const { data: existing } = await sb.from('reports').select('id').eq('user_id', userId).eq('report_type', reportType).eq('period_start', periodStart).eq('period_end', periodEnd).maybeSingle();
  let id;
  if (existing) {
    await sb.from('reports').update({ content: contentJson, generated_at: new Date().toISOString() }).eq('id', existing.id);
    id = existing.id;
  } else {
    const { data: ins } = await sb.from('reports').insert({ user_id: userId, report_type: reportType, period_start: periodStart, period_end: periodEnd, content: contentJson }).select().single();
    id = ins.id;
  }
  return { ok: true, id, report_type: reportType, content };
}

async function computeBankBalancesAsOf(userId, asOfDate) {
  const { data: accounts } = await sb.from('bank_accounts').select('*').eq('user_id', userId).eq('is_active', true).order('id');
  const result = [];
  for (const a of (accounts || [])) {
    const { data: txns } = await sb.from('transactions').select('type,amount,bank_account_id,transfer_to_account_id').eq('user_id', userId).lte('transaction_date', asOfDate);
    let income = 0, expense = 0, transferOut = 0, transferIn = 0;
    for (const t of (txns || [])) {
      const amt = Number(t.amount);
      if (t.type === 'income' && t.bank_account_id === a.id) income += amt;
      else if (t.type === 'expense' && t.bank_account_id === a.id) expense += amt;
      else if (t.type === 'transfer' && t.bank_account_id === a.id) transferOut += amt;
      else if (t.type === 'transfer' && t.transfer_to_account_id === a.id) transferIn += amt;
    }
    const current_balance = Math.round((Number(a.opening_balance) + income - expense - transferOut + transferIn) * 100) / 100;
    result.push({ ...a, current_balance });
  }
  return result;
}

function toCsvLine(values) {
  return values.map(v => '"' + String(v ?? '').replace(/"/g, '""') + '"').join(',');
}

async function exportCsv(resource, filters) {
  const config = await loadMetaConfig();
  const fields = config[resource].fields;
  const { data: { session } } = await sb.auth.getSession();
  let query = sb.from(resource).select('*').eq('user_id', session.user.id).order('id', { ascending: false }).limit(5000);
  query = applyFilters(query, filters);
  const { data: rows, error } = await query;
  if (error) throw error;

  const fkMaps = {};
  for (const [col, meta] of Object.entries(fields)) {
    if (meta.type !== 'fk') continue;
    const fkTable = meta.fk_resource;
    const fkDisplay = (config[fkTable] || {}).display_field || 'id';
    const { data: fkRows } = await sb.from(fkTable).select(`id, ${fkDisplay}`);
    const map = {};
    for (const r of (fkRows || [])) map[r.id] = r[fkDisplay];
    fkMaps[col] = map;
  }

  const columns = Object.keys(fields);
  const lines = [toCsvLine(columns.map(c => fields[c].label))];
  for (const row of rows) {
    lines.push(toCsvLine(columns.map(c => {
      let v = row[c] ?? '';
      if (fkMaps[c] && v !== '' && v !== null) v = fkMaps[c][v] ?? v;
      return v;
    })));
  }
  return { ok: true, csv: lines.join('\n'), filename: resource + '_' + todayStr().replace(/-/g, '') + '.csv' };
}

async function adminExportFullSql() {
  await requireAdmin();
  // 走资料库端函数：不分页、含全部 public 表 + auth.users / identities（密码哈希）。
  const { data, error } = await sb.rpc('admin_export_full_sql');
  if (error) throw error;
  const sql = typeof data === 'string' ? data : (data && data.sql) || '';
  if (!sql) throw new Error('备份是空的，请稍后再试');
  return { ok: true, sql, filename: 'personal_os_full_backup_' + todayStr().replace(/-/g, '') + '.sql' };
}

async function exportMySql() {
  const config = await loadMetaConfig();
  const { data: { session } } = await sb.auth.getSession();
  const userId = session.user.id;
  let sql = `-- personal_os 我的数据导出 (${new Date().toISOString()})，仅包含当前账号自己的数据\n\n`;
  for (const [tbl, cfg] of Object.entries(config)) {
    if (!cfg.user_scoped) continue;
    const { data: rows } = await sb.from(tbl).select('*').eq('user_id', userId);
    if (!rows || !rows.length) continue;
    for (const row of rows) {
      const cols = Object.keys(row);
      const vals = cols.map(c => {
        const v = row[c];
        if (v === null || v === undefined) return 'NULL';
        if (typeof v === 'object') return "'" + JSON.stringify(v).replace(/'/g, "''") + "'";
        return "'" + String(v).replace(/'/g, "''") + "'";
      });
      sql += `INSERT INTO ${tbl} (${cols.join(',')}) VALUES (${vals.join(',')});\n`;
    }
    sql += '\n';
  }
  return { ok: true, sql, filename: 'personal_os_mydata_' + todayStr().replace(/-/g, '') + '.sql' };
}

const SupabaseBridge = {
  async rawCall(payload) {
    const { action } = payload;
    try {
      if (action === 'login') {
        const identifier = payload.email || payload.username;
        const { data, error } = await signInWithIdentifier(identifier, payload.password);
        if (error) {
          const msg = (error.message || '').toLowerCase();
          if (msg.includes('not confirmed') || msg.includes('email not confirmed')) {
            return { ok: false, error: '这个邮箱还没完成验证码，请先去注册页输入邮件里的验证码' };
          }
          return { ok: false, error: '邮箱或密码不对' };
        }
        // 没在网站/App 输过验证码（只点了邮件链接也算未完成注册）时不允许登录
        if (!data.user.email_confirmed_at && !data.user.confirmed_at) {
          await sb.auth.signOut();
          return { ok: false, error: '这个邮箱还没完成验证码，请先去注册页输入邮件里的验证码' };
        }
        const profile = await fetchProfile(data.user.id);
        return { ok: true, user: publicUserFrom(profile, data.user.email || '') };
      }
      if (action === 'register') {
        if (payload.password.length < 6) return { ok: false, error: '密码至少要 6 位' };
        const email = String(payload.email || '').trim().toLowerCase();
        const displayName = String(payload.display_name || '').trim();
        if (!displayName) return { ok: false, error: '请填写名字' };
        if (!looksLikeEmail(email)) return { ok: false, error: '请填写有效的邮箱' };
        const { data, error } = await sb.auth.signUp({
          email,
          password: payload.password,
          options: { data: { display_name: displayName } },
        });
        if (error) {
          const msg = error.message || '';
          if (msg.includes('already') || msg.includes('registered')) return { ok: false, error: '这个邮箱已经有人用了，换一个' };
          return { ok: false, error: msg };
        }
        if (!data.user) return { ok: false, error: '注册失败，请稍后再试' };
        // 开着 Confirm email 时，Supabase 为了不泄漏"这个邮箱注册过没"，对已存在的邮箱
        // 也会回一个假的 user，但 identities 是空的。这里挡掉，不然使用者会一直等验证码。
        if (Array.isArray(data.user.identities) && data.user.identities.length === 0) {
          return { ok: false, error: '这个邮箱已经有人用了，换一个。若还没验证，请登录页点「还没有账号」再注册一次以重寄验证码。' };
        }
        // 即使 Supabase 误开自动登录，也立刻登出：必须在本页输入验证码才算注册成功
        if (data.session) await sb.auth.signOut();
        return { ok: true, needs_otp: true, email, message: '验证码已经寄到 ' + email + '。请输入邮件里的全部数字，不要点邮件里的链接。' };
      }

      // 注册的验证码 (6 位数字)。验证成功就同时完成登入。
      if (action === 'verify_signup_otp') {
        const email = String(payload.email || '').trim().toLowerCase();
        const token = String(payload.token || '').trim();
        const displayName = String(payload.display_name || '').trim();
        if (!token) return { ok: false, error: '请填写验证码' };
        const { data, error } = await sb.auth.verifyOtp({ email, token, type: 'signup' });
        if (error) return { ok: false, error: '验证码不对或已经过期，请重新获取' };
        if (!data.user) return { ok: false, error: '验证失败，请重新获取验证码' };
        if (displayName) {
          await sb.from('profiles').upsert({ id: data.user.id, display_name: displayName, email, role: 'user' });
        }
        const profile = await fetchProfile(data.user.id);
        return { ok: true, user: publicUserFrom(profile, data.user.email || email) };
      }

      // 忘记密码第一步：寄验证码。不管这个邮箱存不存在都回一样的讯息，
      // 免得被人拿来试探"哪些邮箱注册过"。
      if (action === 'request_password_reset') {
        const email = String(payload.email || '').trim().toLowerCase();
        if (!looksLikeEmail(email)) return { ok: false, error: '请填写有效的邮箱' };
        const { error } = await sb.auth.resetPasswordForEmail(email);
        if (error) return { ok: false, error: error.message };
        return { ok: true, message: '如果这个邮箱已经注册过，验证码已经寄出。' };
      }

      // 忘记密码第二步：验证码 + 新密码，使用者自己完成，不需要管理员插手。
      if (action === 'reset_password_with_otp') {
        const email = String(payload.email || '').trim().toLowerCase();
        const token = String(payload.token || '').trim();
        const newPassword = String(payload.new_password || '');
        if (!token) return { ok: false, error: '请填写验证码' };
        if (newPassword.length < 6) return { ok: false, error: '新密码至少要 6 位' };
        const { error: vErr } = await sb.auth.verifyOtp({ email, token, type: 'recovery' });
        if (vErr) return { ok: false, error: '验证码不对或已经过期，请重新获取' };
        const { error: uErr } = await sb.auth.updateUser({ password: newPassword });
        if (uErr) return { ok: false, error: uErr.message };
        return { ok: true };
      }
      if (action === 'logout') {
        await sb.auth.signOut();
        return { ok: true };
      }
      if (action === 'me') {
        const { data: { session } } = await sb.auth.getSession();
        if (!session) return { ok: true, user: null };
        const profile = await fetchProfile(session.user.id);
        return { ok: true, user: publicUserFrom(profile, session.user.email || '') };
      }
      return { ok: false, error: '未知 action: ' + action };
    } catch (e) {
      return { ok: false, error: e.message || String(e) };
    }
  },

  async call(payload) {
    const { resource, action } = payload;
    try {
      if (action === 'meta') {
        const resources = await loadMetaConfig();
        return { ok: true, resources };
      }

      if (action === 'dashboard') {
        const { data: { session } } = await sb.auth.getSession();
        if (!session) return { ok: false, error: '请先登录' };
        return await buildDashboard(session.user.id);
      }

      if (action === 'change_password') {
        // Supabase 自己的 updateUser 不用旧密码就能改，这里为了保留"必须知道旧密码"这个
        // 原本的安全习惯，先用旧密码重新登入一次验证，通过了才真的改新密码。
        const { data: { session } } = await sb.auth.getSession();
        if (!session) return { ok: false, error: '请先登录' };
        const { error: verifyErr } = await sb.auth.signInWithPassword({ email: session.user.email, password: payload.old_password });
        if (verifyErr) return { ok: false, error: '原密码不对' };
        if (payload.new_password.length < 6) return { ok: false, error: '新密码至少要 6 位' };
        const { error } = await sb.auth.updateUser({ password: payload.new_password });
        if (error) return { ok: false, error: error.message };
        return { ok: true };
      }

      if (action === 'list') {
        const { data: { session } } = await sb.auth.getSession();
        const userId = session.user.id;
        // 打开这几个列表页时顺手检查一次有没有到期该自动处理的 (跟 dashboard 一样的逻辑，
        // 不是只有仪表盘才会触发)
        if (resource === 'salary_payments') await autoGenerateDueSalaryPayments(userId);
        if (resource === 'subscriptions') await autoGenerateDueSubscriptions(userId);
        if (resource === 'fixed_deposits') await autoGenerateDueFixedDeposits(userId);
        if (resource === 'reminders') await advanceDueReminders(userId);

        // 管理员 RLS 能看到所有人的资料，但日常列表/下拉必须只显示自己的。
        // 「用户管理」走 admin_list_users，不受这条限制。
        let query = sb.from(resource).select('*').eq('user_id', userId);
        query = applyFilters(query, payload.filters);
        // id 是 UUID，按它倒序等于乱序；备忘录要按日期/创建时间排才能一眼找到最近写的。
        if (resource === 'journal_entries') {
          query = query.order('entry_date', { ascending: false }).order('created_at', { ascending: false });
        } else {
          query = query.order(resource === 'daily_metrics' ? 'metric_date' : 'id', { ascending: false });
        }
        const { data, error } = await query.limit(500);
        if (error) throw error;

        // 银行账户列表额外算出当前余额 + 打码账号，跟旧版 api.php 的 list 特殊处理一样
        // (current_balance 是靠交易记录算出来的，不是存在表里的栏位，通用 select('*') 拿不到，
        // 迁移到 Supabase 时这段一直漏掉，导致这个页面一直显示"期初余额"没变过)。
        if (resource === 'bank_accounts') {
          const balances = await computeBankBalances(userId);
          const byId = {};
          for (const b of balances) byId[b.id] = b;
          for (const r of data) {
            if (byId[r.id]) {
              r.current_balance = byId[r.id].current_balance;
              r.account_number_masked = byId[r.id].account_number_masked;
            }
          }
        }

        return { ok: true, data };
      }

      if (action === 'get') {
        const { data: { session } } = await sb.auth.getSession();
        const { data, error } = await sb.from(resource).select('*').eq('id', payload.id).eq('user_id', session.user.id).maybeSingle();
        if (error) throw error;
        return { ok: true, data };
      }

      if (action === 'create') {
        const config = await loadMetaConfig();
        let insertData = normalizeData(resource, payload.data, config);
        for (const [col, v] of Object.entries(insertData)) {
          if (v === undefined) return { ok: false, error: `字段 ${col} 格式不对` };
        }
        insertData = await applyReminderTimeRule(resource, 'create', null, insertData);
        // 新建就直接选"已完成"的话，顺手盖完成时间，别留一个状态已完成但时间是空的记录。
        if (resource === 'tasks' && insertData.status === 'done') insertData.completed_at = new Date().toISOString();
        const { data, error } = await sb.from(resource).insert(insertData).select().single();
        if (error) throw error;
        if (resource === 'salary_payments') await syncSalaryPayment(data.id);
        if (resource === 'fixed_deposits') await syncFixedDepositOpen(data.id);
        if (resource === 'reminders') await maybeAdvanceRecurringReminder(data.id);
        return { ok: true, id: data.id };
      }

      if (action === 'update') {
        const config = await loadMetaConfig();
        let updateData = normalizeData(resource, payload.data, config);
        for (const [col, v] of Object.entries(updateData)) {
          if (v === undefined) return { ok: false, error: `字段 ${col} 格式不对` };
        }
        updateData = await applyReminderTimeRule(resource, 'update', payload.id, updateData);

        // 完成时间跟着状态走，不让用户自己填：状态变成已完成才盖时间，改回未完成就清空。
        // 只在 status 真的有送来改的时候才动这个栏位，不然随便改个标题也会把完成时间刷新。
        if (resource === 'tasks' && 'status' in updateData) {
          const { data: existingTask } = await sb.from('tasks').select('status').eq('id', payload.id).maybeSingle();
          const wasDone = existingTask?.status === 'done';
          const willBeDone = updateData.status === 'done';
          if (willBeDone && !wasDone) updateData.completed_at = new Date().toISOString();
          else if (!willBeDone && wasDone) updateData.completed_at = null;
        }

        // 编辑定存改本金之前，先记下"改之前"的本金——改完要拿这个跟新值比较才知道差额多少
        let previousFdPrincipal = null;
        if (resource === 'fixed_deposits' && 'principal' in updateData) {
          const { data: existingFd } = await sb.from('fixed_deposits').select('principal').eq('id', payload.id).maybeSingle();
          previousFdPrincipal = existingFd ? Number(existingFd.principal) : null;
        }

        const { data: { session: updSession } } = await sb.auth.getSession();
        const { error } = await sb.from(resource).update(updateData).eq('id', payload.id).eq('user_id', updSession.user.id);
        if (error) throw error;
        if (resource === 'salary_payments') await syncSalaryPayment(payload.id);
        if (resource === 'reminders') await maybeAdvanceRecurringReminder(payload.id);
        if (resource === 'fixed_deposits' && previousFdPrincipal !== null) await syncFixedDepositPrincipalChange(payload.id, previousFdPrincipal);
        return { ok: true };
      }

      if (action === 'mark_subscription_paid') {
        const { data: sub } = await sb.from('subscriptions').select('*').eq('id', payload.id).maybeSingle();
        if (!sub) return { ok: false, error: '找不到这个订阅' };
        if (!sub.bank_account_id) return { ok: false, error: '这个订阅还没设置自动扣款账户' };
        const today = todayStr();
        const { data: txn } = await sb.from('transactions').insert({
          user_id: sub.user_id, type: 'expense', amount: sub.cost, transaction_date: today,
          bank_account_id: sub.bank_account_id, description: '订阅扣费: ' + sub.name, currency: 'MYR',
        }).select().single();
        const base = sub.next_billing_date || today;
        const nextDate = sub.billing_cycle === 'yearly' ? addMonths(base, 12) : addMonths(base, 1);
        await sb.from('subscriptions').update({ next_billing_date: nextDate }).eq('id', payload.id);
        return { ok: true, transaction_id: txn.id, next_billing_date: nextDate };
      }

      if (action === 'delete') {
        const inUseCount = await checkInUse(resource, payload.id);
        if (inUseCount > 0) return { ok: false, error: `还有 ${inUseCount} 条记录在用这个，请先改掉那些记录再删除` };
        if (resource === 'salary_payments') {
          const { data: sp } = await sb.from('salary_payments').select('transaction_id').eq('id', payload.id).maybeSingle();
          if (sp && sp.transaction_id) await sb.from('transactions').delete().eq('id', sp.transaction_id);
        }
        // bank_accounts 被薪资记录的外键挡住删除，前端确认过后会带 cascade 标记重新呼叫，
        // 这里才真的按单笔删除同一套逻辑清掉薪资记录；EPF/SOCSO/EIS 本来就是级联删除，不用管。
        if (resource === 'bank_accounts' && payload.cascade_salary_payments) {
          const { data: sps } = await sb.from('salary_payments').select('id, transaction_id').eq('bank_account_id', payload.id);
          for (const sp of (sps || [])) {
            if (sp.transaction_id) await sb.from('transactions').delete().eq('id', sp.transaction_id);
            await sb.from('salary_payments').delete().eq('id', sp.id);
          }
        }
        const { data: { session: delSession } } = await sb.auth.getSession();
        const { error } = await sb.from(resource).delete().eq('id', payload.id).eq('user_id', delSession.user.id);
        if (error) throw error;
        return { ok: true };
      }

      if (action === 'search') {
        return await runSearch(payload.q);
      }

      if (action === 'generate_report') {
        return await generateReport(payload.report_type, payload.period_start, payload.period_end);
      }

      if (action === 'export_csv') {
        return await exportCsv(resource, payload.filters);
      }

      if (action === 'export_sql') {
        return await exportMySql();
      }

      if (action === 'admin_export_full_sql') {
        return await adminExportFullSql();
      }

      if (action === 'admin_list_users') {
        await requireAdmin();
        const { data, error } = await sb.from('profiles').select('id, display_name, email, role, created_at').order('created_at');
        if (error) throw error;
        return { ok: true, data: data.map(p => ({ id: p.id, username: p.display_name, display_name: p.display_name, email: p.email || '', role: p.role, created_at: p.created_at })) };
      }

      if (action === 'admin_create_user') {
        await requireAdmin();
        const email = String(payload.email || '').trim().toLowerCase();
        const password = String(payload.password || '');
        const displayName = String(payload.display_name || '').trim();
        const role = payload.role === 'admin' ? 'admin' : 'user';
        if (!looksLikeEmail(email)) return { ok: false, error: '请填写有效的邮箱' };
        if (!displayName) return { ok: false, error: '请填写名字' };
        if (password.length < 6) return { ok: false, error: '密码至少要 6 位' };
        const { data: { session: adminSession } } = await sb.auth.getSession();
        const { data, error } = await sb.auth.signUp({
          email,
          password,
          options: { data: { display_name: displayName } },
        });
        if (adminSession) {
          await sb.auth.setSession({ access_token: adminSession.access_token, refresh_token: adminSession.refresh_token });
        }
        if (error) {
          const msg = error.message || '';
          if (msg.includes('already') || msg.includes('registered')) return { ok: false, error: '这个邮箱已经有人用了' };
          return { ok: false, error: msg };
        }
        if (!data.user) return { ok: false, error: '注册失败，请稍后再试' };
        const { error: profErr } = await sb.from('profiles').upsert({ id: data.user.id, display_name: displayName, email, role });
        if (profErr) return { ok: false, error: profErr.message };
        const extra = data.session ? '' : '（对方需要先到邮箱点确认链接才能登录）';
        return { ok: true, id: data.user.id, message: extra || undefined };
      }

      if (action === 'admin_update_user') {
        await requireAdmin();
        const { data: target } = await sb.from('profiles').select('id, role').eq('id', payload.id).maybeSingle();
        if (!target) return { ok: false, error: '找不到这个用户' };
        if (payload.role && payload.role !== 'admin' && target.role === 'admin') {
          const blocked = await wouldRemoveLastAdmin(payload.id);
          if (blocked) return { ok: false, error: '系统至少要留一个管理员' };
        }
        const upd = {};
        if (payload.display_name !== undefined) upd.display_name = payload.display_name;
        if (payload.role !== undefined) upd.role = payload.role;
        if (Object.keys(upd).length) {
          const { error } = await sb.from('profiles').update(upd).eq('id', payload.id);
          if (error) throw error;
        }
        if (payload.email) {
          const { error } = await sb.rpc('admin_update_user_email', { target_id: payload.id, new_email: payload.email });
          if (error) return { ok: false, error: error.message };
        }
        return { ok: true };
      }

      if (action === 'admin_delete_user') {
        await requireAdmin();
        const { data: { session } } = await sb.auth.getSession();
        if (session && session.user.id === payload.id) return { ok: false, error: '不能删除自己' };
        const { data: target } = await sb.from('profiles').select('id, role').eq('id', payload.id).maybeSingle();
        if (!target) return { ok: false, error: '找不到这个用户' };
        if (target.role === 'admin' && await wouldRemoveLastAdmin(payload.id)) {
          return { ok: false, error: '系统至少要留一个管理员' };
        }
        const config = await loadMetaConfig();
        for (const [tableName, cfg] of Object.entries(config)) {
          if (!cfg.user_scoped) continue;
          const { error } = await sb.from(tableName).delete().eq('user_id', payload.id);
          if (error) throw error;
        }
        const { error } = await sb.from('profiles').delete().eq('id', payload.id);
        if (error) throw error;
        // profiles 删了不够：auth.users 还占着这个邮箱，再注册会说已经有人用。
        const { error: authErr } = await sb.rpc('admin_delete_auth_user', { target_id: payload.id });
        if (authErr) return { ok: false, error: authErr.message };
        return { ok: true };
      }

      return { ok: false, error: '这个功能还没搬到 Supabase (action: ' + action + ')，请稍后再试' };
    } catch (e) {
      return { ok: false, error: e.message || String(e) };
    }
  },
};
