<?php
// 统一 API 入口: 网站前端 + Flutter App 都用 POST 打这一个文件。
// 之后换 Supabase 时，只需要把 get_db()/SQL 部分换成呼叫 Supabase REST API，
// meta/dashboard 的 JSON 形状可以保持不变，前端(网站+App)不用大改。

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    exit;
}

require_once __DIR__ . '/db.php';
$config = require __DIR__ . '/config_resources.php';

$raw = file_get_contents('php://input');
$body = json_decode($raw, true);
if (!is_array($body)) $body = [];

$resource = $body['resource'] ?? null;
$action   = $body['action'] ?? 'list';

function normalize_value(array $meta, $value) {
    if ($value === null || $value === '') {
        return ($meta['type'] === 'boolean') ? 0 : null;
    }
    switch ($meta['type']) {
        case 'boolean':
            return ($value === true || $value === 1 || $value === '1' || $value === 'true') ? 1 : 0;
        case 'tags':
            $trimmed = trim((string)$value);
            if ($trimmed === '') return json_encode([]);
            if ($trimmed[0] === '[') {
                json_decode($trimmed);
                if (json_last_error() === JSON_ERROR_NONE) return $trimmed;
            }
            $parts = array_filter(array_map('trim', explode(',', $trimmed)), fn($p) => $p !== '');
            return json_encode(array_values($parts));
        case 'json':
            json_decode($value);
            return (json_last_error() === JSON_ERROR_NONE) ? $value : false;
        case 'url':
            $v = trim((string)$value);
            if (!preg_match('~^https?://~i', $v)) $v = 'https://' . $v;
            return filter_var($v, FILTER_VALIDATE_URL) ? $v : false;
        default:
            return $value;
    }
}

function get_salary_category_id(mysqli $db): ?int {
    $stmt = $db->prepare("SELECT id FROM categories WHERE type='income' AND name='薪水' LIMIT 1");
    $stmt->execute();
    $row = $stmt->get_result()->fetch_assoc();
    return $row ? (int)$row['id'] : null;
}

// 发薪记录是"模板之外的历史事实"：存了之后要自动在 transactions 里生出对应的一笔收入
// (不然财务记账那边看不到这笔钱)，以及在 epf_contributions 里记一笔供款 (如果这笔有算 EPF 的话)。
// 编辑/删除发薪记录时，这两处关联数据要跟着同步，不然会留下对不上账的孤儿记录。
// status != 'paid' (草稿/待发放/已取消) 的记录不应该计入实际余额 —— 撤掉已生成的交易/EPF记录，
// 等状态改回"已发放"时再重新生成，避免"还没到手的钱"被算成已经到手。
function sync_salary_payment(mysqli $db, int $paymentId): void {
    $stmt = $db->prepare("SELECT * FROM salary_payments WHERE id = ?");
    $stmt->bind_param('i', $paymentId);
    $stmt->execute();
    $sp = $stmt->get_result()->fetch_assoc();
    if (!$sp) return;

    if (($sp['status'] ?? 'paid') !== 'paid') {
        if (!empty($sp['transaction_id'])) {
            $delTxn = $db->prepare("DELETE FROM transactions WHERE id = ?");
            $delTxn->bind_param('i', $sp['transaction_id']);
            $delTxn->execute();
            $clear = $db->prepare("UPDATE salary_payments SET transaction_id = NULL WHERE id = ?");
            $clear->bind_param('i', $paymentId);
            $clear->execute();
        }
        $delEpf = $db->prepare("DELETE FROM epf_contributions WHERE salary_payment_id = ?");
        $delEpf->bind_param('i', $paymentId);
        $delEpf->execute();
        return;
    }

    $description = $sp['period_label'] . ' 薪资';
    $categoryId = get_salary_category_id($db);

    if (!empty($sp['transaction_id'])) {
        $upd = $db->prepare("UPDATE transactions SET category_id=?, bank_account_id=?, amount=?, transaction_date=?, description=? WHERE id=?");
        $upd->bind_param('iidssi', $categoryId, $sp['bank_account_id'], $sp['net_salary'], $sp['payment_date'], $description, $sp['transaction_id']);
        $upd->execute();
    } else {
        $ins = $db->prepare("INSERT INTO transactions (category_id, bank_account_id, type, amount, currency, description, transaction_date) VALUES (?, ?, 'income', ?, 'MYR', ?, ?)");
        $ins->bind_param('iidss', $categoryId, $sp['bank_account_id'], $sp['net_salary'], $description, $sp['payment_date']);
        $ins->execute();
        $txnId = $ins->insert_id;
        $link = $db->prepare("UPDATE salary_payments SET transaction_id=? WHERE id=?");
        $link->bind_param('ii', $txnId, $paymentId);
        $link->execute();
    }

    $totalEpf = (float)$sp['employee_epf_amount'] + (float)$sp['employer_epf_amount'];
    $existing = $db->prepare("SELECT id FROM epf_contributions WHERE salary_payment_id = ?");
    $existing->bind_param('i', $paymentId);
    $existing->execute();
    $existingRow = $existing->get_result()->fetch_assoc();

    if ($totalEpf > 0) {
        if ($existingRow) {
            $u = $db->prepare("UPDATE epf_contributions SET contribution_date=?, employee_contribution=?, employer_contribution=? WHERE id=?");
            $u->bind_param('sddi', $sp['payment_date'], $sp['employee_epf_amount'], $sp['employer_epf_amount'], $existingRow['id']);
            $u->execute();
        } else {
            $i = $db->prepare("INSERT INTO epf_contributions (salary_payment_id, contribution_date, employee_contribution, employer_contribution) VALUES (?, ?, ?, ?)");
            $i->bind_param('isdd', $paymentId, $sp['payment_date'], $sp['employee_epf_amount'], $sp['employer_epf_amount']);
            $i->execute();
        }
    } elseif ($existingRow) {
        $d = $db->prepare("DELETE FROM epf_contributions WHERE id = ?");
        $d->bind_param('i', $existingRow['id']);
        $d->execute();
    }
}

