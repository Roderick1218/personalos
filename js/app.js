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
  system: [
    { route: 'backup', icon: '💾', label: '备份与恢复' },
    { route: 'admin-users', icon: '🛡️', label: '用户管理', adminOnly: true },
  ],
};

// v2/v3 规范: 只保留这份文档定义的核心模块，其余(库存/旅行/AI助理等)先从导航隐藏，
// 数据库表和数据都还在，以后要恢复随时把对应 resource 名字加回这个集合就行。
const CORE_VISIBLE = new Set([
  'tasks', 'projects', 'project_categories', 'habits', 'habit_logs',
  'categories', 'transactions', 'subscriptions', 'journal_entries', 'contacts',
  'bank_accounts', 'banks', 'tags', 'bookmarks',
  'salary_profiles', 'salary_payments', 'epf_contributions', 'socso_contributions', 'eis_contributions',
  'reminders', 'reports', 'fixed_deposits', 'daily_metrics',
]);

const PRIORITY_COLOR = { urgent: '#ef4444', high: '#ef4444', medium: '#f59e0b', low: '#22c55e' };
const PRIORITY_LABEL = { urgent: '紧急', high: '高', medium: '中', low: '低' };

let RESOURCES = {};      // meta from backend
let CURRENT_USER = null; // {id, username} — 多用户登录后的当前用户
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
  if (payload.action !== 'meta') {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) {
      // session 掉了 (比如另一台设备登出、token 过期) —— 直接弹回登录页，不留在半吊子界面
      showLoginScreen();
      throw new Error('请先登录');
    }
  }
  const json = await SupabaseBridge.call(payload);
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

