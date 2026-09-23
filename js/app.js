const API = 'api.php';
// 按功能分类，不按使用频率分 (用户明确要求去掉"每天/每周"这种框架)
const GROUP_LABELS = { core: '核心', finance: '财务', personal: '个人', tools: '工具', system: '系统' };
const GROUP_ORDER = ['core', 'finance', 'personal', 'tools', 'system'];
const AVATAR_MENU_RESOURCES = []; // 之前"通用提醒"放这里对应右上角头像菜单，现在已经搬回侧边栏"系统"分组，不用再特殊处理
const BOTTOM_NAV_ROUTES = ['dashboard', 'tasks', 'habits', 'transactions'];

// 侧边栏里有几个不是 resource 的静态路由 (比如"备份与恢复"是个功能页而不是一张表)，
// 按分组附加渲染在对应分组下面，跟其他 resource 导航项长得一样。
// "设置"原本是个多卡片的导航中转页 (标签管理/银行账户/提醒设置/备份与恢复)，用户说前三个都已经
// 各自在侧边栏能直接点到了，只留"备份与恢复"这一个真正有用的，所以这里直接跳过中转页。
const STATIC_NAV_LINKS = {
  system: [{ route: 'backup', icon: '💾', label: '备份与恢复' }],
};

// v2/v3 规范: 只保留这份文档定义的核心模块，其余(库存/旅行/AI助理等)先从导航隐藏，
// 数据库表和数据都还在，以后要恢复随时把对应 resource 名字加回这个集合就行。
const CORE_VISIBLE = new Set([
  'tasks', 'projects', 'project_categories', 'habits', 'habit_logs', 'inbox_items',
  'categories', 'transactions', 'subscriptions', 'journal_entries', 'contacts',
  'bank_accounts', 'banks', 'tags', 'bookmarks',
  'salary_profiles', 'salary_payments', 'epf_contributions',
  'reminders',
]);

const PRIORITY_COLOR = { urgent: '#ef4444', high: '#ef4444', medium: '#f59e0b', low: '#22c55e' };
const PRIORITY_LABEL = { urgent: '紧急', high: '高', medium: '中', low: '低' };

let RESOURCES = {};      // meta from backend
const fkCache = {};      // resource -> full list rows (for resolving fk display text, unfiltered)
const fkFilteredCache = {}; // "resource::{filterJson}" -> filtered list rows (for module-scoped dropdowns e.g. tags)

async function loadFkFiltered(resourceName, filter) {
  const key = `${resourceName}::${JSON.stringify(filter)}`;
  if (fkFilteredCache[key]) return fkFilteredCache[key];
  const filtersPayload = Object.entries(filter).map(([field, value]) => ({ field, op: 'eq', value }));
  const { data } = await api({ resource: resourceName, action: 'list', filters: filtersPayload });
  fkFilteredCache[key] = data;
  return data;
}

async function api(payload) {
  const res = await fetch(API, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
    body: JSON.stringify(payload),
  });
  const json = await res.json();
  if (json.ok === false) throw new Error(json.error || '请求失败');
  return json;
}

async function loadFk(resourceName) {
  if (fkCache[resourceName]) return fkCache[resourceName];
  const { data } = await api({ resource: resourceName, action: 'list' });
  fkCache[resourceName] = data;
  return data;
}

// fkCache/fkFilteredCache 只在第一次用到某个 resource 当下拉选项时才会去拉一次，之后整个会话都不会自动刷新。
// 所以如果在"银行账户/现金"页面新增了一个账户，另一个已经打开过一次的表单 (比如"薪资档案") 里的下拉
// 还是旧的、没有这个新账户 —— 必须在任何一次新增/编辑/删除之后，把这个 resource 的缓存清掉，
// 下次任何表单再用到它时才会重新去后端拉最新列表。
function invalidateFkCache(resourceName) {
  delete fkCache[resourceName];
  for (const key of Object.keys(fkFilteredCache)) {
    if (key.startsWith(`${resourceName}::`)) delete fkFilteredCache[key];
  }
}

function fkLabel(resourceName, id) {
  if (id === null || id === undefined || id === '') return '';
  const rows = fkCache[resourceName] || [];
  const row = rows.find(r => String(r.id) === String(id));
  if (!row) return `#${id}`;
  const displayField = RESOURCES[resourceName]?.display_field || 'id';
  return row[displayField] ?? `#${id}`;
}

function todayStr() {
  return new Date().toISOString().slice(0, 10);
}

function escapeHtml(str) {
  if (str === null || str === undefined) return '';
  return String(str).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}

function skeletonCards(n, heightClass = 'skeleton-card') {
  return Array.from({ length: n }).map(() => `<div class="skeleton ${heightClass}"></div>`).join('');
}

function skeletonLines(n) {
  return Array.from({ length: n }).map((_, i) =>
    `<div class="skeleton skeleton-line ${i === n - 1 ? 'w-60' : ''}"></div>`).join('');
}

// ---------------- Sidebar / Router ----------------

function buildSidebar() {
  const groups = {};
  for (const g of GROUP_ORDER) groups[g] = [];
  for (const [name, cfg] of Object.entries(RESOURCES)) {
    if (AVATAR_MENU_RESOURCES.includes(name)) continue; // 已挪到头像菜单
    if (!CORE_VISIBLE.has(name)) continue; // 非核心模块暂不在导航展示
    if (!groups[cfg.group]) groups[cfg.group] = [];
    groups[cfg.group].push({ name, ...cfg });
  }

  let html = `<a class="nav-item" data-route="dashboard" href="#dashboard"><span class="nav-icon">🏠</span><span class="nav-label"> 今日仪表盘</span></a>`;

  for (const g of GROUP_ORDER) {
    const staticLinks = STATIC_NAV_LINKS[g] || [];
    if (!groups[g].length && !staticLinks.length) continue;
    html += `<div class="nav-group-title">${GROUP_LABELS[g] || g}</div>`;
    for (const link of staticLinks) {
      html += `<a class="nav-item" data-route="${link.route}" href="#${link.route}" title="${escapeHtml(link.label)}"><span class="nav-icon">${link.icon}</span><span class="nav-label"> ${link.label}</span></a>`;
    }
    for (const r of groups[g]) {
      html += `<a class="nav-item" data-route="${r.name}" href="#${r.name}" title="${escapeHtml(r.label)}"><span class="nav-icon">${r.icon}</span><span class="nav-label"> ${r.label}</span></a>`;
    }
  }

  document.getElementById('nav-content').innerHTML = html;
  document.querySelectorAll('.nav-item').forEach(el => {
    el.addEventListener('click', () => {
      setActiveNav(el.dataset.route);
      closeMobileSidebar();
    });
  });
}

function setActiveNav(route) {
  document.querySelectorAll('.nav-item').forEach(el => {
    el.classList.toggle('active', el.dataset.route === route);
  });
  document.querySelectorAll('#bottom-nav a[data-bottom]').forEach(el => {
    el.classList.toggle('active', el.dataset.bottom === route);
  });
}

function openMobileSidebar() {
  document.getElementById('sidebar').classList.add('mobile-open');
  document.getElementById('sidebar-backdrop').classList.add('open');
}
function closeMobileSidebar() {
  document.getElementById('sidebar').classList.remove('mobile-open');
  document.getElementById('sidebar-backdrop').classList.remove('open');
}

function setupTopbarAndBottomNav() {
  document.getElementById('bottom-more').addEventListener('click', (e) => {
    e.preventDefault();
    openMobileSidebar();
  });
  document.getElementById('sidebar-backdrop').addEventListener('click', closeMobileSidebar);

  setupGlobalSearch();
  setupSidebarCollapse();
}

// 侧边栏收起/展开 (只影响这台设备/这个浏览器的显示偏好，纯本地记忆，不需要跟服务器同步)
const SIDEBAR_COLLAPSED_KEY = 'personal_os_sidebar_collapsed';
function setupSidebarCollapse() {
  const sidebar = document.getElementById('sidebar');
  const btn = document.getElementById('sidebar-collapse-btn');
  let collapsed = false;
  try { collapsed = localStorage.getItem(SIDEBAR_COLLAPSED_KEY) === '1'; } catch (e) {}
  sidebar.classList.toggle('collapsed', collapsed);
  btn.addEventListener('click', () => {
    collapsed = !collapsed;
    sidebar.classList.toggle('collapsed', collapsed);
    try { localStorage.setItem(SIDEBAR_COLLAPSED_KEY, collapsed ? '1' : '0'); } catch (e) {}
  });
}

// ---------------- Global search ----------------

