<?php
// 2026-09-28: 从 Supabase (Postgres) 换回 InfinityFree 自己的 MySQL —— 原因: Supabase 虽然
// 数据库本身没问题，但 api.php 这个"中间人"程序还是得放在某个地方 24 小时跑着，本来放在这台
// 电脑的 XAMPP 上，等于网站/App 完全依赖这台电脑开不开机；InfinityFree 是免费的 PHP+MySQL
// 主机，一直开着，且 MySQL 就在同一个主机内网里 (不像 Supabase 要连去悉尼，快很多也不用
// Cloudflare Tunnel 了)。
//
// 重要限制: InfinityFree 的 MySQL 只能从"放在 InfinityFree 自己主机上的 PHP"连，外部机器
// (包括这台开发用的电脑) 连不到 sql304.infinityfree.com —— 这个文件必须实际上传到
// InfinityFree 才能连线成功，在本地 XAMPP 测试这个文件会连线失败(属预期，不是 bug)。
function get_db(): mysqli {
    static $conn = null;
    if ($conn === null) {
        $host = 'sql304.infinityfree.com';
        $port = 3306;
        $user = 'if0_43029692';
        $password = 'TgdtTHLQcH3NDX1'; // TODO: 移到环境变量，不要长期留在代码里
        $dbname = 'if0_43029692_personal_os';
        $conn = mysqli_connect($host, $user, $password, $dbname, $port);
        if (!$conn) {
            http_response_code(500);
            die(json_encode(['error' => 'DB connection failed: ' . mysqli_connect_error()]));
        }
        $conn->set_charset('utf8mb4');
    }
    return $conn;
}
