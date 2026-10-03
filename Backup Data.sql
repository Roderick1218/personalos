-- personal_os 全库备份 (2026-09-25 07:51:05)，包含所有用户的所有数据
SET FOREIGN_KEY_CHECKS=0;

DROP TABLE IF EXISTS `ai_conversations`;
CREATE TABLE `ai_conversations` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `title` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `ai_messages`;
CREATE TABLE `ai_messages` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `conversation_id` int(11) NOT NULL,
  `role` enum('user','assistant') NOT NULL,
  `content` mediumtext NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `conversation_id` (`conversation_id`),
  CONSTRAINT `ai_messages_ibfk_1` FOREIGN KEY (`conversation_id`) REFERENCES `ai_conversations` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `automations`;
CREATE TABLE `automations` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(100) NOT NULL,
  `trigger_type` varchar(50) NOT NULL,
  `trigger_config` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`trigger_config`)),
  `action_type` varchar(50) NOT NULL,
  `action_config` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`action_config`)),
  `is_active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `bank_accounts`;
CREATE TABLE `bank_accounts` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `bank_name` varchar(100) NOT NULL,
  `nickname` varchar(100) NOT NULL,
  `account_type` varchar(50) DEFAULT NULL,
  `account_kind` enum('bank','cash','ewallet') NOT NULL DEFAULT 'bank',
  `bank_id` int(11) DEFAULT NULL,
  `account_number` varchar(50) DEFAULT NULL,
  `opening_balance` decimal(12,2) NOT NULL DEFAULT 0.00,
  `is_active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `fk_account_bank` (`bank_id`),
  KEY `idx_bank_accounts_user_id` (`user_id`),
  CONSTRAINT `fk_account_bank` FOREIGN KEY (`bank_id`) REFERENCES `banks` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `bank_accounts` (`id`,`user_id`,`bank_name`,`nickname`,`account_type`,`account_kind`,`bank_id`,`account_number`,`opening_balance`,`is_active`,`created_at`) VALUES ('1','1','Maybank','主账户',NULL,'bank','1',NULL,'5000.00','1','2026-09-25 12:09:37');
INSERT INTO `bank_accounts` (`id`,`user_id`,`bank_name`,`nickname`,`account_type`,`account_kind`,`bank_id`,`account_number`,`opening_balance`,`is_active`,`created_at`) VALUES ('2','1','现金','手头现金',NULL,'cash',NULL,NULL,'0.00','1','2026-09-25 12:09:37');

DROP TABLE IF EXISTS `banks`;
CREATE TABLE `banks` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `name` varchar(100) NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_banks_user_id` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=16 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('1','1','Maybank','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('2','1','Public Bank','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('3','1','CIMB Bank','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('4','1','RHB Bank','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('5','1','Hong Leong Bank','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('6','1','AmBank','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('7','1','Bank Islam','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('8','1','Bank Rakyat','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('9','1','Alliance Bank','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('10','1','UOB','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('11','1','OCBC','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('12','1','HSBC','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('13','1','Standard Chartered','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('14','1','Bank Muamalat','2026-09-25 12:09:37');
INSERT INTO `banks` (`id`,`user_id`,`name`,`created_at`) VALUES ('15','1','Affin Bank','2026-09-25 12:09:37');

DROP TABLE IF EXISTS `bookmarks`;
CREATE TABLE `bookmarks` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `url` varchar(1000) NOT NULL,
  `title` varchar(255) DEFAULT NULL,
  `is_favorite` tinyint(1) NOT NULL DEFAULT 0,
  `tag_id` int(11) DEFAULT NULL,
  `tags` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`tags`)),
  `is_archived` tinyint(1) NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `fk_bookmark_tag` (`tag_id`),
  KEY `idx_bookmarks_user_id` (`user_id`),
  CONSTRAINT `fk_bookmark_tag` FOREIGN KEY (`tag_id`) REFERENCES `tags` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `bookmarks` (`id`,`user_id`,`url`,`title`,`is_favorite`,`tag_id`,`tags`,`is_archived`,`created_at`) VALUES ('1','1','https://web.whatsapp.com/','Whatsapp','0',NULL,NULL,'0','2026-09-25 14:14:28');
INSERT INTO `bookmarks` (`id`,`user_id`,`url`,`title`,`is_favorite`,`tag_id`,`tags`,`is_archived`,`created_at`) VALUES ('2','6','https://gemini.google.com/','Gemini','0',NULL,NULL,'0','2026-09-25 15:50:41');

DROP TABLE IF EXISTS `budgets`;
CREATE TABLE `budgets` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `category_id` int(11) DEFAULT NULL,
  `month` date NOT NULL COMMENT '存该月第一天, e.g. 2026-09-01',
  `amount` decimal(12,2) NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_category_month` (`category_id`,`month`),
  CONSTRAINT `budgets_ibfk_1` FOREIGN KEY (`category_id`) REFERENCES `categories` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `categories`;