function setupGlobalSearch() {
  const input = document.getElementById('search-input');
  const panel = document.getElementById('search-results');
  let debounceTimer = null;

  input.addEventListener('input', () => {
    clearTimeout(debounceTimer);
    const q = input.value.trim();
    if (!q) { panel.classList.remove('open'); panel.innerHTML = ''; return; }
    debounceTimer = setTimeout(() => runGlobalSearch(q, panel), 250);
  });
  input.addEventListener('focus', () => {
    if (panel.innerHTML) panel.classList.add('open');
  });
  document.addEventListener('click', (e) => {
    if (!e.target.closest('#global-search')) panel.classList.remove('open');
  });
}

async function runGlobalSearch(q, panel) {
  let json;
  try {
    json = await api({ action: 'search', q });
  } catch (e) {
    return;
  }
  const results = json.results || [];
  if (!results.length) {
    panel.innerHTML = `<div class="search-empty">没有找到和"${escapeHtml(q)}"相关的记录</div>`;
    panel.classList.add('open');
    return;
  }
  const groups = {};
  for (const r of results) {
    (groups[r.resource_label] = groups[r.resource_label] || []).push(r);
  }
  let html = '';
  for (const [label, rows] of Object.entries(groups)) {
    html += `<div class="search-group-title">${escapeHtml(label)}</div>`;
    for (const r of rows) {
      html += `<div class="search-row" onclick='openSearchResult("${r.resource}", ${r.id})'>
        <span class="icon">${r.icon}</span>
        <div><div class="title">${escapeHtml(r.title)}</div><div class="sub">${escapeHtml(r.sub)}</div></div>
      </div>`;
    }
  }
  panel.innerHTML = html;
  panel.classList.add('open');
}

function openSearchResult(resourceName, id) {
  document.getElementById('search-results').classList.remove('open');
  document.getElementById('search-input').value = '';
  location.hash = `#${resourceName}`;
  // 先跳到对应的列表页 (确保 fk 缓存等已加载)，再打开这一条的编辑表单
  setTimeout(() => openForm(resourceName, id), 300);
}

function router() {
  const route = (location.hash || '#dashboard').slice(1);
  setActiveNav(route);
  if (route === 'dashboard') renderDashboard();
  else if (route === 'backup') renderBackupPage();
  else if (RESOURCES[route]) renderResourcePage(route);
  else document.getElementById('page-content').innerHTML = '<p class="empty">未知页面</p>';
}

const LAST_BACKUP_KEY = 'personal_os_last_backup';

function renderBackupPage() {
  const el = document.getElementById('page-content');
  const lastBackup = (() => { try { return localStorage.getItem(LAST_BACKUP_KEY); } catch (e) { return null; } })();
  el.innerHTML = `
    <div class="page-title">💾 备份与恢复</div>
    <div class="card" style="max-width:560px;">
      <h3>完整数据库 SQL 备份</h3>
      <p class="stat-sub" id="backup-status">${backupStatusHtml(lastBackup)}</p>
      <button class="btn" id="btn-export-sql" style="margin-top:12px;">📦 导出完整数据库 SQL</button>
      <p class="stat-sub" style="margin-top:14px;">导出内容：全部数据表的结构 + 数据，可直接用 <code>mysql -u root personal_os &lt; 文件.sql</code> 整体还原。请定期导出并妥善保存到本机以外的地方 (比如网盘)，本地 XAMPP 数据库本身不会自动备份。</p>
    </div>
    <div class="card" style="max-width:560px; margin-top:16px;">
      <h3>各模块 CSV 导出</h3>
      <p class="stat-sub">在「财务记账」等列表页顶部工具栏也有单独的「⬇ 导出 CSV」按钮，只导出该模块当前筛选条件下的数据。</p>
    </div>
  `;
  document.getElementById('btn-export-sql').addEventListener('click', exportFullBackup);
}

function backupStatusHtml(lastBackup) {
  if (!lastBackup) return '⚠ 还没有导出过备份，建议现在就导出一份。';
  const days = Math.floor((Date.now() - new Date(lastBackup).getTime()) / 86400000);
  const dateStr = new Date(lastBackup).toLocaleString('zh-CN');
  if (days >= 7) return `⚠ 建议备份 (上次备份：${dateStr}，已经 ${days} 天)`;
  return `最后备份：${dateStr}`;
}