// 用户的心智模型很简单: "薪资档案填好 (公司/EPF%/月薪/发薪日) 之后，到了发薪日应该就自动记一笔"，
// 不应该每个月都要手动开一个十几个字段的表单重填一次。这个函数在每次看仪表盘/发薪记录列表时跑一次，
// 帮所有"在职中 + 每月固定 + 已经设了发薪日"的档案，把"这个月该发的那笔"自动生出来 (如果发薪日已经到了、
// 而且这个月还没生成过的话) —— 幂等: 用 salary_profile_id + period_label 当天然的"这个月生成过没有"判断，
// 不会重复生成；只处理"发薪日已经到了或是今天"的当月，不会提前生出还没到的月份。
function auto_generate_due_salary_payments(mysqli $db): array {
    $generated = [];
    $today = date('Y-m-d');
    $monthStart = date('Y-m-01');
    $daysInMonth = (int)date('t');
    $periodLabel = date('Y-m');

    $profiles = $db->query(
        "SELECT * FROM salary_profiles WHERE status = 'active' AND salary_frequency = 'monthly' AND salary_payment_day IS NOT NULL"
    )->fetch_all(MYSQLI_ASSOC);

    foreach ($profiles as $p) {
        if (empty($p['bank_account_id'])) continue; // 没设入账账户没法自动生成 (required 字段)，跳过让用户自己手动处理

        $paymentDay = min((int)$p['salary_payment_day'], $daysInMonth);
        $paymentDate = date('Y-m-') . str_pad((string)$paymentDay, 2, '0', STR_PAD_LEFT);
        if ($paymentDate > $today) continue; // 这个月的发薪日还没到

        if (!empty($p['end_date']) && $p['end_date'] < $monthStart) continue; // 已经离职/停用，早于这个月
        if (!empty($p['start_date']) && $p['start_date'] > $paymentDate) continue; // 这个月发薪日之前都还没入职

        // 幂等检查: 这个档案这个月已经有一笔了 (不管是自动生成的还是用户手动记的)，就不重复生成。
        // 这里还要多挡一种情况: 如果用户删掉了旧档案再重新建一个新档案 (比如只是想改发薪日，没有直接编辑)，
        // 旧档案已经自动生成的那笔发薪记录会因为外键 ON DELETE SET NULL 变成 salary_profile_id=NULL 的"孤儿记录"
        // (故意不跟着删掉，历史发薪记录不能因为档案被删就消失)，但那笔钱其实已经真实发生过 —— 如果只按新档案的
        // id 去查，会查不到，导致同一个月被重复生成一次。所以同一个账户 + 同一个月 + 是系统自动生成的孤儿记录，
        // 也要算作"这个月已经有了"，不能再生一笔。
        $check = $db->prepare(
            "SELECT id FROM salary_payments
             WHERE period_label = ?
               AND (salary_profile_id = ?
                    OR (salary_profile_id IS NULL AND bank_account_id = ? AND notes LIKE '系统根据薪资档案自动生成%'))"
        );
        $check->bind_param('sii', $periodLabel, $p['id'], $p['bank_account_id']);
        $check->execute();
        if ($check->get_result()->fetch_assoc()) continue;

        // 按比例算基本薪资时，"这个月做到哪一天"不能想当然用月底 —— 入职当月不足整月的话，
        // 实际做到的是"发薪日"那天 (跟手动那个"⚖️ 按天数比例"按钮的算法一致，也是这样验证过的)，
        // 除非这个月本来就要离职 (设了 end_date 且落在这个月内)，那才是用 end_date 当结束日。
        // 只要入职日不晚于这个月 1 号、也没有这个月内离职，就是整月在职，直接发全额月薪，不用按比例。
        $monthEnd = date('Y-m-t');
        $hasPartialStart = !empty($p['start_date']) && $p['start_date'] > $monthStart;
        $hasPartialEnd = !empty($p['end_date']) && $p['end_date'] < $monthEnd;
        $isFullMonth = !$hasPartialStart && !$hasPartialEnd;

        $periodStart = $hasPartialStart ? $p['start_date'] : $monthStart;
        $periodEnd = $hasPartialEnd ? $p['end_date'] : $paymentDate;

        $basicSalary = (float)$p['basic_salary'];
        if (!$isFullMonth) {
            $daysWorked = (strtotime($periodEnd) - strtotime($periodStart)) / 86400 + 1;
            $basicSalary = round($basicSalary * $daysWorked / $daysInMonth, 2);
        }
        $empPct = (float)$p['employee_epf_percent'];
        $emprPct = (float)$p['employer_epf_percent'];
        $empAmt = round($basicSalary * $empPct / 100, 2);
        $emprAmt = round($basicSalary * $emprPct / 100, 2);
        $netSalary = round($basicSalary - $empAmt, 2);
        $notes = '系统根据薪资档案自动生成 (' . date('Y-m-d H:i') . ')。如这个月有花红/津贴等额外收入，可以编辑这笔补上。';

        $periodStartVal = $isFullMonth ? null : $periodStart;
        $periodEndVal = $isFullMonth ? null : $periodEnd;
        $ins = $db->prepare(
            "INSERT INTO salary_payments
                (salary_profile_id, payment_date, period_label, period_start, period_end,
                 basic_salary, employee_epf_percent, employee_epf_amount, employer_epf_percent, employer_epf_amount,
                 net_salary, bank_account_id, status, notes)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'paid', ?)"
        );
        $ins->bind_param(
            'issssddddddis',
            $p['id'], $paymentDate, $periodLabel, $periodStartVal, $periodEndVal,
            $basicSalary, $empPct, $empAmt, $emprPct, $emprAmt,
            $netSalary, $p['bank_account_id'], $notes
        );
        $ins->execute();
        $newId = $ins->insert_id;
        sync_salary_payment($db, $newId);

        $generated[] = [
            'salary_payment_id' => $newId,
            'company_name' => $p['company_name'],
            'period_label' => $periodLabel,
            'net_salary' => $netSalary,
        ];
    }

    return $generated;
}

