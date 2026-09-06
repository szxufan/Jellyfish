# `/v1/videos` 视频生成 API 文档

> 面向调用方。设计背景与内部实现见 [video-generation-mode-design.md](./video-generation-mode-design.md)。
> 本文档已包含「模式统一契约」阶段 1 的能力：**统一 metadata 具名键**。

## 1. 端点总览

| 方法 | 路径                              | 说明                            |
| ---- | --------------------------------- | ------------------------------- |
| POST | `/v1/videos`                      | 提交视频生成任务（OpenAI 兼容） |
| GET  | `/v1/videos/{task_id}`            | 查询任务状态与结果              |
| POST | `/v1/videos/{video_id}/remix`     | 基于已有视频二创（remix）       |
| GET  | `/v1/videos/{task_id}/content`    | 视频内容代理（结果文件流）      |
| POST | `/v1/video/generations`           | 旧版提交端点（兼容保留）        |
| GET  | `/v1/video/generations/{task_id}` | 旧版查询端点（兼容保留）        |

认证：`Authorization: Bearer sk-xxxx`。

## 2. 提交任务（POST `/v1/videos`）

### 2.1 请求体字段

| 字段              | 类型           | 必填   | 说明                                                    |
| ----------------- | -------------- | ------ | ------------------------------------------------------- |
| `model`           | string         | 是     | 模型名（路由到对应渠道）                                |
| `prompt`          | string         | 视渠道 | 文本提示词                                              |
| `image`           | string         | 否     | 单图输入（URL 或 Base64）                               |
| `images`          | striactionng[] | 否     | 多图输入（URL 数组），按数量隐式推导模式，见 §2.3       |
| `input_reference` | string         | 否     | 参考素材（OpenAI 兼容字段），按首帧处理                 |
| `duration`        | int            | 否     | 视频时长（秒）                                          |
| `seconds`         | string         | 否     | 时长（字符串形式，部分渠道如豆包使用）                  |
| `size`            | string         | 否     | 分辨率 / 宽高（渠道相关，如 `1280x720`、`1080p`）       |
| `mode`            | string         | 否     | **可灵清晰度档位**（`std` / `pro`）。注意：不是生成模式 |
| `metadata`        | object         | 否     | 渠道参数透传 + 统一具名键（见 §2.2）                    |

分辨率档位按模型族收敛（经 `metadata.parameters.resolution` 下发，覆盖发生在请求转换末尾）：

| 模型族          | 支持档位                               |
| --------------- | -------------------------------------- |
| 百炼 MiniMax    | `768P`（默认）/ `2K`                   |
| 百炼 HappyHorse | `720P` / `1080P`                       |
| 百炼万相系列    | `480P` / `720P` / `1080P`              |
| 其余渠道        | 渠道相关（`size` / 渠道私有 metadata） |

MiniMax 的档位也可由 `size` 推导（`2K`/`1080P`/`1920*1080` 等 → 2K 档；`720P`/`768P`/`1280*720` 等 → 768P 档；比例串如 `16:9` 不决定档位）。

### 2.2 统一素材具名键（`metadata` 内）

跨渠道统一的显式指定入口。**不传这些键时，行为与历史版本完全一致。**

| 键                  | 类型     | 语义                         |
| ------------------- | -------- | ---------------------------- |
| `first_frame_image` | string   | 首帧图                       |
| `last_frame_image`  | string   | 尾帧图                       |
| `reference_images`  | string[] | 参考图列表（兼容单个字符串） |
| `reference_videos`  | string[] | 参考视频列表                 |
| `reference_audios`  | string[] | 参考音频列表                 |

解析优先级：

```
逃生通道（metadata.input.media / metadata.content 整体覆盖，原样透传）
  → metadata 具名键（半显式）
    → images 数量推导（隐式，现状逻辑）
      → input_reference / image（隐式）
        → text2video
```

### 2.3 隐式模式推导（不传具名键时，现状行为）

| 输入    | vidu   | hailuo v2 | 百炼 MiniMax | 百炼万相3.0 | 即梦   | 可灵     |
| ------- | ------ | --------- | ------------ | ----------- | ------ | -------- |
| 1 张图  | 首帧   | 首帧      | 首帧         | 首帧        | 首帧   | 首帧     |
| 2 张图  | 首尾帧 | 首尾帧    | 首尾帧       | **参考图**  | 首尾帧 | 仅用首张 |
| ≥3 张图 | 参考   | 参考      | 参考         | 参考        | 首尾帧 | 仅用首张 |

注意两点渠道差异：

- **万相3.0**：2 张图是「2 个参考图」而非首尾帧（历史语义，保留）。需要首尾帧语义时请改用具名键。
- **可灵**：隐式路径只用首张图；尾帧必须经 `last_frame_image` 显式指定。

互斥约束（首尾帧与参考素材并存时）：

- 百炼 MiniMax：**丢弃**首尾帧，保留参考素材
- 海螺 v2：首尾帧**降级为参考图**，保留素材
- 显式具名键触发互斥时按上述渠道策略收敛并记录系统日志

### 2.4 具名键渠道支持矩阵

