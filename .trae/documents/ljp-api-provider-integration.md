# 新增 ljp-api 供应商（文生视频具名键 + OpenAI 兼容图片/文本）实施计划

## Summary

新增内置供应商 `ljp_api`（网关名 ljp-api）：

- **视频**：独立集成 `app/core/integrations/ljp_api/`，对接网关 `POST /videos` + `GET /videos/{task_id}`（OpenAI 风格生命周期），支持统一素材具名键（`first_frame_image` / `last_frame_image` / `reference_images` / `reference_videos` / `reference_audios`）与 vidu `metadata.action` 白名单校验+自动推导。
- **图片**：网关图片为标准 OpenAI 兼容 `/v1/images`，直接复用 `OpenAIImageGenerationTask`，不写重复实现。
- **文本**：`ChatOpenAI` 构建链路本身 provider 无关，仅需 `ProviderSpec` 声明 text 类别。
- **业务接入**：studio 镜头视频 `build_run_args` 同步填充具名键字段（data URL），openai / volcengine 行为零变化。

依据：`docs/video-api.md`（网关 API 文档）+ `site/content/docs/guide/llm-provider-registration.md`（项目自带的新增供应商 SOP）。

## 现状分析（Phase 1 探索结论）

接线链路共 6 个注册点（新供应商必须全部对齐，缺一即运行时报错）：

1. `ProviderKey` Literal（`backend/app/core/contracts/provider.py:8`）——目前仅 `openai` / `volcengine`。
2. `ProviderSpec` 注册（`backend/app/services/llm/provider_bootstrap.py`）——key/别名/类别/默认 base_url。
3. 任务适配器注册（`backend/app/core/tasks/bootstrap.py` 的 `TASK_ADAPTER_SPECS`）——`(task_kind, provider_key) → 工厂`。
4. 能力分派 if/else（`backend/app/core/integrations/video_capabilities.py` 与 `image_capabilities.py` 的 `register/clear/resolve` 三组函数）——**else 分支默认落 volcengine**，新 key 不加分支会解析到错误能力。
5. 下载鉴权分支（`backend/app/services/film/generated_video.py:212`）——`if provider == "openai"` 才带 Bearer 头。
6. 网关响应差异：错误体为 `{code, message, data}`；任务 ID 为 `task_` 前缀；状态机 `queued/in_progress/completed/failed` 与 OpenAI 相同。

已确认无 DB 迁移（`providers` 表结构不变）、无前端硬编码枚举（ProvidersTab/ModelsTab 动态消费 `/llm/providers/supported`）、无 OpenAPI/generated client 变更（`ProviderSupportedRead` schema 不变，仅数据新增条目）。

## 改动清单

### A. 契约层（共享，可选字段零破坏）

**A1. `backend/app/core/contracts/provider.py`**
- `ProviderKey = Literal["openai", "volcengine", "ljp_api"]`。

**A2. `backend/app/core/contracts/video_generation.py` — `VideoGenerationInput` 增加字段**

```python
first_frame_image: Optional[str] = None      # 具名键：首帧（URL / data URL）
last_frame_image: Optional[str] = None       # 具名键：尾帧
reference_images: Optional[list[str]] = None # 具名键：参考图列表
reference_videos: Optional[list[str]] = None # 具名键：参考视频列表
reference_audios: Optional[list[str]] = None # 具名键：参考音频列表
metadata: Optional[dict[str, Any]] = None    # 网关逃生通道原样透传（如 metadata.input.media / metadata.content / metadata.action）
```

- `require_prompt_or_any_reference` 校验器扩展：任一具名键有值即视为"有参考素材"，不再强制 prompt。
- 新字段全部 Optional 且默认 None：openai / volcengine payload 不读取它们，老调用方行为逐字节不变（`extra="forbid"` 不受影响）。

### B. ljp_api 集成层（新目录 `backend/app/core/integrations/ljp_api/`）

**B1. `__init__.py`** — 空模块标记。

**B2. `video_payload.py` — `build_create_video_body(input_) -> dict`**

构建规则（对应网关文档 §2）：

```python
body = {"prompt": input_.prompt or ""}
body["model"] = input_.model              # 有值才写（网关按 model 路由渠道）
size = derive_provider_size(provider="ljp_api", model=..., ratio=...)  # 有值才写
body["duration"] = int(seconds)            # seconds 有值才写
body["seconds"] = str(int(seconds))        # 豆包渠道字符串形式，同上
seed / watermark 有值才写（顶层字段）

metadata: dict[str, Any] = {}
# 1) 一等具名键直映：first_frame_image / last_frame_image / reference_images / reference_videos / reference_audios
# 2) base64 帧字段降级映射（build_run_args 老路径兜底，具名键未占用时生效）：
#    first_frame_base64 -> metadata.first_frame_image（to_image_data_url 转 data URL）
#    last_frame_base64  -> metadata.last_frame_image
#    key_frame_base64   -> metadata.reference_images 首元素（网关无 key 帧概念，作为参考素材）
# 3) input.metadata（逃生通道）整体 merge，键冲突时逃生通道优先
# 4) action 处理：
#    - 显式 metadata.action：校验白名单 {"textGenerate","generate","firstTailGenerate","referenceGenerate"}，
#      非法 -> ValueError("invalid_action: ...")（本地拦截，对应网关 400）
#    - 未显式且 model 前缀含 "vidu"（大小写不敏感）时自动推导：
#      first+last -> firstTailGenerate；first -> generate；reference_images -> referenceGenerate；否则 textGenerate
#    - 非 vidu 模型不写 action（网关渠道私有参数，避免污染其他渠道）
# 5) metadata 非空才挂到 body["metadata"]
# 6) 顶层 input_reference 不写（网关侧 OpenAI 兼容字段，具名键已完整表达）
最后调用 validate_ljp_api_video_options(input_)
```

