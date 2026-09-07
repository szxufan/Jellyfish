-- 009: 移除 model_settings.api_timeout 死设置
-- 背景：该字段自引入起未被任何执行链路消费（文本 LLM、图片/视频任务超时均为独立硬编码），
-- 在设置页展示会造成"可配置"的误解，故移除。
-- 注意：MySQL 不支持 `DROP COLUMN IF EXISTS`，需通过 information_schema + PREPARE 幂等执行。

SET @has_api_timeout = (
  SELECT COUNT(*)
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = 'model_settings'
    AND COLUMN_NAME = 'api_timeout'
);

SET @drop_api_timeout = IF(
  @has_api_timeout = 1,
  'ALTER TABLE model_settings DROP COLUMN api_timeout',
  'SELECT 1'
);
PREPARE stmt_drop_api_timeout FROM @drop_api_timeout;
EXECUTE stmt_drop_api_timeout;
DEALLOCATE PREPARE stmt_drop_api_timeout;
