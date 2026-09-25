<?php
// 统一 API 入口: 网站前端 + Flutter App 都用 POST 打这一个文件。
// 之后换 Supabase 时，只需要把 get_db()/SQL 部分换成呼叫 Supabase REST API，
// meta/dashboard 的 JSON 形状可以保持不变，前端(网站+App)不用大改。

session_start(); // 多用户登录状态靠 PHP session，必须在任何输出之前先开

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

// ---------------- 登录 / 多用户 ----------------
// 这几个 action 本身就是"登录相关"，不需要 (也不可能) 先登录才能用。
if ($action === 'login') {
    $username = trim((string)($body['username'] ?? ''));
    $password = (string)($body['password'] ?? '');
    $db = get_db();
    $stmt = $db->prepare("SELECT * FROM users WHERE username = ?");
    $stmt->bind_param('s', $username);
    $stmt->execute();
    $user = $stmt->get_result()->fetch_assoc();
    if (!$user || !password_verify($password, $user['password_hash'])) {
        http_response_code(401);
        echo json_encode(['ok' => false, 'error' => '用户名或密码不对'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    session_regenerate_id(true); // 防止 session fixation
    $_SESSION['user_id'] = (int)$user['id'];
    $_SESSION['username'] = $user['username'];
    echo json_encode(['ok' => true, 'user' => ['id' => (int)$user['id'], 'username' => $user['username'], 'display_name' => $user['display_name'], 'role' => $user['role']]], JSON_UNESCAPED_UNICODE);
    exit;
}
if ($action === 'register') {
    // 自助注册: 新账号一开始就是完全空白的一份 (跟其他所有账号一样，靠 user_scoped 的通用隔离机制，
    // 不需要额外写任何"新用户初始化"的逻辑) —— 注册成功直接当场登入，不用再手动登一次。
    $username = trim((string)($body['username'] ?? ''));
    $password = (string)($body['password'] ?? '');
    $displayName = trim((string)($body['display_name'] ?? '')) ?: $username;

    if (mb_strlen($username) < 2) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '用户名至少要 2 个字符'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    if (mb_strlen($password) < 6) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '密码至少要 6 位'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $db = get_db();
    $check = $db->prepare("SELECT id FROM users WHERE username = ?");
    $check->bind_param('s', $username);
    $check->execute();
    if ($check->get_result()->fetch_assoc()) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '这个用户名已经有人用了，换一个'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // role 故意不给客户端传值的空间 —— 自助注册的账号永远只能是 'user' (DB 默认值)，
    // 想要 admin 权限只能由现有 admin 在"用户管理"里手动升级，不能自己注册就拿到。
    $hash = password_hash($password, PASSWORD_DEFAULT);
    $ins = $db->prepare("INSERT INTO users (username, password_hash, display_name) VALUES (?, ?, ?)");
    $ins->bind_param('sss', $username, $hash, $displayName);
    $ins->execute();
    $newUserId = (int)$ins->insert_id;

    session_regenerate_id(true);
    $_SESSION['user_id'] = $newUserId;
    $_SESSION['username'] = $username;
    echo json_encode(['ok' => true, 'user' => ['id' => $newUserId, 'username' => $username, 'display_name' => $displayName, 'role' => 'user']], JSON_UNESCAPED_UNICODE);
    exit;
}
if ($action === 'logout') {
    $_SESSION = [];
    session_destroy();
    echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
    exit;
}
if ($action === 'me') {
    if (empty($_SESSION['user_id'])) {
        echo json_encode(['ok' => true, 'user' => null], JSON_UNESCAPED_UNICODE);
        exit;
    }
    // 跟下面通用鉴权一样，role 现查现算，不信任 session 缓存 (见下面那段注释)
    $db = get_db();
    $stmt = $db->prepare("SELECT id, username, display_name, role FROM users WHERE id = ?");
    $stmt->bind_param('i', $_SESSION['user_id']);
    $stmt->execute();
    $row = $stmt->get_result()->fetch_assoc();
    if (!$row) {
        // 账号被删了 (比如 admin 刚删掉这个人)，session 还留着但人已经不存在了 —— 当作没登入
        $_SESSION = [];
        session_destroy();
        echo json_encode(['ok' => true, 'user' => null], JSON_UNESCAPED_UNICODE);
        exit;
    }
    echo json_encode(['ok' => true, 'user' => ['id' => (int)$row['id'], 'username' => $row['username'], 'display_name' => $row['display_name'], 'role' => $row['role']]], JSON_UNESCAPED_UNICODE);
    exit;
}
if ($action === 'change_password') {
    if (empty($_SESSION['user_id'])) {
        http_response_code(401);
        echo json_encode(['ok' => false, 'error' => '请先登录'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $db = get_db();
    $old = (string)($body['old_password'] ?? '');
    $new = (string)($body['new_password'] ?? '');
    if (mb_strlen($new) < 4) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '新密码至少要 4 位'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $stmt = $db->prepare("SELECT password_hash FROM users WHERE id = ?");
    $stmt->bind_param('i', $_SESSION['user_id']);
    $stmt->execute();
    $row = $stmt->get_result()->fetch_assoc();
    if (!$row || !password_verify($old, $row['password_hash'])) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '原密码不对'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $newHash = password_hash($new, PASSWORD_DEFAULT);
    $upd = $db->prepare("UPDATE users SET password_hash = ? WHERE id = ?");
    $upd->bind_param('si', $newHash, $_SESSION['user_id']);
    $upd->execute();
    echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
    exit;
}

// 其他所有 action 都要先登录 —— 这个系统现在是多人共用的，任何数据操作都要知道"是谁在操作"
// 才能正确做隔离 (下面 list/get/create/update/delete 都靠 $currentUserId 过滤)。
if (empty($_SESSION['user_id'])) {
    http_response_code(401);
    echo json_encode(['ok' => false, 'error' => '请先登录', 'code' => 'AUTH_REQUIRED'], JSON_UNESCAPED_UNICODE);
    exit;
}
$currentUserId = (int)$_SESSION['user_id'];
// 权限每次都直接查表现算，不信任 session 里缓存的 role —— 万一 admin 刚把某人的权限
// 降级/升级，对方不需要重新登入就能立刻反映最新权限，不会有"改了权限但还没生效"的空窗期。
$currentUserRoleStmt = get_db()->prepare("SELECT role FROM users WHERE id = ?");
$currentUserRoleStmt->bind_param('i', $currentUserId);
$currentUserRoleStmt->execute();
$currentUserRoleRow = $currentUserRoleStmt->get_result()->fetch_assoc();
$currentUserRole = $currentUserRoleRow['role'] ?? 'user';
$isAdmin = $currentUserRole === 'admin';

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

function get_salary_category_id(mysqli $db, int $userId): ?int {
    $stmt = $db->prepare("SELECT id FROM categories WHERE type='income' AND name='薪水' AND user_id = ? LIMIT 1");
    $stmt->bind_param('i', $userId);
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
    $spUserId = (int)$sp['user_id'];
    $categoryId = get_salary_category_id($db, $spUserId);

    if (!empty($sp['transaction_id'])) {
        $upd = $db->prepare("UPDATE transactions SET category_id=?, bank_account_id=?, amount=?, transaction_date=?, description=? WHERE id=?");
        $upd->bind_param('iidssi', $categoryId, $sp['bank_account_id'], $sp['net_salary'], $sp['payment_date'], $description, $sp['transaction_id']);
        $upd->execute();
    } else {
        $ins = $db->prepare("INSERT INTO transactions (user_id, category_id, bank_account_id, type, amount, currency, description, transaction_date) VALUES (?, ?, ?, 'income', ?, 'MYR', ?, ?)");
        $ins->bind_param('iiidss', $spUserId, $categoryId, $sp['bank_account_id'], $sp['net_salary'], $description, $sp['payment_date']);
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
        // 2024 新制度: Akaun Persaraan/Sejahtera/Fleksibel 三个户口按比例分——这里是自动生成的路径
        // (没有用户在场填表)，只能先套默认比例 75/15/10 (跟 config_resources.php 的默认值一致)，
        // 用户自己在 EPF 供款记录页面手动改这笔的比例/金额都可以，不会被下次同步覆盖掉
        // (下面 UPDATE 分支只在没有既有比例被改过的情况下才重算，见下面判断)。
        $defaultPersaraanPct = 75.0;
        $defaultSejahteraPct = 15.0;
        $defaultFleksibelPct = 10.0;
        $persaraanAmt = round($totalEpf * $defaultPersaraanPct / 100, 2);
        $sejahteraAmt = round($totalEpf * $defaultSejahteraPct / 100, 2);
        $fleksibelAmt = round($totalEpf * $defaultFleksibelPct / 100, 2);

        if ($existingRow) {
            $u = $db->prepare(
                "UPDATE epf_contributions
                 SET contribution_date=?, employee_contribution=?, employer_contribution=?,
                     persaraan_amount=?, sejahtera_amount=?, fleksibel_amount=?
                 WHERE id=?"
            );
            $u->bind_param('sdddddi', $sp['payment_date'], $sp['employee_epf_amount'], $sp['employer_epf_amount'],
                $persaraanAmt, $sejahteraAmt, $fleksibelAmt, $existingRow['id']);
            $u->execute();
        } else {
            $i = $db->prepare(
                "INSERT INTO epf_contributions
                    (user_id, salary_payment_id, contribution_date, employee_contribution, employer_contribution,
                     persaraan_percent, sejahtera_percent, fleksibel_percent, persaraan_amount, sejahtera_amount, fleksibel_amount)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            );
            $i->bind_param('iisdddddddd', $spUserId, $paymentId, $sp['payment_date'], $sp['employee_epf_amount'], $sp['employer_epf_amount'],
                $defaultPersaraanPct, $defaultSejahteraPct, $defaultFleksibelPct, $persaraanAmt, $sejahteraAmt, $fleksibelAmt);
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
function auto_generate_due_salary_payments(mysqli $db, int $userId): array {
    $generated = [];
    $skipped = []; // 发薪日已经到了、但缺东西没法自动生成的档案 —— 之前是完全静默跳过，用户完全不知道
                    // 为什么"到了发薪日却没有记录"，这次改成收集起来，让前端可以提示用户去补
    $today = date('Y-m-d');
    $monthStart = date('Y-m-01');
    $daysInMonth = (int)date('t');
    $periodLabel = date('Y-m');

    $profStmt = $db->prepare(
        "SELECT * FROM salary_profiles WHERE user_id = ? AND status = 'active' AND salary_frequency = 'monthly' AND salary_payment_day IS NOT NULL"
    );
    $profStmt->bind_param('i', $userId);
    $profStmt->execute();
    $profiles = $profStmt->get_result()->fetch_all(MYSQLI_ASSOC);

    foreach ($profiles as $p) {
        $paymentDay = min((int)$p['salary_payment_day'], $daysInMonth);
        $paymentDate = date('Y-m-') . str_pad((string)$paymentDay, 2, '0', STR_PAD_LEFT);
        if ($paymentDate > $today) continue; // 这个月的发薪日还没到，不用管

        if (empty($p['bank_account_id'])) {
            // 没设入账账户没法自动生成 (salary_payments.bank_account_id 是 required 字段) ——
            // 发薪日已经过了却生不出记录，这个必须让用户知道，不能就这样悄悄跳过
            $skipped[] = ['company_name' => $p['company_name'], 'reason' => '没有设置"入账账户"'];
            continue;
        }

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
             WHERE user_id = ? AND period_label = ?
               AND (salary_profile_id = ?
                    OR (salary_profile_id IS NULL AND bank_account_id = ? AND notes LIKE '系统根据薪资档案自动生成%'))"
        );
        $check->bind_param('isii', $userId, $periodLabel, $p['id'], $p['bank_account_id']);
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
                (user_id, salary_profile_id, payment_date, period_label, period_start, period_end,
                 basic_salary, employee_epf_percent, employee_epf_amount, employer_epf_percent, employer_epf_amount,
                 net_salary, bank_account_id, status, notes)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'paid', ?)"
        );
        $ins->bind_param(
            'iissssddddddis',
            $userId, $p['id'], $paymentDate, $periodLabel, $periodStartVal, $periodEndVal,
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

    return ['generated' => $generated, 'skipped' => $skipped];
}

// 用户的心智模型: "填好购买日期/费用/自动扣款账户之后，从那天起每期(月/年)应该自动生成一笔支出记录"，
// 不需要每期手动点"标记已扣费"。这个函数在每次看仪表盘/订阅列表时跑一次: 对每个"使用中"的订阅，
// 只要它的"下次扣费日"(没有就用"购买/开始日期")已经到了或过了，就生成对应的支出记录并把这个日期
// 往后推一期 —— 循环推进 (跟 advance_due_reminders() 同样的做法)，这样好几期没打开网站也能一次性补齐，
// 不用连续开好几次网站才能一期一期追上。幂等靠 next_billing_date 本身: 生成完就立刻往后推，下次
// 再跑这个函数时同一期不会重复触发。
function auto_generate_due_subscriptions(mysqli $db, int $userId): array {
    $generated = [];
    $skipped = []; // 已经到期但缺"自动扣款账户"没法生成的订阅 —— 收集起来让前端提示用户去补，不能悄悄跳过
    $today = date('Y-m-d');

    $stmt = $db->prepare("SELECT * FROM subscriptions WHERE user_id = ? AND is_active = 1");
    $stmt->bind_param('i', $userId);
    $stmt->execute();
    $subs = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);

    foreach ($subs as $s) {
        $due = $s['next_billing_date'] ?: $s['start_date'];
        if (empty($due)) continue; // 两个日期都没填 (旧数据/表单被绕过)，没办法算，安静跳过

        if (empty($s['bank_account_id'])) {
            if ($due <= $today) {
                $skipped[] = ['name' => $s['name'], 'reason' => '没有设置"自动扣款账户"'];
            }
            continue;
        }

        $originalDue = $due;
        $guard = 0;
        while ($due <= $today && $guard < 120) { // 120 期上限 (月费的话等于 10 年份) 防止异常数据一次生成太多笔
            $desc = '订阅扣费: ' . $s['name'];
            $ins = $db->prepare(
                "INSERT INTO transactions (user_id, type, amount, transaction_date, bank_account_id, description, currency)
                 VALUES (?, 'expense', ?, ?, ?, ?, 'MYR')"
            );
            $ins->bind_param('idsis', $userId, $s['cost'], $due, $s['bank_account_id'], $desc);
            $ins->execute();

            $generated[] = ['subscription_id' => (int)$s['id'], 'name' => $s['name'], 'amount' => (float)$s['cost'], 'date' => $due];

            $interval = $s['billing_cycle'] === 'yearly' ? '+1 year' : '+1 month';
            $due = date('Y-m-d', strtotime($interval, strtotime($due)));
            $guard++;
        }

        if ($due !== $originalDue) {
            $upd = $db->prepare("UPDATE subscriptions SET next_billing_date = ? WHERE id = ?");
            $upd->bind_param('si', $due, $s['id']);
            $upd->execute();
        }
    }

    return ['generated' => $generated, 'skipped' => $skipped];
}

// 新增定存时，如果填了"存入账户"，自动记一笔支出把本金从那个账户挪出去 (定存本金不算"可花的钱"，
// 不这样做的话资产分布/总余额会一直把这笔钱算成活期存款里，跟现实脱节)。只在 create 时呼叫一次，
// 不会在编辑既有记录时重复扣。
function sync_fixed_deposit_open(mysqli $db, int $fdId): void {
    $stmt = $db->prepare("SELECT * FROM fixed_deposits WHERE id = ?");
    $stmt->bind_param('i', $fdId);
    $stmt->execute();
    $fd = $stmt->get_result()->fetch_assoc();
    if (!$fd || empty($fd['source_account_id'])) return;

    $desc = '定存: 存入 (' . number_format((float)$fd['tenure_months'], 0) . '个月, 到期 ' . $fd['maturity_date'] . ')';
    $ins = $db->prepare(
        "INSERT INTO transactions (user_id, type, amount, transaction_date, bank_account_id, description, currency)
         VALUES (?, 'expense', ?, ?, ?, ?, 'MYR')"
    );
    $ins->bind_param('idsis', $fd['user_id'], $fd['principal'], $fd['start_date'], $fd['source_account_id'], $desc);
    $ins->execute();
    $txnId = $ins->insert_id;

    $upd = $db->prepare("UPDATE fixed_deposits SET opening_transaction_id = ? WHERE id = ?");
    $upd->bind_param('ii', $txnId, $fdId);
    $upd->execute();
}

// 用户的心智模型: "填好本金/利率/期限/到期处理方式之后，到期系统应该自动处理，不用自己盯着日历手动操作"。
// 到期处理方式两种: ① 转入账户 —— 本金+利息 (单利: 本金×年利率%×期限月数/12) 记一笔收入存进指定账户，
// 这张定存标记为已处理，到此为止；② 自动展期 (钱滚钱) —— 本金+利息变成下一期的本金，另开一张新的定存
// 记录 (start_date=上一期到期日，maturity_action/destination_account_id 都沿用)，旧的这张标记已处理，
// 不会进到银行余额里。循环推进 (像 auto_generate_due_subscriptions 一样) 是为了短期限定存好几期没打开
// 网站时也能一次性追上，不用连续开好几次才逐期展期。
function auto_generate_due_fixed_deposits(mysqli $db, int $userId): array {
    $matured = [];
    $skipped = [];
    $today = date('Y-m-d');

    $stmt = $db->prepare("SELECT * FROM fixed_deposits WHERE user_id = ? AND status = 'active'");
    $stmt->bind_param('i', $userId);
    $stmt->execute();
    $fds = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);

    foreach ($fds as $fd) {
        $current = $fd;
        $currentId = (int)$fd['id'];
        $guard = 0;

        while (!empty($current['maturity_date']) && $current['maturity_date'] <= $today && $guard < 60) {
            $principal = (float)$current['principal'];
            $rate = (float)$current['interest_rate'];
            $months = (int)$current['tenure_months'];
            $interest = round($principal * $rate / 100 * $months / 12, 2);
            $maturityAmount = round($principal + $interest, 2);

            if ($current['maturity_action'] === 'renew') {
                $newStart = $current['maturity_date'];
                $newMaturity = date('Y-m-d', strtotime("+{$months} months", strtotime($newStart)));
                $ins = $db->prepare(
                    "INSERT INTO fixed_deposits
                        (user_id, bank_id, principal, interest_rate, tenure_months, start_date, maturity_date,
                         maturity_action, destination_account_id, status, renewed_from_id)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)"
                );
                // 10 个占位符: user_id, bank_id, principal, interest_rate, tenure_months, start_date,
                // maturity_date, maturity_action, destination_account_id, renewed_from_id —— 类型字符串
                // 长度务必用工具重新数一次再确认 (这个专案之前真的因为手动数错吃过 bind_param 的亏)。
                $ins->bind_param(
                    'iiddisssii',
                    $userId, $current['bank_id'], $maturityAmount, $rate, $months,
                    $newStart, $newMaturity, $current['maturity_action'], $current['destination_account_id'], $currentId
                );
                $ins->execute();
                $newId = $ins->insert_id;

                $upd = $db->prepare("UPDATE fixed_deposits SET status = 'matured' WHERE id = ?");
                $upd->bind_param('i', $currentId);
                $upd->execute();

                $matured[] = [
                    'id' => $currentId, 'action' => 'renew', 'principal' => $principal, 'interest' => $interest,
                    'new_id' => $newId, 'new_maturity_date' => $newMaturity,
                ];

                $current = [
                    'id' => $newId, 'bank_id' => $current['bank_id'], 'principal' => $maturityAmount,
                    'interest_rate' => $rate, 'tenure_months' => $months, 'start_date' => $newStart,
                    'maturity_date' => $newMaturity, 'maturity_action' => $current['maturity_action'],
                    'destination_account_id' => $current['destination_account_id'],
                ];
                $currentId = $newId;
            } else {
                if (empty($current['destination_account_id'])) {
                    $skipped[] = ['id' => $currentId, 'reason' => '没有设置"到期转入账户"'];
                    break;
                }
                $desc = '定存到期: 本金 RM ' . number_format($principal, 2) . ' + 利息 RM ' . number_format($interest, 2);
                $ins = $db->prepare(
                    "INSERT INTO transactions (user_id, type, amount, transaction_date, bank_account_id, description, currency)
                     VALUES (?, 'income', ?, ?, ?, ?, 'MYR')"
                );
                $ins->bind_param('idsis', $userId, $maturityAmount, $current['maturity_date'], $current['destination_account_id'], $desc);
                $ins->execute();

                $upd = $db->prepare("UPDATE fixed_deposits SET status = 'matured' WHERE id = ?");
                $upd->bind_param('i', $currentId);
                $upd->execute();

                $matured[] = [
                    'id' => $currentId, 'action' => 'transfer', 'principal' => $principal,
                    'interest' => $interest, 'total' => $maturityAmount,
                ];
                break; // 转入账户是终态，这条链到此结束
            }
            $guard++;
        }
    }

    return ['matured' => $matured, 'skipped' => $skipped];
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
function advance_due_reminders(mysqli $db, int $userId): void {
    $now = date('Y-m-d H:i:s');
    $stmt = $db->prepare(
        "SELECT * FROM reminders WHERE user_id = ? AND repeat_rule IS NOT NULL AND repeat_rule != 'none' AND is_sent = 0 AND remind_at <= ?"
    );
    $stmt->bind_param('is', $userId, $now);
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

function compute_bank_balances(mysqli $db, int $userId): array {
    $stmt0 = $db->prepare("SELECT * FROM bank_accounts WHERE user_id = ? AND is_active = 1 ORDER BY id");
    $stmt0->bind_param('i', $userId);
    $stmt0->execute();
    $accounts = $stmt0->get_result()->fetch_all(MYSQLI_ASSOC);
    foreach ($accounts as &$a) {
        $id = (int)$a['id'];
        $stmt = $db->prepare(
            "SELECT
                COALESCE(SUM(CASE WHEN type = 'income' AND bank_account_id = ? THEN amount ELSE 0 END), 0) AS income,
                COALESCE(SUM(CASE WHEN type = 'expense' AND bank_account_id = ? THEN amount ELSE 0 END), 0) AS expense,
                COALESCE(SUM(CASE WHEN type = 'transfer' AND bank_account_id = ? THEN amount ELSE 0 END), 0) AS transfer_out,
                COALESCE(SUM(CASE WHEN type = 'transfer' AND transfer_to_account_id = ? THEN amount ELSE 0 END), 0) AS transfer_in
             FROM transactions WHERE user_id = ?"
        );
        $stmt->bind_param('iiiii', $id, $id, $id, $id, $userId);
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

function build_dashboard(mysqli $db, int $userId): array {
    $today = date('Y-m-d');
    $out = ['ok' => true, 'date' => $today];

    // 到发薪日就自动帮活跃的月薪档案生一笔发薪记录 (见函数注释) —— 每次看仪表盘都顺手检查一次
    $salaryAutoResult = auto_generate_due_salary_payments($db, $userId);
    $out['auto_generated_salary'] = $salaryAutoResult['generated'];
    $out['auto_generate_skipped_salary'] = $salaryAutoResult['skipped'];

    // 订阅到期自动生成扣费记录 (见函数注释) —— 每次看仪表盘都顺手检查一次
    $subAutoResult = auto_generate_due_subscriptions($db, $userId);
    $out['auto_generated_subscriptions'] = $subAutoResult['generated'];
    $out['auto_generate_skipped_subscriptions'] = $subAutoResult['skipped'];

    // 定存到期自动处理 (转入账户/自动展期，见函数注释) —— 每次看仪表盘都顺手检查一次
    $fdAutoResult = auto_generate_due_fixed_deposits($db, $userId);
    $out['auto_matured_fixed_deposits'] = $fdAutoResult['matured'];
    $out['auto_generate_skipped_fixed_deposits'] = $fdAutoResult['skipped'];

    $stmt = $db->prepare("SELECT * FROM tasks WHERE user_id = ? AND (status = 'today' OR due_date = ?) ORDER BY priority DESC, id DESC");
    $stmt->bind_param('is', $userId, $today);
    $stmt->execute();
    $out['tasks_today'] = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);

    $stmt = $db->prepare("SELECT * FROM habits WHERE user_id = ? AND is_active = 1 ORDER BY id");
    $stmt->bind_param('i', $userId);
    $stmt->execute();
    $habits = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);
    $stmt = $db->prepare("SELECT habit_id, completed FROM habit_logs WHERE user_id = ? AND log_date = ?");
    $stmt->bind_param('is', $userId, $today);
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

    $stmt = $db->prepare("SELECT * FROM journal_entries WHERE user_id = ? AND entry_date = ?");
    $stmt->bind_param('is', $userId, $today);
    $stmt->execute();
    $out['journal_today'] = $stmt->get_result()->fetch_assoc();

    $stmt = $db->prepare("SELECT * FROM transactions WHERE user_id = ? AND transaction_date = ? ORDER BY id DESC");
    $stmt->bind_param('is', $userId, $today);
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

    $bankAccounts = compute_bank_balances($db, $userId);
    $out['bank_accounts'] = $bankAccounts;
    $out['total_balance'] = array_sum(array_column($bankAccounts, 'current_balance'));

    // 定存总额 (存款中的本金加总) —— 特意跟 total_balance 分开显示，不合并进去:
    // 定存本金已经从来源账户扣走了 (不算活期余额)，但也不是"可以马上花的钱"，两者意义不同
    $fdStmt = $db->prepare("SELECT COALESCE(SUM(principal),0) AS total, COUNT(*) AS cnt FROM fixed_deposits WHERE user_id = ? AND status = 'active'");
    $fdStmt->bind_param('i', $userId);
    $fdStmt->execute();
    $fdRow = $fdStmt->get_result()->fetch_assoc();
    $out['fixed_deposits_total'] = (float)$fdRow['total'];
    $out['fixed_deposits_count'] = (int)$fdRow['cnt'];

    // 本月收支 (给仪表盘的统计卡 + 支出分类圆环图用)
    $monthStart = date('Y-m-01');
    $monthEnd = date('Y-m-t');
    $stmt = $db->prepare("SELECT * FROM transactions WHERE user_id = ? AND transaction_date BETWEEN ? AND ?");
    $stmt->bind_param('iss', $userId, $monthStart, $monthEnd);
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

    $catStmt = $db->prepare("SELECT * FROM categories WHERE user_id = ?");
    $catStmt->bind_param('i', $userId);
    $catStmt->execute();
    $categories = $catStmt->get_result()->fetch_all(MYSQLI_ASSOC);
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
    $recentStmt = $db->prepare("SELECT * FROM transactions WHERE user_id = ? ORDER BY transaction_date DESC, id DESC LIMIT 5");
    $recentStmt->bind_param('i', $userId);
    $recentStmt->execute();
    $recentRows = $recentStmt->get_result()->fetch_all(MYSQLI_ASSOC);
    foreach ($recentRows as &$r) {
        $cat = $categoryById[$r['category_id']] ?? null;
        $r['category_label'] = $cat['name'] ?? '未分类';
        $r['category_icon'] = $cat['icon'] ?? '💳';
    }
    unset($r);
    $out['recent_transactions'] = $recentRows;

    // 薪资: 预期 (在职的月薪档案) vs 实际 (这个月真的记录了的发薪) —— 绝对不能把预期当成已经到手的钱
    $profStmt = $db->prepare("SELECT * FROM salary_profiles WHERE user_id = ? AND status = 'active' AND salary_frequency = 'monthly'");
    $profStmt->bind_param('i', $userId);
    $profStmt->execute();
    $activeProfiles = $profStmt->get_result()->fetch_all(MYSQLI_ASSOC);
    $out['expected_monthly_salary'] = array_sum(array_column($activeProfiles, 'basic_salary'));

    $stmt = $db->prepare("SELECT COALESCE(SUM(net_salary), 0) AS total FROM salary_payments WHERE user_id = ? AND status = 'paid' AND payment_date BETWEEN ? AND ?");
    $stmt->bind_param('iss', $userId, $monthStart, $monthEnd);
    $stmt->execute();
    $out['actual_monthly_salary'] = (float)$stmt->get_result()->fetch_assoc()['total'];

    // EPF 累计供款 (全部历史) —— 2024 新制度的 Akaun Persaraan/Sejahtera/Fleksibel 三户口累计也一起算，
    // 给仪表盘的饼图用 (每笔供款自己按各自那笔的比例分好、存成 persaraan_amount 等，这里只是加总)
    $epfStmt = $db->prepare(
        "SELECT COALESCE(SUM(employee_contribution),0) AS emp, COALESCE(SUM(employer_contribution),0) AS empr,
                COALESCE(SUM(additional_contribution),0) AS add_,
                COALESCE(SUM(persaraan_amount),0) AS persaraan, COALESCE(SUM(sejahtera_amount),0) AS sejahtera,
                COALESCE(SUM(fleksibel_amount),0) AS fleksibel
         FROM epf_contributions WHERE user_id = ?"
    );
    $epfStmt->bind_param('i', $userId);
    $epfStmt->execute();
    $epfRow = $epfStmt->get_result()->fetch_assoc();
    $out['epf_cumulative'] = [
        'employee' => (float)$epfRow['emp'],
        'employer' => (float)$epfRow['empr'],
        'additional' => (float)$epfRow['add_'],
        'total' => (float)$epfRow['emp'] + (float)$epfRow['empr'] + (float)$epfRow['add_'],
        'persaraan' => (float)$epfRow['persaraan'],
        'sejahtera' => (float)$epfRow['sejahtera'],
        'fleksibel' => (float)$epfRow['fleksibel'],
    ];

    $stmt = $db->prepare("SELECT * FROM daily_metrics WHERE user_id = ? AND metric_date = ?");
    $stmt->bind_param('is', $userId, $today);
    $stmt->execute();
    $out['metric_today'] = $stmt->get_result()->fetch_assoc();

    $inboxStmt = $db->prepare("SELECT * FROM inbox_items WHERE user_id = ? AND is_processed = 0 ORDER BY id DESC LIMIT 10");
    $inboxStmt->bind_param('i', $userId);
    $inboxStmt->execute();
    $out['inbox_unprocessed'] = $inboxStmt->get_result()->fetch_all(MYSQLI_ASSOC);

    // 即将到来的提醒: 订阅续费 (在各自的 remind_days_before 窗口内) + 生日 (未来 14 天内, 不看年份)
    $todayDate = new DateTime($today);

    $subStmt = $db->prepare("SELECT * FROM subscriptions WHERE user_id = ? AND is_active = 1 AND next_billing_date IS NOT NULL");
    $subStmt->bind_param('i', $userId);
    $subStmt->execute();
    $subs = $subStmt->get_result()->fetch_all(MYSQLI_ASSOC);
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

    $contactStmt = $db->prepare("SELECT * FROM contacts WHERE user_id = ? AND birthday IS NOT NULL");
    $contactStmt->bind_param('i', $userId);
    $contactStmt->execute();
    $contacts = $contactStmt->get_result()->fetch_all(MYSQLI_ASSOC);
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

// 报表汇总的核心计算: 跟 build_dashboard() 的算法基本一致，只是日期范围从"今天/这个月"
// 换成"任意自订区间" (周报/月报/年报都只是区间长短不同，算法完全共用)。
// 存成 reports.content 这份 JSON 快照，之后不会因为交易被改/删就跟着变 —— 想要最新数字
// 就重新生成同一个区间的报表 (会覆盖，不会重复堆一份)。
function build_report_content(mysqli $db, int $userId, string $periodStart, string $periodEnd): array {
    $out = ['period_start' => $periodStart, 'period_end' => $periodEnd];

    $stmt = $db->prepare("SELECT * FROM transactions WHERE user_id = ? AND transaction_date BETWEEN ? AND ?");
    $stmt->bind_param('iss', $userId, $periodStart, $periodEnd);
    $stmt->execute();
    $rows = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);

    $catStmt = $db->prepare("SELECT * FROM categories WHERE user_id = ?");
    $catStmt->bind_param('i', $userId);
    $catStmt->execute();
    $categoryById = [];
    foreach ($catStmt->get_result()->fetch_all(MYSQLI_ASSOC) as $c) $categoryById[$c['id']] = $c;

    $income = 0.0;
    $expense = 0.0;
    $categoryTotals = [];
    foreach ($rows as $r) {
        if ($r['type'] === 'income') {
            $income += (float)$r['amount'];
        } elseif ($r['type'] === 'expense') {
            $expense += (float)$r['amount'];
            $cid = $r['category_id'] ?? 'none';
            $categoryTotals[$cid] = ($categoryTotals[$cid] ?? 0) + (float)$r['amount'];
        }
    }
    $out['income_total'] = round($income, 2);
    $out['expense_total'] = round($expense, 2);
    $out['net'] = round($income - $expense, 2);

    $breakdown = [];
    foreach ($categoryTotals as $cid => $amount) {
        $cat = $categoryById[$cid] ?? null;
        $breakdown[] = ['label' => $cat['name'] ?? '未分类', 'color' => $cat['color'] ?? '#9CA3AF', 'amount' => round($amount, 2)];
    }
    usort($breakdown, fn($a, $b) => $b['amount'] <=> $a['amount']);
    $out['category_breakdown'] = $breakdown;

    $expenseRows = array_values(array_filter($rows, fn($r) => $r['type'] === 'expense'));
    usort($expenseRows, fn($a, $b) => (float)$b['amount'] <=> (float)$a['amount']);
    $out['top_expenses'] = array_map(function ($r) use ($categoryById) {
        $cat = $categoryById[$r['category_id']] ?? null;
        return [
            'description' => $r['description'] ?: ($cat['name'] ?? '未分类'),
            'amount' => (float)$r['amount'],
            'date' => $r['transaction_date'],
            'category_label' => $cat['name'] ?? '未分类',
        ];
    }, array_slice($expenseRows, 0, 5));

    $stmt = $db->prepare("SELECT COALESCE(SUM(net_salary),0) AS total FROM salary_payments WHERE user_id=? AND status='paid' AND payment_date BETWEEN ? AND ?");
    $stmt->bind_param('iss', $userId, $periodStart, $periodEnd);
    $stmt->execute();
    $out['salary_received'] = (float)$stmt->get_result()->fetch_assoc()['total'];

    $stmt = $db->prepare(
        "SELECT COALESCE(SUM(employee_contribution),0) e, COALESCE(SUM(employer_contribution),0) er, COALESCE(SUM(additional_contribution),0) a
         FROM epf_contributions WHERE user_id=? AND contribution_date BETWEEN ? AND ?"
    );
    $stmt->bind_param('iss', $userId, $periodStart, $periodEnd);
    $stmt->execute();
    $epfRow = $stmt->get_result()->fetch_assoc();
    $out['epf_contributed'] = ['employee' => (float)$epfRow['e'], 'employer' => (float)$epfRow['er'], 'additional' => (float)$epfRow['a']];

    // 订阅扣费统计: 靠交易说明的"订阅扣费: "前缀识别 (跟 mark_subscription_paid()/
    // auto_generate_due_subscriptions() 生成的交易描述格式完全一致，不需要额外打标记字段)
    $subCount = 0;
    $subTotal = 0.0;
    foreach ($rows as $r) {
        if ($r['type'] === 'expense' && strpos((string)$r['description'], '订阅扣费: ') === 0) {
            $subCount++;
            $subTotal += (float)$r['amount'];
        }
    }
    $out['subscriptions_charged'] = ['count' => $subCount, 'total' => round($subTotal, 2)];

    // 期末各账户余额快照: 只算到 period_end 为止发生的交易，不是"现在"的余额 ——
    // 报表本来就该反映"那个时间点"的状态，即使之后又记了新账，这份报表的数字也不该跟着变。
    $accStmt = $db->prepare("SELECT * FROM bank_accounts WHERE user_id = ? AND is_active = 1 ORDER BY id");
    $accStmt->bind_param('i', $userId);
    $accStmt->execute();
    $accountBalances = [];
    $totalBalance = 0.0;
    foreach ($accStmt->get_result()->fetch_all(MYSQLI_ASSOC) as $a) {
        $id = (int)$a['id'];
        $bstmt = $db->prepare(
            "SELECT
                COALESCE(SUM(CASE WHEN type='income' AND bank_account_id=? THEN amount ELSE 0 END),0) AS income,
                COALESCE(SUM(CASE WHEN type='expense' AND bank_account_id=? THEN amount ELSE 0 END),0) AS expense,
                COALESCE(SUM(CASE WHEN type='transfer' AND bank_account_id=? THEN amount ELSE 0 END),0) AS transfer_out,
                COALESCE(SUM(CASE WHEN type='transfer' AND transfer_to_account_id=? THEN amount ELSE 0 END),0) AS transfer_in
             FROM transactions WHERE user_id=? AND transaction_date <= ?"
        );
        $bstmt->bind_param('iiiiis', $id, $id, $id, $id, $userId, $periodEnd);
        $bstmt->execute();
        $b = $bstmt->get_result()->fetch_assoc();
        $balance = round((float)$a['opening_balance'] + (float)$b['income'] - (float)$b['expense'] - (float)$b['transfer_out'] + (float)$b['transfer_in'], 2);
        $accountBalances[] = ['nickname' => $a['nickname'], 'kind' => $a['account_kind'], 'balance' => $balance];
        $totalBalance += $balance;
    }
    $out['account_balances'] = $accountBalances;
    $out['total_balance_at_period_end'] = round($totalBalance, 2);

    $stmt = $db->prepare(
        "SELECT h.name AS name, COUNT(*) AS cnt FROM habit_logs hl
         JOIN habits h ON h.id = hl.habit_id
         WHERE hl.user_id = ? AND hl.completed = 1 AND hl.log_date BETWEEN ? AND ?
         GROUP BY h.id, h.name ORDER BY cnt DESC"
    );
    $stmt->bind_param('iss', $userId, $periodStart, $periodEnd);
    $stmt->execute();
    $out['habit_checkins'] = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);

    $stmt = $db->prepare("SELECT COUNT(*) AS cnt FROM journal_entries WHERE user_id=? AND entry_date BETWEEN ? AND ?");
    $stmt->bind_param('iss', $userId, $periodStart, $periodEnd);
    $stmt->execute();
    $out['journal_entry_count'] = (int)$stmt->get_result()->fetch_assoc()['cnt'];

    return $out;
}

// ---------------- Admin: 用户管理 + 全库备份 ----------------
// 这几个 action 只有 role='admin' 的账号能用 (权限在这里现查现判断，不是只靠前端隐藏入口)。

if ($action === 'admin_list_users') {
    if (!$isAdmin) {
        http_response_code(403);
        echo json_encode(['ok' => false, 'error' => '只有管理员能用这个功能'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $db = get_db();
    $res = $db->query("SELECT id, username, display_name, role, created_at FROM users ORDER BY id");
    echo json_encode(['ok' => true, 'data' => $res->fetch_all(MYSQLI_ASSOC)], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'admin_create_user') {
    if (!$isAdmin) {
        http_response_code(403);
        echo json_encode(['ok' => false, 'error' => '只有管理员能用这个功能'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $db = get_db();
    $username = trim((string)($body['username'] ?? ''));
    $password = (string)($body['password'] ?? '');
    $displayName = trim((string)($body['display_name'] ?? '')) ?: $username;
    $role = ($body['role'] ?? 'user') === 'admin' ? 'admin' : 'user';

    if (mb_strlen($username) < 2) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '用户名至少要 2 个字符'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    if (mb_strlen($password) < 6) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '密码至少要 6 位'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $check = $db->prepare("SELECT id FROM users WHERE username = ?");
    $check->bind_param('s', $username);
    $check->execute();
    if ($check->get_result()->fetch_assoc()) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '这个用户名已经有人用了，换一个'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $hash = password_hash($password, PASSWORD_DEFAULT);
    $ins = $db->prepare("INSERT INTO users (username, password_hash, display_name, role) VALUES (?, ?, ?, ?)");
    $ins->bind_param('ssss', $username, $hash, $displayName, $role);
    $ins->execute();
    echo json_encode(['ok' => true, 'id' => (int)$ins->insert_id], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'admin_update_user') {
    if (!$isAdmin) {
        http_response_code(403);
        echo json_encode(['ok' => false, 'error' => '只有管理员能用这个功能'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $db = get_db();
    $targetId = (int)($body['id'] ?? 0);
    $target = $db->prepare("SELECT * FROM users WHERE id = ?");
    $target->bind_param('i', $targetId);
    $target->execute();
    $targetUser = $target->get_result()->fetch_assoc();
    if (!$targetUser) {
        http_response_code(404);
        echo json_encode(['ok' => false, 'error' => '找不到这个用户'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $sets = [];
    $types = '';
    $vals = [];

    if (array_key_exists('display_name', $body)) {
        $sets[] = 'display_name = ?';
        $types .= 's';
        $vals[] = trim((string)$body['display_name']);
    }
    if (array_key_exists('username', $body)) {
        $newUsername = trim((string)$body['username']);
        if (mb_strlen($newUsername) < 2) {
            http_response_code(400);
            echo json_encode(['ok' => false, 'error' => '用户名至少要 2 个字符'], JSON_UNESCAPED_UNICODE);
            exit;
        }
        if ($newUsername !== $targetUser['username']) {
            $dup = $db->prepare("SELECT id FROM users WHERE username = ? AND id != ?");
            $dup->bind_param('si', $newUsername, $targetId);
            $dup->execute();
            if ($dup->get_result()->fetch_assoc()) {
                http_response_code(400);
                echo json_encode(['ok' => false, 'error' => '这个用户名已经有人用了，换一个'], JSON_UNESCAPED_UNICODE);
                exit;
            }
        }
        $sets[] = 'username = ?';
        $types .= 's';
        $vals[] = $newUsername;
    }
    if (array_key_exists('role', $body)) {
        $newRole = $body['role'] === 'admin' ? 'admin' : 'user';
        // 不能把系统里最后一个 admin 降级成 user，不然以后没人能再管理账号
        if ($newRole !== 'admin' && $targetUser['role'] === 'admin') {
            $adminCount = (int)$db->query("SELECT COUNT(*) c FROM users WHERE role='admin'")->fetch_assoc()['c'];
            if ($adminCount <= 1) {
                http_response_code(400);
                echo json_encode(['ok' => false, 'error' => '这是系统里最后一个管理员，不能降级 (至少要留一个管理员)'], JSON_UNESCAPED_UNICODE);
                exit;
            }
        }
        $sets[] = 'role = ?';
        $types .= 's';
        $vals[] = $newRole;
    }
    if (!empty($body['password'])) {
        $newPassword = (string)$body['password'];
        if (mb_strlen($newPassword) < 6) {
            http_response_code(400);
            echo json_encode(['ok' => false, 'error' => '密码至少要 6 位'], JSON_UNESCAPED_UNICODE);
            exit;
        }
        $sets[] = 'password_hash = ?';
        $types .= 's';
        $vals[] = password_hash($newPassword, PASSWORD_DEFAULT);
    }

    if ($sets) {
        $types .= 'i';
        $vals[] = $targetId;
        $sql = "UPDATE users SET " . implode(', ', $sets) . " WHERE id = ?";
        $upd = $db->prepare($sql);
        $upd->bind_param($types, ...$vals);
        $upd->execute();
    }
    echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'admin_delete_user') {
    if (!$isAdmin) {
        http_response_code(403);
        echo json_encode(['ok' => false, 'error' => '只有管理员能用这个功能'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $db = get_db();
    $targetId = (int)($body['id'] ?? 0);
    if ($targetId === $currentUserId) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '不能删除自己，请找另一个管理员帮忙删'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $target = $db->prepare("SELECT * FROM users WHERE id = ?");
    $target->bind_param('i', $targetId);
    $target->execute();
    $targetUser = $target->get_result()->fetch_assoc();
    if (!$targetUser) {
        http_response_code(404);
        echo json_encode(['ok' => false, 'error' => '找不到这个用户'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    if ($targetUser['role'] === 'admin') {
        $adminCount = (int)$db->query("SELECT COUNT(*) c FROM users WHERE role='admin'")->fetch_assoc()['c'];
        if ($adminCount <= 1) {
            http_response_code(400);
            echo json_encode(['ok' => false, 'error' => '这是系统里最后一个管理员，不能删除'], JSON_UNESCAPED_UNICODE);
            exit;
        }
    }

    // 删除账号连同这个人名下所有模块的数据一起清掉 (不是软删，删了就真的没了) ——
    // 用 config 里 user_scoped=true 的表清单，逐一删掉这个 user_id 底下的所有行，
    // 不用另外维护一份重复的表名单，config 加新表自动就会被这里的清理逻辑涵盖到。
    foreach ($config as $tableName => $cfg) {
        if (empty($cfg['user_scoped'])) continue;
        $del = $db->prepare("DELETE FROM `$tableName` WHERE user_id = ?");
        $del->bind_param('i', $targetId);
        $del->execute();
    }
    $delUser = $db->prepare("DELETE FROM users WHERE id = ?");
    $delUser->bind_param('i', $targetId);
    $delUser->execute();

    echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
    exit;
}

// 全库备份 (admin 专用): 跟 export_sql (每个人只能导出自己的数据) 不一样，这个是整个数据库的
// 完整备份 —— 每张表现查 SHOW CREATE TABLE 拿到跟当前结构完全一致的建表语句 + 所有用户的所有数据，
// 拿这份 SQL 去另一台全新的 MySQL 直接跑就能整个还原回来，是真正意义上的"备份整个 SQL database"
// (跟 export_sql 只含 INSERT、假设表已经存在不同)。
if ($action === 'admin_export_full_sql') {
    if (!$isAdmin) {
        http_response_code(403);
        echo json_encode(['ok' => false, 'error' => '只有管理员能用这个功能'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $db = get_db();
    $tables = [];
    $res = $db->query('SHOW TABLES');
    while ($row = $res->fetch_row()) $tables[] = $row[0];

    $sql = "-- personal_os 全库备份 (" . date('Y-m-d H:i:s') . ")，包含所有用户的所有数据\n";
    $sql .= "SET FOREIGN_KEY_CHECKS=0;\n\n";
    foreach ($tables as $tbl) {
        $createRow = $db->query("SHOW CREATE TABLE `$tbl`")->fetch_assoc();
        $sql .= "DROP TABLE IF EXISTS `$tbl`;\n" . $createRow['Create Table'] . ";\n\n";

        $rows = $db->query("SELECT * FROM `$tbl`")->fetch_all(MYSQLI_ASSOC);
        foreach ($rows as $row) {
            $cols = implode(',', array_map(fn($c) => "`$c`", array_keys($row)));
            $vals = implode(',', array_map(function ($v) use ($db) {
                return $v === null ? 'NULL' : "'" . $db->real_escape_string((string)$v) . "'";
            }, array_values($row)));
            $sql .= "INSERT INTO `$tbl` ($cols) VALUES ($vals);\n";
        }
        if ($rows) $sql .= "\n";
    }
    $sql .= "SET FOREIGN_KEY_CHECKS=1;\n";

    echo json_encode(['ok' => true, 'sql' => $sql, 'filename' => 'personal_os_full_backup_' . date('Ymd_His') . '.sql'], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'meta') {
    echo json_encode(['ok' => true, 'resources' => $config], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'dashboard') {
    echo json_encode(build_dashboard(get_db(), $currentUserId), JSON_UNESCAPED_UNICODE);
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
        $stmt = $db->prepare("SELECT * FROM `$tbl` WHERE user_id = ? AND ($where) ORDER BY id DESC LIMIT 8");
        $types = 'i' . str_repeat('s', count($spec['cols']));
        $params = array_merge([$currentUserId], array_fill(0, count($spec['cols']), $like));
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

// 订阅"标记已扣费": 到期不自动生成账目 (订阅金额/日期用户可能还没确认扣款成功)，
// 要用户手动点一下才生成对应的支出记录，并把下次扣费日期推后一个周期。
if ($action === 'mark_subscription_paid') {
    $db = get_db();
    $id = (int)($body['id'] ?? 0);
    $stmt = $db->prepare("SELECT * FROM subscriptions WHERE id = ? AND user_id = ?");
    $stmt->bind_param('ii', $id, $currentUserId);
    $stmt->execute();
    $sub = $stmt->get_result()->fetch_assoc();
    if (!$sub) {
        http_response_code(404);
        echo json_encode(['ok' => false, 'error' => '找不到这个订阅']);
        exit;
    }
    if (empty($sub['bank_account_id'])) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '这个订阅还没设置自动扣款账户']);
        exit;
    }

    $today = date('Y-m-d');
    $desc = '订阅扣费: ' . $sub['name'];
    $tStmt = $db->prepare("INSERT INTO transactions (user_id, type, amount, transaction_date, bank_account_id, description, currency) VALUES (?, 'expense', ?, ?, ?, ?, 'MYR')");
    $tStmt->bind_param('idsis', $currentUserId, $sub['cost'], $today, $sub['bank_account_id'], $desc);
    $tStmt->execute();
    $transactionId = $tStmt->insert_id;

    $base = $sub['next_billing_date'] ?: $today;
    $interval = $sub['billing_cycle'] === 'yearly' ? '+1 year' : '+1 month';
    $nextDate = date('Y-m-d', strtotime($interval, strtotime($base)));
    $uStmt = $db->prepare("UPDATE subscriptions SET next_billing_date = ? WHERE id = ? AND user_id = ?");
    $uStmt->bind_param('sii', $nextDate, $id, $currentUserId);
    $uStmt->execute();

    echo json_encode(['ok' => true, 'transaction_id' => $transactionId, 'next_billing_date' => $nextDate], JSON_UNESCAPED_UNICODE);
    exit;
}

// 报表汇总: 生成 (或重新生成) 某个区间的汇总快照。同一个用户 + 类型 + 区间已经生成过的话
// 直接覆盖更新那一条 (不会重复堆一份) —— 这跟 salary_payments 的"历史事实、永不覆盖"不同，
// 报表本质是"任意时刻按当下数据算出来的一份摘要"，用户随时可以重新按同一个区间刷新数字。
if ($action === 'generate_report') {
    $db = get_db();
    $reportType = (string)($body['report_type'] ?? 'monthly');
    if (!in_array($reportType, ['weekly', 'monthly', 'yearly'], true)) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '报表类型不对']);
        exit;
    }
    $periodStart = (string)($body['period_start'] ?? '');
    $periodEnd = (string)($body['period_end'] ?? '');
    if (!$periodStart || !$periodEnd || $periodStart > $periodEnd) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '请选择正确的开始/结束日期']);
        exit;
    }

    $content = build_report_content($db, $currentUserId, $periodStart, $periodEnd);
    $contentJson = json_encode($content, JSON_UNESCAPED_UNICODE);

    $check = $db->prepare("SELECT id FROM reports WHERE user_id = ? AND report_type = ? AND period_start = ? AND period_end = ?");
    $check->bind_param('isss', $currentUserId, $reportType, $periodStart, $periodEnd);
    $check->execute();
    $existing = $check->get_result()->fetch_assoc();

    if ($existing) {
        $upd = $db->prepare("UPDATE reports SET content = ?, generated_at = NOW() WHERE id = ?");
        $upd->bind_param('si', $contentJson, $existing['id']);
        $upd->execute();
        $id = (int)$existing['id'];
    } else {
        $ins = $db->prepare("INSERT INTO reports (user_id, report_type, period_start, period_end, content) VALUES (?, ?, ?, ?, ?)");
        $ins->bind_param('issss', $currentUserId, $reportType, $periodStart, $periodEnd, $contentJson);
        $ins->execute();
        $id = $ins->insert_id;
    }

    echo json_encode(['ok' => true, 'id' => $id, 'report_type' => $reportType, 'content' => $content], JSON_UNESCAPED_UNICODE);
    exit;
}

// 备份: 纯 PHP 拼 SQL (不依赖 mysqldump 可执行文件的路径)。
// v4.8 多用户改动: 现在是共用数据库，不能再整个 DROP TABLE + 全部数据倒出去 (会把别人的数据也导出/
// 还原时整表清空)，改成只导出"当前登录用户自己的那些行"，且只用 INSERT (不含建表语句) ——
// 定位从"整个数据库灾难备份"变成"导出我自己的数据"，真要还原是拿这份 INSERT 语句手动跑进
// 已经存在的表，不会动到别人的数据或表结构。
if ($action === 'export_sql') {
    $db = get_db();
    $tables = [];
    $res = $db->query('SHOW TABLES');
    while ($row = $res->fetch_row()) $tables[] = $row[0];

    $sql = "-- personal_os 我的数据导出 (" . date('Y-m-d H:i:s') . ")，仅包含当前账号自己的数据\n\n";
    foreach ($tables as $tbl) {
        $userScoped = $db->query("SHOW COLUMNS FROM `$tbl` LIKE 'user_id'")->fetch_assoc();
        if (!$userScoped) continue; // 不是个人数据的表 (共用参考表/系统表) 不导出

        $stmt = $db->prepare("SELECT * FROM `$tbl` WHERE user_id = ?");
        $stmt->bind_param('i', $currentUserId);
        $stmt->execute();
        $rows = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);
        if (!$rows) continue;

        foreach ($rows as $row) {
            $cols = implode(',', array_map(fn($c) => "`$c`", array_keys($row)));
            $vals = implode(',', array_map(function ($v) use ($db) {
                return $v === null ? 'NULL' : "'" . $db->real_escape_string((string)$v) . "'";
            }, array_values($row)));
            $sql .= "INSERT INTO `$tbl` ($cols) VALUES ($vals);\n";
        }
        $sql .= "\n";
    }

    echo json_encode(['ok' => true, 'sql' => $sql, 'filename' => 'personal_os_mydata_' . date('Ymd_His') . '.sql'], JSON_UNESCAPED_UNICODE);
    exit;
}

if (!$resource || !isset($config[$resource])) {
    http_response_code(400);
    echo json_encode(['ok' => false, 'error' => 'Unknown resource']);
    exit;
}

$table = $resource;
$fields = $config[$resource]['fields'];
$userScoped = !empty($config[$resource]['user_scoped']);
$db = get_db();

switch ($action) {

    case 'list': {
        // 打开"发薪记录"列表页时也顺手检查一次有没有到发薪日该自动生成的 (不用非得从仪表盘才会触发)
        if ($resource === 'salary_payments') auto_generate_due_salary_payments($db, $currentUserId);
        // 打开"订阅管理"列表页时也顺手检查一次有没有到期该自动生成的扣费记录
        if ($resource === 'subscriptions') auto_generate_due_subscriptions($db, $currentUserId);
        // 打开"定期存款"列表页时也顺手检查一次有没有到期该自动处理的定存
        if ($resource === 'fixed_deposits') auto_generate_due_fixed_deposits($db, $currentUserId);
        // 打开"通用提醒"列表页时顺手把过期未处理的重复提醒往后推 (见函数注释)
        if ($resource === 'reminders') advance_due_reminders($db, $currentUserId);

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
        // 多用户隔离: 这个 resource 是个人数据的话，不管前端有没有传，都强制加上"只查自己的"，
        // 不能让前端漏传或被绕过 —— 隔离必须在后端这一层保证，不能只靠前端不去查别人的。
        if ($userScoped) { $where[] = 'user_id = ?'; $params[] = $currentUserId; $types .= 'i'; }

        $sql = "SELECT * FROM `$table`";
        if ($where) $sql .= ' WHERE ' . implode(' AND ', $where);
        $sql .= ' ORDER BY id DESC LIMIT 500';
        $stmt = $db->prepare($sql);
        if ($params) $stmt->bind_param($types, ...$params);
        $stmt->execute();
        $rows = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);

        // 银行账户列表额外算出当前余额 + 打码账号，不用另开一个 endpoint
        if ($resource === 'bank_accounts') {
            $balances = compute_bank_balances($db, $currentUserId);
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
        if ($userScoped) {
            $stmt = $db->prepare("SELECT * FROM `$table` WHERE id = ? AND user_id = ?");
            $stmt->bind_param('ii', $id, $currentUserId);
        } else {
            $stmt = $db->prepare("SELECT * FROM `$table` WHERE id = ?");
            $stmt->bind_param('i', $id);
        }
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

        // subscriptions 特殊规则: 新增时如果没填"下次扣费日期"，直接拿"购买/开始日期"当第一期的扣费日 ——
        // 用户的心智模型是"填购买日期，系统自己算"，不该还要求他自己再填一次几乎一样的日期。
        // 只在 create 时补，编辑既有记录时不动 (next_billing_date 到那时候已经被自动生成逻辑推进过，
        // 不能被这里悄悄拉回 start_date)。
        if ($resource === 'subscriptions' && $action === 'create' && !empty($data['start_date']) && empty($data['next_billing_date'])) {
            $data['next_billing_date'] = $data['start_date'];
        }

        // fixed_deposits 特殊规则: 新增时如果没填"到期日期"，用"开始日期 + 存款期限"自动算一个 ——
        // 跟 subscriptions 的 start_date→next_billing_date 是同一个心智模型。
        // 到期处理方式选"转入账户"的话，转入账户是必填的 (不能到期了却不知道钱要存去哪)。
        if ($resource === 'fixed_deposits') {
            if ($action === 'create' && !empty($data['start_date']) && !empty($data['tenure_months']) && empty($data['maturity_date'])) {
                $months = (int)$data['tenure_months'];
                $data['maturity_date'] = date('Y-m-d', strtotime("+{$months} months", strtotime($data['start_date'])));
            }
            $maturityAction = $data['maturity_action'] ?? null;
            if ($maturityAction === 'transfer' && empty($data['destination_account_id'])) {
                http_response_code(400);
                echo json_encode(['ok' => false, 'error' => '到期处理方式选"转入账户"就必须选到期转入账户']);
                exit;
            }
            if ($maturityAction === 'renew' && array_key_exists('destination_account_id', $data)) {
                $data['destination_account_id'] = null; // 展期不需要转入账户，避免留着旧值造成混淆
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
                $exStmt = $db->prepare("SELECT remind_at FROM reminders WHERE id = ? AND user_id = ?");
                $exStmt->bind_param('ii', $existingId, $currentUserId);
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
            // 多用户隔离: create 一律强制盖上"是谁创建的"，不管前端传了什么 user_id 都不理会
            // ($fields 里本来就没有 user_id 这个可编辑字段，客户端传了也进不了 $cols，这里是唯一来源)
            if ($userScoped) {
                $cols[] = 'user_id';
                $vals[] = $currentUserId;
                $types .= 'i';
            }
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
            if ($resource === 'fixed_deposits') sync_fixed_deposit_open($db, $newId);
            echo json_encode(['ok' => true, 'id' => $newId], JSON_UNESCAPED_UNICODE);
        } else {
            $id = (int)($body['id'] ?? 0);
            $setList = implode(',', array_map(fn($c) => "`$c` = ?", $cols));
            // 多用户隔离: 只能改自己的行，就算知道别人的 id 也一样改不动 (WHERE 直接过滤掉)
            $sql = "UPDATE `$table` SET $setList WHERE id = ?" . ($userScoped ? ' AND user_id = ?' : '');
            $types .= 'i';
            $vals[] = $id;
            if ($userScoped) { $types .= 'i'; $vals[] = $currentUserId; }
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
                $stmt = $db->prepare("SELECT COUNT(*) AS c FROM `$refTable` WHERE `$refCol` = ? AND user_id = ?");
                $stmt->bind_param('ii', $id, $currentUserId);
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
            $stmt = $db->prepare("SELECT transaction_id FROM salary_payments WHERE id = ? AND user_id = ?");
            $stmt->bind_param('ii', $id, $currentUserId);
            $stmt->execute();
            $row = $stmt->get_result()->fetch_assoc();
            if ($row && $row['transaction_id']) {
                $delTxn = $db->prepare("DELETE FROM transactions WHERE id = ? AND user_id = ?");
                $delTxn->bind_param('ii', $row['transaction_id'], $currentUserId);
                $delTxn->execute();
            }
        }

        // 定存删除时，新增当下自动扣本金那笔交易也一起清掉 (到期后自动生成的转入/展期记录不联动清，
        // 逻辑跟 subscriptions 的 mark_subscription_paid 一样 —— 那已经是真实发生过的历史事实)
        if ($resource === 'fixed_deposits') {
            $stmt = $db->prepare("SELECT opening_transaction_id FROM fixed_deposits WHERE id = ? AND user_id = ?");
            $stmt->bind_param('ii', $id, $currentUserId);
            $stmt->execute();
            $row = $stmt->get_result()->fetch_assoc();
            if ($row && $row['opening_transaction_id']) {
                $delTxn = $db->prepare("DELETE FROM transactions WHERE id = ? AND user_id = ?");
                $delTxn->bind_param('ii', $row['opening_transaction_id'], $currentUserId);
                $delTxn->execute();
            }
        }

        // 多用户隔离: 只能删自己的行
        $sql = "DELETE FROM `$table` WHERE id = ?" . ($userScoped ? ' AND user_id = ?' : '');
        $stmt = $db->prepare($sql);
        if ($userScoped) $stmt->bind_param('ii', $id, $currentUserId);
        else $stmt->bind_param('i', $id);
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
        if ($userScoped) { $where[] = 'user_id = ?'; $params[] = $currentUserId; $types .= 'i'; }

        $sql = "SELECT * FROM `$table`";
        if ($where) $sql .= ' WHERE ' . implode(' AND ', $where);
        $sql .= ' ORDER BY id DESC LIMIT 5000';
        $stmt = $db->prepare($sql);
        if ($params) $stmt->bind_param($types, ...$params);
        $stmt->execute();
        $rows = $stmt->get_result()->fetch_all(MYSQLI_ASSOC);

        // fk 字段导出成可读名称，不是裸 id (fk 目标表如果也是个人数据，只能拿自己的那份来对应名字)
        $fkMaps = [];
        foreach ($fields as $col => $meta) {
            if ($meta['type'] !== 'fk') continue;
            $fkTable = $meta['fk_resource'];
            $fkDisplay = $config[$fkTable]['display_field'] ?? 'id';
            $fkUserScoped = !empty($config[$fkTable]['user_scoped']);
            $map = [];
            if ($fkUserScoped) {
                $fkStmt = $db->prepare("SELECT id, `$fkDisplay` AS label FROM `$fkTable` WHERE user_id = ?");
                $fkStmt->bind_param('i', $currentUserId);
                $fkStmt->execute();
                $res = $fkStmt->get_result();
            } else {
                $res = $db->query("SELECT id, `$fkDisplay` AS label FROM `$fkTable`");
            }
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