async function exportFullBackup() {
  const btn = document.getElementById('btn-export-sql');
  btn.disabled = true;
  btn.textContent = '导出中...';
  try {
    const res = await api({ action: 'export_sql' });
    const blob = new Blob(['﻿' + res.sql], { type: 'application/sql;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = res.filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    try { localStorage.setItem(LAST_BACKUP_KEY, new Date().toISOString()); } catch (e) {}
    document.getElementById('backup-status').innerHTML = backupStatusHtml(localStorage.getItem(LAST_BACKUP_KEY));
  } catch (e) {
    alert('导出失败：' + e.message);
  } finally {
    btn.disabled = false;
    btn.textContent = '📦 导出完整数据库 SQL';
  }
}

// ---------------- Dashboard ----------------

function dashboardSkeleton() {
  return `
    <div class="skeleton skeleton-line w-40" style="height:26px;width:220px;"></div>
    <div class="stat-grid" style="margin-top:16px;">
      <div class="skeleton skeleton-card" style="height:88px;"></div>
      <div class="skeleton skeleton-card" style="height:88px;"></div>
      <div class="skeleton skeleton-card" style="height:88px;"></div>
      <div class="skeleton skeleton-card" style="height:88px;"></div>
    </div>
    <div class="grid-3">
      <div class="skeleton skeleton-card" style="height:220px;"></div>
      <div class="skeleton skeleton-card" style="height:220px;"></div>
      <div class="skeleton skeleton-card" style="height:220px;"></div>
    </div>
  `;
}

function greetingText() {
  const h = new Date().getHours();
  if (h < 12) return '早上好';
  if (h < 18) return '下午好';
  return '晚上好';
}

function buildDonutHtml(breakdown) {
  const total = breakdown.reduce((s, c) => s + c.amount, 0);
  if (!total) return '<p class="empty">这个月还没有支出记录</p>';
  let cumulative = 0;
  const stops = breakdown.map(c => {
    const start = (cumulative / total) * 360;
    cumulative += c.amount;
    const end = (cumulative / total) * 360;
    return `${c.color} ${start}deg ${end}deg`;
  }).join(', ');
  const legend = breakdown.map(c => `
    <div class="donut-legend-item">
      <span class="donut-legend-left"><span class="donut-legend-dot" style="background:${c.color};"></span>${escapeHtml(c.label)}</span>
      <span class="donut-legend-pct">${((c.amount / total) * 100).toFixed(0)}%</span>
    </div>
  `).join('');
  return `
    <div class="donut-wrap">
      <div class="donut" style="background: conic-gradient(${stops});">
        <div class="donut-center"><span class="amount">RM ${total.toFixed(0)}</span><span class="label">本月支出</span></div>
      </div>
      <div class="donut-legend">${legend}</div>
    </div>
  `;
}

const ACCOUNT_KIND_COLOR = { bank: '#3B82F6', cash: '#16A34A', ewallet: '#7C3AED' };
const ACCOUNT_KIND_ICON = { bank: '🏦', cash: '💵', ewallet: '📱' };
const ACCOUNT_KIND_LABEL = { bank: '银行户口', cash: '手头现金', ewallet: '电子钱包' };

function buildAssetBarChart(accounts) {
  if (!accounts.length) return '<p class="empty">还没有银行账户/现金记录，去"银行账户/现金"页面加一个吧</p>';
  const sorted = [...accounts].sort((a, b) => Number(b.current_balance) - Number(a.current_balance));
  const maxVal = Math.max(...sorted.map(a => Number(a.current_balance)), 1);
  const bars = sorted.map(a => {
    const color = ACCOUNT_KIND_COLOR[a.account_kind] || '#9CA3AF';
    const icon = ACCOUNT_KIND_ICON[a.account_kind] || '🏦';
    const pct = Math.max((Number(a.current_balance) / maxVal) * 100, 2);
    return `
      <div style="margin-bottom:12px;">
        <div style="display:flex;justify-content:space-between;font-size:13px;margin-bottom:4px;">
          <span>${icon} ${escapeHtml(a.nickname)} <span class="stat-sub">${ACCOUNT_KIND_LABEL[a.account_kind] || ''}</span></span>
          <strong>RM ${Number(a.current_balance).toFixed(2)}</strong>
        </div>
        <div style="background:#f1f4f9;border-radius:6px;height:12px;overflow:hidden;">
          <div style="width:${pct}%;background:${color};height:100%;border-radius:6px;"></div>
        </div>
      </div>
    `;
  }).join('');
  return bars;
}

async function renderDashboard() {
  const el = document.getElementById('page-content');
  el.innerHTML = dashboardSkeleton();
  const d = await api({ action: 'dashboard' });

  const habitRows = d.habits.map(h => `
    <div class="habit-row">
      <label style="display:flex;align-items:center;gap:10px;cursor:pointer;flex:1;">
        <input type="checkbox" ${h.checked_today ? 'checked' : ''} onchange="toggleHabit(${h.id}, this.checked)">
        ${escapeHtml(h.name)}
      </label>
      <span class="stat-sub">${h.frequency === 'daily' ? '每天' : h.frequency === 'weekly' ? '每周' : '自定义'}</span>
    </div>
  `).join('') || '<p class="empty">还没有习惯，去"习惯"页面加一个吧</p>';

  const taskRows = d.tasks_today.map(t => `
    <div class="swipe-wrap" data-task-id="${t.id}">
      <div class="swipe-bg"></div>
      <div class="swipe-content">
        <div class="habit-row" style="border-left:4px solid ${PRIORITY_COLOR[t.priority] || '#9CA3AF'};padding-left:10px;">
          <span>${escapeHtml(t.title)} <span class="badge" style="background:${PRIORITY_COLOR[t.priority]}22;color:${PRIORITY_COLOR[t.priority]};">${PRIORITY_LABEL[t.priority] || t.priority}</span></span>
          <button class="btn small secondary" onclick="quickCompleteTask(${t.id})">✓ 完成</button>
        </div>
      </div>
    </div>
  `).join('') || '<p class="empty">今天没有待办任务</p>';

  const inboxRows = d.inbox_unprocessed.map(i => `
    <div class="habit-row"><span>${escapeHtml(i.content)}</span></div>
  `).join('') || '<p class="empty">收件箱是空的</p>';

  const recentTxnRows = (d.recent_transactions || []).map(t => `
    <div class="list-row">
      <div class="list-row-icon">${t.category_icon || '💳'}</div>
      <div class="list-row-body">
        <div class="list-row-title">${escapeHtml(t.description || t.category_label)}</div>
        <div class="list-row-sub">${escapeHtml(t.category_label)} · ${t.transaction_date}</div>
      </div>
      <div class="list-row-right">
        <div class="list-row-amount ${t.type}">${t.type === 'income' ? '+' : t.type === 'expense' ? '-' : ''} RM ${Number(t.amount).toFixed(2)}</div>
      </div>
    </div>
  `).join('') || '<p class="empty">还没有交易记录</p>';

  const upcomingSubRows = (d.upcoming_subscriptions || []).map(s => `
    <div class="list-row">
      <div class="list-row-icon" style="background:var(--icon-orange-bg);color:var(--icon-orange-fg);">🔄</div>
      <div class="list-row-body">
        <div class="list-row-title">${escapeHtml(s.name)}</div>
        <div class="list-row-sub">${s.days_until === 0 ? '今天扣费' : s.days_until + ' 天后扣费'}</div>
      </div>
      <div class="list-row-right"><div class="list-row-amount expense">RM ${Number(s.cost).toFixed(2)}</div></div>
    </div>
  `).join('');
  const upcomingBirthdayRows = (d.upcoming_birthdays || []).map(c => `
    <div class="list-row">
      <div class="list-row-icon" style="background:var(--icon-purple-bg);color:var(--icon-purple-fg);">🎂</div>
      <div class="list-row-body">
        <div class="list-row-title">${escapeHtml(c.name)}</div>
        <div class="list-row-sub">${c.days_until === 0 ? '今天生日' : c.days_until + ' 天后生日'}</div>
      </div>
    </div>
  `).join('');
  const upcomingHtml = (upcomingSubRows + upcomingBirthdayRows) || '<p class="empty">近期没有订阅续费或生日提醒</p>';

  const monthNet = (d.month_income || 0) - (d.month_expense || 0);

  const autoSalaryNote = (d.auto_generated_salary || []).length
    ? `<div class="resource-note">✅ 已自动生成 ${d.auto_generated_salary.map(g => `「${escapeHtml(g.company_name)}」${g.period_label} 发薪 RM ${Number(g.net_salary).toFixed(2)}`).join('、')}，如有花红/津贴可以去"发薪记录"编辑补上。</div>`
    : '';

  el.innerHTML = `
    <div class="dash-header">
      <div>
        <div class="dash-greeting">${greetingText()}！👋</div>
        <div class="dash-greeting-sub">这是你今天的生活概览</div>
      </div>
      <div class="dash-date">${d.date}</div>
    </div>
    ${autoSalaryNote}

    <div class="stat-grid">
      <div class="stat-card">
        <div class="stat-icon bg-purple">💰</div>
        <div class="stat-info">
          <div class="stat-label-row"><span class="stat-label">总余额</span><span class="stat-dot" style="background:#7C3AED;"></span></div>
          <div class="stat-value">RM ${Number(d.total_balance || 0).toFixed(2)}</div>
          <div class="stat-foot">${(d.bank_accounts || []).length} 个账户</div>
        </div>
      </div>
      <div class="stat-card">
        <div class="stat-icon bg-red">🛍️</div>
        <div class="stat-info">
          <div class="stat-label-row"><span class="stat-label">今日支出</span><span class="stat-dot" style="background:#EF4444;"></span></div>
          <div class="stat-value">RM ${d.expense_today.toFixed(2)}</div>
          <div class="stat-foot">${d.date}</div>
        </div>
      </div>
      <div class="stat-card">
        <div class="stat-icon bg-green">📈</div>
        <div class="stat-info">
          <div class="stat-label-row"><span class="stat-label">今日收入</span><span class="stat-dot" style="background:#16A34A;"></span></div>
          <div class="stat-value">RM ${d.income_today.toFixed(2)}</div>
          <div class="stat-foot">${d.date}</div>
        </div>
      </div>
      <div class="stat-card">
        <div class="stat-icon bg-blue">📊</div>
        <div class="stat-info">
          <div class="stat-label-row"><span class="stat-label">本月结余</span><span class="stat-dot" style="background:${monthNet >= 0 ? '#16A34A' : '#EF4444'};"></span></div>
          <div class="stat-value">RM ${monthNet.toFixed(2)}</div>
          <div class="stat-foot">收入 RM ${Number(d.month_income || 0).toFixed(0)} · 支出 RM ${Number(d.month_expense || 0).toFixed(0)}</div>
        </div>
      </div>
    </div>

    <div class="dash-row-3">
      <div class="card">
        <h3>💼 资产分布 <span class="card-period-badge">实时 ⌄</span></h3>
        ${buildAssetBarChart(d.bank_accounts || [])}
      </div>
    </div>

    <div class="dash-row-2">
      <div class="card">
        <h3>💼 本月薪资</h3>
        <div class="stat-number">RM ${Number(d.actual_monthly_salary || 0).toFixed(2)}</div>
        <div class="stat-sub">实际已收到</div>
        <div style="margin-top:10px;color:var(--muted);font-size:13px;">
          预期 (在职月薪档案): RM ${Number(d.expected_monthly_salary || 0).toFixed(2)}
        </div>
      </div>
      <div class="card">
        <h3>🏦 EPF 累计供款</h3>
        <div class="stat-number">RM ${Number(d.epf_cumulative?.total || 0).toFixed(2)}</div>
        <div class="stat-sub">员工 + 雇主 + 自愿供款总计</div>
        <div style="margin-top:10px;font-size:13px;color:var(--text-body);">
          员工 RM ${Number(d.epf_cumulative?.employee || 0).toFixed(2)} ·
          雇主 RM ${Number(d.epf_cumulative?.employer || 0).toFixed(2)}
        </div>
      </div>
    </div>

    <div class="grid-3">
      <div class="card">
        <h3>📊 支出分类占比 <span class="card-period-badge">本月 ⌄</span></h3>
        ${buildDonutHtml(d.category_breakdown || [])}
      </div>
      <div class="card">
        <h3>💳 最近交易</h3>
        ${recentTxnRows}
      </div>
      <div class="card">
        <h3>⏰ 即将到来</h3>
        ${upcomingHtml}
      </div>
    </div>

    <div class="dash-actions-row">
      <div class="card">
        <h3>⚡ 快速操作</h3>
        <div class="quick-actions">
          <button class="quick-action-btn" onclick='openForm("transactions", null, {type:"expense"})'>
            <span class="quick-action-icon bg-red" style="background:var(--icon-red-bg);color:var(--icon-red-fg);">🛍️</span>
            <span class="quick-action-label">记支出</span>
          </button>
          <button class="quick-action-btn" onclick='openForm("transactions", null, {type:"income"})'>
            <span class="quick-action-icon" style="background:var(--icon-green-bg);color:var(--icon-green-fg);">📈</span>
            <span class="quick-action-label">记收入</span>
          </button>
          <button class="quick-action-btn" onclick='openForm("tasks", null, {status:"today"})'>
            <span class="quick-action-icon" style="background:var(--icon-blue-bg);color:var(--icon-blue-fg);">✅</span>
            <span class="quick-action-label">新任务</span>
          </button>
          <button class="quick-action-btn" onclick='openForm("bookmarks", null, {})'>
            <span class="quick-action-icon" style="background:var(--icon-purple-bg);color:var(--icon-purple-fg);">🔗</span>
            <span class="quick-action-label">加链接</span>
          </button>
          <button class="quick-action-btn" onclick='openForm("journal_entries", null, {})'>
            <span class="quick-action-icon" style="background:var(--icon-orange-bg);color:var(--icon-orange-fg);">📓</span>
            <span class="quick-action-label">写日记</span>
          </button>
        </div>
      </div>
      <div class="motivate-card">
        <div class="icon">🌱</div>
        <div class="quote">Small steps every day<br>lead to big results.</div>
      </div>
    </div>

    <div class="dash-row-2">
      <div class="card tint-blue interactive">
        <h3>✅ 今天的任务 <button class="btn icon-only" onclick="toggleQuickAdd('task-add')">+</button></h3>
        <div class="quick-add-row" id="task-add">
          <input type="text" id="task-add-input" placeholder="输入任务标题，回车快速添加" onkeydown="if(event.key==='Enter') quickAddTask()">
          <button class="btn small" onclick="quickAddTask()">添加</button>
        </div>
        <div id="task-rows">${taskRows}</div>
      </div>
      <div class="card interactive">
        <h3>🔁 习惯打卡</h3>
        ${habitRows}
      </div>
    </div>

    <div class="dash-row-2">
      <div class="card">
        <h3>❤️ 今日健康</h3>
        ${d.metric_today
          ? `<p>体重 ${d.metric_today.weight_kg ?? '-'} kg · 睡眠 ${d.metric_today.sleep_hours ?? '-'} 小时 · 心情 ${d.metric_today.mood ?? '-'} /5 ${d.metric_today.steps ? '· 步数 ' + d.metric_today.steps : ''}</p>`
          : '<p class="empty">今天还没记录 (手机 App 会自动同步步数)</p>'}
      </div>
      <div class="card">
        <h3>📓 今日日记</h3>
        ${d.journal_today ? `<p>${escapeHtml((d.journal_today.content || '').slice(0, 80))}...</p>` : '<p class="empty">今天还没写</p>'}
      </div>
    </div>

    <div class="dash-row-3">
      <div class="card">
        <h3>📥 收件箱待整理 <button class="btn icon-only" onclick="toggleQuickAdd('inbox-add')">+</button></h3>
        <div class="quick-add-row" id="inbox-add">
          <input type="text" id="inbox-add-input" placeholder="随手记一句，回车快速添加" onkeydown="if(event.key==='Enter') quickAddInbox()">
          <button class="btn small" onclick="quickAddInbox()">添加</button>
        </div>
        ${inboxRows}
      </div>
    </div>
  `;

  el.querySelectorAll('.swipe-wrap[data-task-id]').forEach(wrap => {
    const taskId = Number(wrap.dataset.taskId);
    attachSwipe(wrap,
      () => deleteTaskFromDashboard(taskId),   // swipe left -> delete
      () => quickCompleteTask(taskId)          // swipe right -> complete
    );
  });
}

function toggleQuickAdd(id) {
  const row = document.getElementById(id);
  row.classList.toggle('open');
  if (row.classList.contains('open')) row.querySelector('input').focus();
}

async function quickAddTask() {
  const input = document.getElementById('task-add-input');
  const title = input.value.trim();
  if (!title) return;
  await api({ resource: 'tasks', action: 'create', data: { title, status: 'today', priority: 'medium' } });
  input.value = '';
  renderDashboard();
}

async function quickAddInbox() {
  const input = document.getElementById('inbox-add-input');
  const content = input.value.trim();
  if (!content) return;
  await api({ resource: 'inbox_items', action: 'create', data: { content, item_type: 'note' } });
  input.value = '';
  renderDashboard();
}

async function deleteTaskFromDashboard(taskId) {
  await api({ resource: 'tasks', action: 'delete', id: taskId });
  renderDashboard();
}

async function toggleHabit(habitId, checked) {
  await api({
    resource: 'habit_logs', action: 'create',
    data: { habit_id: habitId, log_date: todayStr(), completed: checked },
  });
}

async function quickCompleteTask(taskId) {
  await api({ resource: 'tasks', action: 'update', id: taskId, data: { status: 'done' } });
  renderDashboard();
}

// ---------------- Swipe gesture (touch: left=delete, right=complete) ----------------

function attachSwipe(wrapEl, onSwipeLeft, onSwipeRight) {
  const content = wrapEl.querySelector('.swipe-content');
  const bg = wrapEl.querySelector('.swipe-bg');
  const THRESHOLD = 80;
  let startX = 0, dx = 0, dragging = false;

  content.addEventListener('pointerdown', (e) => {
    dragging = true;
    startX = e.clientX;
    content.style.transition = 'none';
    content.setPointerCapture(e.pointerId);
  });

  content.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    dx = e.clientX - startX;
    content.style.transform = `translateX(${dx}px)`;
    if (dx < -10) {
      bg.className = 'swipe-bg delete';
      bg.style.display = 'flex';
      bg.textContent = '🗑 删除';
    } else if (dx > 10) {
      bg.className = 'swipe-bg complete';
      bg.style.display = 'flex';
      bg.textContent = '✓ 完成';
    } else {
      bg.style.display = 'none';
    }
  });

  function endDrag() {
    if (!dragging) return;
    dragging = false;
    content.style.transition = '';
    if (dx <= -THRESHOLD) {
      content.style.transform = 'translateX(-100%)';
      setTimeout(() => onSwipeLeft && onSwipeLeft(), 160);
    } else if (dx >= THRESHOLD) {
      content.style.transform = 'translateX(100%)';
      setTimeout(() => onSwipeRight && onSwipeRight(), 160);
    } else {
      content.style.transform = 'translateX(0)';
      bg.style.display = 'none';
    }
    dx = 0;
  }

  content.addEventListener('pointerup', endDrag);
  content.addEventListener('pointercancel', endDrag);
}

