#!/usr/bin/env sh
# 功能：容器启动前按环境变量生成 HTTPS 证书与 Basic Auth 配置，并渲染 nginx 配置。
# 说明：
# - FRONT_TLS_CERT / FRONT_TLS_KEY：证书与私钥内容（PEM 文本），二者必须同时提供，写入 /etc/nginx/certs/。
# - FRONT_BASIC_AUTH_USER / FRONT_BASIC_AUTH_PASSWORD：Basic Auth 账号密码，生成 /etc/nginx/auth/htpasswd。
# - 未启用 Basic Auth 时容器直接退出（FRONT_BASIC_AUTH 为 fail-fast 防误用开关）。
# - 配置由 nginx.conf.template 渲染：AUTH_BASIC_LINES 在无认证时为空，有认证时为两条 auth_basic 指令。
set -eu

CERT_DIR="/etc/nginx/certs"
AUTH_DIR="/etc/nginx/auth"
CERT_FILE="${CERT_DIR}/tls.crt"
KEY_FILE="${CERT_DIR}/tls.key"
HTPASSWD_FILE="${AUTH_DIR}/htpasswd"

mkdir -p "${CERT_DIR}" "${AUTH_DIR}"

# 1) TLS 证书：由环境变量注入，或使用 openssl 生成的自签证书
if [ -n "${FRONT_TLS_CERT:-}" ] && [ -n "${FRONT_TLS_KEY:-}" ]; then
  echo "[entrypoint] Using TLS cert/key from FRONT_TLS_CERT / FRONT_TLS_KEY"
  printf '%s\n' "${FRONT_TLS_CERT}" > "${CERT_FILE}"
  printf '%s\n' "${FRONT_TLS_KEY}" > "${KEY_FILE}"
  chmod 600 "${KEY_FILE}"
else
  echo "[entrypoint] FRONT_TLS_CERT/FRONT_TLS_KEY not set, generating self-signed certificate"
  FRONT_TLS_CN="${FRONT_TLS_CN:-localhost}"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "${KEY_FILE}" -out "${CERT_FILE}" \
    -subj "/CN=${FRONT_TLS_CN}" \
    -addext "subjectAltName=DNS:${FRONT_TLS_CN},DNS:localhost,IP:127.0.0.1"
fi

# 2) Basic Auth：账号密码由环境变量提供；未配置时拒绝启动，避免误以为有密码保护
if [ -n "${FRONT_BASIC_AUTH_USER:-}" ] && [ -n "${FRONT_BASIC_AUTH_PASSWORD:-}" ]; then
  echo "[entrypoint] Generating htpasswd for FRONT_BASIC_AUTH_USER"
  printf '%s:%s\n' \
    "${FRONT_BASIC_AUTH_USER}" \
    "$(printf '%s' "${FRONT_BASIC_AUTH_PASSWORD}" | openssl passwd -stdin -apr1)" \
    > "${HTPASSWD_FILE}"
else
  if [ "${FRONT_BASIC_AUTH:-true}" != "false" ]; then
    echo "[entrypoint] ERROR: FRONT_BASIC_AUTH_USER/FRONT_BASIC_AUTH_PASSWORD not set." >&2
    echo "[entrypoint] Set FRONT_BASIC_AUTH=false to explicitly start without password protection." >&2
    exit 1
  fi
  echo "[entrypoint] WARNING: Basic auth disabled (FRONT_BASIC_AUTH=false)"
fi

# 3) 渲染 nginx 配置：无认证时两个占位行渲染为空行，有认证时为 auth_basic / auth_basic_user_file 指令
# 模板放在 /etc/nginx/site-templates/（避开官方 20-envsubst-on-templates.sh 扫描的
# /etc/nginx/templates/，否则会被 envsubst 先渲染出含未替换占位符的坏配置）。
TEMPLATE_DIR="/etc/nginx/site-templates"
mkdir -p "${TEMPLATE_DIR}"
if [ -f "${TEMPLATE_DIR}/nginx.conf.template" ]; then
  :
elif [ -f "/etc/nginx/templates/nginx.conf.template" ]; then
  # 兼容旧镜像布局
  cp /etc/nginx/templates/nginx.conf.template "${TEMPLATE_DIR}/nginx.conf.template"
else
  echo "[entrypoint] ERROR: nginx.conf.template not found in ${TEMPLATE_DIR}" >&2
  exit 1
fi

if [ -n "${HTPASSWD_FILE:-}" ] && [ -f "${HTPASSWD_FILE}" ]; then
  AUTH_BASIC_LINE_1='  auth_basic "Restricted";'
  AUTH_BASIC_LINE_2="  auth_basic_user_file ${HTPASSWD_FILE};"
else
  AUTH_BASIC_LINE_1=""
  AUTH_BASIC_LINE_2=""
fi

sed \
  -e "s|\${AUTH_BASIC_LINE_1}|${AUTH_BASIC_LINE_1}|" \
  -e "s|\${AUTH_BASIC_LINE_2}|${AUTH_BASIC_LINE_2}|" \
  -e "s|\${SSL_CERT_FILE}|${CERT_FILE}|g" \
  -e "s|\${SSL_KEY_FILE}|${KEY_FILE}|g" \
  "${TEMPLATE_DIR}/nginx.conf.template" > /etc/nginx/conf.d/default.conf
