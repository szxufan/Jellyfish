"""ljp-api 视频：请求体构建（具名键直映 + base64 降级 + action 推导）。"""

from __future__ import annotations

from typing import Any

from app.core.integrations.ljp_api.video_capabilities import validate_ljp_api_video_options
from app.core.integrations.openai.video_payload import to_image_data_url
from app.core.integrations.video_capabilities import derive_provider_size
from app.core.contracts.video_generation import VideoGenerationInput, _strip_optional_b64

# vidu 渠道私有 action 白名单（网关 400 invalid_action 的本地前置校验）。
VIDU_ACTION_WHITELIST = frozenset({"textGenerate", "generate", "firstTailGenerate", "referenceGenerate"})


def _derive_vidu_action(metadata: dict[str, Any]) -> str | None:
    """按素材组合推导 vidu action；无素材语境时返回 None（写 textGenerate 交给网关兜底）。"""
    if metadata.get("first_frame_image") and metadata.get("last_frame_image"):
        return "firstTailGenerate"
    if metadata.get("first_frame_image"):
        return "generate"
    if metadata.get("reference_images"):
        return "referenceGenerate"
    return None


def _apply_action(metadata: dict[str, Any], *, model: str | None, escape_metadata: dict[str, Any]) -> None:
    """action 处理：显式（逃生通道）优先并校验白名单；vidu 模型自动推导。"""
    explicit_action = escape_metadata.get("action")
    if explicit_action is not None:
        action = str(explicit_action).strip()
        if action not in VIDU_ACTION_WHITELIST:
            raise ValueError(
                f"invalid_action: {action!r}; allowed values: {sorted(VIDU_ACTION_WHITELIST)}"
            )
        metadata["action"] = action
        return
    if model and "vidu" in model.strip().lower():
        metadata["action"] = _derive_vidu_action(metadata) or "textGenerate"


def build_create_video_body(input_: VideoGenerationInput) -> dict[str, Any]:
    validate_ljp_api_video_options(input_)

    body: dict[str, Any] = {"prompt": input_.prompt or ""}
    if input_.model:
        body["model"] = input_.model
    size = derive_provider_size(provider="ljp_api", model=input_.model, ratio=input_.ratio)
    if size:
        body["size"] = size
    if input_.seconds is not None:
        # duration（int，通用）与 seconds（string，豆包）双写，网关按渠道自选。
        body["duration"] = int(input_.seconds)
        body["seconds"] = str(int(input_.seconds))
    if input_.seed is not None:
        body["seed"] = int(input_.seed)
    if input_.watermark is not None:
        body["watermark"] = bool(input_.watermark)

    metadata: dict[str, Any] = {}
    # 1) 一等具名键直映
    ff = _strip_optional_b64(input_.first_frame_image)
    if ff:
        metadata["first_frame_image"] = ff
    lf = _strip_optional_b64(input_.last_frame_image)
    if lf:
        metadata["last_frame_image"] = lf
    refs: list[str] = []
    if input_.reference_images:
        refs.extend(item for item in input_.reference_images if _strip_optional_b64(item))
    ref_videos = [item for item in (input_.reference_videos or []) if _strip_optional_b64(item)]
    ref_audios = [item for item in (input_.reference_audios or []) if _strip_optional_b64(item)]

    # 2) base64 帧字段降级映射（具名键未占用时兜底；网关无 key 帧概念，关键帧作参考图）
    ff_b64 = _strip_optional_b64(input_.first_frame_base64)
    if ff_b64 and "first_frame_image" not in metadata:
        metadata["first_frame_image"] = to_image_data_url(ff_b64)
    lf_b64 = _strip_optional_b64(input_.last_frame_base64)
    if lf_b64 and "last_frame_image" not in metadata:
        metadata["last_frame_image"] = to_image_data_url(lf_b64)
    kf_b64 = _strip_optional_b64(input_.key_frame_base64)
    if kf_b64:
        refs.insert(0, to_image_data_url(kf_b64))

    if refs:
        metadata["reference_images"] = refs
    if ref_videos:
        metadata["reference_videos"] = ref_videos
    if ref_audios:
        metadata["reference_audios"] = ref_audios

    # 3) 逃生通道整体 merge，键冲突时以其优先；随后处理 action
    escape_metadata = input_.metadata or {}
    metadata.update(escape_metadata)
    _apply_action(metadata, model=input_.model, escape_metadata=escape_metadata)

    if metadata:
        body["metadata"] = metadata
    return body