// 通用提醒的"重复"功能: 算出下一次提醒时间应该是什么时候。
function next_reminder_time(string $fromDateTime, string $rule, ?int $interval, ?string $unit): string {
    $dt = new DateTime($fromDateTime);
    switch ($rule) {
        case 'daily':    $dt->modify('+1 day'); break;
        case 'weekly':   $dt->modify('+1 week'); break;
        case 'biweekly': $dt->modify('+2 weeks'); break;
        case 'monthly':  $dt->modify('+1 month'); break;
        case 'yearly':   $dt->modify('+1 year'); break;
        case 'custom':
            $n = max(1, (int)($interval ?? 1));
            $map = ['day' => 'day', 'week' => 'week', 'month' => 'month', 'year' => 'year'];
            $u = $map[$unit ?? 'day'] ?? 'day';
            $dt->modify("+{$n} {$u}");
            break;
        default: break; // 'none' 不该走到这里 (调用方已经挡过)
    }
    return $dt->format('Y-m-d H:i:s');
}

// 提醒被标记"已发送"(用户勾了 is_sent，或者是从下面 advance_due_reminders 判断时间已经过了) 时，
// 如果这条设了"重复"，不应该就这样结束 —— 自动把 remind_at 推到下一次、is_sent 重新变回未发送，
// 这样用户不用每次都手动重新建一条一样的提醒。
function maybe_advance_recurring_reminder(mysqli $db, int $id): void {
    $stmt = $db->prepare("SELECT * FROM reminders WHERE id = ?");
    $stmt->bind_param('i', $id);
    $stmt->execute();
    $r = $stmt->get_result()->fetch_assoc();
    if (!$r) return;
    if (!$r['is_sent']) return;
    if (empty($r['repeat_rule']) || $r['repeat_rule'] === 'none') return;

    $next = next_reminder_time($r['remind_at'], $r['repeat_rule'], $r['repeat_interval'] ?? null, $r['repeat_unit'] ?? null);
    $upd = $db->prepare("UPDATE reminders SET remind_at = ?, is_sent = 0 WHERE id = ?");
    $upd->bind_param('si', $next, $id);
    $upd->execute();
}

// 网站本身没有会一直跑的后台服务去"到点提醒"，所以每次打开"通用提醒"列表页时顺便检查一次:
// 有重复设置、但提醒时间已经过去却还没处理 (is_sent 还是 0) 的，直接自动往后排到下一个未来的时间点
// (可能要连续推好几次 —— 比如每天提醒的东西一个星期没打开网站，得从过去一路推到今天/明天，而不是只推一天)。
function advance_due_reminders(mysqli $db): void {
    $now = date('Y-m-d H:i:s');
    $stmt = $db->prepare(
        "SELECT * FROM reminders WHERE repeat_rule IS NOT NULL AND repeat_rule != 'none' AND is_sent = 0 AND remind_at <= ?"
    );
    $stmt->bind_param('s', $now);
    $stmt->execute();
    $rows = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);

    foreach ($rows as $r) {
        $next = $r['remind_at'];
        $guard = 0;
        while ($next <= $now && $guard < 1000) {
            $next = next_reminder_time($next, $r['repeat_rule'], $r['repeat_interval'] ?? null, $r['repeat_unit'] ?? null);
            $guard++;
        }
        if ($next !== $r['remind_at']) {
            $upd = $db->prepare("UPDATE reminders SET remind_at = ? WHERE id = ?");
            $upd->bind_param('si', $next, $r['id']);
            $upd->execute();
        }
    }
}

function compute_bank_balances(mysqli $db): array {
    $accounts = $db->query("SELECT * FROM bank_accounts WHERE is_active = 1 ORDER BY id")->fetch_all(MYSQLI_ASSOC);
    foreach ($accounts as &$a) {
        $id = (int)$a['id'];
        $stmt = $db->prepare(
            "SELECT
                COALESCE(SUM(CASE WHEN type = 'income' AND bank_account_id = ? THEN amount ELSE 0 END), 0) AS income,
                COALESCE(SUM(CASE WHEN type = 'expense' AND bank_account_id = ? THEN amount ELSE 0 END), 0) AS expense,
                COALESCE(SUM(CASE WHEN type = 'transfer' AND bank_account_id = ? THEN amount ELSE 0 END), 0) AS transfer_out,
                COALESCE(SUM(CASE WHEN type = 'transfer' AND transfer_to_account_id = ? THEN amount ELSE 0 END), 0) AS transfer_in
             FROM transactions"
        );
        $stmt->bind_param('iiii', $id, $id, $id, $id);
        $stmt->execute();
        $row = $stmt->get_result()->fetch_assoc();
        $a['current_balance'] = round(
            (float)$a['opening_balance'] + (float)$row['income'] - (float)$row['expense']
            - (float)$row['transfer_out'] + (float)$row['transfer_in'],
            2
        );
        // 界面只显示末 4 位账号，不暴露完整账号
        if (!empty($a['account_number'])) {
            $a['account_number_masked'] = '**** ' . substr($a['account_number'], -4);
        } else {
            $a['account_number_masked'] = null;
        }
    }
    unset($a);
    return $accounts;
}