// ---------------- Filters (declarative, driven by config_resources.php 'filters') ----------------

const FILTER_STATE = {};

function initFilterState(resourceName, filters) {
  if (FILTER_STATE[resourceName]) return FILTER_STATE[resourceName];
  const state = {};
  for (const f of filters) {
    if (f.type === 'month') state[f.field] = { year: '', month: '' };
    else if (f.type === 'daterange') state[f.field] = { from: '', to: '' };
    else state[f.field] = '';
  }
  FILTER_STATE[resourceName] = state;
  return state;
}

function buildFilterBarHtml(resourceName, cfg) {
  const filters = cfg.filters || [];
  if (!filters.length) return '';
  const state = initFilterState(resourceName, filters);

  const controls = filters.map(f => {
    const fieldCfg = cfg.fields[f.field];
    if (f.type === 'month') {
      const currentYear = new Date().getFullYear();
      const years = [];
      for (let y = currentYear - 3; y <= currentYear + 1; y++) years.push(y);
      const yearOpts = `<option value="">全部年份</option>` + years.map(y =>
        `<option value="${y}" ${state[f.field].year == String(y) ? 'selected' : ''}>${y}</option>`).join('');
      const monthOpts = `<option value="">全部月份</option>` + Array.from({ length: 12 }, (_, i) => i + 1).map(m =>
        `<option value="${m}" ${state[f.field].month == String(m) ? 'selected' : ''}>${m}月</option>`).join('');
      return `<select data-filter="${f.field}" data-part="year" onchange="onFilterChange('${resourceName}')">${yearOpts}</select>
              <select data-filter="${f.field}" data-part="month" onchange="onFilterChange('${resourceName}')">${monthOpts}</select>`;
    }
    if (f.type === 'daterange') {
      return `<input type="date" data-filter="${f.field}" data-part="from" value="${state[f.field].from}" onchange="onFilterChange('${resourceName}')">
              <span style="color:var(--muted);">至</span>
              <input type="date" data-filter="${f.field}" data-part="to" value="${state[f.field].to}" onchange="onFilterChange('${resourceName}')">`;
    }
    if (f.type === 'select') {
      const opts = `<option value="">全部${fieldCfg.label}</option>` + Object.entries(fieldCfg.options).map(([v, l]) =>
        `<option value="${v}" ${state[f.field] === v ? 'selected' : ''}>${l}</option>`).join('');
      return `<select data-filter="${f.field}" onchange="onFilterChange('${resourceName}')">${opts}</select>`;
    }
    if (f.type === 'fk_select') {
      const rows = fkCache[fieldCfg.fk_resource] || [];
      const displayField = RESOURCES[fieldCfg.fk_resource]?.display_field || 'id';
      const opts = `<option value="">全部${fieldCfg.label}</option>` + rows.map(r =>
        `<option value="${r.id}" ${state[f.field] === String(r.id) ? 'selected' : ''}>${escapeHtml(r[displayField])}</option>`).join('');
      return `<select data-filter="${f.field}" onchange="onFilterChange('${resourceName}')">${opts}</select>`;
    }
    if (f.type === 'text_search') {
      return `<input type="text" data-filter="${f.field}" placeholder="搜索${fieldCfg.label}" value="${escapeHtml(state[f.field])}" oninput="onFilterChange('${resourceName}')">`;
    }
    if (f.type === 'tag_search') {
      return `<input type="text" data-filter="${f.field}" placeholder="按标签筛选" value="${escapeHtml(state[f.field])}" oninput="onFilterChange('${resourceName}')">`;
    }
    return '';
  }).join('');

  return `<div class="filter-bar">${controls}<button class="btn small secondary" onclick="clearFilters('${resourceName}')">清除筛选</button></div>`;
}