| 渠道            | `first_frame_image` | `last_frame_image` | `reference_images`     | `reference_videos` | `reference_audios` |
| --------------- | ------------------- | ------------------ | ---------------------- | ------------------ | ------------------ |
| hailuo v2       | ✅                  | ✅                 | ✅                     | ✅                 | ✅                 |
| 百炼 MiniMax    | ✅                  | ✅                 | ✅                     | ✅                 | ✅                 |
| 百炼万相3.0     | ✅                  | ❌                 | ✅                     | ❌                 | ❌                 |
| 百炼 HappyHorse | ✅（i2v）           | ❌                 | ✅（r2v / video-edit） | ❌                 | ❌                 |
| 可灵            | ✅                  | ✅                 | ❌                     | ❌                 | ❌                 |
| vidu            | ✅                  | ✅                 | ✅                     | ❌                 | ❌                 |
| 豆包            | ✅                  | ✅                 | ✅                     | ✅                 | ✅                 |

未列出的渠道（hailuo v1、gemini/vertex、sora 等）暂不支持具名键：
hailuo v1 经 `metadata` 原样透传上游字段；sora 原样透传请求体；gemini/vertex 仅支持单图。

### 2.5 请求示例

**文生视频**

```bash
curl -X POST https://your.domain/v1/videos \
  -H "Authorization: Bearer sk-xxxx" -H "Content-Type: application/json" \
  -d '{"model":"viduq2","prompt":"镜头缓慢推进","duration":5}'
```

**首尾帧插值（显式，推荐）**

```bash
curl -X POST https://your.domain/v1/videos \
  -H "Authorization: Bearer sk-xxxx" -H "Content-Type: application/json" \
  -d '{
    "model":"MiniMax/MiniMax-H3",
    "prompt":"镜头缓慢推进",
    "metadata":{
      "first_frame_image":"https://example.com/a.png",
      "last_frame_image":"https://example.com/b.png"
    }
  }'
```

**参考生视频（图 + 视频 + 音频）**

```bash
curl -X POST https://your.domain/v1/videos \
  -H "Authorization: Bearer sk-xxxx" -H "Content-Type: application/json" \
  -d '{
    "model":"MiniMax/MiniMax-H3",
    "prompt":"角色跟随节奏起舞",
    "metadata":{
      "reference_images":["https://example.com/char1.png","https://example.com/char2.png"],
      "reference_videos":["https://example.com/motion.mp4"],
      "reference_audios":["https://example.com/bgm.mp3"]
    }
  }'
```

**可灵尾帧（显式）**

```bash
curl -X POST https://your.domain/v1/videos \
  -H "Authorization: Bearer sk-xxxx" -H "Content-Type: application/json" \
  -d '{
    "model":"kling-v2-master",
    "prompt":"花朵绽放",
    "metadata":{
      "first_frame_image":"https://example.com/bud.png",
      "last_frame_image":"https://example.com/bloom.png"
    }
  }'
```

**兼容：`images` 数量推导（不传具名键，行为不变）**

```bash
curl -X POST https://your.domain/v1/videos \
  -H "Authorization: Bearer sk-xxxx" -H "Content-Type: application/json" \
  -d '{"model":"viduq2","prompt":"p","images":["https://example.com/a.png","https://example.com/b.png"]}'
```

### 2.6 提交响应

响应体跟随各上游格式，其中任务 ID 统一替换为本系统公开 ID（`task_` 前缀）。示例（OpenAI 风格渠道）：

```json
{
  "id": "task_20260829_abcd1234",
  "object": "video",
  "model": "sora-2",
  "status": "queued",
  "created_at": 1756454400
}
```

## 3. 查询任务（GET `/v1/videos/{task_id}`）

返回 OpenAI Video 对象：

| 字段           | 类型   | 说明                                              |
| -------------- | ------ | ------------------------------------------------- |
| `id`           | string | 公开任务 ID                                       |
| `object`       | string | 固定 `video`                                      |
| `model`        | string | 模型名                                            |
| `status`       | string | `queued` / `in_progress` / `completed` / `failed` |
| `progress`     | int    | 进度百分比                                        |
| `created_at`   | int64  | 创建时间（unix 秒）                               |
| `completed_at` | int64  | 完成时间                                          |
| `error`        | object | 失败信息 `{code, message}`                        |
| `metadata`     | object | 结果元数据（含视频地址等，渠道相关）              |

```bash
curl https://your.domain/v1/videos/task_20260829_abcd1234 \
  -H "Authorization: Bearer sk-xxxx"
```

视频文件可经 `GET /v1/videos/{task_id}/content` 代理获取。

## 4. 错误格式

```json
{ "code": "invalid_action", "message": "...", "data": null }
```

常见错误：

| HTTP | code                      | 场景                                                                                                           |
| ---- | ------------------------- | -------------------------------------------------------------------------------------------------------------- | ------ |
| 400  | `invalid_action`          | vidu `metadata.action` 非法（合法值：`textGenerate` / `generate` / `firstTailGenerate` / `referenceGenerate`） | action |
| 400  | `invalid_request`         | 请求体解析失败 / 缺少必要字段                                                                                  |
| 400  | `task_not_exist`          | 查询不存在的任务                                                                                               |
| 401  | —                         | 未授权                                                                                                         |
| 500  | `build_request_failed` 等 | 内部错误                                                                                                       |

## 5. 兼容性说明

- **零回归**：不传 §2.2 具名键时，所有请求行为与历史版本完全一致。
- **逃生通道保留**：`metadata.input.media`（百炼）、`metadata.content`（海螺/豆包）整体覆盖上游请求体的用法继续支持，且优先级最高。
- **`metadata.action`（vidu）**：继续支持，但已有白名单校验（非法值返回 400）；与具名键并存时以 `metadata.action` 优先。后续版本可能标记 deprecated，建议迁移到具名键。
- **`mode` 字段**：仅用于可灵清晰度档位，请勿用于表达生成模式。