CREATE TABLE `categories` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `name` varchar(100) NOT NULL,
  `type` enum('income','expense') NOT NULL,
  `color` varchar(20) DEFAULT NULL,
  `icon` varchar(50) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_categories_user_id` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=16 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('1','1','薪水','income','#22c55e',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('2','1','Freelance','income','#0EA5E9',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('3','1','Bonus','income','#F59E0B',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('4','1','Allowance','income','#14B8A6',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('5','1','Commission','income','#8B5CF6',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('6','1','Business','income','#EC4899',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('7','1','Interest','income','#22C55E',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('8','1','Fixed Deposit Interest','income','#22C55E',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('9','1','Dividend','income','#22C55E',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('10','1','Refund','income','#6B7280',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('11','1','Gift','income','#EF4444',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('12','1','餐饮','expense','#ef4444',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('13','1','交通','expense','#f59e0b',NULL,'2026-09-25 12:09:37');
INSERT INTO `categories` (`id`,`user_id`,`name`,`type`,`color`,`icon`,`created_at`) VALUES ('14','1','娱乐','expense','#8b5cf6',NULL,'2026-09-25 12:09:37');

DROP TABLE IF EXISTS `contacts`;
CREATE TABLE `contacts` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `name` varchar(100) NOT NULL,
  `birthday` date DEFAULT NULL,
  `remind_days_before` int(11) NOT NULL DEFAULT 3,
  `phone` varchar(30) DEFAULT NULL,
  `email` varchar(255) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `tags` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`tags`)),
  `last_contact_date` date DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_contacts_user_id` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `daily_metrics`;