function onFilterChange(resourceName) {
  const cfg = RESOURCES[resourceName];
  const state = FILTER_STATE[resourceName];
  document.querySelectorAll(`.filter-bar [data-filter]`).forEach(el => {
    const field = el.dataset.filter;
    const part = el.dataset.part;
    if (part) state[field][part] = el.value;
    else state[field] = el.value;
  });
  renderResourcePage(resourceName);
}

function clearFilters(resourceName) {
  delete FILTER_STATE[resourceName];
  renderResourcePage(resourceName);
}

function buildFiltersPayload(resourceName, cfg) {
  const filters = cfg.filters || [];
  const state = initFilterState(resourceName, filters);
  const payload = [];
  for (const f of filters) {
    const val = state[f.field];
    if (f.type === 'month') {
      if (val.year) {
        const y = val.year, m = val.month;
        if (m) {
          const lastDay = new Date(Number(y), Number(m), 0).getDate();
          payload.push({ field: f.field, op: 'gte', value: `${y}-${String(m).padStart(2, '0')}-01` });
          payload.push({ field: f.field, op: 'lte', value: `${y}-${String(m).padStart(2, '0')}-${lastDay}` });
        } else {
          payload.push({ field: f.field, op: 'gte', value: `${y}-01-01` });
          payload.push({ field: f.field, op: 'lte', value: `${y}-12-31` });
        }
      }
    } else if (f.type === 'daterange') {
      if (val.from) payload.push({ field: f.field, op: 'gte', value: val.from });
      if (val.to) payload.push({ field: f.field, op: 'lte', value: val.to });
    } else if (f.type === 'text_search' || f.type === 'tag_search') {
      if (val) payload.push({ field: f.field, op: 'like', value: val });
    } else {
      if (val) payload.push({ field: f.field, op: 'eq', value: val });
    }
  }
  return payload;
}

function renderCategoryBreakdown(data, cfg) {
  // 仅财务记账用: 按分类汇总支出金额，画一个纯 CSS 横向条形图 (不引入图表库)
  const totals = {};
  let maxVal = 0;
  for (const row of data) {
    if (row.type !== 'expense') continue;
    const label = fkLabel('categories', row.category_id) || '未分类';
    totals[label] = (totals[label] || 0) + Number(row.amount);
    maxVal = Math.max(maxVal, totals[label]);
  }
  const entries = Object.entries(totals).sort((a, b) => b[1] - a[1]);
  if (!entries.length) return '';
  const bars = entries.map(([label, amount]) => `
    <div style="margin-bottom:10px;">
      <div style="display:flex;justify-content:space-between;font-size:13px;margin-bottom:4px;">
        <span>${escapeHtml(label)}</span><span>RM ${amount.toFixed(2)}</span>
      </div>
      <div style="background:#f1f4f9;border-radius:6px;height:10px;overflow:hidden;">
        <div style="width:${maxVal ? (amount / maxVal * 100) : 0}%;background:var(--blue);height:100%;border-radius:6px;"></div>
      </div>
    </div>
  `).join('');
  return `<div class="card"><h3>📊 支出分类占比</h3>${bars}</div>`;
}

const CARD_GRID_RESOURCES = new Set(['subscriptions', 'bookmarks', 'contacts']);

function renderItemGrid(resourceName, data) {
  if (!data.length) return '<div class="card"><p class="empty">还没有数据</p></div>';

  if (resourceName === 'subscriptions') {
    const statusColor = { Active: '#16A34A', active: '#16A34A', Cancelled: '#9CA3AF', cancelled: '#9CA3AF', Paused: '#EA580C', paused: '#EA580C' };
    const cards = data.map(s => {
      const active = s.is_active == 1;
      const color = active ? '#16A34A' : '#9CA3AF';
      return `
        <div class="item-card">
          <div class="item-card-header">
            <div class="item-card-icon" style="background:var(--icon-orange-bg);color:var(--icon-orange-fg);">🔄</div>
            <div>
              <div class="item-card-title">${escapeHtml(s.name)}</div>
              <div class="item-card-sub">${escapeHtml(s.category || '')}</div>
            </div>
          </div>
          <div class="item-card-body">
            <strong style="font-size:16px;color:var(--navy);">RM ${Number(s.cost).toFixed(2)}</strong> / ${s.billing_cycle === 'monthly' ? '月' : '年'}<br>
            下次扣费：${s.next_billing_date || '-'}
          </div>
          <div class="item-card-footer">
            <span class="badge" style="background:${color}22;color:${color};">${active ? '使用中' : '已停用'}</span>
            <span>
              <button class="btn small secondary" onclick='openForm("subscriptions", ${s.id})'>编辑</button>
              <button class="btn small danger" onclick='deleteRow("subscriptions", ${s.id})'>删除</button>
            </span>
          </div>
        </div>`;
    }).join('');
    return `<div class="item-grid">${cards}</div>`;
  }

  if (resourceName === 'bookmarks') {
    const cards = data.map(l => {
      const tagLabel = l.tag_id ? fkLabel('tags', l.tag_id) : '';
      const tagColor = l.tag_id ? fkColor('tags', l.tag_id) : '#9CA3AF';
      return `
        <div class="item-card">
          <div class="item-card-header">
            <div class="item-card-icon" style="background:var(--icon-blue-bg);color:var(--icon-blue-fg);">🔗</div>
            <div style="min-width:0;">
              <div class="item-card-title">${l.is_favorite == 1 ? '⭐ ' : ''}${escapeHtml(l.title || l.url)}</div>
              <div class="item-card-sub" style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${escapeHtml(l.url)}</div>
            </div>
          </div>
          <div class="item-card-footer">
            ${tagLabel ? `<span class="badge" style="background:${tagColor}22;color:${tagColor};">${escapeHtml(tagLabel)}</span>` : '<span></span>'}
            <span>
              <a class="btn small secondary" href="${escapeHtml(l.url)}" target="_blank" rel="noopener">打开</a>
              <button class="btn small secondary" onclick='copyToClipboard("${escapeHtml(l.url)}")'>复制</button>
              <button class="btn small secondary" onclick='openForm("bookmarks", ${l.id})'>编辑</button>
              <button class="btn small danger" onclick='deleteRow("bookmarks", ${l.id})'>删除</button>
            </span>
          </div>
        </div>`;
    }).join('');
    return `<div class="item-grid">${cards}</div>`;
  }

  if (resourceName === 'contacts') {
    const cards = data.map(c => {
      const initial = (c.name || '?').trim().charAt(0).toUpperCase();
      const tags = (() => { try { return (JSON.parse(c.tags || '[]')).join(', '); } catch (e) { return ''; } })();
      return `
        <div class="item-card">
          <div class="item-card-header">
            <div class="item-card-icon" style="background:var(--icon-purple-bg);color:var(--icon-purple-fg);font-weight:700;">${escapeHtml(initial)}</div>
            <div>
              <div class="item-card-title">${escapeHtml(c.name)}</div>
              <div class="item-card-sub">${c.phone ? `<a href="tel:${escapeHtml(c.phone)}">${escapeHtml(c.phone)}</a>` : ''}</div>
            </div>
          </div>
          <div class="item-card-body">
            ${c.birthday ? `🎂 ${c.birthday}` : ''} ${tags ? `<br>🏷️ ${escapeHtml(tags)}` : ''}
          </div>
          <div class="item-card-footer">
            <span></span>
            <span>
              <button class="btn small secondary" onclick='openForm("contacts", ${c.id})'>编辑</button>
              <button class="btn small danger" onclick='deleteRow("contacts", ${c.id})'>删除</button>
            </span>
          </div>
        </div>`;
    }).join('');
    return `<div class="item-grid">${cards}</div>`;
  }

  return '';
}

