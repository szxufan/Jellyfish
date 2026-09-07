"""ljp-api 视频网关：POST /videos 与 GET /videos/{task_id}。

网关生命周期与 OpenAI Videos 一致，差异点：
- 任务 ID 由网关统一分配（task_ 前缀），响应原样透传；
- 错误体为 {code, message, data}，需解析进异常消息；
- 无内置默认 base_url（纯网关型），未配置时直接报错。
"""

from __future__ import annotations

from typing import Any

from app.core.integrations.ljp_api.video_payload import build_create_video_body
from app.core.contracts.provider import ProviderConfig
from app.core.contracts.video_generation import VideoGenerationInput


def _require_base_url(cfg: ProviderConfig) -> str:
    """网关无默认端点，base_url 必须由 Provider 配置显式提供。"""
    base_url = (cfg.base_url or "").strip().rstrip("/")
    if not base_url:
        raise RuntimeError("ljp-api base_url is required: configure Provider.base_url first")
    return base_url


def _extract_error_message(response: Any) -> str | None:
    """解析网关错误体 {code, message, data}；解析失败时返回 None 由调用方兜底。"""
    try:
        data: dict[str, Any] = response.json()
    except Exception:  # noqa: BLE001
        return None
    if not isinstance(data, dict):
        return None
    code = data.get("code")
    message = data.get("message")
    if code is None and message is None:
        return None
    return f"ljp-api error {code}: {message}"


class LjpApiVideoApiAdapter:
    """ljp-api 视频网关 HTTP 适配器；无状态，可单测替换。"""

    async def create_video(
        self,
        *,
        cfg: ProviderConfig,
        input_: VideoGenerationInput,
        timeout_s: float,
    ) -> str:
        try:
            import httpx
        except ImportError as e:  # pragma: no cover
            raise RuntimeError("httpx is required for video generation tasks") from e

        base_url = _require_base_url(cfg)
        headers = {
            "Authorization": f"Bearer {cfg.api_key}",
            "Content-Type": "application/json",
        }
        body = build_create_video_body(input_)

        async with httpx.AsyncClient(timeout=timeout_s) as client:
            r = await client.post(f"{base_url}/videos", headers=headers, json=body)
            if r.status_code >= 400:
                raise RuntimeError(_extract_error_message(r) or f"ljp-api /videos HTTP {r.status_code}: {r.text}")
            data: dict[str, Any] = r.json()
            video_id = str(data.get("id") or "")
            if not video_id:
                raise RuntimeError(f"ljp-api /videos missing id: {data!r}")
            return video_id

    async def get_video(
        self,
        *,
        cfg: ProviderConfig,
        video_id: str,
        timeout_s: float,
    ) -> dict[str, Any]:
        try:
            import httpx
        except ImportError as e:  # pragma: no cover
            raise RuntimeError("httpx is required for video generation tasks") from e

        base_url = _require_base_url(cfg)
        headers = {"Authorization": f"Bearer {cfg.api_key}"}

        async with httpx.AsyncClient(timeout=timeout_s) as client:
            rr = await client.get(f"{base_url}/videos/{video_id}", headers=headers)
            if rr.status_code >= 400:
                raise RuntimeError(_extract_error_message(rr) or f"ljp-api /videos/{video_id} HTTP {rr.status_code}: {rr.text}")
            return rr.json()
