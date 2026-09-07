from __future__ import annotations

import pytest

from app.core.task_manager.types import BaseTask
from app.core.tasks.registry import register_task_adapter, resolve_task_adapter


class _DummyTask(BaseTask):
    async def run(self, *args, **kwargs):  # noqa: ANN002, ANN003
        return None

    async def status(self):
        return {}

    async def is_done(self) -> bool:
        return True

    async def get_result(self):
        return None


class _AnotherDummyTask(BaseTask):
    async def run(self, *args, **kwargs):  # noqa: ANN002, ANN003
        return None

    async def status(self):
        return {}

    async def is_done(self) -> bool:
        return True

    async def get_result(self):
        return None


def _factory_a(**kwargs) -> BaseTask:  # noqa: ANN003
    return _DummyTask()


def _factory_b(**kwargs) -> BaseTask:  # noqa: ANN003
    return _AnotherDummyTask()


def test_register_task_adapter_is_idempotent_for_same_factory() -> None:
    register_task_adapter("unit_test_kind", "unit_test_provider", _factory_a)
    register_task_adapter("unit_test_kind", "unit_test_provider", _factory_a)

    resolved = resolve_task_adapter("unit_test_kind", "unit_test_provider")
    assert resolved is _factory_a


def test_register_task_adapter_rejects_conflict_factory() -> None:
    register_task_adapter("unit_test_kind_conflict", "unit_test_provider", _factory_a)
    with pytest.raises(ValueError) as exc_info:
        register_task_adapter("unit_test_kind_conflict", "unit_test_provider", _factory_b)
    assert "task adapter conflict" in str(exc_info.value)


def test_resolve_task_adapter_raises_for_unknown_key() -> None:
    with pytest.raises(ValueError) as exc_info:
        resolve_task_adapter("not_registered_kind", "not_registered_provider")
    assert "Unsupported provider/task adapter" in str(exc_info.value)


def test_builtin_adapters_include_ljp_api() -> None:
    """内置注册后，ljp_api 的图片（复用 openai 实现）与视频适配器应可解析。"""
    from app.bootstrap import bootstrap_all_registries
    from app.core.tasks.image_generation_tasks import ImageGenerationTask
    from app.core.tasks.video_generation_tasks import VideoGenerationTask

    bootstrap_all_registries()

    image_factory = resolve_task_adapter("image_generation", "ljp_api")
    assert image_factory is ImageGenerationTask._build_openai_impl

    video_factory = resolve_task_adapter("video_generation", "ljp_api")
    assert video_factory is VideoGenerationTask._build_ljp_api_impl


def test_builtin_provider_registry_supports_ljp_api() -> None:
    """能力注册表应认识 ljp_api 及其别名，且三类模型均支持。"""
    from app.bootstrap import bootstrap_all_registries
    from app.models.llm import ModelCategoryKey
    from app.services.llm.provider_registry import (
        get_provider_spec,
        is_provider_category_supported,
        resolve_provider_key_from_name,
    )

    bootstrap_all_registries()

    assert resolve_provider_key_from_name("连接派") == "ljp_api"
    assert resolve_provider_key_from_name("ljp-api") == "ljp_api"

    spec = get_provider_spec("ljp_api")
    assert spec.display_name == "连接派"
    assert spec.default_base_url is None
    assert is_provider_category_supported("ljp_api", ModelCategoryKey.text)
    assert is_provider_category_supported("ljp_api", ModelCategoryKey.image)
    assert is_provider_category_supported("ljp_api", ModelCategoryKey.video)