// ---------------- Generic resource list page ----------------

async function renderResourcePage(resourceName) {
  const cfg = RESOURCES[resourceName];
  const el = document.getElementById('page-content');
  el.innerHTML = `
    <div class="toolbar">
      <div class="page-title" style="margin-bottom:0;">${cfg.icon} ${cfg.label}</div>
    </div>
    ${cfg.note ? `<div class="resource-note">💡 ${escapeHtml(cfg.note)}</div>` : ''}
    <div class="card">${skeletonLines(5)}</div>
  `;

  // preload fk lists referenced by this resource's fields (needed for both table display + fk_select filter options)
  const fkFields = Object.entries(cfg.fields).filter(([, f]) => f.type === 'fk');
  await Promise.all(fkFields.map(([, f]) => loadFk(f.fk_resource)));
  await Promise.all(fkFields.filter(([, f]) => f.fk_filter).map(([, f]) => loadFkFiltered(f.fk_resource, f.fk_filter)));

  const filtersPayload = buildFiltersPayload(resourceName, cfg);
  const { data } = await api({ resource: resourceName, action: 'list', filters: filtersPayload });
  const columns = Object.keys(cfg.fields).filter(c => !cfg.fields[c].hidden);

  const extraCols = resourceName === 'bank_accounts' ? ['当前余额'] : [];
  const headerHtml = columns.map(c => `<th>${escapeHtml(fieldMainLabel(cfg.fields[c]))}</th>`).join('') +
    extraCols.map(c => `<th>${c}</th>`).join('');
  const rowsHtml = data.map(row => {
    const cells = columns.map(c => {
      const f = cfg.fields[c];
      let val = row[c];
      if (c === 'account_number' && resourceName === 'bank_accounts') {
        val = row.account_number_masked ?? val;
      } else if (f.type === 'fk') {
        val = fkLabel(f.fk_resource, val);
        if (f.fk_resource === 'tags' && val) {
          const color = fkColor('tags', row[c]);
          return `<td><span class="badge" style="background:${color}22;color:${color};">${escapeHtml(val)}</span></td>`;
        }
      } else if (f.type === 'url') {
        val = val ? `<a href="${escapeHtml(val)}" target="_blank" rel="noopener">${escapeHtml(val)}</a>` : '';
        return `<td>${val}</td>`;
      } else if (f.type === 'color') {
        return `<td>${val ? `<span class="color-dot" style="background:${escapeHtml(val)};"></span>${escapeHtml(val)}` : ''}</td>`;
      } else if (f.type === 'boolean') val = (val == 1) ? '✅' : '—';
      else if (f.type === 'tags') { try { val = (JSON.parse(val || '[]')).join(', '); } catch (e) {} }
      else if (f.type === 'select' && f.options && f.options[val]) val = f.options[val];
      else if (val === null) val = '';
      return `<td>${escapeHtml(val)}</td>`;
    }).join('');
    const extraCells = resourceName === 'bank_accounts'
      ? `<td><strong>RM ${Number(row.current_balance ?? 0).toFixed(2)}</strong></td>` : '';
    const rowStyle = (resourceName === 'tasks' && PRIORITY_COLOR[row.priority])
      ? `style="border-left:4px solid ${PRIORITY_COLOR[row.priority]};"` : '';
    const linkBtn = (resourceName === 'projects' && row.link)
      ? `<a class="btn small secondary" href="${escapeHtml(row.link)}" target="_blank" rel="noopener">🔗 打开</a>` : '';
    const copyBtn = (resourceName === 'bookmarks')
      ? `<button class="btn small secondary" onclick='copyToClipboard("${escapeHtml(row.url)}")'>📋 复制</button>` : '';
    return `
      <tr ${rowStyle}>
        ${cells}
        ${extraCells}
        <td>
          ${linkBtn}
          ${copyBtn}
          <button class="btn small secondary" onclick='openForm("${resourceName}", ${row.id})'>编辑</button>
          <button class="btn small danger" onclick='deleteRow("${resourceName}", ${row.id})'>删除</button>
        </td>
      </tr>`;
  }).join('') || `<tr><td colspan="${columns.length + 1}" class="empty">还没有数据</td></tr>`;

  const filterBarHtml = buildFilterBarHtml(resourceName, cfg);
  const breakdownHtml = resourceName === 'transactions' ? renderCategoryBreakdown(data, cfg) : '';
  const csvBtn = resourceName === 'transactions'
    ? `<button class="btn secondary" onclick='exportCsv("${resourceName}")'>⬇ 导出 CSV</button>` : '';

  const bodyHtml = CARD_GRID_RESOURCES.has(resourceName)
    ? renderItemGrid(resourceName, data)
    : `<div class="card"><table><thead><tr>${headerHtml}<th></th></tr></thead><tbody>${rowsHtml}</tbody></table></div>`;

  el.innerHTML = `
    <div class="toolbar">
      <div class="page-title" style="margin-bottom:0;">${cfg.icon} ${cfg.label}</div>
      <div style="display:flex;gap:8px;">
        ${csvBtn}
        <button class="btn" onclick='openForm("${resourceName}", null)'>+ 新增</button>
      </div>
    </div>
    ${cfg.note ? `<div class="resource-note">💡 ${escapeHtml(cfg.note)}</div>` : ''}
    ${filterBarHtml}
    ${breakdownHtml}
    ${bodyHtml}
  `;
}

function fkColor(resourceName, id) {
  if (id === null || id === undefined || id === '') return '#9CA3AF';
  const rows = fkCache[resourceName] || [];
  const row = rows.find(r => String(r.id) === String(id));
  return row?.color || '#9CA3AF';
}

async function copyToClipboard(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch (e) {
    // 部分浏览器/非 HTTPS 环境 clipboard API 不可用，静默失败即可
  }
}