// tags 栏位在 Postgres 是 jsonb，Supabase 回传时已经是解析好的数组，不再是 MySQL 时代
// 那种要自己 JSON.parse() 的字符串——直接 parse 一个已经是数组的东西会抛错。这里统一处理
// 两种可能的形状 (数组本身 / 还没解析的 JSON 字符串 / 空)，避免到处重复同一段 try/catch。
function parseTagsField(value) {
  if (Array.isArray(value)) return value;
  if (!value) return [];
  try { const parsed = JSON.parse(value); return Array.isArray(parsed) ? parsed : []; } catch (e) { return []; }
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

  const isAdmin = CURRENT_USER?.role === 'admin';
  for (const g of GROUP_ORDER) {
    const staticLinks = (STATIC_NAV_LINKS[g] || []).filter(l => !l.adminOnly || isAdmin);
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

  // 用 .onclick 赋值而不是 addEventListener —— 这几个元素是页面固定结构 (不像 nav-content 每次
  // boot() 都会整个重新生成)，用户登出又重新登入的话 boot() 会再跑一次，addEventListener 会重复绑定
  document.getElementById('sidebar-username').textContent = '👤 ' + (CURRENT_USER?.display_name || CURRENT_USER?.username || '');
  document.getElementById('sidebar-change-pw').onclick = (e) => { e.preventDefault(); openChangePasswordModal(); };
  document.getElementById('sidebar-logout').onclick = (e) => { e.preventDefault(); logout(); };
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
      html += `<div class="search-row" onclick='openSearchResult("${r.resource}", "${r.id}")'>
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
  else if (route === 'reports') renderReportsPage();
  else if (route === 'admin-users') renderAdminUsersPage();
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
      <h3>导出我的数据</h3>
      <p class="stat-sub" id="backup-status">${backupStatusHtml(lastBackup)}</p>
      <button class="btn" id="btn-export-sql" style="margin-top:12px;">📦 导出我的数据 (SQL)</button>
      <p class="stat-sub" style="margin-top:14px;">导出当前账号的数据，格式是一串 INSERT 语句。请定期保存到本机以外的地方（例如网盘）。</p>
    </div>
    <div class="card" style="max-width:560px; margin-top:16px;">
      <h3>各模块 CSV 导出</h3>
      <p class="stat-sub">在「财务记账」等列表页顶部工具栏也有单独的「⬇ 导出 CSV」按钮，只导出该模块当前筛选条件下的数据。</p>
    </div>
    ${CURRENT_USER?.role === 'admin' ? `
    <div class="card" style="max-width:560px; margin-top:16px;">
      <h3>🛡️ 全库备份 (管理员)</h3>
      <p class="stat-sub">导出全部登录资料与业务数据。新项目请先跑 <code>个人系统_schema_supabase.sql</code> 建表和权限，再执行这份 SQL。请妥善保管。</p>
      <button class="btn danger" id="btn-export-full-sql" style="margin-top:12px;">🛡️ 导出全库备份 (SQL)</button>
    </div>` : ''}
  `;
  document.getElementById('btn-export-sql').addEventListener('click', exportFullBackup);
  if (CURRENT_USER?.role === 'admin') {
    document.getElementById('btn-export-full-sql').addEventListener('click', exportFullDbBackup);
  }
}

async function exportFullDbBackup() {
  const btn = document.getElementById('btn-export-full-sql');
  btn.disabled = true;
  btn.textContent = '导出中...';
  try {
    const res = await api({ action: 'admin_export_full_sql' });
    const blob = new Blob(['﻿' + res.sql], { type: 'application/sql;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = res.filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  } catch (e) {
    alert('导出失败：' + e.message);
  } finally {
    btn.disabled = false;
    btn.textContent = '🛡️ 导出全库备份 (SQL)';
  }
}

// ---------------- 用户管理 (仅 admin) ----------------

const ROLE_LABEL = { admin: '管理员', user: '普通用户' };

async function renderAdminUsersPage() {
  const el = document.getElementById('page-content');
  el.innerHTML = `
    <div class="toolbar">
      <div class="page-title" style="margin-bottom:0;">🛡️ 用户管理</div>
      <button class="btn" id="btn-add-user">+ 新增用户</button>
    </div>
    <div class="resource-note">💡 只有管理员能看到这个页面。新增/编辑账号，或把某人升级/降级成管理员。系统至少要留一个管理员，不能把最后一个降级或删除。</div>
    <div id="admin-users-list">${skeletonLines(4)}</div>
  `;
  document.getElementById('btn-add-user').addEventListener('click', () => openAdminUserForm(null));
  await loadAndRenderAdminUsers();
}

let ADMIN_USERS_CACHE = [];

async function loadAndRenderAdminUsers() {
  const listEl = document.getElementById('admin-users-list');
  let users;
  try {
    const res = await api({ action: 'admin_list_users' });
    users = res.data;
    ADMIN_USERS_CACHE = users;
  } catch (e) {
    listEl.innerHTML = `<p class="empty">加载失败：${escapeHtml(e.message)}</p>`;
    return;
  }
  listEl.innerHTML = `
    <div class="card">
      <table>
        <thead><tr><th>名字</th><th>角色</th><th>创建时间</th><th></th></tr></thead>
        <tbody>
          ${users.map(u => `
            <tr>
              <td>${escapeHtml(u.display_name || u.username || '')}${u.id === CURRENT_USER.id ? ' <span class="stat-sub">(我)</span>' : ''}</td>
              <td><span class="badge" style="background:${u.role === 'admin' ? 'rgba(0,240,255,0.15);color:var(--accent)' : 'rgba(255,255,255,0.08);color:var(--muted)'};">${ROLE_LABEL[u.role] || u.role}</span></td>
              <td class="stat-sub">${u.created_at}</td>
              <td style="text-align:right; white-space:nowrap;">
                <button class="btn small secondary" onclick='openAdminUserFormById("${u.id}")'>编辑</button>
                <button class="btn small danger" onclick='deleteAdminUser("${u.id}")' ${u.id === CURRENT_USER.id ? 'disabled title="不能删除自己"' : ''}>删除</button>
              </td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function openAdminUserFormById(id) {
  openAdminUserForm(ADMIN_USERS_CACHE.find(u => u.id === id) || null);
}

function openAdminUserForm(user) {
  const isEdit = !!user;
  const modalRoot = document.getElementById('modal-root');
  modalRoot.innerHTML = `
    <div class="modal-backdrop" onclick="if(event.target===this) closeForm()">
      <div class="modal">
        <h3>${isEdit ? '编辑用户' : '新增用户'}</h3>
        <div class="field"><label>名字</label><input type="text" id="admin-user-display-name" value="${isEdit ? escapeHtml(user.display_name || '') : ''}" autocomplete="off"></div>
        <div class="field"><label>邮箱</label><input type="email" id="admin-user-email" value="${isEdit ? escapeHtml(user.email || '') : ''}" autocomplete="off"></div>
        <div class="field">
          <label>角色</label>
          <select id="admin-user-role">
            <option value="user" ${!isEdit || user.role === 'user' ? 'selected' : ''}>普通用户</option>
            <option value="admin" ${isEdit && user.role === 'admin' ? 'selected' : ''}>管理员</option>
          </select>
        </div>
        ${!isEdit
          ? '<div class="field"><label>密码 (至少 6 位)</label><input type="password" id="admin-user-password" autocomplete="new-password"></div>'
          : ''}
        <div id="admin-user-form-error" class="login-error"></div>
        <div class="modal-actions">
          <button class="btn secondary" onclick="closeForm()" type="button">取消</button>
          <button class="btn" onclick="submitAdminUserForm(${isEdit ? "'" + user.id + "'" : 'null'})" type="button">保存</button>
        </div>
      </div>
    </div>
  `;
}

async function submitAdminUserForm(id) {
  const displayName = document.getElementById('admin-user-display-name').value.trim();
  const role = document.getElementById('admin-user-role').value;
  const errEl = document.getElementById('admin-user-form-error');
  errEl.textContent = '';
  if (!displayName) { errEl.textContent = '请填写名字'; return; }

  try {
    if (id) {
      const email = document.getElementById('admin-user-email').value.trim();
      await api({ action: 'admin_update_user', id, display_name: displayName, role, email });
    } else {
      const email = document.getElementById('admin-user-email').value.trim();
      const password = document.getElementById('admin-user-password').value;
      if (!email) { errEl.textContent = '请填写邮箱'; return; }
      if (password.length < 6) { errEl.textContent = '密码至少要 6 位'; return; }
      const res = await api({ action: 'admin_create_user', email, display_name: displayName, role, password });
      if (res && res.message) alert(res.message);
    }
    closeForm();
    await loadAndRenderAdminUsers();
  } catch (e) {
    errEl.textContent = e.message;
  }
}

async function deleteAdminUser(id) {
  const user = ADMIN_USERS_CACHE.find(u => u.id === id);
  const username = user ? user.username : `#${id}`;
  if (!confirm(`确定要删除用户「${username}」吗？\n\n这会永久删除这个账号名下所有模块的所有数据 (任务/交易/日记...全部)，不是只删账号本身，不能恢复。`)) return;
  try {
    await api({ action: 'admin_delete_user', id });
  } catch (e) {
    alert(e.message);
    return;
  }
  await loadAndRenderAdminUsers();
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

// ---------------- 报表汇总 ----------------

const REPORT_TYPE_LABEL = { weekly: '周报', monthly: '月报', yearly: '年报' };
const REPORT_QUICK_OPTIONS = {
  weekly: [{ value: 'this_week', label: '本周' }, { value: 'last_week', label: '上周' }],
  monthly: [{ value: 'this_month', label: '本月' }, { value: 'last_month', label: '上月' }],
  yearly: [{ value: 'this_year', label: '今年' }, { value: 'last_year', label: '去年' }],
};

function pad2(n) { return String(n).padStart(2, '0'); }
function toYMD(d) { return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`; }

// 根据"类型 + 快捷选项"算出对应的开始/结束日期，填进两个日期输入框 (用户还是可以自己改成任意区间)
function computeQuickPeriod(reportType, quickPick) {
  const now = new Date();
  if (reportType === 'weekly') {
    const day = now.getDay(); // 0=周日 ... 6=周六
    const diffToMonday = (day === 0 ? -6 : 1 - day);
    const monday = new Date(now.getFullYear(), now.getMonth(), now.getDate() + diffToMonday);
    if (quickPick === 'last_week') monday.setDate(monday.getDate() - 7);
    const sunday = new Date(monday.getFullYear(), monday.getMonth(), monday.getDate() + 6);
    return [toYMD(monday), toYMD(sunday)];
  }
  if (reportType === 'yearly') {
    let year = now.getFullYear();
    if (quickPick === 'last_year') year -= 1;
    return [`${year}-01-01`, `${year}-12-31`];
  }
  let year = now.getFullYear(), month = now.getMonth(); // monthly (默认)
  if (quickPick === 'last_month') { month -= 1; if (month < 0) { month = 11; year -= 1; } }
  const start = new Date(year, month, 1);
  const end = new Date(year, month + 1, 0);
  return [toYMD(start), toYMD(end)];
}

// 把 period_start/period_end 显示成人话 (整月/整年就显示"2026年9月"，不是标准整月整年区间就直接显示日期范围)
function formatReportPeriodLabel(r) {
  const start = r.period_start, end = r.period_end;
  if (r.report_type === 'yearly' && start.slice(5) === '01-01' && end.slice(5) === '12-31' && start.slice(0, 4) === end.slice(0, 4)) {
    return `${start.slice(0, 4)}年`;
  }
  if (r.report_type === 'monthly' && start.slice(0, 7) === end.slice(0, 7) && start.slice(8, 10) === '01') {
    const d = new Date(start + 'T00:00:00');
    const lastDay = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
    if (Number(end.slice(8, 10)) === lastDay) return `${start.slice(0, 4)}年${Number(start.slice(5, 7))}月`;
  }
  return `${start} ~ ${end}`;
}

async function renderReportsPage() {
  const el = document.getElementById('page-content');
  el.innerHTML = `
    <div class="toolbar">
      <div class="page-title" style="margin-bottom:0;">📑 报表汇总</div>
    </div>
    <div class="resource-note">💡 选一个期间生成报表：收支/分类占比/前5大支出/薪资/EPF供款/订阅扣费/期末各账户余额，外加习惯打卡次数和日记篇数。同一个期间可以重新生成覆盖最新数字，不会重复堆一份。</div>
    <div class="card" style="max-width:640px;">
      <h3>生成新报表</h3>
      <div style="display:flex; gap:12px; flex-wrap:wrap;">
        <div class="field" style="min-width:140px;">
          <label>类型</label>
          <select id="report-type-select">
            <option value="monthly">月报</option>
            <option value="weekly">周报</option>
            <option value="yearly">年报</option>
          </select>
        </div>
        <div class="field" style="min-width:140px;">
          <label>期间</label>
          <select id="report-quick-select"></select>
        </div>
      </div>
      <div style="display:flex; gap:12px; flex-wrap:wrap;">
        <div class="field" style="min-width:160px;"><label>开始日期</label><input type="date" id="report-period-start"></div>
        <div class="field" style="min-width:160px;"><label>结束日期</label><input type="date" id="report-period-end"></div>
      </div>
      <button class="btn" id="btn-generate-report">📑 生成报表</button>
    </div>
    <div id="reports-list" style="margin-top:20px;">${skeletonLines(3)}</div>
  `;

  function refreshQuickOptions() {
    const type = document.getElementById('report-type-select').value;
    const sel = document.getElementById('report-quick-select');
    const opts = REPORT_QUICK_OPTIONS[type];
    sel.innerHTML = opts.map(o => `<option value="${o.value}">${escapeHtml(o.label)}</option>`).join('') + '<option value="custom">自订日期</option>';
    applyQuickPick();
  }
  function applyQuickPick() {
    const type = document.getElementById('report-type-select').value;
    const pick = document.getElementById('report-quick-select').value;
    if (pick === 'custom') return;
    const [start, end] = computeQuickPeriod(type, pick);
    document.getElementById('report-period-start').value = start;
    document.getElementById('report-period-end').value = end;
  }
  document.getElementById('report-type-select').addEventListener('change', refreshQuickOptions);
  document.getElementById('report-quick-select').addEventListener('change', applyQuickPick);
  refreshQuickOptions();

  document.getElementById('btn-generate-report').addEventListener('click', async () => {
    const btn = document.getElementById('btn-generate-report');
    const reportType = document.getElementById('report-type-select').value;
    const periodStart = document.getElementById('report-period-start').value;
    const periodEnd = document.getElementById('report-period-end').value;
    if (!periodStart || !periodEnd || periodStart > periodEnd) { alert('请选择正确的开始/结束日期'); return; }
    btn.disabled = true;
    btn.textContent = '生成中...';
    try {
      await api({ action: 'generate_report', report_type: reportType, period_start: periodStart, period_end: periodEnd });
      await loadAndRenderReportsList();
    } catch (e) {
      alert('生成失败：' + e.message);
    } finally {
      btn.disabled = false;
      btn.textContent = '📑 生成报表';
    }
  });

  await loadAndRenderReportsList();
}

async function loadAndRenderReportsList() {
  const listEl = document.getElementById('reports-list');
  const { data } = await api({ resource: 'reports', action: 'list' });
  const reports = [...data].sort((a, b) => b.period_start.localeCompare(a.period_start));
  if (!reports.length) {
    listEl.innerHTML = '<p class="empty">还没有生成过报表，选好期间点上面的"生成报表"试试</p>';
    return;
  }
  listEl.innerHTML = reports.map(r => reportCardHtml(r)).join('');
}

function reportCardHtml(r) {
  // r.content 是 Postgres 的 jsonb 栏位，Supabase 回传时已经是解析好的对象/数组，
  // 不再是 MySQL 时代那种要自己 JSON.parse() 的字符串——parse 一个已经是物件的东西会
  // 抛错，被下面吞掉后就变成永远显示空的 {}，看起来就像"报表生成了但内容都是空的"。
  const content = (r.content && typeof r.content === 'object') ? r.content
    : (() => { try { return JSON.parse(r.content); } catch (e) { return {}; } })();
  const periodLabel = formatReportPeriodLabel(r);
  const net = Number(content.net || 0);
  const netColor = net >= 0 ? '#00FF87' : '#FF3366';
  return `
    <div class="card" style="max-width:900px; margin-bottom:16px;">
      <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px;">
        <div>
          <strong style="font-size:16px;color:var(--navy);">${escapeHtml(periodLabel)}</strong>
          <span class="badge" style="background:#DBEAFE;color:#2563EB;margin-left:8px;">${REPORT_TYPE_LABEL[r.report_type] || r.report_type}</span>
        </div>
        <span>
          <button class="btn small secondary" onclick='toggleReportDetail("${r.id}")'>查看详情</button>
          <button class="btn small danger" onclick='deleteReport("${r.id}")'>删除</button>
        </span>
      </div>
      <div style="display:flex; gap:28px; margin-top:12px; flex-wrap:wrap;">
        <div><div class="stat-sub">收入</div><strong>RM ${Number(content.income_total || 0).toFixed(2)}</strong></div>
        <div><div class="stat-sub">支出</div><strong>RM ${Number(content.expense_total || 0).toFixed(2)}</strong></div>
        <div><div class="stat-sub">结余</div><strong style="color:${netColor};">RM ${net.toFixed(2)}</strong></div>
      </div>
      <div id="report-detail-${r.id}" style="display:none; margin-top:16px; border-top:1px solid var(--border); padding-top:16px;">
        ${reportDetailHtml(content)}
      </div>
    </div>
  `;
}

function reportDetailHtml(c) {
  const topExpensesHtml = (c.top_expenses || []).length
    ? c.top_expenses.map(t => `
        <div class="list-row">
          <div class="list-row-icon">🧾</div>
          <div class="list-row-body">
            <div class="list-row-title">${escapeHtml(t.description)}</div>
            <div class="list-row-sub">${escapeHtml(t.category_label)} · ${t.date}</div>
          </div>
          <div class="list-row-right"><div class="list-row-amount expense">- RM ${Number(t.amount).toFixed(2)}</div></div>
        </div>`).join('')
    : '<p class="empty">这段期间没有支出记录</p>';

  const habitsHtml = (c.habit_checkins || []).length
    ? c.habit_checkins.map(h => `<div class="donut-legend-item"><span class="donut-legend-left">${escapeHtml(h.name)}</span><span>${h.cnt} 次</span></div>`).join('')
    : '<p class="empty">这段期间没有习惯打卡记录</p>';

  const accountsHtml = (c.account_balances || []).length
    ? c.account_balances.map(a => `<div class="donut-legend-item"><span class="donut-legend-left">${escapeHtml(a.nickname)}</span><span>RM ${Number(a.balance).toFixed(2)}</span></div>`).join('')
    : '<p class="empty">还没有银行账户/现金记录</p>';

  const epf = c.epf_contributed || {};
  const subs = c.subscriptions_charged || {};

  return `
    <div class="grid-3">
      <div>
        <h4>支出分类占比</h4>
        ${buildDonutHtml(c.category_breakdown || [], '期间支出', '这段期间没有支出记录')}
      </div>
      <div>
        <h4>薪资 / EPF / 订阅 / 日记</h4>
        <p>💼 薪资收入：RM ${Number(c.salary_received || 0).toFixed(2)}</p>
        <p>🏦 EPF 供款：员工 RM ${Number(epf.employee || 0).toFixed(2)} · 雇主 RM ${Number(epf.employer || 0).toFixed(2)} · 自愿 RM ${Number(epf.additional || 0).toFixed(2)}</p>
        <p>🔄 订阅扣费：${subs.count || 0} 笔，共 RM ${Number(subs.total || 0).toFixed(2)}</p>
        <p>📓 日记：${c.journal_entry_count || 0} 篇</p>
      </div>
      <div>
        <h4>期末账户余额 (合计 RM ${Number(c.total_balance_at_period_end || 0).toFixed(2)})</h4>
        ${accountsHtml}
      </div>
    </div>
    <div style="margin-top:20px;">
      <h4>前 5 大支出</h4>
      ${topExpensesHtml}
    </div>
    <div style="margin-top:20px;">
      <h4>习惯打卡次数</h4>
      ${habitsHtml}
    </div>
  `;
}

function toggleReportDetail(id) {
  const detailEl = document.getElementById(`report-detail-${id}`);
  if (detailEl) detailEl.style.display = detailEl.style.display === 'none' ? 'block' : 'none';
}

async function deleteReport(id) {
  if (!confirm('确定要删除这份报表吗？(只删除这份汇总快照，不会动到原始的交易/薪资等记录)')) return;
  try {
    await api({ resource: 'reports', action: 'delete', id });
  } catch (e) {
    alert(e.message);
    return;
  }
  await loadAndRenderReportsList();
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

function buildDonutHtml(breakdown, centerLabel = '本月支出', emptyText = '这个月还没有支出记录', legendMode = 'percent') {
  const total = breakdown.reduce((s, c) => s + c.amount, 0);
  if (!total) return `<p class="empty">${escapeHtml(emptyText)}</p>`;
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
      <span class="donut-legend-pct">${legendMode === 'amount' ? 'RM ' + c.amount.toFixed(2) : ((c.amount / total) * 100).toFixed(0) + '%'}</span>
    </div>
  `).join('');
  return `
    <div class="donut-wrap">
      <div class="donut" style="background: conic-gradient(${stops});">
        <div class="donut-center"><span class="amount">RM ${total.toFixed(0)}</span><span class="label">${escapeHtml(centerLabel)}</span></div>
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

// 资产占比饼图: 复用 buildDonutHtml (它本来就是通用的 {label,color,amount} breakdown 渲染器)，
// 每个账户一个颜色 (用色板按顺序分配，同类型比如两个银行户口才不会撞色分不清) —— 只放余额>0的账户，
// 负数/零余额在圆饼图里没意义 (资产分布那个长条图已经能看到负数了)。
function buildAssetDonutHtml(accounts) {
  const positive = accounts.filter(a => Number(a.current_balance) > 0);
  if (!positive.length) return '<p class="empty">还没有正余额的账户</p>';
  const sorted = [...positive].sort((a, b) => Number(b.current_balance) - Number(a.current_balance));
  const breakdown = sorted.map((a, i) => ({
    label: `${ACCOUNT_KIND_ICON[a.account_kind] || '🏦'} ${a.nickname}`,
    color: COLOR_PALETTE[i % COLOR_PALETTE.length],
    amount: Number(a.current_balance),
  }));
  return buildDonutHtml(breakdown, '总资产', '还没有正余额的账户');
}

// EPF 2024 新制度三户口占比饼图: Akaun Persaraan (退休) / Akaun Sejahtera (安康) / Akaun Fleksibel (灵活)。
// 数字来自每笔 epf_contributions 自己存的 persaraan_amount/sejahtera_amount/fleksibel_amount 加总
// (每笔可以各自设置比例，见 config_resources.php 的说明) —— 这里只是把累计数字画成饼图。
const EPF_ACCOUNT_COLOR = { persaraan: '#3B82F6', sejahtera: '#16A34A', fleksibel: '#F59E0B' };
function buildEpfAccountDonutHtml(epfCumulative) {
  const c = epfCumulative || {};
  const breakdown = [
    { label: 'Akaun Persaraan', color: EPF_ACCOUNT_COLOR.persaraan, amount: Number(c.persaraan || 0) },
    { label: 'Akaun Sejahtera', color: EPF_ACCOUNT_COLOR.sejahtera, amount: Number(c.sejahtera || 0) },
    { label: 'Akaun Fleksibel', color: EPF_ACCOUNT_COLOR.fleksibel, amount: Number(c.fleksibel || 0) },
  ];
  return buildDonutHtml(breakdown, 'EPF 总额', '还没有 EPF 供款记录', 'amount');
}

async function renderDashboard() {
  const el = document.getElementById('page-content');
  el.innerHTML = dashboardSkeleton();
  const d = await api({ action: 'dashboard' });

  const habitRows = d.habits.map(h => `
    <div class="habit-row">
      <label style="display:flex;align-items:center;gap:10px;cursor:pointer;flex:1;">
        <input type="checkbox" ${h.checked_today ? 'checked' : ''} onchange="toggleHabit('${h.id}', this.checked)">
        ${escapeHtml(h.name)}
      </label>
      <span class="stat-sub">${h.frequency === 'daily' ? '每天' : h.frequency === 'weekly' ? '每周' : '自定义'}</span>
    </div>
  `).join('') || '<p class="empty">还没有习惯，去"习惯"页面加一个吧</p>';

  // 2026-09-29: 拿掉左右滑动手势 (跟按钮抢点击，会把"✓ 完成"按钮的点击吃掉)，
  // 只保留点按钮完成这一种操作方式，用户明确说不要滑动了。
  const taskRows = d.tasks_today.map(t => `
    <div class="habit-row" style="border-left:4px solid ${PRIORITY_COLOR[t.priority] || '#9CA3AF'};padding-left:10px;">
      <span>${escapeHtml(t.title)} <span class="badge" style="background:${PRIORITY_COLOR[t.priority]}22;color:${PRIORITY_COLOR[t.priority]};">${PRIORITY_LABEL[t.priority] || t.priority}</span></span>
      <button class="btn small secondary" onclick="quickCompleteTask('${t.id}')">✓ 完成</button>
    </div>
  `).join('') || '<p class="empty">没有待办任务</p>';

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
  const skippedSalaryNote = (d.auto_generate_skipped_salary || []).length
    ? `<div class="resource-note warning">⚠ 「${d.auto_generate_skipped_salary.map(s => `${escapeHtml(s.company_name)}」发薪日已经到了，但${escapeHtml(s.reason)}，没办法自动生成发薪记录`).join('；「')}——去"薪资档案"把这个补上，下次打开就会自动生成了。</div>`
    : '';
  const autoSubNote = (d.auto_generated_subscriptions || []).length
    ? `<div class="resource-note">✅ 已自动生成 ${d.auto_generated_subscriptions.map(g => `「${escapeHtml(g.name)}」${g.date} 扣费 RM ${Number(g.amount).toFixed(2)}`).join('、')}。</div>`
    : '';
  const skippedSubNote = (d.auto_generate_skipped_subscriptions || []).length
    ? `<div class="resource-note warning">⚠ 「${d.auto_generate_skipped_subscriptions.map(s => `${escapeHtml(s.name)}」已经到期，但${escapeHtml(s.reason)}，没办法自动生成扣费记录`).join('；「')}——去"订阅管理"把这个补上，下次打开就会自动生成了。</div>`
    : '';
  const maturedFdNote = (d.auto_matured_fixed_deposits || []).length
    ? `<div class="resource-note">✅ ${d.auto_matured_fixed_deposits.map(m => m.action === 'renew'
        ? `一笔定存到期，本金 RM ${Number(m.principal).toFixed(2)} + 利息 RM ${Number(m.interest).toFixed(2)} 已自动展期`
        : `一笔定存到期，本金 RM ${Number(m.principal).toFixed(2)} + 利息 RM ${Number(m.interest).toFixed(2)} = RM ${Number(m.total).toFixed(2)} 已自动存入指定账户`
      ).join('；')}。</div>`
    : '';
  const skippedFdNote = (d.auto_generate_skipped_fixed_deposits || []).length
    ? `<div class="resource-note warning">⚠ 有 ${d.auto_generate_skipped_fixed_deposits.length} 笔定存已经到期，但没有设置"到期转入账户"，没办法自动处理——去"定期存款"把这个补上，下次打开就会自动处理了。</div>`
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
    ${skippedSalaryNote}
    ${autoSubNote}
    ${skippedSubNote}
    ${maturedFdNote}
    ${skippedFdNote}

    <div class="stat-grid">
      <div class="stat-card">
        <div class="stat-icon bg-purple">💰</div>
        <div class="stat-info">
          <div class="stat-label-row"><span class="stat-label">总余额</span><span class="stat-dot" style="background:#7C3AED;"></span></div>
          <div class="stat-value">RM ${Number(d.total_balance || 0).toFixed(2)}</div>
          <div class="stat-foot">${(d.bank_accounts || []).length} 个账户${(d.fixed_deposits_count || 0) > 0 ? ` · 另有定存 RM ${Number(d.fixed_deposits_total).toFixed(2)} (${d.fixed_deposits_count}笔)` : ''}</div>
        </div>
      </div>
      <div class="stat-card">
        <div class="stat-icon bg-red">🛍️</div>
        <div class="stat-info">
          <div class="stat-label-row"><span class="stat-label">今日支出</span><span class="stat-dot" style="background:#FF3366;"></span></div>
          <div class="stat-value">RM ${d.expense_today.toFixed(2)}</div>
          <div class="stat-foot">${d.date}</div>
        </div>
      </div>
      <div class="stat-card">
        <div class="stat-icon bg-green">📈</div>
        <div class="stat-info">
          <div class="stat-label-row"><span class="stat-label">今日收入</span><span class="stat-dot" style="background:#00FF87;"></span></div>
          <div class="stat-value">RM ${d.income_today.toFixed(2)}</div>
          <div class="stat-foot">${d.date}</div>
        </div>
      </div>
      <div class="stat-card">
        <div class="stat-icon bg-blue">📊</div>
        <div class="stat-info">
          <div class="stat-label-row"><span class="stat-label">本月结余</span><span class="stat-dot" style="background:${monthNet >= 0 ? '#00FF87' : '#FF3366'};"></span></div>
          <div class="stat-value">RM ${monthNet.toFixed(2)}</div>
          <div class="stat-foot">收入 RM ${Number(d.month_income || 0).toFixed(0)} · 支出 RM ${Number(d.month_expense || 0).toFixed(0)}</div>
        </div>
      </div>
    </div>

    <div class="dash-row-2">
      <div class="card">
        <h3>💼 资产分布 <span class="card-period-badge">实时 ⌄</span></h3>
        ${buildAssetBarChart(d.bank_accounts || [])}
      </div>
      <div class="card">
        <h3>🥧 资产占比</h3>
        ${buildAssetDonutHtml(d.bank_accounts || [])}
      </div>
    </div>

    <div class="grid-3">
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
      <div class="card">
        <h3>🥧 EPF 户口占比 <span class="card-period-badge">Akaun 三户口</span></h3>
        ${buildEpfAccountDonutHtml(d.epf_cumulative)}
      </div>
    </div>

    <div class="dash-row-2">
      <div class="card">
        <h3>🛡️ SOCSO 累计供款</h3>
        <div class="stat-number">RM ${Number(d.socso_cumulative?.total || 0).toFixed(2)}</div>
        <div class="stat-sub">员工 + 雇主供款总计</div>
        <div style="margin-top:10px;font-size:13px;color:var(--text-body);">
          员工 RM ${Number(d.socso_cumulative?.employee || 0).toFixed(2)} ·
          雇主 RM ${Number(d.socso_cumulative?.employer || 0).toFixed(2)}
        </div>
      </div>
      <div class="card">
        <h3>🆘 EIS 累计供款</h3>
        <div class="stat-number">RM ${Number(d.eis_cumulative?.total || 0).toFixed(2)}</div>
        <div class="stat-sub">员工 + 雇主供款总计</div>
        <div style="margin-top:10px;font-size:13px;color:var(--text-body);">
          员工 RM ${Number(d.eis_cumulative?.employee || 0).toFixed(2)} ·
          雇主 RM ${Number(d.eis_cumulative?.employer || 0).toFixed(2)}
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
          <button class="quick-action-btn" onclick='openForm("tasks", null, {status:"todo"})'>
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
        <h3>✅ 待办任务 <button class="btn icon-only" onclick="toggleQuickAdd('task-add')">+</button></h3>
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
      <div class="card interactive" onclick="location.hash='#daily_metrics'" style="cursor:pointer;">
        <h3>❤️ 今日健康 <span class="card-period-badge">历史 ›</span></h3>
        ${d.metric_today
          ? `<p>体重 ${d.metric_today.weight_kg ?? '-'} kg · 睡眠 ${d.metric_today.sleep_hours ?? '-'} 小时 · 心情 ${d.metric_today.mood ?? '-'} /5 ${d.metric_today.steps ? '· 步数 ' + d.metric_today.steps : ''}</p>`
          : '<p class="empty">今天还没记录 (手机 App 会自动同步步数)</p>'}
      </div>
      <div class="card">
        <h3>📓 今日日记</h3>
        ${d.journal_today ? `<p>${escapeHtml((d.journal_today.content || '').slice(0, 80))}...</p>` : '<p class="empty">今天还没写</p>'}
      </div>
    </div>
  `;
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
  await api({ resource: 'tasks', action: 'create', data: { title, status: 'todo', priority: 'medium' } });
  input.value = '';
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

// ---------------- Filters (declarative, driven by config_resources.php 'filters') ----------------

const FILTER_STATE = {};

function initFilterState(resourceName, filters) {
  if (FILTER_STATE[resourceName]) return FILTER_STATE[resourceName];
  const state = {};
  for (const f of filters) {
    if (f.type === 'month') state[f.field] = { year: '', month: '' };
    else if (f.type === 'daterange') state[f.field] = { from: '', to: '' };
    else if (f.type === 'period') state[f.field] = resourceName === 'daily_metrics' ? 'week' : '';
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
    // 防御: filters 里若残留了一个已经不在 fields 里的字段 (例如 reminders 的 related_type 被
    // tag_id 取代后忘了同步删掉这条 filter)，下面读 fieldCfg.label/options 会抛 TypeError。
    // 这个函数在 try/catch 之外被呼叫，一抛错整个页面就会永远停在骨架屏，所以这里直接跳过坏掉的项。
    if (f.type === 'period') {
      const opts = [['week', '最近一周'], ['month', '本月'], ['', '全部']].map(([v, l]) =>
        `<option value="${v}" ${state[f.field] === v ? 'selected' : ''}>${l}</option>`).join('');
      return `<select data-filter="${f.field}" onchange="onFilterChange('${resourceName}')">${opts}</select>`;
    }
    if (!fieldCfg) return '';
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
      // fk_filter (比如标签要按 module 分类) 之前这里一直没套用，一直显示"这个 resource 的全部行"——
      // 联系人的标签筛选下拉会看到提醒模块的标签混进来，就是这里漏掉的。
      const filterKey = fieldCfg.fk_filter ? `${fieldCfg.fk_resource}::${JSON.stringify(fieldCfg.fk_filter)}` : null;
      const rows = (filterKey ? fkFilteredCache[filterKey] : fkCache[fieldCfg.fk_resource]) || [];
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
    if (f.type === 'period') {
      const range = periodRange(val);
      if (range) {
        payload.push({ field: 'metric_date', op: 'gte', value: range.from });
        payload.push({ field: 'metric_date', op: 'lte', value: range.to });
      }
    } else if (f.type === 'month') {
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
      if (state._period) continue;
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


function localYmd(d) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return y + '-' + m + '-' + day;
}
function periodRange(preset) {
  const now = new Date();
  now.setHours(0, 0, 0, 0);
  if (preset === 'week') {
    const from = new Date(now);
    from.setDate(from.getDate() - 6);
    return { from: localYmd(from), to: localYmd(now) };
  }
  if (preset === 'month') {
    const from = new Date(now.getFullYear(), now.getMonth(), 1);
    const to = new Date(now.getFullYear(), now.getMonth() + 1, 0);
    return { from: localYmd(from), to: localYmd(to) };
  }
  return null;
}
function fillStepDays(rows, from, to) {
  const byDate = {};
  for (const r of rows || []) {
    const k = String(r.metric_date || '').slice(0, 10);
    if (!k) continue;
    byDate[k] = Number(r.steps) || 0;
  }
  const out = [];
  const d = new Date(from + 'T00:00:00');
  const end = new Date(to + 'T00:00:00');
  if (isNaN(d) || isNaN(end) || d > end) return rows || [];
  while (d <= end) {
    const k = localYmd(d);
    out.push({ metric_date: k, steps: byDate[k] ?? 0 });
    d.setDate(d.getDate() + 1);
  }
  return out;
}

function renderStepsChart(data) {
  let rows = (data || []).slice().sort((a, b) => String(a.metric_date).localeCompare(String(b.metric_date)));
  const preset = (FILTER_STATE.daily_metrics && FILTER_STATE.daily_metrics._period) || '';
  const range = periodRange(preset);
  if (range) rows = fillStepDays(rows, range.from, range.to);
  if (!rows.length) return '';
  const max = Math.max(1, ...rows.map(r => Number(r.steps) || 0));
  const bars = rows.map(r => {
    const n = Number(r.steps) || 0;
    const h = Math.round(n / max * 100);
    const d = String(r.metric_date || '').slice(5);
    return `<div class="steps-bar" title="${escapeHtml(String(r.metric_date || ''))}: ${n}">
      <div class="steps-bar-col"><div class="steps-bar-fill" style="height:${Math.max(h, 2)}%"></div></div>
      <div class="steps-bar-val">${n}</div>
      <div class="steps-bar-label">${escapeHtml(d)}</div>
    </div>`;
  }).join('');
  return `<div class="card"><h3>🚶 步数走势</h3><div class="steps-chart">${bars}</div></div>`;
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

const CARD_GRID_RESOURCES = new Set(['subscriptions', 'bookmarks', 'contacts', 'fixed_deposits']);

function renderItemGrid(resourceName, data) {
  if (!data.length) return '<div class="card"><p class="empty">还没有数据</p></div>';

  if (resourceName === 'subscriptions') {
    const statusColor = { Active: '#00FF87', active: '#00FF87', Cancelled: '#9CA3AF', cancelled: '#9CA3AF', Paused: '#EA580C', paused: '#EA580C' };
    const cards = data.map(s => {
      const active = s.is_active == 1;
      const color = active ? '#00FF87' : '#9CA3AF';
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
            下次扣费：${s.next_billing_date || '-'}<br>
            扣款账户：${s.bank_account_id ? escapeHtml(fkLabel('bank_accounts', s.bank_account_id)) : '<span style="color:var(--danger);">未设置</span>'}
          </div>
          <div class="item-card-footer">
            <span class="badge" style="background:${color}22;color:${color};">${active ? '使用中' : '已停用'}</span>
            <span>
              <button class="btn small" onclick='markSubscriptionPaid("${s.id}")'>✅ 标记已扣费</button>
              <button class="btn small secondary" onclick='openForm("subscriptions", "${s.id}")'>编辑</button>
              <button class="btn small danger" onclick='deleteRow("subscriptions", "${s.id}")'>删除</button>
            </span>
          </div>
        </div>`;
    }).join('');
    return `<div class="item-grid">${cards}</div>`;
  }

  if (resourceName === 'fixed_deposits') {
    const statusColor = { active: '#00FF87', matured: '#7FDBFF', withdrawn: '#9CA3AF' };
    const statusLabel = { active: '存款中', matured: '已到期处理', withdrawn: '提前解约' };
    const cards = data.map(fd => {
      const rate = Number(fd.interest_rate);
      const months = Number(fd.tenure_months);
      const principal = Number(fd.principal);
      const interest = Math.round(principal * rate / 100 * months / 12 * 100) / 100;
      const maturityAmount = principal + interest;
      const color = statusColor[fd.status] || '#9CA3AF';
      const bankLabel = fd.bank_id ? fkLabel('banks', fd.bank_id) : '未指定银行';
      const actionLabel = fd.maturity_action === 'renew'
        ? '🔁 自动展期 (钱滚钱)'
        : `➡️ 转入 ${fd.destination_account_id ? escapeHtml(fkLabel('bank_accounts', fd.destination_account_id)) : '<span style="color:var(--danger);">未设置账户</span>'}`;
      return `
        <div class="item-card">
          <div class="item-card-header">
            <div class="item-card-icon" style="background:var(--icon-green-bg);color:var(--icon-green-fg);">🏦</div>
            <div>
              <div class="item-card-title">${escapeHtml(bankLabel)}</div>
              <div class="item-card-sub">年利率 ${rate}% · ${months} 个月</div>
            </div>
          </div>
          <div class="item-card-body">
            <strong style="font-size:16px;color:var(--navy);">RM ${principal.toFixed(2)}</strong> 本金<br>
            到期日：${fd.maturity_date || '-'}（预估到期 RM ${maturityAmount.toFixed(2)}，含利息 RM ${interest.toFixed(2)}）<br>
            到期处理：${actionLabel}
          </div>
          <div class="item-card-footer">
            <span class="badge" style="background:${color}22;color:${color};">${statusLabel[fd.status] || fd.status}</span>
            <span>
              <button class="btn small secondary" onclick='openForm("fixed_deposits", "${fd.id}")'>编辑</button>
              <button class="btn small danger" onclick='deleteRow("fixed_deposits", "${fd.id}")'>删除</button>
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
              <button class="btn small secondary" onclick='openForm("bookmarks", "${l.id}")'>编辑</button>
              <button class="btn small danger" onclick='deleteRow("bookmarks", "${l.id}")'>删除</button>
            </span>
          </div>
        </div>`;
    }).join('');
    return `<div class="item-grid">${cards}</div>`;
  }

  if (resourceName === 'contacts') {
    const cards = data.map(c => {
      const initial = (c.name || '?').trim().charAt(0).toUpperCase();
      const tags = parseTagsField(c.tags).join(', ');
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
              <button class="btn small secondary" onclick='openForm("contacts", "${c.id}")'>编辑</button>
              <button class="btn small danger" onclick='deleteRow("contacts", "${c.id}")'>删除</button>
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

  // preload fk lists referenced by this resource's fields (needed for both table display + fk_select filter options)——
  // 包一层 try/catch: 之前这几行万一有一个 promise 失败 (比如某个 fk_resource 查询出错)，
  // 整个 renderResourcePage 就会直接中断在这里，后面"填真正内容"那段永远不会跑到，
  // 页面就会卡在最上面设的骨架屏 (skeleton) 一直转，看起来像是"刷新不出来"。
  try {
    const fkFields = Object.entries(cfg.fields).filter(([, f]) => f.type === 'fk');
    await Promise.all(fkFields.map(([, f]) => loadFk(f.fk_resource)));
    await Promise.all(fkFields.filter(([, f]) => f.fk_filter).map(([, f]) => loadFkFiltered(f.fk_resource, f.fk_filter)));
  } catch (e) {
    console.error('preload fk lists failed for', resourceName, e);
  }

  let data;
  try {
    const filtersPayload = buildFiltersPayload(resourceName, cfg);
    ({ data } = await api({ resource: resourceName, action: 'list', filters: filtersPayload }));
    if (resourceName === 'daily_metrics' && Array.isArray(data)) {
      data.sort((a, b) => String(b.metric_date || '').localeCompare(String(a.metric_date || '')));
    }
  } catch (e) {
    console.error('load list failed for', resourceName, e);
    el.innerHTML = `
      <div class="toolbar">
        <div class="page-title" style="margin-bottom:0;">${cfg.icon} ${cfg.label}</div>
      </div>
      <div class="card"><p class="empty">加载失败：${escapeHtml(e.message || String(e))}</p></div>
    `;
    return;
  }
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
      else if (f.type === 'tags') { val = parseTagsField(val).join(', '); }
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
          <button class="btn small secondary" onclick='openForm("${resourceName}", "${row.id}")'>编辑</button>
          <button class="btn small danger" onclick='deleteRow("${resourceName}", "${row.id}")'>删除</button>
        </td>
      </tr>`;
  }).join('') || `<tr><td colspan="${columns.length + 1}" class="empty">还没有数据</td></tr>`;

  const filterBarHtml = buildFilterBarHtml(resourceName, cfg);
  const breakdownHtml = resourceName === 'transactions' ? renderCategoryBreakdown(data, cfg) : '';
  const stepsChartHtml = resourceName === 'daily_metrics' ? renderStepsChart(data) : '';
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
        ${cfg.allow_create === false ? '' : `<button class="btn" onclick='openForm("${resourceName}", null)'>+ 新增</button>`}
      </div>
    </div>
    ${cfg.note ? `<div class="resource-note">💡 ${escapeHtml(cfg.note)}</div>` : ''}
    ${filterBarHtml}
    ${stepsChartHtml}
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
  fixed_deposits: '如果这笔定存有设置"存入账户"，删除会连同新增时自动扣本金那笔交易一起消失。已经到期处理过 (转入账户/自动展期) 产生的交易/新定存记录不会被连带删除，那些是已经真实发生的事实。',
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

async function markSubscriptionPaid(id) {
  if (!confirm('确定要标记这笔订阅已扣费吗？\n\n会自动生成一笔支出记录，并把下次扣费日期推后一个周期。')) return;
  try {
    await api({ action: 'mark_subscription_paid', id });
  } catch (e) {
    alert(e.message);
    return;
  }
  renderResourcePage('subscriptions');
}

// ---------------- Generic add/edit form modal ----------------

async function openForm(resourceName, id, presetData) {
  const cfg = RESOURCES[resourceName];
  if (!id && cfg.allow_create === false) return;
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
          <button class="btn" onclick="submitForm('${resourceName}', ${id ? `'${id}'` : 'null'})" type="button">保存</button>
        </div>
      </div>
    </div>
  `;

  setupConditionalFields();
  if (resourceName === 'salary_payments') setupSalaryPaymentAutofill(id);
  if (resourceName === 'epf_contributions') setupEpfSplitAutofill(id);
}

// 填了员工/雇主/自愿供款金额 (或改了三个户口的 %) 之后，自动按比例算出 Akaun Persaraan/Sejahtera/
// Fleksibel 各自的金额——只在新增时自动算 (编辑已有记录不动，跟薪资那边同一个"历史记录不能被悄悄
// 重算"的原则一样，用户要改自己手动改金额栏位)。
function setupEpfSplitAutofill(existingId) {
  if (existingId) return;
  const form = document.getElementById('record-form');
  const empInput = form.querySelector('[data-field="employee_contribution"]');
  const emprInput = form.querySelector('[data-field="employer_contribution"]');
  const addInput = form.querySelector('[data-field="additional_contribution"]');
  const pPctInput = form.querySelector('[data-field="persaraan_percent"]');
  const sPctInput = form.querySelector('[data-field="sejahtera_percent"]');
  const fPctInput = form.querySelector('[data-field="fleksibel_percent"]');
  const pAmtInput = form.querySelector('[data-field="persaraan_amount"]');
  const sAmtInput = form.querySelector('[data-field="sejahtera_amount"]');
  const fAmtInput = form.querySelector('[data-field="fleksibel_amount"]');
  if (!pAmtInput || !sAmtInput || !fAmtInput) return;

  function recompute() {
    const total = (parseFloat(empInput?.value) || 0) + (parseFloat(emprInput?.value) || 0) + (parseFloat(addInput?.value) || 0);
    const pPct = parseFloat(pPctInput?.value) || 0;
    const sPct = parseFloat(sPctInput?.value) || 0;
    const fPct = parseFloat(fPctInput?.value) || 0;
    pAmtInput.value = (total * pPct / 100).toFixed(2);
    sAmtInput.value = (total * sPct / 100).toFixed(2);
    fAmtInput.value = (total * fPct / 100).toFixed(2);
  }
  [empInput, emprInput, addInput, pPctInput, sPctInput, fPctInput].filter(Boolean).forEach(el => el.addEventListener('input', recompute));
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
  const empSocsoPctInput = form.querySelector('[data-field="employee_socso_percent"]');
  const emprSocsoPctInput = form.querySelector('[data-field="employer_socso_percent"]');
  const empSocsoAmtInput = form.querySelector('[data-field="employee_socso_amount"]');
  const emprSocsoAmtInput = form.querySelector('[data-field="employer_socso_amount"]');
  const empEisPctInput = form.querySelector('[data-field="employee_eis_percent"]');
  const emprEisPctInput = form.querySelector('[data-field="employer_eis_percent"]');
  const empEisAmtInput = form.querySelector('[data-field="employee_eis_amount"]');
  const emprEisAmtInput = form.querySelector('[data-field="employer_eis_amount"]');
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
      const profile = (fkCache['salary_profiles'] || []).find(p => String(p.id) === profileSel?.value);
      // 按薪资档案设置的"用哪个月的天数当分母"来算 (有些公司算上个月的天数，不是这个月的)
      const useMonth = (profile?.prorate_basis === 'previous_month') ? startDate.getMonth() : (startDate.getMonth() + 1);
      const daysInMonth = new Date(startDate.getFullYear(), useMonth, 0).getDate();
      const fullBasic = profile ? Number(profile.basic_salary) : (parseFloat(basicInput?.value) || 0);
      const prorated = Math.round(fullBasic * daysWorked / daysInMonth * 100) / 100;
      if (basicInput) basicInput.value = prorated.toFixed(2);
      recompute();
      alert(`这期做了 ${daysWorked} 天，${profile?.prorate_basis === 'previous_month' ? '上个月' : '当月'}共 ${daysInMonth} 天\n基本薪资 RM ${fullBasic.toFixed(2)} × ${daysWorked}/${daysInMonth} = RM ${prorated.toFixed(2)}`);
    };
    anchor?.after(btn);
  }

  // 选薪资档案 -> 带出基本薪资/EPF 百分比/入账账户 (只在新增、还没手动改过的时候自动带，不覆盖编辑中的历史记录)
  function applyProfile() {
    const profile = (fkCache['salary_profiles'] || []).find(p => String(p.id) === profileSel.value);
    if (!profile) return;
    if (basicInput) basicInput.value = profile.basic_salary;
    if (empPctInput) empPctInput.value = profile.enable_epf === false ? 0 : profile.employee_epf_percent;
    if (emprPctInput) emprPctInput.value = profile.enable_epf === false ? 0 : profile.employer_epf_percent;
    if (empSocsoPctInput) empSocsoPctInput.value = profile.enable_socso === true ? profile.employee_socso_percent : 0;
    if (emprSocsoPctInput) emprSocsoPctInput.value = profile.enable_socso === true ? profile.employer_socso_percent : 0;
    if (empEisPctInput) empEisPctInput.value = profile.enable_eis === true ? profile.employee_eis_percent : 0;
    if (emprEisPctInput) emprEisPctInput.value = profile.enable_eis === true ? profile.employer_eis_percent : 0;
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
    const empSocsoPct = parseFloat(empSocsoPctInput?.value) || 0;
    const emprSocsoPct = parseFloat(emprSocsoPctInput?.value) || 0;
    const empEisPct = parseFloat(empEisPctInput?.value) || 0;
    const emprEisPct = parseFloat(emprEisPctInput?.value) || 0;
    const otherDeduct = parseFloat(otherDeductInput?.value) || 0;

    // EPF/SOCSO/EIS 一般算在基本薪资上 (不含津贴/花红/佣金)，这里只是给个建议值，金额栏位随时可以手动改
    const empAmt = Math.round(basic * empPct / 100 * 100) / 100;
    const emprAmt = Math.round(basic * emprPct / 100 * 100) / 100;
    const empSocsoAmt = Math.round(basic * empSocsoPct / 100 * 100) / 100;
    const emprSocsoAmt = Math.round(basic * emprSocsoPct / 100 * 100) / 100;
    const empEisAmt = Math.round(basic * empEisPct / 100 * 100) / 100;
    const emprEisAmt = Math.round(basic * emprEisPct / 100 * 100) / 100;
    if (empAmtInput) empAmtInput.value = empAmt.toFixed(2);
    if (emprAmtInput) emprAmtInput.value = emprAmt.toFixed(2);
    if (empSocsoAmtInput) empSocsoAmtInput.value = empSocsoAmt.toFixed(2);
    if (emprSocsoAmtInput) emprSocsoAmtInput.value = emprSocsoAmt.toFixed(2);
    if (empEisAmtInput) empEisAmtInput.value = empEisAmt.toFixed(2);
    if (emprEisAmtInput) emprEisAmtInput.value = emprEisAmt.toFixed(2);

    // SOCSO/EIS 员工那一份也是从实收里扣的，跟 EPF 员工那份一样会让到手的钱变少
    const gross = basic + allowance + bonus + commission + otherAdd;
    const net = gross - empAmt - empSocsoAmt - empEisAmt - otherDeduct;
    if (netInput) netInput.value = net.toFixed(2);
  }

  // 新增时才自动算 (编辑已有记录时，历史金额不应该被悄悄重新计算，用户要改自己手动改)
  if (!existingId) {
    [basicInput, allowanceInput, bonusInput, commissionInput, otherAddInput, empPctInput, emprPctInput, empSocsoPctInput, emprSocsoPctInput, empEisPctInput, emprEisPctInput, otherDeductInput]
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
    // checkbox (boolean 字段) 的 .value 永远是固定字串 "on"，跟有没有勾选完全无关——
    // 真正的勾选状态要看 .checked，这里特别处理，不然 show_when 接在 boolean 字段上永远不会生效。
    const update = () => {
      const currentValue = controller.type === 'checkbox' ? String(controller.checked) : controller.value;
      const show = notValue !== undefined ? (currentValue !== notValue) : (currentValue === requiredValue);
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
        <textarea data-field="${key}" ${ph} ${f.type === 'json' ? 'style="font-family:monospace;"' : ''}>${escapeHtml(f.type === 'json' && value && typeof value === 'object' ? JSON.stringify(value) : value)}</textarea></div>`;
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
      return `<div class="field">${label}<input type="number" ${ph} data-field="${key}" value="${escapeHtml(value)}" ${f.min !== undefined ? `min="${f.min}"` : ''} ${f.max !== undefined ? `max="${f.max}"` : ''} ${f.readonly ? 'disabled' : ''}></div>${f.readonly ? '<p class="empty" style="margin-top:-8px;">由 App 根据走路自动记录，不能手动改</p>' : ''}`;
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
      const display = parseTagsField(value).join(', ');
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
    if (cfg.fields[key].readonly) continue;
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

// ---------------- 登录 / 多用户 ----------------

function showLoginScreen() {
  document.getElementById('login-screen').style.display = 'flex';
  document.getElementById('app').style.display = 'none';
}
function hideLoginScreen() {
  document.getElementById('login-screen').style.display = 'none';
  document.getElementById('app').style.display = 'flex';
}

// 登录/登出/查状态这几个不走 api() (api() 遇到 401 会自己弹回登录页，这几个本身就是在处理登录页，
// 会绕圈)，直接用最原始的 fetch。
async function rawApi(payload) {
  return SupabaseBridge.rawCall(payload);
}

let LOGIN_MODE = 'login'; // 'login' | 'register' | 'forgot'
let LOGIN_STEP = 'form';   // 'form' | 'otp'
let PENDING_DISPLAY_NAME = '';
let PENDING_EMAIL = '';

const OTP_REQUIRED_HINT = '为确认邮箱真的存在，注册和重设密码都要输入邮箱收到的验证码。';

function setLoginMode(mode) {
  LOGIN_MODE = mode;
  LOGIN_STEP = 'form';
  PENDING_DISPLAY_NAME = '';
  PENDING_EMAIL = '';
  const isRegister = mode === 'register';
  const isForgot = mode === 'forgot';
  document.getElementById('login-step-form').style.display = 'block';
  document.getElementById('login-step-otp').style.display = 'none';
  document.getElementById('login-display-name-field').style.display = isRegister ? 'block' : 'none';
  document.getElementById('login-password-field').style.display = isForgot ? 'none' : 'block';
  document.getElementById('login-password-confirm-field').style.display = isRegister ? 'block' : 'none';
  document.getElementById('login-forgot-row').style.display = isForgot ? 'none' : 'block';
  document.getElementById('login-newpw-field').style.display = 'none';
  document.getElementById('login-newpw2-field').style.display = 'none';
  const nameInput = document.getElementById('login-display-name');
  if (nameInput) nameInput.required = isRegister;
  const pwInput = document.getElementById('login-password');
  if (pwInput) pwInput.required = !isForgot;
  document.getElementById('login-submit-btn').textContent = isRegister ? '注册' : (isForgot ? '寄送验证码' : '登录');
  document.getElementById('login-mode-toggle').textContent = isRegister ? '已经有账号？点这里登录' : '还没有账号？点这里注册';
  document.getElementById('login-forgot-row').style.display = isForgot ? 'none' : 'block';
  document.getElementById('login-sub').textContent = isRegister
    ? '填写名字、邮箱和密码，我们会寄一组验证码到你的邮箱'
    : (isForgot ? '输入你注册时用的邮箱，我们会寄一组验证码给你' : '用邮箱和密码登录');
  document.getElementById('login-error').textContent = '';
  const otpInput = document.getElementById('login-otp');
  if (otpInput) otpInput.value = '';
  if (pwInput) pwInput.setAttribute('autocomplete', isRegister ? 'new-password' : 'current-password');
}

// 注册流程的第二步：输入邮箱验证码。验证成功就等于完成登入。
async function submitSignupOtp(errEl) {
  const token = document.getElementById('login-otp').value.trim();
  if (!token) { errEl.textContent = '请填写验证码'; return; }
  const json = await rawApi({ action: 'verify_signup_otp', email: PENDING_EMAIL, token, display_name: PENDING_DISPLAY_NAME });
  if (!json.ok) { errEl.textContent = json.error || '验证失败'; return; }
  CURRENT_USER = json.user;
  hideLoginScreen();
  boot();
}

// 忘记密码第二步：验证码 + 新密码，使用者自己完成。
async function submitResetOtp(errEl) {
  const token = document.getElementById('login-otp').value.trim();
  const pw = document.getElementById('login-newpw').value;
  const pw2 = document.getElementById('login-newpw2').value;
  if (!token) { errEl.textContent = '请填写验证码'; return; }
  if (pw.length < 6) { errEl.textContent = '新密码至少要 6 位'; return; }
  if (pw !== pw2) { errEl.textContent = '两次输入的新密码不一样'; return; }
  const json = await rawApi({ action: 'reset_password_with_otp', email: PENDING_EMAIL, token, new_password: pw });
  if (!json.ok) { errEl.textContent = json.error || '重设失败'; return; }
  alert('密码已经改好，请用新密码登录。');
  setLoginMode('login');
  document.getElementById('login-email').value = PENDING_EMAIL;
  document.getElementById('login-error').textContent = '';
}

function setupLoginForm() {
  document.getElementById('login-mode-toggle').addEventListener('click', (e) => {
    e.preventDefault();
    setLoginMode(LOGIN_MODE === 'register' ? 'login' : 'register');
  });

  document.getElementById('login-forgot-link').addEventListener('click', (e) => {
    e.preventDefault();
    setLoginMode('forgot');
  });

  document.getElementById('login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const email = document.getElementById('login-email').value.trim();
    const password = document.getElementById('login-password').value;
    const errEl = document.getElementById('login-error');
    errEl.textContent = '';

    // 已经是第二步：走验证码
    if (LOGIN_STEP === 'otp') {
      if (LOGIN_MODE === 'register') await submitSignupOtp(errEl);
      else await submitResetOtp(errEl);
      return;
    }

    if (LOGIN_MODE === 'register') {
      const passwordConfirm = document.getElementById('login-password-confirm').value;
      const displayName = document.getElementById('login-display-name').value.trim();
      if (!displayName) { errEl.textContent = '请填写名字'; return; }
      if (!email) { errEl.textContent = '请填写邮箱'; return; }
      if (password !== passwordConfirm) { errEl.textContent = '两次输入的密码不一样'; return; }
      const json = await rawApi({ action: 'register', email, password, display_name: displayName });
      if (!json.ok) { errEl.textContent = json.error || '注册失败'; return; }
      if (json.user) { CURRENT_USER = json.user; hideLoginScreen(); boot(); return; }
      PENDING_EMAIL = json.email || email;
      PENDING_DISPLAY_NAME = displayName;
      LOGIN_STEP = 'otp';
      document.getElementById('login-step-form').style.display = 'none';
      document.getElementById('login-step-otp').style.display = 'block';
      document.getElementById('login-otp-hint').textContent = json.message || ('验证码已经寄到 ' + PENDING_EMAIL);
      document.getElementById('login-submit-btn').textContent = '验证并开始使用';
      document.getElementById('login-mode-toggle').textContent = '收不到？点这里回到上一步';
      return;
    }

    if (LOGIN_MODE === 'forgot') {
      if (!email) { errEl.textContent = '请填写邮箱'; return; }
      const json = await rawApi({ action: 'request_password_reset', email });
      if (!json.ok) { errEl.textContent = json.error || '寄送失败'; return; }
      PENDING_EMAIL = email;
      LOGIN_STEP = 'otp';
      document.getElementById('login-step-form').style.display = 'none';
      document.getElementById('login-step-otp').style.display = 'block';
      document.getElementById('login-newpw-field').style.display = 'block';
      document.getElementById('login-newpw2-field').style.display = 'block';
      document.getElementById('login-otp-hint').textContent = json.message || ('如果这个邮箱注册过，验证码已经寄到 ' + PENDING_EMAIL);
      document.getElementById('login-submit-btn').textContent = '验证并重设密码';
      document.getElementById('login-mode-toggle').textContent = '收不到？点这里回到上一步';
      return;
    }

    const json = await rawApi({ action: 'login', email, password });
    if (!json.ok) { errEl.textContent = json.error || '登录失败'; return; }
    CURRENT_USER = json.user;
    document.getElementById('login-password').value = '';
    hideLoginScreen();
    boot();
  });
}

async function logout() {
  if (!confirm('确定要退出登录吗？')) return;
  await rawApi({ action: 'logout' });
  CURRENT_USER = null;
  RESOURCES = {};
  // 清掉缓存: 下一个登入的可能是别人，不能让上一个用户的下拉选项/资料残留在内存里
  Object.keys(fkCache).forEach(k => delete fkCache[k]);
  Object.keys(fkFilteredCache).forEach(k => delete fkFilteredCache[k]);
  showLoginScreen();
}

function openChangePasswordModal() {
  const modalRoot = document.getElementById('modal-root');
  modalRoot.innerHTML = `
    <div class="modal-backdrop" onclick="if(event.target===this) closeForm()">
      <div class="modal">
        <h3>🔑 修改密码</h3>
        <div class="field"><label>原密码</label><input type="password" id="pw-old"></div>
        <div class="field"><label>新密码（至少 6 位）</label><input type="password" id="pw-new"></div>
        <div class="field"><label>再输入一次新密码</label><input type="password" id="pw-new2"></div>
        <div class="modal-actions">
          <button class="btn secondary" onclick="closeForm()" type="button">取消</button>
          <button class="btn" onclick="submitChangePassword()" type="button">保存</button>
        </div>
      </div>
    </div>
  `;
}

async function submitChangePassword() {
  const oldPw = document.getElementById('pw-old').value;
  const newPw = document.getElementById('pw-new').value;
  const newPw2 = document.getElementById('pw-new2').value;
  if (!oldPw || !newPw) { alert('请填写原密码和新密码'); return; }
  if (newPw !== newPw2) { alert('两次输入的新密码不一样'); return; }
  try {
    await api({ action: 'change_password', old_password: oldPw, new_password: newPw });
    closeForm();
    alert('密码改好了，下次登录用新密码');
  } catch (e) {
    alert('修改失败：' + e.message);
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

async function checkAuthAndStart() {
  setupLoginForm();
  const json = await rawApi({ action: 'me' });
  if (json.user) {
    CURRENT_USER = json.user;
    hideLoginScreen();
    boot();
  } else {
    showLoginScreen();
  }
}

checkAuthAndStart();