function build_dashboard(mysqli $db): array {
    $today = date('Y-m-d');
    $out = ['ok' => true, 'date' => $today];

    // 到发薪日就自动帮活跃的月薪档案生一笔发薪记录 (见函数注释) —— 每次看仪表盘都顺手检查一次
    $out['auto_generated_salary'] = auto_generate_due_salary_payments($db);

    $stmt = $db->prepare("SELECT * FROM tasks WHERE status = 'today' OR due_date = ? ORDER BY priority DESC, id DESC");
    $stmt->bind_param('s', $today);
    $stmt->execute();
    $out['tasks_today'] = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);

    $habits = $db->query("SELECT * FROM habits WHERE is_active = 1 ORDER BY id")->fetch_all(MYSQLI_ASSOC);
    $stmt = $db->prepare("SELECT habit_id, completed FROM habit_logs WHERE log_date = ?");
    $stmt->bind_param('s', $today);
    $stmt->execute();
    $logMap = [];
    foreach ($stmt->get_result()->fetch_all(MYSQLI_ASSOC) as $l) {
        $logMap[$l['habit_id']] = (bool)$l['completed'];
    }
    foreach ($habits as &$h) {
        $h['checked_today'] = $logMap[$h['id']] ?? false;
    }
    unset($h);
    $out['habits'] = $habits;

    $stmt = $db->prepare("SELECT * FROM journal_entries WHERE entry_date = ?");
    $stmt->bind_param('s', $today);
    $stmt->execute();
    $out['journal_today'] = $stmt->get_result()->fetch_assoc();

    $stmt = $db->prepare("SELECT * FROM transactions WHERE transaction_date = ? ORDER BY id DESC");
    $stmt->bind_param('s', $today);
    $stmt->execute();
    $rows = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);
    $out['transactions_today'] = $rows;
    $income = 0.0;
    $expense = 0.0;
    foreach ($rows as $r) {
        // 转账不计入收支 (只是钱从自己的一个账户挪到另一个账户)
        if ($r['type'] === 'income') $income += (float)$r['amount'];
        elseif ($r['type'] === 'expense') $expense += (float)$r['amount'];
    }
    $out['income_today'] = $income;
    $out['expense_today'] = $expense;

    $bankAccounts = compute_bank_balances($db);
    $out['bank_accounts'] = $bankAccounts;
    $out['total_balance'] = array_sum(array_column($bankAccounts, 'current_balance'));

    // 本月收支 (给仪表盘的统计卡 + 支出分类圆环图用)
    $monthStart = date('Y-m-01');
    $monthEnd = date('Y-m-t');
    $stmt = $db->prepare("SELECT * FROM transactions WHERE transaction_date BETWEEN ? AND ?");
    $stmt->bind_param('ss', $monthStart, $monthEnd);
    $stmt->execute();
    $monthRows = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);
    $monthIncome = 0.0;
    $monthExpense = 0.0;
    $categoryTotals = []; // category_id => sum
    foreach ($monthRows as $r) {
        if ($r['type'] === 'income') $monthIncome += (float)$r['amount'];
        elseif ($r['type'] === 'expense') {
            $monthExpense += (float)$r['amount'];
            $cid = $r['category_id'] ?? 'none';
            $categoryTotals[$cid] = ($categoryTotals[$cid] ?? 0) + (float)$r['amount'];
        }
    }
    $out['month_income'] = $monthIncome;
    $out['month_expense'] = $monthExpense;

    $categories = $db->query("SELECT * FROM categories")->fetch_all(MYSQLI_ASSOC);
    $categoryById = [];
    foreach ($categories as $c) $categoryById[$c['id']] = $c;
    $breakdown = [];
    foreach ($categoryTotals as $cid => $amount) {
        $cat = $categoryById[$cid] ?? null;
        $breakdown[] = [
            'label' => $cat['name'] ?? '未分类',
            'color' => $cat['color'] ?? '#9CA3AF',
            'amount' => round($amount, 2),
        ];
    }
    usort($breakdown, fn($a, $b) => $b['amount'] <=> $a['amount']);
    $out['category_breakdown'] = $breakdown;

    // 最近几笔交易 (不分日期，仪表盘"Recent Transactions"用)
    $recentRows = $db->query("SELECT * FROM transactions ORDER BY transaction_date DESC, id DESC LIMIT 5")->fetch_all(MYSQLI_ASSOC);
    foreach ($recentRows as &$r) {
        $cat = $categoryById[$r['category_id']] ?? null;
        $r['category_label'] = $cat['name'] ?? '未分类';
        $r['category_icon'] = $cat['icon'] ?? '💳';
    }
    unset($r);
    $out['recent_transactions'] = $recentRows;

    // 薪资: 预期 (在职的月薪档案) vs 实际 (这个月真的记录了的发薪) —— 绝对不能把预期当成已经到手的钱
    $activeProfiles = $db->query(
        "SELECT * FROM salary_profiles WHERE status = 'active' AND salary_frequency = 'monthly'"
    )->fetch_all(MYSQLI_ASSOC);
    $out['expected_monthly_salary'] = array_sum(array_column($activeProfiles, 'basic_salary'));

    $stmt = $db->prepare("SELECT COALESCE(SUM(net_salary), 0) AS total FROM salary_payments WHERE status = 'paid' AND payment_date BETWEEN ? AND ?");
    $stmt->bind_param('ss', $monthStart, $monthEnd);
    $stmt->execute();
    $out['actual_monthly_salary'] = (float)$stmt->get_result()->fetch_assoc()['total'];

    // EPF 累计供款 (全部历史)
    $epfRow = $db->query(
        "SELECT COALESCE(SUM(employee_contribution),0) AS emp, COALESCE(SUM(employer_contribution),0) AS empr, COALESCE(SUM(additional_contribution),0) AS add_ FROM epf_contributions"
    )->fetch_assoc();
    $out['epf_cumulative'] = [
        'employee' => (float)$epfRow['emp'],
        'employer' => (float)$epfRow['empr'],
        'additional' => (float)$epfRow['add_'],
        'total' => (float)$epfRow['emp'] + (float)$epfRow['empr'] + (float)$epfRow['add_'],
    ];

    $stmt = $db->prepare("SELECT * FROM daily_metrics WHERE metric_date = ?");
    $stmt->bind_param('s', $today);
    $stmt->execute();
    $out['metric_today'] = $stmt->get_result()->fetch_assoc();

    $out['inbox_unprocessed'] = $db->query(
        "SELECT * FROM inbox_items WHERE is_processed = 0 ORDER BY id DESC LIMIT 10"
    )->fetch_all(MYSQLI_ASSOC);

    // 即将到来的提醒: 订阅续费 (在各自的 remind_days_before 窗口内) + 生日 (未来 14 天内, 不看年份)
    $todayDate = new DateTime($today);

    $subs = $db->query(
        "SELECT * FROM subscriptions WHERE is_active = 1 AND next_billing_date IS NOT NULL"
    )->fetch_all(MYSQLI_ASSOC);
    $upcomingSubs = [];
    foreach ($subs as $s) {
        $due = new DateTime($s['next_billing_date']);
        $daysUntil = (int)$todayDate->diff($due)->format('%r%a');
        if ($daysUntil >= 0 && $daysUntil <= (int)$s['remind_days_before']) {
            $s['days_until'] = $daysUntil;
            $upcomingSubs[] = $s;
        }
    }
    usort($upcomingSubs, fn($a, $b) => $a['days_until'] <=> $b['days_until']);
    $out['upcoming_subscriptions'] = $upcomingSubs;

    $contacts = $db->query(
        "SELECT * FROM contacts WHERE birthday IS NOT NULL"
    )->fetch_all(MYSQLI_ASSOC);
    $upcomingBirthdays = [];
    foreach ($contacts as $c) {
        $bday = new DateTime($c['birthday']);
        $next = new DateTime($todayDate->format('Y') . '-' . $bday->format('m-d'));
        if ($next < $todayDate) {
            $next->modify('+1 year');
        }
        $daysUntil = (int)$todayDate->diff($next)->format('%r%a');
        if ($daysUntil >= 0 && $daysUntil <= (int)$c['remind_days_before']) {
            $c['days_until'] = $daysUntil;
            $upcomingBirthdays[] = $c;
        }
    }
    usort($upcomingBirthdays, fn($a, $b) => $a['days_until'] <=> $b['days_until']);
    $out['upcoming_birthdays'] = $upcomingBirthdays;

    return $out;
}

