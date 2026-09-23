<?php
// XAMPP 本地测试连接 (见 memory: 这台机器有两个 MySQL, XAMPP 自己的 MariaDB 跑在 3307)
function get_db(): mysqli {
    static $conn = null;
    if ($conn === null) {
        $conn = new mysqli('127.0.0.1', 'root', '', 'personal_os', 3307);
        if ($conn->connect_error) {
            http_response_code(500);
            die(json_encode(['error' => 'DB connection failed: ' . $conn->connect_error]));
        }
        $conn->set_charset('utf8mb4');
    }
    return $conn;
}
