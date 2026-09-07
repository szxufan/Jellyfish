"""Settings.cors_origins_list 的解析行为测试。"""

import pytest

from app.config import Settings


def test_cors_origins_wildcard_returns_star() -> None:
    """配置为 "*" 时应原样返回 ["*"]，交由 CORSMiddleware 放行任意 Origin。"""
    settings = Settings(cors_origins="*")
    assert settings.cors_origins_list == ["*"]


def test_cors_origins_comma_separated() -> None:
    """逗号分隔配置应拆分为来源列表并去除空白项。"""
    settings = Settings(cors_origins="http://a:1, http://b:2 ,")
    assert settings.cors_origins_list == ["http://a:1", "http://b:2"]


def test_cors_origins_json_array() -> None:
    """JSON 数组配置应解析为字符串列表。"""
    settings = Settings(cors_origins='["http://a","http://b"]')
    assert settings.cors_origins_list == ["http://a", "http://b"]


def test_cors_origins_empty_returns_empty_list() -> None:
    """空配置应返回空列表（不放开任何 Origin）。"""
    settings = Settings(cors_origins="")
    assert settings.cors_origins_list == []


def test_cors_middleware_wildcard_allows_any_origin(client) -> None:
    """端到端：默认配置下任意 Origin 的请求应获得 CORS 头。

    说明：conftest 的 app 使用当前 Settings 默认值（"*"），
    因此带 Origin 的请求应回显 access-control-allow-origin: *。
    """
    response = client.get("/health", headers={"Origin": "https://any.example.com"})
    assert response.status_code == 200
    assert response.headers.get("access-control-allow-origin") == "*"