if ($action === 'meta') {
    echo json_encode(['ok' => true, 'resources' => $config], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'dashboard') {
    echo json_encode(build_dashboard(get_db()), JSON_UNESCAPED_UNICODE);
    exit;
}

// 全局搜索: 只覆盖真正常用来"翻旧账"的几个模块，按各自最有意义的文本字段做 LIKE 匹配。不依赖 $resource。
if ($action === 'search') {
    $q = trim((string)($body['q'] ?? ''));
    if ($q === '' || mb_strlen($q) < 1) {
        echo json_encode(['ok' => true, 'results' => []], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $db = get_db();
    $like = '%' . $q . '%';

    // resource => [拿来匹配的字段, 结果标题, 结果附带说明]
    $targets = [
        'transactions'     => ['cols' => ['description'], 'title' => fn($r) => $r['description'] ?: '（无说明）', 'sub' => fn($r) => 'RM ' . number_format((float)$r['amount'], 2) . ' · ' . $r['transaction_date']],
        'salary_payments'  => ['cols' => ['period_label', 'notes'], 'title' => fn($r) => $r['period_label'], 'sub' => fn($r) => 'RM ' . number_format((float)$r['net_salary'], 2) . ' · ' . $r['payment_date']],
        'tasks'            => ['cols' => ['title', 'description'], 'title' => fn($r) => $r['title'], 'sub' => fn($r) => $r['status'] ?? ''],
        'projects'         => ['cols' => ['name', 'description'], 'title' => fn($r) => $r['name'], 'sub' => fn($r) => $r['status'] ?? ''],
        'contacts'         => ['cols' => ['name', 'notes'], 'title' => fn($r) => $r['name'], 'sub' => fn($r) => $r['phone'] ?? ''],
        'bookmarks'        => ['cols' => ['title', 'url'], 'title' => fn($r) => $r['title'] ?: $r['url'], 'sub' => fn($r) => $r['url']],
        'journal_entries'  => ['cols' => ['content'], 'title' => fn($r) => $r['entry_date'], 'sub' => fn($r) => mb_substr((string)$r['content'], 0, 40)],
        'subscriptions'    => ['cols' => ['name', 'notes'], 'title' => fn($r) => $r['name'], 'sub' => fn($r) => 'RM ' . number_format((float)$r['cost'], 2)],
        'reminders'        => ['cols' => ['message'], 'title' => fn($r) => $r['message'], 'sub' => fn($r) => $r['remind_at'] ?? ''],
    ];

    $results = [];
    foreach ($targets as $tbl => $spec) {
        $where = implode(' OR ', array_map(fn($c) => "`$c` LIKE ?", $spec['cols']));
        $stmt = $db->prepare("SELECT * FROM `$tbl` WHERE $where ORDER BY id DESC LIMIT 8");
        $types = str_repeat('s', count($spec['cols']));
        $params = array_fill(0, count($spec['cols']), $like);
        $stmt->bind_param($types, ...$params);
        $stmt->execute();
        foreach ($stmt->get_result()->fetch_all(MYSQLI_ASSOC) as $row) {
            $results[] = [
                'resource' => $tbl,
                'resource_label' => $config[$tbl]['label'] ?? $tbl,
                'icon' => $config[$tbl]['icon'] ?? '📄',
                'id' => (int)$row['id'],
                'title' => (string)$spec['title']($row),
                'sub' => (string)$spec['sub']($row),
            ];
        }
    }
    echo json_encode(['ok' => true, 'results' => $results], JSON_UNESCAPED_UNICODE);
    exit;
}

// 完整数据库 SQL 备份: 纯 PHP 拼 SQL (不依赖 mysqldump 可执行文件的路径)，
// 结构 (SHOW CREATE TABLE) + 数据 (INSERT) 都要，方便真出问题时能整个还原。不依赖 $resource。
if ($action === 'export_sql') {
    $db = get_db();
    $tables = [];
    $res = $db->query('SHOW TABLES');
    while ($row = $res->fetch_row()) $tables[] = $row[0];

    $sql = "-- personal_os 完整备份 (" . date('Y-m-d H:i:s') . ")\nSET FOREIGN_KEY_CHECKS=0;\n\n";
    foreach ($tables as $tbl) {
        $create = $db->query("SHOW CREATE TABLE `$tbl`")->fetch_assoc();
        $sql .= "DROP TABLE IF EXISTS `$tbl`;\n" . $create['Create Table'] . ";\n\n";

        $rows = $db->query("SELECT * FROM `$tbl`")->fetch_all(MYSQLI_ASSOC);
        foreach ($rows as $row) {
            $cols = implode(',', array_map(fn($c) => "`$c`", array_keys($row)));
            $vals = implode(',', array_map(function ($v) use ($db) {
                return $v === null ? 'NULL' : "'" . $db->real_escape_string((string)$v) . "'";
            }, array_values($row)));
            $sql .= "INSERT INTO `$tbl` ($cols) VALUES ($vals);\n";
        }
        $sql .= "\n";
    }
    $sql .= "SET FOREIGN_KEY_CHECKS=1;\n";

    echo json_encode(['ok' => true, 'sql' => $sql, 'filename' => 'personal_os_backup_' . date('Ymd_His') . '.sql'], JSON_UNESCAPED_UNICODE);
    exit;
}

if (!$resource || !isset($config[$resource])) {
    http_response_code(400);
    echo json_encode(['ok' => false, 'error' => 'Unknown resource']);
    exit;
}

$table = $resource;
$fields = $config[$resource]['fields'];
$db = get_db();

switch ($action) {

    case 'list': {
        // 打开"发薪记录"列表页时也顺手检查一次有没有到发薪日该自动生成的 (不用非得从仪表盘才会触发)
        if ($resource === 'salary_payments') auto_generate_due_salary_payments($db);
        // 打开"通用提醒"列表页时顺手把过期未处理的重复提醒往后推 (见函数注释)
        if ($resource === 'reminders') advance_due_reminders($db);

        $rawFilters = is_array($body['filters'] ?? null) ? $body['filters'] : [];
        // 两种格式都支持:
        //  旧格式 {field: value} 精确匹配, 或 {field: {op, value}}
        //  新格式 [{field, op, value}, ...] 允许同一字段多个条件(比如日期区间 gte+lte)
        $conditions = [];
        if (array_is_list($rawFilters)) {
            foreach ($rawFilters as $cond) {
                if (isset($cond['field'])) $conditions[] = $cond;
            }
        } else {
            foreach ($rawFilters as $field => $val) {
                if (is_array($val) && isset($val['op'])) {
                    $conditions[] = ['field' => $field, 'op' => $val['op'], 'value' => $val['value']];
                } else {
                    $conditions[] = ['field' => $field, 'op' => 'eq', 'value' => $val];
                }
            }
        }

        $where = [];
        $params = [];
        $types = '';
        foreach ($conditions as $cond) {
            $col = $cond['field'];
            if (!isset($fields[$col]) && $col !== 'id') continue;
            $v = $cond['value'] ?? null;
            if ($v === null || $v === '') continue;
            $op = $cond['op'] ?? 'eq';
            if ($op === 'eq') { $where[] = "`$col` = ?"; $params[] = $v; $types .= 's'; }
            elseif ($op === 'gte') { $where[] = "`$col` >= ?"; $params[] = $v; $types .= 's'; }
            elseif ($op === 'lte') { $where[] = "`$col` <= ?"; $params[] = $v; $types .= 's'; }
            elseif ($op === 'like') { $where[] = "`$col` LIKE ?"; $params[] = '%' . $v . '%'; $types .= 's'; }
        }
        $sql = "SELECT * FROM `$table`";
        if ($where) $sql .= ' WHERE ' . implode(' AND ', $where);
        $sql .= ' ORDER BY id DESC LIMIT 500';
        $stmt = $db->prepare($sql);
        if ($params) $stmt->bind_param($types, ...$params);
        $stmt->execute();
        $rows = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);

        // 银行账户列表额外算出当前余额 + 打码账号，不用另开一个 endpoint
        if ($resource === 'bank_accounts') {
            $balances = compute_bank_balances($db);
            $byId = [];
            foreach ($balances as $b) $byId[$b['id']] = $b;
            foreach ($rows as &$r) {
                if (isset($byId[$r['id']])) {
                    $r['current_balance'] = $byId[$r['id']]['current_balance'];
                    $r['account_number_masked'] = $byId[$r['id']]['account_number_masked'];
                }
            }
            unset($r);
        }

        echo json_encode(['ok' => true, 'data' => $rows], JSON_UNESCAPED_UNICODE);
        break;
    }

    case 'get': {
        $id = (int)($body['id'] ?? 0);
        $stmt = $db->prepare("SELECT * FROM `$table` WHERE id = ?");
        $stmt->bind_param('i', $id);
        $stmt->execute();
        echo json_encode(['ok' => true, 'data' => $stmt->get_result()->fetch_assoc()], JSON_UNESCAPED_UNICODE);
        break;
    }

    case 'create':
    case 'update': {
        $data = is_array($body['data'] ?? null) ? $body['data'] : [];

        // 必填字段校验 (网站/Flutter 前端已经挡过一次，这里再挡一次防止绕过)。
        // 只校验 $data 里确实带了这个 key 但填空的情况 —— 像 NotificationService 只传
        // {is_sent:true} 这种"只改一个字段"的局部更新，不应该被其他必填字段挡下来。
        foreach ($fields as $col => $meta) {
            if (empty($meta['required']) || $meta['type'] === 'boolean') continue;
            if (!array_key_exists($col, $data)) continue;
            if ($data[$col] === null || $data[$col] === '') {
                http_response_code(400);
                echo json_encode(['ok' => false, 'error' => "字段 {$meta['label']} 是必填的"]);
                exit;
            }
        }

        // transactions 特殊规则: 转入账户只在类型=转账时才有意义，且转账账户/金额要经得起检查
        if ($resource === 'transactions' && array_key_exists('type', $data)) {
            if ($data['type'] === 'transfer') {
                if (empty($data['transfer_to_account_id'])) {
                    http_response_code(400);
                    echo json_encode(['ok' => false, 'error' => '转账必须选择转入账户']);
                    exit;
                }
                $fromId = $data['bank_account_id'] ?? null;
                $toId = $data['transfer_to_account_id'] ?? null;
                if ($fromId !== null && $toId !== null && (string)$fromId === (string)$toId) {
                    http_response_code(400);
                    echo json_encode(['ok' => false, 'error' => '转出账户和转入账户不能是同一个']);
                    exit;
                }
                if (isset($data['amount']) && (float)$data['amount'] <= 0) {
                    http_response_code(400);
                    echo json_encode(['ok' => false, 'error' => '转账金额必须大于 0']);
                    exit;
                }
            } elseif (array_key_exists('transfer_to_account_id', $data)) {
                $data['transfer_to_account_id'] = null; // 不是转账就不该留着这个值，避免脏数据
            }
        }

        // reminders 特殊规则: 表单只填"几点" (HH:MM)，日期在这里自动算好拼回完整的 remind_at。
        // 新增: 这个点今天还没过就用今天，过了就用明天。编辑: 保留原本这条记录的日期，只换时间 ——
        // 不然每次打开编辑随便存一下，都会被"现在"的日期覆盖，把已经按重复规则往后推的排程打乱。
        if ($resource === 'reminders' && array_key_exists('remind_at', $data) && preg_match('/^\d{2}:\d{2}$/', (string)$data['remind_at'])) {
            $time = $data['remind_at'];
            if ($action === 'update') {
                $existingId = (int)($body['id'] ?? 0);
                $exStmt = $db->prepare("SELECT remind_at FROM reminders WHERE id = ?");
                $exStmt->bind_param('i', $existingId);
                $exStmt->execute();
                $exRow = $exStmt->get_result()->fetch_assoc();
                $datePart = $exRow ? substr($exRow['remind_at'], 0, 10) : date('Y-m-d');
            } else {
                $datePart = date('Y-m-d');
                if ("$datePart $time:00" <= date('Y-m-d H:i:s')) {
                    $datePart = date('Y-m-d', strtotime('+1 day'));
                }
            }
            $data['remind_at'] = "$datePart $time:00";
        }

        $cols = [];
        $vals = [];
        $types = '';
        foreach ($fields as $col => $meta) {
            if (!array_key_exists($col, $data)) continue;
            $v = normalize_value($meta, $data[$col]);
            if ($v === false && in_array($meta['type'], ['json', 'url'], true)) {
                $label = $meta['type'] === 'url' ? '不是合法的链接' : '不是合法 JSON';
                http_response_code(400);
                echo json_encode(['ok' => false, 'error' => "字段 $col $label"]);
                exit;
            }
            $cols[] = $col;
            $vals[] = $v;
            $types .= 's';
        }
        if (!$cols) {
            http_response_code(400);
            echo json_encode(['ok' => false, 'error' => 'No data']);
            exit;
        }
        if ($action === 'create') {
            $colList = implode(',', array_map(fn($c) => "`$c`", $cols));
            $placeholders = implode(',', array_fill(0, count($cols), '?'));
            $updateList = implode(',', array_map(fn($c) => "`$c` = VALUES(`$c`)", $cols));
            $sql = "INSERT INTO `$table` ($colList) VALUES ($placeholders) ON DUPLICATE KEY UPDATE $updateList";
            $stmt = $db->prepare($sql);
            $stmt->bind_param($types, ...$vals);
            $stmt->execute();
            $newId = $stmt->insert_id;
            if ($resource === 'salary_payments') sync_salary_payment($db, $newId);
            if ($resource === 'reminders') maybe_advance_recurring_reminder($db, $newId);
            echo json_encode(['ok' => true, 'id' => $newId], JSON_UNESCAPED_UNICODE);
        } else {
            $id = (int)($body['id'] ?? 0);
            $setList = implode(',', array_map(fn($c) => "`$c` = ?", $cols));
            $sql = "UPDATE `$table` SET $setList WHERE id = ?";
            $types .= 'i';
            $vals[] = $id;
            $stmt = $db->prepare($sql);
            $stmt->bind_param($types, ...$vals);
            $stmt->execute();
            if ($resource === 'salary_payments') sync_salary_payment($db, $id);
            if ($resource === 'reminders') maybe_advance_recurring_reminder($db, $id);
            echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
        }
        break;
    }

    case 'delete': {
        $id = (int)($body['id'] ?? 0);

        // 防止误删已经被引用的标签/银行账户，先检查有没有记录在用
        $usageChecks = [
            'tags'          => ['transactions' => 'tag_id', 'tasks' => 'tag_id', 'bookmarks' => 'tag_id'],
            'bank_accounts' => ['transactions' => 'bank_account_id'],
            'banks'         => ['bank_accounts' => 'bank_id'],
        ];
        if (isset($usageChecks[$resource])) {
            foreach ($usageChecks[$resource] as $refTable => $refCol) {
                $stmt = $db->prepare("SELECT COUNT(*) AS c FROM `$refTable` WHERE `$refCol` = ?");
                $stmt->bind_param('i', $id);
                $stmt->execute();
                $count = (int)$stmt->get_result()->fetch_assoc()['c'];
                if ($count > 0) {
                    http_response_code(400);
                    echo json_encode(['ok' => false, 'error' => "还有 $count 条记录在用这个，请先改掉那些记录再删除"]);
                    exit;
                }
            }
        }

        // 发薪记录删除时，自动生成的那笔交易也一起清掉 (epf_contributions 靠外键 CASCADE 自动跟着删)
        if ($resource === 'salary_payments') {
            $stmt = $db->prepare("SELECT transaction_id FROM salary_payments WHERE id = ?");
            $stmt->bind_param('i', $id);
            $stmt->execute();
            $row = $stmt->get_result()->fetch_assoc();
            if ($row && $row['transaction_id']) {
                $delTxn = $db->prepare("DELETE FROM transactions WHERE id = ?");
                $delTxn->bind_param('i', $row['transaction_id']);
                $delTxn->execute();
            }
        }

        $stmt = $db->prepare("DELETE FROM `$table` WHERE id = ?");
        $stmt->bind_param('i', $id);
        $stmt->execute();
        echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
        break;
    }

    case 'export_csv': {
        // 返回 CSV 文本内容 (JSON 包一层)，前端自己拼成 Blob 触发下载，不用改这个文件全局的 Content-Type。
        $rawFilters = is_array($body['filters'] ?? null) ? $body['filters'] : [];
        $conditions = [];
        if (array_is_list($rawFilters)) {
            foreach ($rawFilters as $cond) if (isset($cond['field'])) $conditions[] = $cond;
        } else {
            foreach ($rawFilters as $field => $val) $conditions[] = ['field' => $field, 'op' => 'eq', 'value' => $val];
        }
        $where = []; $params = []; $types = '';
        foreach ($conditions as $cond) {
            $col = $cond['field'];
            if (!isset($fields[$col]) && $col !== 'id') continue;
            $v = $cond['value'] ?? null;
            if ($v === null || $v === '') continue;
            $op = $cond['op'] ?? 'eq';
            if ($op === 'eq') { $where[] = "`$col` = ?"; $params[] = $v; $types .= 's'; }
            elseif ($op === 'gte') { $where[] = "`$col` >= ?"; $params[] = $v; $types .= 's'; }
            elseif ($op === 'lte') { $where[] = "`$col` <= ?"; $params[] = $v; $types .= 's'; }
        }
        $sql = "SELECT * FROM `$table`";
        if ($where) $sql .= ' WHERE ' . implode(' AND ', $where);
        $sql .= ' ORDER BY id DESC LIMIT 5000';
        $stmt = $db->prepare($sql);
        if ($params) $stmt->bind_param($types, ...$params);
        $stmt->execute();
        $rows = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);

        // fk 字段导出成可读名称，不是裸 id
        $fkMaps = [];
        foreach ($fields as $col => $meta) {
            if ($meta['type'] !== 'fk') continue;
            $fkTable = $meta['fk_resource'];
            $fkDisplay = $config[$fkTable]['display_field'] ?? 'id';
            $map = [];
            $res = $db->query("SELECT id, `$fkDisplay` AS label FROM `$fkTable`");
            while ($r = $res->fetch_assoc()) $map[$r['id']] = $r['label'];
            $fkMaps[$col] = $map;
        }

        $columns = array_keys($fields);
        $lines = [implode(',', array_map(fn($c) => $fields[$c]['label'], $columns))];
        foreach ($rows as $row) {
            $cells = array_map(function ($c) use ($row, $fkMaps) {
                $v = $row[$c] ?? '';
                if (isset($fkMaps[$c]) && $v !== '' && $v !== null) {
                    $v = $fkMaps[$c][$v] ?? $v;
                }
                $v = str_replace('"', '""', (string)$v);
                return '"' . $v . '"';
            }, $columns);
            $lines[] = implode(',', $cells);
        }
        echo json_encode(['ok' => true, 'csv' => implode("\n", $lines), 'filename' => $resource . '_' . date('Ymd') . '.csv'], JSON_UNESCAPED_UNICODE);
        break;
    }

    default:
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => 'Unknown action']);
}
