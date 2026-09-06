---
title: "Docker 部署"
weight: 3
description: "通过 Docker Compose 拉起完整依赖与服务。"
---

## 服务组成

- Front
- Backend
- MySQL
- RustFS

## 启动方式

```bash
cp deploy/compose/.env.example deploy/compose/.env
docker compose --env-file deploy/compose/.env -f deploy/compose/docker-compose.yml up --build
```

## 必改的安全配置

`.env` 中以下默认凭据必须在部署前修改（生成强随机串可用 `openssl rand -base64 24`）：

- `MYSQL_ROOT_PASSWORD`、`MYSQL_PASSWORD`
- `RUSTFS_ACCESS_KEY`、`RUSTFS_SECRET_KEY`
- `REDIS_PASSWORD`（必填，未设置时 Redis 服务会启动失败）

若虚拟机有公网访问，还需用防火墙/安全组将 3306（MySQL）、6379（Redis）、9000/9001（RustFS）限制为仅内网访问，仅放行 22、7788、8000。

## 数据存储路径

RustFS 数据（生成的图片、视频资产）默认存放在 Docker 命名卷 `rustfs_data`。若使用独立数据盘，在 `.env` 中设置绝对路径即可切换为 bind mount：

```bash
RUSTFS_DATA_PATH=/data/jellyfish/rustfs
```

注意：切换路径后需迁移旧命名卷数据（`docker cp` 或重新生成资产），且宿主机目录属主需与容器内运行用户一致。

## 默认访问地址

- 前端：`http://localhost:7788`
- 后端：`http://localhost:8000`
- RustFS Console：`http://localhost:9001`

## 说明

首次启动会自动初始化数据库，并导入提示词模板数据。