复用 `app.core.integrations.openai.video_payload.to_image_data_url` 与 `_strip_optional_b64`。

**B3. `video.py` — `LjpApiVideoApiAdapter`**

- `create_video(cfg, input_, timeout_s) -> str`：`POST {base_url}/videos`，Bearer 认证，JSON body 来自 B2。响应 `id` 为空时 `RuntimeError`（网关 id 为 `task_` 前缀，直接透传）。
- `get_video(cfg, video_id, timeout_s) -> dict`：`GET {base_url}/videos/{video_id}`。
- 两方法捕获 `httpx.HTTPStatusError`：尝试解析响应体 `{code, message, data}`，抛 `RuntimeError(f"ljp-api error {code}: {message}")`（含 body 原文兜底）——解决网关错误结构与 OpenAI 不同的问题。
- `cfg.base_url` 为空时 `RuntimeError("ljp-api base_url is required...")`（无内置默认，杜绝打到错误端点）。

**B4. `video_capabilities.py`**

照抄 volcengine 版结构：`_LJP_API_DEFAULT = VideoModelCapability(supports_seed=True, supports_watermark=True, allowed_ratios=set(ALLOWED_RATIOS), default_ratio="16:9")` + `register_ljp_api_video_capability` / `clear_ljp_api_video_capability_overrides` / `resolve_ljp_api_video_capability`（最长前缀优先）/ `validate_ljp_api_video_options`。

**B5. 图片与文本不新建实现**：

- 图片：网关是标准 OpenAI 兼容 `/v1/images`，直接注册复用 `ImageGenerationTask._build_openai_impl`（见 C2）。
- 文本：`_build_chat_openai_model`（`app/services/llm/resolver.py`）provider 无关，走 `resolve_effective_base_url`，无需改动。

### C. 注册与分派接线

**C1. `backend/app/services/llm/provider_bootstrap.py`** 追加：

```python
ProviderSpec(
    key="ljp_api",
    display_name="LJP API",
    aliases=("ljp-api", "ljp_api", "ljpapi", "ljp api"),
    supported_categories=(ModelCategoryKey.text, ModelCategoryKey.image, ModelCategoryKey.video),
    default_base_url=None,   # 纯网关型，创建 Provider 时必须显式填写 base_url
)
```

**C2. `backend/app/core/tasks/bootstrap.py`** — `TASK_ADAPTER_SPECS` 追加：

```python
("image_generation", "ljp_api", ImageGenerationTask._build_openai_impl),  # 标准 OpenAI 兼容 /v1/images，复用实现
("video_generation", "ljp_api", VideoGenerationTask._build_ljp_api_impl),
```

**C3. `backend/app/core/tasks/video_generation_tasks.py`**

- 新增 `LjpApiVideoGenerationTask(AbstractVideoGenerationTask)`：`_create_task` 走 B3 adapter；`_poll_and_get_result` 轮询 `status in ("completed","failed")`，failed 抛 `RuntimeError(f"ljp-api video failed: {meta.get('error')!r}")`，成功返回 `VideoGenerationResult(url=f"{base_url}/videos/{id}/content", provider="ljp_api", status="completed")`。
- `VideoGenerationTask` 加静态工厂 `_build_ljp_api_impl`；`__all__` 加 `LjpApiVideoGenerationTask`。

**C4. `backend/app/core/integrations/video_capabilities.py`** — 三组分派函数（`register_video_model_capability` / `clear_video_model_capability_overrides` / `resolve_video_capability`）加 `ljp_api` 分支：`if provider == "ljp_api": -> ljp_api.video_capabilities`。`clear(provider=None)` 分支同步调用 ljp_api 清空。

**C5. `backend/app/core/integrations/image_capabilities.py`** — 三组分派函数把 `ljp_api` 与 `openai` 归并同一分支（标准 OpenAI 兼容，共用能力声明）；`clear(provider=None)` 同步。

### D. 业务接入（studio 镜头视频链路）

**D1. `backend/app/services/film/generated_video.py`**

- `persist_generated_video_to_shot`（L212）：`if provider == "openai"` 改为 `if provider in ("openai", "ljp_api")`——网关 content 代理同样需要 Bearer。
- `build_run_args`（L177-L191）：`input` dict 追加具名键字段：

