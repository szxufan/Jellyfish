#!/usr/bin/env sh
# 功能：容器启动前将 FRONT_TLS_CERT / FRONT_TLS_KEY 指定的证书与私钥装配到 nginx 可读位置，
#       并按环境变量生成 Basic Auth 配置、渲染 nginx 站点配置。
# 说明：
# - FRONT_TLS_CERT / FRONT_TLS_KEY：宿主机上证书与私钥文件路径（如 /home/user/certs/site.pem），
#   二者必须同时提供；文件由 compose 按同一 HOST 路径 bind mount 进容器，容器内固定为
#   /etc/nginx/certs/tls.crt 与 /etc/nginx/certs/tls.key（映射关系见 docker-compose.yml）。
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

# 1) TLS 证书：从容器内固定路径校验并装配（fail-fast，避免 nginx 启动阶段才暴露 PEM 错误）
if [ ! -s "${CERT_FILE}" ] || [ ! -s "${KEY_FILE}" ]; then
  echo "[entrypoint] ERROR: ${CERT_FILE} / ${KEY_FILE} missing or empty." >&2
  echo "[entrypoint] HINT: set FRONT_TLS_CERT/FRONT_TLS_KEY in .env to host cert/key file paths." >&2
  echo "[entrypoint] HINT: compose bind-mounts those files into the container; see deploy/compose/docker-compose.yml." >&2
  exit 1
fi
chmod 600 "${KEY_FILE}" 2>/dev/null || true
# PEM 合法性与证书/私钥配对校验（POSIX 写法，busybox ash 无进程替换）
if ! openssl x509 -in "${CERT_FILE}" -noout >/dev/null 2>&1; then
  echo "[entrypoint] ERROR: ${CERT_FILE} is not a valid PEM certificate." >&2
  exit 1
fi
if ! openssl pkey -in "${KEY_FILE}" -noout >/dev/null 2>&1; then
  echo "[entrypoint] ERROR: ${KEY_FILE} is not a valid PEM private key." >&2
  exit 1
fi
_cert_pub="$(mktemp)"
_key_pub="$(mktemp)"
openssl x509 -in "${CERT_FILE}" -noout -pubkey 2>/dev/null \
  | openssl pkey -pubin -outform DER > "${_cert_pub}" 2>/dev/null || true
openssl pkey -in "${KEY_FILE}" -pubout -outform DER > "${_key_pub}" 2>/dev/null || true
if ! cmp -s "${_cert_pub}" "${_key_pub}"; then
  rm -f "${_cert_pub}" "${_key_pub}"
  echo "[entrypoint] ERROR: certificate and private key do not match (different key pair)." >&2
  exit 1
fi
rm -f "${_cert_pub}" "${_key_pub}"
echo "[entrypoint] TLS cert/key validated: ${CERT_FILE}"

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
