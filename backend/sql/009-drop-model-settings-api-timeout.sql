-- 009: 移除 model_settings.api_timeout 死设置
-- 背景：该字段自引入起未被任何执行链路消费（文本 LLM、图片/视频任务超时均为独立硬编码），
-- 在设置页展示会造成"可配置"的误解，故移除。

ALTER TABLE model_settings DROP COLUMN IF EXISTS api_timeout;
