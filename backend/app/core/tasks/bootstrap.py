"""任务执行器注册入口。"""

from __future__ import annotations

from app.core.tasks.image_generation_tasks import ImageGenerationTask
from app.core.tasks.registry import register_task_adapter
from app.core.tasks.video_generation_tasks import VideoGenerationTask


TASK_ADAPTER_SPECS = (
    ("image_generation", "openai", ImageGenerationTask._build_openai_impl),
    ("image_generation", "volcengine", ImageGenerationTask._build_volcengine_impl),
    # ljp-api 图片为标准 OpenAI 兼容 /v1/images，直接复用 openai 实现，不重复造轮子。
    ("image_generation", "ljp_api", ImageGenerationTask._build_openai_impl),
    ("video_generation", "openai", VideoGenerationTask._build_openai_impl),
    ("video_generation", "volcengine", VideoGenerationTask._build_volcengine_impl),
    ("video_generation", "ljp_api", VideoGenerationTask._build_ljp_api_impl),
)


def bootstrap_task_adapters() -> None:
    """注册内置任务执行器（幂等）。"""

    for task_kind, provider, factory in TASK_ADAPTER_SPECS:
        register_task_adapter(task_kind, provider, factory)
