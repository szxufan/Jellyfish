"""ljp-api 视频 integrations：httpx MockTransport 单测（不发起真实网络请求）。"""

from __future__ import annotations

import json

import httpx
import pytest

from app.core.integrations.ljp_api.video import LjpApiVideoApiAdapter
from app.core.integrations.ljp_api.video_payload import build_create_video_body
from app.core.contracts.provider import ProviderConfig
from app.core.contracts.video_generation import VideoGenerationInput


def _patch_httpx_client(monkeypatch: pytest.MonkeyPatch, transport: httpx.MockTransport) -> None:
    real_client = httpx.AsyncClient

    def factory(**kwargs: object) -> httpx.AsyncClient:
        timeout = kwargs.get("timeout", 60.0)
        return real_client(transport=transport, timeout=timeout)  # type: ignore[arg-type]

    monkeypatch.setattr(httpx, "AsyncClient", factory)


def _cfg(base_url: str = "https://gw.example.com/v1") -> ProviderConfig:
    return ProviderConfig(provider="ljp_api", api_key="sk-ljp", base_url=base_url)


def _input(**overrides: object) -> VideoGenerationInput:
    payload: dict[str, object] = {"prompt": "镜头缓慢推进", "ratio": "16:9"}
    payload.update(overrides)
    return VideoGenerationInput.model_validate(payload)


def test_payload_named_keys_and_base_fields() -> None:
    body = build_create_video_body(
        _input(
            first_frame_image="https://example.com/a.png",
            last_frame_image="https://example.com/b.png",
            reference_images=["https://example.com/r1.png"],
            reference_videos=["https://example.com/m.mp4"],
            reference_audios=["https://example.com/bgm.mp3"],
            seconds=6,
            seed=42,
            watermark=False,
            model="viduq2",
        )
    )
    assert body["model"] == "viduq2"
    assert body["duration"] == 6
    assert body["seconds"] == "6"
    assert body["seed"] == 42
    assert body["watermark"] is False
    assert body["metadata"]["first_frame_image"] == "https://example.com/a.png"
    assert body["metadata"]["last_frame_image"] == "https://example.com/b.png"
    assert body["metadata"]["reference_images"] == ["https://example.com/r1.png"]
    assert body["metadata"]["reference_videos"] == ["https://example.com/m.mp4"]
    assert body["metadata"]["reference_audios"] == ["https://example.com/bgm.mp3"]


def test_payload_vidu_action_auto_derived() -> None:
    # 首尾帧 -> firstTailGenerate
    body = build_create_video_body(
        _input(
            model="viduq2",
            first_frame_image="https://example.com/a.png",
            last_frame_image="https://example.com/b.png",
        )
    )
    assert body["metadata"]["action"] == "firstTailGenerate"

    # 仅首帧 -> generate
    body = build_create_video_body(_input(model="viduq2", first_frame_image="https://example.com/a.png"))
    assert body["metadata"]["action"] == "generate"

    # 参考图 -> referenceGenerate
    body = build_create_video_body(_input(model="viduq2", reference_images=["https://example.com/r.png"]))
    assert body["metadata"]["action"] == "referenceGenerate"

    # 纯文 -> textGenerate
    body = build_create_video_body(_input(model="viduq2"))
    assert body["metadata"]["action"] == "textGenerate"

    # 非 vidu 模型不写 action
    body = build_create_video_body(_input(model="kling-v2", first_frame_image="https://example.com/a.png"))
    assert "action" not in body["metadata"]


def test_payload_explicit_action_validated_and_prioritized() -> None:
    # 显式合法 action 透传且优先于自动推导
    body = build_create_video_body(
        _input(
            model="viduq2",
            first_frame_image="https://example.com/a.png",
            metadata={"action": "referenceGenerate"},
        )
    )
    assert body["metadata"]["action"] == "referenceGenerate"

    # 非法 action 本地拦截（对应网关 400 invalid_action）
    with pytest.raises(ValueError, match="invalid_action"):
        build_create_video_body(_input(metadata={"action": "bogus"}))


def test_payload_escape_metadata_overrides_named_keys() -> None:
    body = build_create_video_body(
        _input(
            first_frame_image="https://example.com/a.png",
            metadata={"first_frame_image": "https://cdn.example.com/override.png"},
        )
    )
    assert body["metadata"]["first_frame_image"] == "https://cdn.example.com/override.png"


def test_payload_base64_frame_fallback_mapping() -> None:
    # 仅传 base64 帧字段（业务老路径）时降级映射到具名键
    body = build_create_video_body(
        _input(
            first_frame_base64="AAAA",
            key_frame_base64="BBBB",
        )
    )
    assert body["metadata"]["first_frame_image"] == "data:image/png;base64,AAAA"
    assert body["metadata"]["reference_images"] == ["data:image/png;base64,BBBB"]


def test_payload_named_reference_without_prompt_passes_validator() -> None:
    # 仅具名键、无 prompt 也应通过契约校验
    body = build_create_video_body(_input(prompt=None, first_frame_image="https://example.com/a.png"))
    assert body["prompt"] == ""


@pytest.mark.asyncio
async def test_adapter_create_posts_gateway_body(monkeypatch: pytest.MonkeyPatch) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert str(request.url).rstrip("/").endswith("/videos")
        assert request.headers["Authorization"] == "Bearer sk-ljp"
        payload = json.loads(request.content.decode())
        assert payload["prompt"] == "镜头缓慢推进"
        assert payload["metadata"]["first_frame_image"] == "https://example.com/a.png"
        return httpx.Response(200, json={"id": "task_20260907_abc123", "status": "queued"})

    _patch_httpx_client(monkeypatch, httpx.MockTransport(handler))
    vid = await LjpApiVideoApiAdapter().create_video(
        cfg=_cfg(), input_=_input(first_frame_image="https://example.com/a.png"), timeout_s=30.0
    )
    assert vid == "task_20260907_abc123"


@pytest.mark.asyncio
async def test_adapter_get_returns_meta(monkeypatch: pytest.MonkeyPatch) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "GET"
        assert "/videos/task_x" in str(request.url)
        return httpx.Response(200, json={"id": "task_x", "status": "completed", "progress": 100})

    _patch_httpx_client(monkeypatch, httpx.MockTransport(handler))
    meta = await LjpApiVideoApiAdapter().get_video(cfg=_cfg(), video_id="task_x", timeout_s=30.0)
    assert meta["status"] == "completed"


@pytest.mark.asyncio
async def test_adapter_parses_gateway_error_body(monkeypatch: pytest.MonkeyPatch) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"code": "invalid_action", "message": "bad action", "data": None})

    _patch_httpx_client(monkeypatch, httpx.MockTransport(handler))
    with pytest.raises(RuntimeError, match="ljp-api error invalid_action: bad action"):
        await LjpApiVideoApiAdapter().create_video(cfg=_cfg(), input_=_input(), timeout_s=30.0)


@pytest.mark.asyncio
async def test_adapter_requires_base_url() -> None:
    with pytest.raises(RuntimeError, match="base_url is required"):
        await LjpApiVideoApiAdapter().create_video(cfg=_cfg(base_url=""), input_=_input(), timeout_s=30.0)


@pytest.mark.asyncio
async def test_adapter_create_missing_id_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"status": "queued"})

    _patch_httpx_client(monkeypatch, httpx.MockTransport(handler))
    with pytest.raises(RuntimeError, match="missing id"):
        await LjpApiVideoApiAdapter().create_video(cfg=_cfg(), input_=_input(), timeout_s=30.0)