```python
"first_frame_image": frame_map.get(ShotFrameType.first),
"last_frame_image": frame_map.get(ShotFrameType.last),
```

`key_frame_base64` 保留原字段（ljp-api payload 层映射为参考图，见 B2）。openai / volcengine payload 不读新字段，行为零变化；ljp-api 收到后直接用具名键语义下发。

### E. 测试（遵循项目 MockTransport 模式）

**E1. 新增 `backend/tests/core/integrations/test_ljp_api_video_adapters.py`**

- create：断言 body 含 `metadata.first_frame_image` / `last_frame_image` / `reference_images`；`duration`/`seconds` 同发；`seed`/`watermark` 透传。
- create：vidu 模型自动推导 action（首尾帧 → `firstTailGenerate`；仅首帧 → `generate`；参考图 → `referenceGenerate`；纯文 → `textGenerate`）；非 vidu 模型不写 action。
- create：显式 `metadata.action` 非法值 → `ValueError("invalid_action...")`；合法值透传且优先。
- create：逃生通道 `metadata.input.media` 整体透传且优先级高于具名键。
- create：base64 帧降级映射（仅传 `first_frame_base64` 时转 data URL 进具名键；`key_frame_base64` 进 `reference_images`）。
- poll：`completed` 返回 meta；HTTP 错误响应体 `{code,message}` 被解析进异常消息。
- base_url 缺失报错。

**E2. 扩展 `backend/tests/test_video_adapters.py`（或并入 E1）**：`VideoGenerationInput` 新字段——仅传具名键（无 prompt）通过校验器；新字段默认 None 不影响老构造。

**E3. 扩展 `backend/tests/test_task_registry.py` / 新增 registry 断言**：`(video_generation, ljp_api)` 与 `(image_generation, ljp_api)` 已注册且可解析；`resolve_provider_key_from_name("ljp-api") == "ljp_api"`；`bootstrap_builtin_providers` 后 supported 列表含 ljp_api 三类别。

**E4. 扩展 `backend/tests/test_llm_api_responses.py`**：`providers/supported` 断言加 `"ljp_api" in keys`（L205 附近），`category=video` 过滤含 ljp_api。

**E5. 扩展 `backend/tests/test_generated_video_service.py`**：seed ljp_api provider + video 模型后 `build_run_args` 返回的 `input` 含 `first_frame_image`/`last_frame_image`（data URL），老字段仍在；`persist` 对 `ljp_api` 带 Bearer 头（或以单元方式断言 headers 分支）。

### F. 文档

**F1. `site/content/docs/guide/llm-provider-registration.md`** 增补 "ljp-api" 小节：key/别名/三类支持、无默认 base_url（创建 Provider 必填）、视频具名键与 vidu action 行为、图片复用 OpenAI 兼容实现、content 下载带 Bearer。

## 决策与假设

1. **key 命名 `ljp_api`**（下划线），`ljp-api` 作为别名——对齐现有 `aliyun_bailian` 命名约定；registry 别名机制保证 `ljp-api` 名称可解析。
2. **不设默认 base_url**（用户确认）：运行时 `cfg.base_url` 为空直接报错；DB Provider 表 `base_url` 非空必填，正常路径总有值。
3. **图片复用 OpenAI 实现**（用户确认"图片和文本就是标准的 OpenAI 兼容接口"）：不写 `LjpApiImageGenerationTask` 重复代码，注册表直接指向 `_build_openai_impl`，注释说明原因。
4. **key 帧语义映射**：网关无 key_frame 概念，ljp-api payload 将 `key_frame_base64` 映射为 `reference_images` 首元素；仅 openai 保留 `input_reference` 语义（优先级 key > first > last）。
5. **action 只对 vidu 模型自动推导**：action 是 vidu 渠道私有参数（文档 §5），无差别写入可能污染其他渠道；显式传入时任何模型都校验白名单后透传（逃生通道语义）。
6. **duration 与 seconds 双写**：网关文档两者并存（duration int 通用 / seconds string 豆包），双写让网关按渠道自选，无互斥风险。
7. **轮询超时**：沿用现有 OpenAI/Volcengine Task 的 `while True + poll_interval` 节奏（无独立超时），保持一致，不在本次引入新机制。
8. **状态机映射**：网关 `queued/in_progress/completed/failed` 与 OpenAI 相同，终态判断复用同一组字符串。

## 验证步骤

1. `cd backend && uv run pytest tests/core/integrations/ -q`（E1/E2 全绿）
2. `cd backend && uv run pytest tests/test_task_registry.py tests/test_llm_api_responses.py -q`（E3/E4 全绿）
3. `cd backend && uv run pytest tests/test_generated_video_service.py -q`（E5 全绿）
4. `cd backend && uv run pytest -q` 全量回归，确认 openai / volcengine 既有用例零失败（零破坏验证）
5. 手动 smoke（可选，需真实网关地址）：UI 创建 Provider（名称 `ljp-api`、填 base_url + api_key）→ 添加 video 模型 → 设为默认 → 镜头视频生成，观察任务日志中 create/poll 请求体与结果落库。