CREATE TABLE `daily_metrics` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `metric_date` date NOT NULL,
  `weight_kg` decimal(5,2) DEFAULT NULL,
  `sleep_hours` decimal(4,2) DEFAULT NULL,
  `water_ml` int(11) DEFAULT NULL,
  `mood` tinyint(4) DEFAULT NULL COMMENT '1-5',
  `steps` int(11) DEFAULT NULL,
  `notes` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_user_metric_date` (`user_id`,`metric_date`),
  KEY `idx_daily_metrics_user_id` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `epf_contributions`;
CREATE TABLE `epf_contributions` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `salary_payment_id` int(11) DEFAULT NULL,
  `contribution_date` date NOT NULL,
  `employee_contribution` decimal(12,2) NOT NULL DEFAULT 0.00,
  `employer_contribution` decimal(12,2) NOT NULL DEFAULT 0.00,
  `additional_contribution` decimal(12,2) NOT NULL DEFAULT 0.00,
  `persaraan_percent` decimal(5,2) NOT NULL DEFAULT 75.00 COMMENT 'v4.9: 2024 新制度 Akaun Persaraan/Sejahtera/Fleksibel 三户口比例，默认75/15/10 (我所知的官方默认值，非100%保证，每笔可各自调整)',
  `sejahtera_percent` decimal(5,2) NOT NULL DEFAULT 15.00,
  `fleksibel_percent` decimal(5,2) NOT NULL DEFAULT 10.00,
  `persaraan_amount` decimal(12,2) NOT NULL DEFAULT 0.00,
  `sejahtera_amount` decimal(12,2) NOT NULL DEFAULT 0.00,
  `fleksibel_amount` decimal(12,2) NOT NULL DEFAULT 0.00,
  `notes` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `fk_epf_salary_payment` (`salary_payment_id`),
  KEY `idx_epf_contributions_user_id` (`user_id`),
  CONSTRAINT `fk_epf_salary_payment` FOREIGN KEY (`salary_payment_id`) REFERENCES `salary_payments` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `exercises`;
CREATE TABLE `exercises` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(100) NOT NULL,
  `category` varchar(50) DEFAULT NULL COMMENT '如 胸/背/腿/有氧',
  `notes` text DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `fixed_deposits`;
CREATE TABLE `fixed_deposits` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `bank_id` int(11) DEFAULT NULL,
  `principal` decimal(12,2) NOT NULL,
  `interest_rate` decimal(5,2) NOT NULL,
  `tenure_months` int(11) NOT NULL DEFAULT 3,
  `source_account_id` int(11) DEFAULT NULL,
  `opening_transaction_id` int(11) DEFAULT NULL,
  `start_date` date NOT NULL,
  `maturity_date` date DEFAULT NULL,
  `maturity_action` enum('transfer','renew') NOT NULL DEFAULT 'transfer',
  `destination_account_id` int(11) DEFAULT NULL,
  `status` enum('active','matured','withdrawn') NOT NULL DEFAULT 'active',
  `renewed_from_id` int(11) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_fixed_deposits_user_id` (`user_id`),
  KEY `idx_fixed_deposits_bank_id` (`bank_id`),
  KEY `idx_fixed_deposits_source_account` (`source_account_id`),
  KEY `idx_fixed_deposits_dest_account` (`destination_account_id`),
  KEY `idx_fixed_deposits_renewed_from` (`renewed_from_id`),
  KEY `fk_fd_opening_txn` (`opening_transaction_id`),
  CONSTRAINT `fk_fd_bank` FOREIGN KEY (`bank_id`) REFERENCES `banks` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_fd_dest_account` FOREIGN KEY (`destination_account_id`) REFERENCES `bank_accounts` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_fd_opening_txn` FOREIGN KEY (`opening_transaction_id`) REFERENCES `transactions` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_fd_renewed_from` FOREIGN KEY (`renewed_from_id`) REFERENCES `fixed_deposits` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_fd_source_account` FOREIGN KEY (`source_account_id`) REFERENCES `bank_accounts` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `goals`;
CREATE TABLE `goals` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `title` varchar(255) NOT NULL,
  `description` text DEFAULT NULL,
  `period_type` enum('year','quarter','month') NOT NULL,
  `period_value` varchar(20) NOT NULL COMMENT '如 2026, 2026-Q1, 2026-09',
  `status` enum('active','completed','abandoned') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `habit_logs`;
CREATE TABLE `habit_logs` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `habit_id` int(11) NOT NULL,
  `log_date` date NOT NULL,
  `completed` tinyint(1) NOT NULL DEFAULT 1,
  `note` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_habit_date` (`habit_id`,`log_date`),
  KEY `idx_habit_logs_user_id` (`user_id`),
  CONSTRAINT `habit_logs_ibfk_1` FOREIGN KEY (`habit_id`) REFERENCES `habits` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `habits`;
CREATE TABLE `habits` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `name` varchar(100) NOT NULL,
  `description` text DEFAULT NULL,
  `frequency` enum('daily','weekly','custom') NOT NULL DEFAULT 'daily',
  `target_per_week` int(11) DEFAULT NULL,
  `color` varchar(20) DEFAULT NULL,
  `is_active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_habits_user_id` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=4 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `habits` (`id`,`user_id`,`name`,`description`,`frequency`,`target_per_week`,`color`,`is_active`,`created_at`) VALUES ('1','1','喝水 2L',NULL,'daily','7',NULL,'1','2026-09-25 12:09:37');
INSERT INTO `habits` (`id`,`user_id`,`name`,`description`,`frequency`,`target_per_week`,`color`,`is_active`,`created_at`) VALUES ('2','1','运动',NULL,'weekly','3',NULL,'1','2026-09-25 12:09:37');
INSERT INTO `habits` (`id`,`user_id`,`name`,`description`,`frequency`,`target_per_week`,`color`,`is_active`,`created_at`) VALUES ('3','1','阅读 30 分钟',NULL,'daily','7',NULL,'1','2026-09-25 12:09:37');

DROP TABLE IF EXISTS `inbox_items`;
CREATE TABLE `inbox_items` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `content` varchar(500) NOT NULL,
  `item_type` enum('task','idea','note') NOT NULL DEFAULT 'note',
  `is_processed` tinyint(1) NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_inbox_items_user_id` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `interactions`;
