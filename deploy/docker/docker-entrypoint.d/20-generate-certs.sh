#!/usr/bin/env sh
# 功能：容器启动前按环境变量生成 HTTPS 证书与 Basic Auth 配置，并渲染 nginx 配置。
# 说明：
# - FRONT_TLS_CERT / FRONT_TLS_KEY：证书与私钥（PEM），二者必须同时提供，写入 /etc/nginx/certs/。
#   支持两种写法（二者一致即可）：直接填 PEM 文本内容（含 BEGIN/END 行），或填宿主机文件路径
#   （如 /home/user/cert.pem，注意该路径需挂载进容器可读，否则按内容处理会导致 nginx 启动失败）。
# - FRONT_BASIC_AUTH_USER / FRONT_BASIC_AUTH_PASSWORD：Basic Auth 账号密码，生成 /etc/nginx/auth/htpasswd。
# - 未启用 Basic Auth 时容器直接退出（FRONT_BASIC_AUTH 为 fail-fast 防误用开关）。
# - 配置由 nginx.conf.template 渲染：AUTH_BASIC_LINES 在无认证时为空，有认证时为两条 auth_basic 指令。
set -eu

CERT_DIR="/etc/nginx/certs"
AUTH_DIR="/etc/nginx/auth"
CERT_FILE="${CERT_DIR}/tls.crt"
KEY_FILE="${CERT_DIR}/tls.key"
HTPASSWD_FILE="${AUTH_DIR}/htpasswd"

# resolve_tls_input：把 FRONT_TLS_CERT / FRONT_TLS_KEY 的值解析为 PEM 文本。
# 参数：$1 = 变量值；$2 = 变量名（用于报错提示）。
# 规则：若值以 / 开头且对应文件存在且可读，则读取文件内容；否则原样视为 PEM 文本。
# 返回：将 PEM 文本写入全局变量 TLS_INPUT；文件不可读时以明确错误退出，避免生成坏证书。
resolve_tls_input() {
  _value="$1"
  _name="$2"
  case "$_value" in
    /*)
      if [ -f "$_value" ] && [ -r "$_value" ]; then
        TLS_INPUT="$(cat "$_value")"
      else
        echo "[entrypoint] ERROR: ${_name} looks like a path but file not found/readable: ${_value}" >&2
        echo "[entrypoint] HINT: mount the cert/key file into the container, or paste PEM content instead." >&2
        exit 1
      fi
      ;;
    *)
      TLS_INPUT="$_value"
      ;;
  esac
}

mkdir -p "${CERT_DIR}" "${AUTH_DIR}"

# 1) TLS 证书：由环境变量注入（PEM 文本或文件路径），或使用 openssl 生成的自签证书
if [ -n "${FRONT_TLS_CERT:-}" ] && [ -n "${FRONT_TLS_KEY:-}" ]; then
  echo "[entrypoint] Using TLS cert/key from FRONT_TLS_CERT / FRONT_TLS_KEY"
  resolve_tls_input "${FRONT_TLS_CERT}" "FRONT_TLS_CERT"
  printf '%s\n' "${TLS_INPUT}" > "${CERT_FILE}"
  resolve_tls_input "${FRONT_TLS_KEY}" "FRONT_TLS_KEY"
  printf '%s\n' "${TLS_INPUT}" > "${KEY_FILE}"
  chmod 600 "${KEY_FILE}"
  # fail-fast：内容非法时立即退出，避免 nginx 启动阶段才报出难排查的 PEM 错误
  if ! openssl x509 -in "${CERT_FILE}" -noout >/dev/null 2>&1; then
    echo "[entrypoint] ERROR: FRONT_TLS_CERT is not a valid PEM certificate (path unreadable or wrong content)." >&2
    exit 1
  fi
  if ! openssl pkey -in "${KEY_FILE}" -noout >/dev/null 2>&1; then
    echo "[entrypoint] ERROR: FRONT_TLS_KEY is not a valid PEM private key (path unreadable or wrong content)." >&2
    exit 1
  fi
  # 证书与私钥配对校验：比较两者导出的公钥 DER（POSIX 写法，busybox ash 无进程替换）
  _cert_pub="$(mktemp)"
  _key_pub="$(mktemp)"
  openssl x509 -in "${CERT_FILE}" -noout -pubkey 2>/dev/null \
    | openssl pkey -pubin -outform DER > "${_cert_pub}" 2>/dev/null || true
  openssl pkey -in "${KEY_FILE}" -pubout -outform DER > "${_key_pub}" 2>/dev/null || true
  if ! cmp -s "${_cert_pub}" "${_key_pub}"; then
    rm -f "${_cert_pub}" "${_key_pub}"
    echo "[entrypoint] ERROR: FRONT_TLS_CERT and FRONT_TLS_KEY do not match (different key pair)." >&2
    exit 1
  fi
  rm -f "${_cert_pub}" "${_key_pub}"
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