async function exportCsv(resourceName) {
  const cfg = RESOURCES[resourceName];
  const filtersPayload = buildFiltersPayload(resourceName, cfg);
  const res = await api({ resource: resourceName, action: 'export_csv', filters: filtersPayload });
  const blob = new Blob(['﻿' + res.csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = res.filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

// 删除前的后果说明：财务相关的删除一旦做错不好补救，多说一句会删掉什么
const DELETE_CONSEQUENCE = {
  salary_payments: '删除这笔发薪记录，会同时删除它自动生成的那笔收入交易，以及关联的 EPF 供款记录。',
  salary_profiles: '⚠ 如果只是想改发薪日/月薪/EPF% 等设置，请点"编辑"而不是删除。删除档案不会删掉它已经自动生成过的发薪记录 (那些钱是真实发生过的事实，会保留)，但那些记录会变成和档案"失联"的孤儿记录——如果之后又建一个新档案，可能会让同一个月被重复生成一次。',
  transactions: '删除这笔交易会直接影响相关银行账户/现金的余额计算。如果这笔是发薪记录自动生成的，请改在"发薪记录"那边删除，不要在这里单独删。',
  bank_accounts: '删除账户前，请确认这个账户名下已经没有交易记录引用它（有引用会被后端拒绝）。',
  banks: '删除银行前，请确认没有银行账户还挂在这家银行名下（有引用会被后端拒绝）。',
  tags: '删除标签前，请确认没有交易/任务/链接还在用这个标签（有引用会被后端拒绝）。',
  subscriptions: '删除这个订阅会连同它的续费提醒一起消失，且不可恢复。',
};

async function deleteRow(resourceName, id) {
  const extra = DELETE_CONSEQUENCE[resourceName];
  const msg = extra ? `确定要删除这条记录吗？\n\n${extra}` : '确定要删除这条记录吗？';
  if (!confirm(msg)) return;
  try {
    await api({ resource: resourceName, action: 'delete', id });
  } catch (e) {
    alert(e.message);
    return;
  }
  invalidateFkCache(resourceName);
  renderResourcePage(resourceName);
}

// ---------------- Generic add/edit form modal ----------------

async function openForm(resourceName, id, presetData) {
  const cfg = RESOURCES[resourceName];
  let record = {};
  if (id) {
    const { data } = await api({ resource: resourceName, action: 'get', id });
    record = data || {};
  }
  if (presetData) record = { ...record, ...presetData };

  // fk 下拉可能还没预加载 (比如从仪表盘"快速操作"直接弹表单，没经过 renderResourcePage)
  const fkFields = Object.entries(cfg.fields).filter(([, f]) => f.type === 'fk');
  await Promise.all(fkFields.map(([, f]) => loadFk(f.fk_resource)));
  await Promise.all(fkFields.filter(([, f]) => f.fk_filter).map(([, f]) => loadFkFiltered(f.fk_resource, f.fk_filter)));

  const fieldsHtml = await Promise.all(Object.entries(cfg.fields).filter(([, f]) => !f.hidden).map(async ([key, f]) => {
    let value = record[key];
    if (value === undefined) {
      value = f.default !== undefined ? f.default : '';
      if (f.default_today && !id) value = todayStr();
    }
    const inner = renderField(key, f, value);
    // show_when 字段包一层可以整块隐藏/显示的 wrapper (比如"转入账户"只在类型=转账时出现)。
    // 支持两种写法: {field, value} = 等于这个值才显示；{field, not} = 不等于这个值才显示 (比如
    // "关联ID"只在关联类型不是"自定义"时才有意义，"自定义说明"反过来只在是"自定义"时才有意义)。
    if (!f.show_when) return inner;
    const attrs = [`data-field-wrapper="${key}"`, `data-show-when-field="${f.show_when.field}"`];
    if (f.show_when.value !== undefined) attrs.push(`data-show-when-value="${f.show_when.value}"`);
    if (f.show_when.not !== undefined) attrs.push(`data-show-when-not="${f.show_when.not}"`);
    return `<div ${attrs.join(' ')}>${inner}</div>`;
  }));

  const modalRoot = document.getElementById('modal-root');
  modalRoot.innerHTML = `
    <div class="modal-backdrop" onclick="if(event.target===this) closeForm()">
      <div class="modal">
        <h3>${id ? '编辑' : '新增'} · ${cfg.label}</h3>
        <form id="record-form">${fieldsHtml.join('')}</form>
        <div class="modal-actions">
          <button class="btn secondary" onclick="closeForm()" type="button">取消</button>
          <button class="btn" onclick='submitForm("${resourceName}", ${id ? id : 'null'})' type="button">保存</button>
        </div>
      </div>
    </div>
  `;

  setupConditionalFields();
  if (resourceName === 'salary_payments') setupSalaryPaymentAutofill(id);
}

function setupSalaryPaymentAutofill(existingId) {
  const form = document.getElementById('record-form');
  const profileSel = form.querySelector('[data-field="salary_profile_id"]');
  const basicInput = form.querySelector('[data-field="basic_salary"]');
  const allowanceInput = form.querySelector('[data-field="allowance"]');
  const bonusInput = form.querySelector('[data-field="bonus"]');
  const commissionInput = form.querySelector('[data-field="commission"]');
  const otherAddInput = form.querySelector('[data-field="other_addition"]');
  const empPctInput = form.querySelector('[data-field="employee_epf_percent"]');
  const emprPctInput = form.querySelector('[data-field="employer_epf_percent"]');
  const empAmtInput = form.querySelector('[data-field="employee_epf_amount"]');
  const emprAmtInput = form.querySelector('[data-field="employer_epf_amount"]');
  const otherDeductInput = form.querySelector('[data-field="other_deductions"]');
  const netInput = form.querySelector('[data-field="net_salary"]');
  const bankSel = form.querySelector('[data-field="bank_account_id"]');
  const periodStartInput = form.querySelector('[data-field="period_start"]');
  const periodEndInput = form.querySelector('[data-field="period_end"]');

  // 入职/离职当月不足整月 (比如 9/2 入职，9/22 发第一份粮，只做了 2-22 号)：
  // 填起薪日+止薪日，按"这段天数 / 当月总天数"的比例算基本薪资，而不是整月的数。
  if (periodEndInput) {
    const anchor = periodEndInput.closest('.field');
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'btn small secondary';
    btn.style.cssText = 'margin:-6px 0 14px;';
    btn.textContent = '⚖️ 按天数比例算基本薪资';
    btn.onclick = () => {
      const start = periodStartInput?.value;
      const end = periodEndInput?.value;
      if (!start || !end) { alert('请先填"本期起薪日"和"本期止薪日"'); return; }
      const startDate = new Date(start);
      const endDate = new Date(end);
      if (endDate < startDate) { alert('止薪日不能早于起薪日'); return; }
      const daysWorked = Math.round((endDate - startDate) / 86400000) + 1;
      const daysInMonth = new Date(startDate.getFullYear(), startDate.getMonth() + 1, 0).getDate();
      const profile = (fkCache['salary_profiles'] || []).find(p => String(p.id) === profileSel?.value);
      const fullBasic = profile ? Number(profile.basic_salary) : (parseFloat(basicInput?.value) || 0);
      const prorated = Math.round(fullBasic * daysWorked / daysInMonth * 100) / 100;
      if (basicInput) basicInput.value = prorated.toFixed(2);
      recompute();
      alert(`这期做了 ${daysWorked} 天，当月共 ${daysInMonth} 天\n基本薪资 RM ${fullBasic.toFixed(2)} × ${daysWorked}/${daysInMonth} = RM ${prorated.toFixed(2)}`);
    };
    anchor?.after(btn);
  }

  // 选薪资档案 -> 带出基本薪资/EPF 百分比/入账账户 (只在新增、还没手动改过的时候自动带，不覆盖编辑中的历史记录)
  function applyProfile() {
    const profile = (fkCache['salary_profiles'] || []).find(p => String(p.id) === profileSel.value);
    if (!profile) return;
    if (basicInput) basicInput.value = profile.basic_salary;
    if (empPctInput) empPctInput.value = profile.employee_epf_percent;
    if (emprPctInput) emprPctInput.value = profile.employer_epf_percent;
    if (bankSel && profile.bank_account_id) bankSel.value = profile.bank_account_id;
    recompute();
  }
  if (profileSel) {
    profileSel.addEventListener('change', applyProfile);
    // 如果表单打开时下拉已经带了预选值 (比如以后哪里用 presetData 带档案进来)，
    // select 的 value 会有但不会触发 change 事件，这里保险起见补一次
    if (!existingId && profileSel.value) applyProfile();
  }

  function recompute() {
    const basic = parseFloat(basicInput?.value) || 0;
    const allowance = parseFloat(allowanceInput?.value) || 0;
    const bonus = parseFloat(bonusInput?.value) || 0;
    const commission = parseFloat(commissionInput?.value) || 0;
    const otherAdd = parseFloat(otherAddInput?.value) || 0;
    const empPct = parseFloat(empPctInput?.value) || 0;
    const emprPct = parseFloat(emprPctInput?.value) || 0;
    const otherDeduct = parseFloat(otherDeductInput?.value) || 0;

    // EPF 一般算在基本薪资上 (不含津贴/花红/佣金)，这里只是给个建议值，金额栏位随时可以手动改
    const empAmt = Math.round(basic * empPct / 100 * 100) / 100;
    const emprAmt = Math.round(basic * emprPct / 100 * 100) / 100;
    if (empAmtInput) empAmtInput.value = empAmt.toFixed(2);
    if (emprAmtInput) emprAmtInput.value = emprAmt.toFixed(2);

    const gross = basic + allowance + bonus + commission + otherAdd;
    const net = gross - empAmt - otherDeduct;
    if (netInput) netInput.value = net.toFixed(2);
  }

  // 新增时才自动算 (编辑已有记录时，历史金额不应该被悄悄重新计算，用户要改自己手动改)
  if (!existingId) {
    [basicInput, allowanceInput, bonusInput, commissionInput, otherAddInput, empPctInput, emprPctInput, otherDeductInput]
      .filter(Boolean)
      .forEach(el => el.addEventListener('input', recompute));
  }
}

function setupConditionalFields() {
  document.querySelectorAll('[data-field-wrapper]').forEach(wrapper => {
    const controllerField = wrapper.dataset.showWhenField;
    const requiredValue = wrapper.dataset.showWhenValue;
    const notValue = wrapper.dataset.showWhenNot;
    const controller = document.querySelector(`#record-form [data-field="${controllerField}"]`);
    if (!controller) return;
    const update = () => {
      const show = notValue !== undefined ? (controller.value !== notValue) : (controller.value === requiredValue);
      wrapper.style.display = show ? '' : 'none';
    };
    update();
    controller.addEventListener('change', update);
  });
}

// 很多字段的 label 本来就在括号里写了说明 (如"期初余额 (这个账户第一次...)")，
// 把括号部分拆出来渲染成更小更淡的提示文字，主标题保持醒目 —— 不用逐个字段改，直接对所有 label 生效。
function splitLabel(label) {
  const m = /^(.*?)\s*[（(]([^)）]+)[）)]\s*$/.exec(label);
  return m ? { main: m[1], hint: m[2] } : { main: label, hint: null };
}
function fieldMainLabel(f) { return splitLabel(f.label).main; }
function fieldLabel(f) {
  const { main, hint } = splitLabel(f.label);
  return `<label>${escapeHtml(main)}${f.required ? ' *' : ''}${hint ? `<span class="field-hint">（${escapeHtml(hint)}）</span>` : ''}</label>`;
}

// 一份好看、彼此容易分辨的预设色板 (给分类/标签/项目分类/习惯这些"选颜色"用) —— 用户不用自己想/记 hex 编码,
// 点圆圈选就好；右边留一个原生颜色选择器给真的想自定义的人用。
const COLOR_PALETTE = [
  '#3B82F6', '#EF4444', '#16A34A', '#F59E0B', '#7C3AED', '#EC4899',
  '#06B6D4', '#84CC16', '#F97316', '#6366F1', '#14B8A6', '#64748B',
];

function pickColor(btn) {
  const wrap = btn.closest('.color-swatch-picker');
  const hidden = wrap.querySelector('input[type=hidden]');
  hidden.value = btn.dataset.color;
  wrap.querySelectorAll('.color-swatch').forEach(s => s.classList.toggle('selected', s === btn));
  const custom = wrap.querySelector('.color-swatch-custom');
  if (custom) custom.value = btn.dataset.color;
}
function pickColorCustom(input) {
  const wrap = input.closest('.color-swatch-picker');
  const hidden = wrap.querySelector('input[type=hidden]');
  hidden.value = input.value;
  wrap.querySelectorAll('.color-swatch').forEach(s => s.classList.remove('selected'));
}

function renderField(key, f, value) {
  const label = fieldLabel(f);
  const ph = f.placeholder ? `placeholder="${escapeHtml(f.placeholder)}"` : '';
  switch (f.type) {
    case 'color': {
      const current = (value || '').toLowerCase();
      const swatches = COLOR_PALETTE.map(c => `<button type="button" class="color-swatch${current === c.toLowerCase() ? ' selected' : ''}" style="background:${c};" data-color="${c}" onclick="pickColor(this)" title="${c}"></button>`).join('');
      return `<div class="field">${label}
        <div class="color-swatch-picker">
          ${swatches}
          <input type="color" class="color-swatch-custom" title="自定义颜色" value="${current || '#9ca3af'}" onchange="pickColorCustom(this)">
          <input type="hidden" data-field="${key}" value="${escapeHtml(value)}">
        </div>
      </div>`;
    }
    case 'textarea':
    case 'json':
      return `<div class="field">${label}
        <textarea data-field="${key}" ${ph} ${f.type === 'json' ? 'style="font-family:monospace;"' : ''}>${escapeHtml(value)}</textarea></div>`;
    case 'select': {
      const opts = Object.entries(f.options).map(([v, l]) =>
        `<option value="${v}" ${String(value) === v ? 'selected' : ''}>${l}</option>`).join('');
      return `<div class="field">${label}<select data-field="${key}">${opts}</select></div>`;
    }
    case 'fk': {
      const rows = f.fk_filter
        ? (fkFilteredCache[`${f.fk_resource}::${JSON.stringify(f.fk_filter)}`] || [])
        : (fkCache[f.fk_resource] || []);
      const displayField = RESOURCES[f.fk_resource]?.display_field || 'id';
      const opts = `<option value="">（无）</option>` + rows.map(r =>
        `<option value="${r.id}" ${String(value) === String(r.id) ? 'selected' : ''}>${escapeHtml(r[displayField])}</option>`).join('');
      return `<div class="field">${label}<select data-field="${key}">${opts}</select></div>`;
    }
    case 'url':
      return `<div class="field">${label}<input type="url" placeholder="${f.placeholder ? escapeHtml(f.placeholder) : 'https://...'}" data-field="${key}" value="${escapeHtml(value)}"></div>`;
    case 'boolean':
      return `<div class="field checkbox">
        <input type="checkbox" id="f_${key}" data-field="${key}" ${value == 1 || value === true ? 'checked' : ''}>
        <label for="f_${key}">${escapeHtml(f.label)}</label></div>`;
    case 'number':
      return `<div class="field">${label}<input type="number" ${ph} data-field="${key}" value="${escapeHtml(value)}" ${f.min !== undefined ? `min="${f.min}"` : ''} ${f.max !== undefined ? `max="${f.max}"` : ''}></div>`;
    case 'decimal':
      return `<div class="field">${label}<input type="number" step="0.01" ${ph || 'placeholder="0.00"'} data-field="${key}" value="${escapeHtml(value)}"></div>`;
    case 'date':
      return `<div class="field">${label}<input type="date" data-field="${key}" value="${escapeHtml(value)}"></div>`;
    case 'time': {
      // 存的值可能是纯时间 (如 time_blocks."14:30:00") 也可能是完整日期时间 (如 reminders.remind_at
      // "2026-09-25 05:30:00" —— 表单只要用户填"几点"，日期是后端自动算的，见 api.php)，两种都要能抓到时间部分
      const timePart = (value || '').includes(' ') ? (value || '').split(' ')[1] : (value || '');
      return `<div class="field">${label}<input type="time" data-field="${key}" value="${escapeHtml(timePart.slice(0,5))}"></div>`;
    }
    case 'datetime':
      return `<div class="field">${label}<input type="datetime-local" data-field="${key}" value="${escapeHtml((value||'').replace(' ','T').slice(0,16))}"></div>`;
    case 'tags': {
      let display = value;
      try { display = JSON.parse(value || '[]').join(', '); } catch (e) {}
      return `<div class="field">${label}<input type="text" placeholder="${f.placeholder ? escapeHtml(f.placeholder) : '逗号分隔，如：读书, 效率'}" data-field="${key}" value="${escapeHtml(display)}"></div>`;
    }
    default:
      return `<div class="field">${label}<input type="text" ${ph} data-field="${key}" value="${escapeHtml(value)}"></div>`;
  }
}

function closeForm() {
  document.getElementById('modal-root').innerHTML = '';
}

async function submitForm(resourceName, id) {
  const cfg = RESOURCES[resourceName];
  const form = document.getElementById('record-form');
  const data = {};
  for (const key of Object.keys(cfg.fields)) {
    const f = cfg.fields[key];
    const el = form.querySelector(`[data-field="${key}"]`);
    if (!el) continue;
    if (f.type === 'boolean') data[key] = el.checked;
    else data[key] = el.value;
  }
  // required field check
  for (const [key, f] of Object.entries(cfg.fields)) {
    if (f.required && f.type !== 'boolean' && !data[key]) {
      alert(`请填写：${fieldMainLabel(f)}`);
      return;
    }
  }
  // 转账必须要有转入账户，且转出/转入不能是同一个账户，金额要大于 0
  // (这几条不是"通用必填"，只在类型=转账时才要求；后端也重复挡一遍，这里只是让用户更早看到提示)
  if (resourceName === 'transactions' && data.type === 'transfer') {
    if (!data.transfer_to_account_id) {
      alert('请选择转入账户');
      return;
    }
    if (data.bank_account_id === data.transfer_to_account_id) {
      alert('转出账户和转入账户不能是同一个');
      return;
    }
    if (!(parseFloat(data.amount) > 0)) {
      alert('转账金额必须大于 0');
      return;
    }
  }
  try {
    if (id) {
      await api({ resource: resourceName, action: 'update', id, data });
    } else {
      await api({ resource: resourceName, action: 'create', data });
    }
    invalidateFkCache(resourceName);
    closeForm();
    // 当前在仪表盘打开的表单(比如"快速操作")，保存后刷新仪表盘；否则刷新对应资源列表页
    const currentRoute = (location.hash || '#dashboard').slice(1);
    if (currentRoute === 'dashboard') renderDashboard();
    else renderResourcePage(resourceName);
  } catch (e) {
    alert('保存失败：' + e.message);
  }
}

// ---------------- Boot ----------------

async function boot() {
  const meta = await api({ action: 'meta' });
  RESOURCES = meta.resources;
  buildSidebar();
  setupTopbarAndBottomNav();
  window.addEventListener('hashchange', router);
  router();
}

boot();