CREATE TABLE `interactions` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `contact_id` int(11) NOT NULL,
  `interaction_date` date NOT NULL,
  `interaction_type` enum('call','meet','message','gift','other') NOT NULL DEFAULT 'other',
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `contact_id` (`contact_id`),
  CONSTRAINT `interactions_ibfk_1` FOREIGN KEY (`contact_id`) REFERENCES `contacts` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `journal_entries`;
CREATE TABLE `journal_entries` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `entry_date` date NOT NULL,
  `content` mediumtext DEFAULT NULL,
  `mood` tinyint(4) DEFAULT NULL COMMENT '1-5',
  `tags` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`tags`)),
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_user_entry_date` (`user_id`,`entry_date`),
  KEY `idx_journal_entries_user_id` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `key_results`;
CREATE TABLE `key_results` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `goal_id` int(11) NOT NULL,
  `title` varchar(255) NOT NULL,
  `target_value` decimal(12,2) DEFAULT NULL,
  `current_value` decimal(12,2) NOT NULL DEFAULT 0.00,
  `unit` varchar(30) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `goal_id` (`goal_id`),
  CONSTRAINT `key_results_ibfk_1` FOREIGN KEY (`goal_id`) REFERENCES `goals` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `learning_logs`;
CREATE TABLE `learning_logs` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `skill_id` int(11) NOT NULL,
  `log_date` date NOT NULL,
  `duration_minutes` int(11) NOT NULL,
  `notes` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `skill_id` (`skill_id`),
  CONSTRAINT `learning_logs_ibfk_1` FOREIGN KEY (`skill_id`) REFERENCES `skills` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `media_entries`;
CREATE TABLE `media_entries` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `title` varchar(255) NOT NULL,
  `media_type` enum('book','movie','tv','game') NOT NULL,
  `status` enum('planned','in_progress','completed','dropped') NOT NULL DEFAULT 'planned',
  `rating` tinyint(4) DEFAULT NULL COMMENT '1-10',
  `started_at` date DEFAULT NULL,
  `finished_at` date DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `pantry_items`;
CREATE TABLE `pantry_items` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(100) NOT NULL,
  `quantity` decimal(10,2) DEFAULT NULL,
  `unit` varchar(20) DEFAULT NULL,
  `expiry_date` date DEFAULT NULL,
  `notes` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `profiles`;
CREATE TABLE `profiles` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `display_name` varchar(100) DEFAULT NULL,
  `timezone` varchar(50) DEFAULT 'Asia/Kuala_Lumpur',
  `locale` varchar(10) DEFAULT 'zh-CN',
  `avatar_text` varchar(10) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `profiles` (`id`,`display_name`,`timezone`,`locale`,`avatar_text`,`created_at`,`updated_at`) VALUES ('1','WHB User','Asia/Kuala_Lumpur','zh-CN',NULL,'2026-09-25 12:09:37','2026-09-25 12:09:37');

DROP TABLE IF EXISTS `project_categories`;
CREATE TABLE `project_categories` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `name` varchar(100) NOT NULL,
  `color` varchar(20) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_project_categories_user_id` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `project_categories` (`id`,`user_id`,`name`,`color`) VALUES ('1','1','Coding','#2B7BB9');
INSERT INTO `project_categories` (`id`,`user_id`,`name`,`color`) VALUES ('2','1','学习','#22c55e');
INSERT INTO `project_categories` (`id`,`user_id`,`name`,`color`) VALUES ('3','1','游戏','#8b5cf6');
INSERT INTO `project_categories` (`id`,`user_id`,`name`,`color`) VALUES ('4','1','生活','#f59e0b');

DROP TABLE IF EXISTS `projects`;
CREATE TABLE `projects` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `name` varchar(100) NOT NULL,
  `description` text DEFAULT NULL,
  `category_id` int(11) DEFAULT NULL,
  `link` varchar(500) DEFAULT NULL,
  `status` enum('active','completed','archived') NOT NULL DEFAULT 'active',
  `color` varchar(20) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_projects_user_id` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `reading_logs`;
CREATE TABLE `reading_logs` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `media_entry_id` int(11) NOT NULL,
  `log_date` date NOT NULL,
  `progress_note` varchar(255) DEFAULT NULL,
  `progress_amount` int(11) DEFAULT NULL COMMENT '页数/分钟数，看 media_type 决定单位',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `media_entry_id` (`media_entry_id`),
  CONSTRAINT `reading_logs_ibfk_1` FOREIGN KEY (`media_entry_id`) REFERENCES `media_entries` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `recipes`;
CREATE TABLE `recipes` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `title` varchar(255) NOT NULL,
  `ingredients` text DEFAULT NULL,
  `instructions` text DEFAULT NULL,
  `tags` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`tags`)),
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `recurrence_rules`;
CREATE TABLE `recurrence_rules` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `template_id` int(11) DEFAULT NULL,
  `related_type` enum('task','habit','journal','custom') NOT NULL,
  `related_id` int(11) DEFAULT NULL,
  `rule` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL COMMENT '例如 {"freq":"weekly","interval":1,"days":["mon","wed"]}' CHECK (json_valid(`rule`)),
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `template_id` (`template_id`),
  CONSTRAINT `recurrence_rules_ibfk_1` FOREIGN KEY (`template_id`) REFERENCES `templates` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `reminders`;
CREATE TABLE `reminders` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `related_type` enum('task','habit','subscription','custom') NOT NULL,
  `related_id` int(11) DEFAULT NULL,
  `related_note` varchar(255) DEFAULT NULL COMMENT 'v4.6: 关联类型=custom 时用来自由填写具体是什么事，related_id 对自定义类型没有意义',
  `remind_at` datetime NOT NULL COMMENT 'v4.6: 表单只填几点 (HH:MM)，日期由 api.php 自动算好拼上去，见 create/update 里的特殊处理',
  `message` varchar(255) NOT NULL,
  `is_sent` tinyint(1) NOT NULL DEFAULT 0,
  `repeat_rule` enum('none','daily','weekly','biweekly','monthly','yearly','custom') NOT NULL DEFAULT 'none' COMMENT 'v4.5: 标记已发送或时间过了没处理时，会自动把 remind_at 推到下一次',
  `repeat_interval` int(11) DEFAULT NULL COMMENT '只在 repeat_rule=custom 时用，配合 repeat_unit',
  `repeat_unit` enum('day','week','month','year') DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_reminders_user_id` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `reports`;
CREATE TABLE `reports` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `report_type` enum('weekly','monthly','yearly') NOT NULL,
  `period_start` date NOT NULL,
  `period_end` date NOT NULL,
  `content` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL COMMENT '汇总后的任务/习惯/财务/健康数据' CHECK (json_valid(`content`)),
  `generated_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_reports_period` (`user_id`,`report_type`,`period_start`,`period_end`),
  KEY `idx_reports_user_id` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `salary_payments`;
CREATE TABLE `salary_payments` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `salary_profile_id` int(11) DEFAULT NULL COMMENT '没有挂档案也可以单独记一笔 (比如自由职业收入)',
  `payment_date` date NOT NULL,
  `period_label` varchar(50) NOT NULL COMMENT '如 2026-09 / September 2026',
  `period_start` date DEFAULT NULL COMMENT '入职/离职当月不足整月时填，配合止薪日按比例算基本薪资',
  `period_end` date DEFAULT NULL,
  `basic_salary` decimal(12,2) NOT NULL DEFAULT 0.00,
  `allowance` decimal(12,2) NOT NULL DEFAULT 0.00,
  `bonus` decimal(12,2) NOT NULL DEFAULT 0.00,
  `commission` decimal(12,2) NOT NULL DEFAULT 0.00,
  `other_addition` decimal(12,2) NOT NULL DEFAULT 0.00,
  `employee_epf_percent` decimal(5,2) NOT NULL DEFAULT 0.00 COMMENT '这笔当时用的百分比，之后改默认值不影响这里',
  `employee_epf_amount` decimal(12,2) NOT NULL DEFAULT 0.00,
  `employer_epf_percent` decimal(5,2) NOT NULL DEFAULT 0.00,
  `employer_epf_amount` decimal(12,2) NOT NULL DEFAULT 0.00,
  `other_deductions` decimal(12,2) NOT NULL DEFAULT 0.00,
  `net_salary` decimal(12,2) NOT NULL COMMENT '实际入账金额',
  `bank_account_id` int(11) NOT NULL,
  `status` enum('draft','pending','paid','cancelled') NOT NULL DEFAULT 'paid' COMMENT 'v4: 只有 paid 才计入 transactions/epf_contributions，其余状态不影响实际余额',
  `transaction_id` int(11) DEFAULT NULL COMMENT '自动生成的那笔收入交易，删/改这笔发薪记录时会跟着同步',
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `fk_salary_payment_profile` (`salary_profile_id`),
  KEY `fk_salary_payment_bank` (`bank_account_id`),
  KEY `fk_salary_payment_txn` (`transaction_id`),
  KEY `idx_salary_payments_user_id` (`user_id`),
  CONSTRAINT `fk_salary_payment_bank` FOREIGN KEY (`bank_account_id`) REFERENCES `bank_accounts` (`id`),
  CONSTRAINT `fk_salary_payment_profile` FOREIGN KEY (`salary_profile_id`) REFERENCES `salary_profiles` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_salary_payment_txn` FOREIGN KEY (`transaction_id`) REFERENCES `transactions` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `salary_profiles`;
CREATE TABLE `salary_profiles` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `company_name` varchar(150) NOT NULL,
  `position` varchar(150) DEFAULT NULL,
  `basic_salary` decimal(12,2) NOT NULL DEFAULT 0.00,
  `salary_frequency` enum('monthly','biweekly','weekly','custom') NOT NULL DEFAULT 'monthly',
  `salary_payment_day` tinyint(4) DEFAULT NULL COMMENT '每月发薪日 1-31，随意频率可留空',
  `bank_account_id` int(11) DEFAULT NULL,
  `employee_epf_percent` decimal(5,2) NOT NULL DEFAULT 11.00,
  `employer_epf_percent` decimal(5,2) NOT NULL DEFAULT 13.00,
  `start_date` date NOT NULL,
  `end_date` date DEFAULT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `fk_salary_profile_bank` (`bank_account_id`),
  KEY `idx_salary_profiles_user_id` (`user_id`),
  CONSTRAINT `fk_salary_profile_bank` FOREIGN KEY (`bank_account_id`) REFERENCES `bank_accounts` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `settings`;
CREATE TABLE `settings` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `key` varchar(100) NOT NULL,
  `value` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`value`)),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_setting_key` (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `shopping_list`;
CREATE TABLE `shopping_list` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `item_name` varchar(100) NOT NULL,
  `quantity` varchar(50) DEFAULT NULL,
  `is_purchased` tinyint(1) NOT NULL DEFAULT 0,
  `notes` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `skills`;
CREATE TABLE `skills` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(100) NOT NULL,
  `category` varchar(50) DEFAULT NULL,
  `target_hours` decimal(8,2) DEFAULT NULL,
  `current_hours` decimal(8,2) NOT NULL DEFAULT 0.00,
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `subscriptions`;
CREATE TABLE `subscriptions` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `name` varchar(100) NOT NULL,
  `cost` decimal(10,2) NOT NULL,
  `bank_account_id` int(11) DEFAULT NULL,
  `start_date` date DEFAULT NULL,
  `billing_cycle` enum('monthly','yearly') NOT NULL DEFAULT 'monthly',
  `next_billing_date` date DEFAULT NULL,
  `remind_days_before` int(11) NOT NULL DEFAULT 3,
  `category` varchar(50) DEFAULT NULL,
  `is_active` tinyint(1) NOT NULL DEFAULT 1,
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_subscriptions_user_id` (`user_id`),
  KEY `bank_account_id` (`bank_account_id`),
  CONSTRAINT `fk_subscriptions_bank_account` FOREIGN KEY (`bank_account_id`) REFERENCES `bank_accounts` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `tags`;
CREATE TABLE `tags` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `name` varchar(100) NOT NULL,
  `color` varchar(20) DEFAULT NULL,
  `module` enum('finance','task','link') NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_tags_user_id` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `tags` (`id`,`user_id`,`name`,`color`,`module`,`created_at`) VALUES ('1','1','Important','#f59e0b','task','2026-09-25 12:09:37');
INSERT INTO `tags` (`id`,`user_id`,`name`,`color`,`module`,`created_at`) VALUES ('2','1','Tools','#2B7BB9','link','2026-09-25 12:09:37');
INSERT INTO `tags` (`id`,`user_id`,`name`,`color`,`module`,`created_at`) VALUES ('3','1','Learning','#22c55e','link','2026-09-25 12:09:37');
INSERT INTO `tags` (`id`,`user_id`,`name`,`color`,`module`,`created_at`) VALUES ('4','1','Games','#8b5cf6','link','2026-09-25 12:09:37');

DROP TABLE IF EXISTS `tasks`;
CREATE TABLE `tasks` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `project_id` int(11) DEFAULT NULL,
  `tag_id` int(11) DEFAULT NULL,
  `title` varchar(255) NOT NULL,
  `description` text DEFAULT NULL,
  `status` enum('inbox','today','upcoming','done') NOT NULL DEFAULT 'inbox',
  `priority` enum('low','medium','high','urgent') NOT NULL DEFAULT 'medium',
  `due_date` date DEFAULT NULL,
  `completed_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `project_id` (`project_id`),
  KEY `fk_task_tag` (`tag_id`),
  KEY `idx_tasks_user_id` (`user_id`),
  CONSTRAINT `fk_task_tag` FOREIGN KEY (`tag_id`) REFERENCES `tags` (`id`) ON DELETE SET NULL,
  CONSTRAINT `tasks_ibfk_1` FOREIGN KEY (`project_id`) REFERENCES `projects` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `templates`;
CREATE TABLE `templates` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `template_type` enum('task','habit','journal') NOT NULL,
  `name` varchar(100) NOT NULL,
  `content` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL CHECK (json_valid(`content`)),
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `time_blocks`;
CREATE TABLE `time_blocks` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `block_date` date NOT NULL,
  `start_time` time NOT NULL,
  `end_time` time NOT NULL,
  `title` varchar(255) NOT NULL,
  `task_id` int(11) DEFAULT NULL,
  `planned` tinyint(1) NOT NULL DEFAULT 1 COMMENT '1=计划, 0=实际回顾记录',
  `actual_note` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `task_id` (`task_id`),
  CONSTRAINT `time_blocks_ibfk_1` FOREIGN KEY (`task_id`) REFERENCES `tasks` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `transactions`;
CREATE TABLE `transactions` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 1,
  `category_id` int(11) DEFAULT NULL,
  `bank_account_id` int(11) DEFAULT NULL,
  `transfer_to_account_id` int(11) DEFAULT NULL,
  `tag_id` int(11) DEFAULT NULL,
  `type` enum('income','expense','transfer') NOT NULL,
  `amount` decimal(12,2) NOT NULL,
  `currency` varchar(10) NOT NULL DEFAULT 'MYR',
  `description` varchar(255) DEFAULT NULL,
  `transaction_date` date NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `category_id` (`category_id`),
  KEY `fk_txn_bank_account` (`bank_account_id`),
  KEY `fk_txn_transfer_to` (`transfer_to_account_id`),
  KEY `fk_txn_tag` (`tag_id`),
  KEY `idx_transactions_user_id` (`user_id`),
  CONSTRAINT `fk_txn_bank_account` FOREIGN KEY (`bank_account_id`) REFERENCES `bank_accounts` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_txn_tag` FOREIGN KEY (`tag_id`) REFERENCES `tags` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_txn_transfer_to` FOREIGN KEY (`transfer_to_account_id`) REFERENCES `bank_accounts` (`id`) ON DELETE SET NULL,
  CONSTRAINT `transactions_ibfk_1` FOREIGN KEY (`category_id`) REFERENCES `categories` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `trip_items`;
CREATE TABLE `trip_items` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `trip_id` int(11) NOT NULL,
  `item_type` enum('itinerary','expense','checklist') NOT NULL,
  `title` varchar(255) NOT NULL,
  `item_date` date DEFAULT NULL,
  `amount` decimal(12,2) DEFAULT NULL,
  `is_done` tinyint(1) NOT NULL DEFAULT 0,
  `notes` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `trip_id` (`trip_id`),
  CONSTRAINT `trip_items_ibfk_1` FOREIGN KEY (`trip_id`) REFERENCES `trips` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `trips`;
CREATE TABLE `trips` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `title` varchar(255) NOT NULL,
  `destination` varchar(255) DEFAULT NULL,
  `start_date` date DEFAULT NULL,
  `end_date` date DEFAULT NULL,
  `budget` decimal(12,2) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `users`;
CREATE TABLE `users` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `username` varchar(50) NOT NULL,
  `password_hash` varchar(255) NOT NULL,
  `display_name` varchar(100) DEFAULT NULL,
  `role` enum('admin','user') NOT NULL DEFAULT 'user',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_username` (`username`)
) ENGINE=InnoDB AUTO_INCREMENT=7 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `users` (`id`,`username`,`password_hash`,`display_name`,`role`,`created_at`) VALUES ('1','Roderick','$2y$10$lirEi/7bBcqkeNJ4kSOZ1eWJAJSZ8qR.mueoGwa3Cj50gqbKMmFZi','Roderick','admin','2026-09-25 12:09:37');
INSERT INTO `users` (`id`,`username`,`password_hash`,`display_name`,`role`,`created_at`) VALUES ('6','Testing','$2y$10$Zri/gn6cIv61A4HtxUIVkezJmca0rX2JP.XKBjCcOfIz4TpcQJa82','Testing','user','2026-09-25 15:49:34');

DROP TABLE IF EXISTS `webhook_logs`;
CREATE TABLE `webhook_logs` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `automation_id` int(11) DEFAULT NULL,
  `payload` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`payload`)),
  `status` enum('success','failed') NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `automation_id` (`automation_id`),
  CONSTRAINT `webhook_logs_ibfk_1` FOREIGN KEY (`automation_id`) REFERENCES `automations` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `workout_sets`;
CREATE TABLE `workout_sets` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `workout_id` int(11) NOT NULL,
  `exercise_id` int(11) NOT NULL,
  `set_number` int(11) NOT NULL,
  `reps` int(11) DEFAULT NULL,
  `weight_kg` decimal(6,2) DEFAULT NULL,
  `rest_seconds` int(11) DEFAULT NULL,
  `notes` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `workout_id` (`workout_id`),
  KEY `exercise_id` (`exercise_id`),
  CONSTRAINT `workout_sets_ibfk_1` FOREIGN KEY (`workout_id`) REFERENCES `workouts` (`id`) ON DELETE CASCADE,
  CONSTRAINT `workout_sets_ibfk_2` FOREIGN KEY (`exercise_id`) REFERENCES `exercises` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP TABLE IF EXISTS `workouts`;
CREATE TABLE `workouts` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `workout_date` date NOT NULL,
  `name` varchar(100) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SET FOREIGN_KEY_CHECKS=1;
