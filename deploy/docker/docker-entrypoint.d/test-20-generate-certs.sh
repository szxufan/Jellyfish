#!/usr/bin/env bash
# 功能：本地验证 20-generate-certs.sh 的 TLS 装配与 Basic Auth 逻辑。
# 说明：脚本读取的是容器内固定路径 /etc/nginx/certs/tls.crt|tls.key（由 compose 单文件 bind mount 注入），
#       测试通过路径重写隔离运行，不触碰真实 /etc/nginx。
# 覆盖场景：
#   A) 证书/私钥文件已挂载 + Basic Auth 开启 -> 成功且生成 htpasswd
#   B) 证书/私钥文件缺失 -> fail-fast（模拟未设置 FRONT_TLS_CERT/FRONT_TLS_KEY 或挂载缺失）
#   C) 证书内容不是合法 PEM -> fail-fast
#   D) 证书与私钥不匹配 -> fail-fast
#   E) Basic Auth 关闭时渲染的 nginx 配置不含 auth_basic 指令
# 运行方式：bash deploy/docker/docker-entrypoint.d/test-20-generate-certs.sh（依赖 openssl）
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)/20-generate-certs.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/certs" "$WORK/auth" "$WORK/templates" "$WORK/src_certs" "$WORK/conf.d"
# 最小 nginx 模板，占位符与生产模板一致
cat > "$WORK/templates/nginx.conf.template" <<'EOF'
server {
    listen 443 ssl;
    ssl_certificate ${SSL_CERT_FILE};
    ssl_certificate_key ${SSL_KEY_FILE};
${AUTH_BASIC_LINE_1}
${AUTH_BASIC_LINE_2}
}
EOF

# 准备两套独立证书/私钥（场景 D 用于配对校验）
openssl req -x509 -nodes -newkey rsa:2048 -days 1 -keyout "$WORK/src_certs/a.key" -out "$WORK/src_certs/a.pem" -subj "/CN=test-a" 2>/dev/null
openssl req -x509 -nodes -newkey rsa:2048 -days 1 -keyout "$WORK/src_certs/b.key" -out "$WORK/src_certs/b.pem" -subj "/CN=test-b" 2>/dev/null

# 生成路径重写后的被测脚本副本（仅测试用，不改动原脚本）
sed -e "s|/etc/nginx/certs|$WORK/certs|g" \
    -e "s|/etc/nginx/auth|$WORK/auth|g" \
    -e "s|/etc/nginx/site-templates|$WORK/templates|g" \
    -e "s|/etc/nginx/conf.d/default.conf|$WORK/conf.d/default.conf|g" "$SRC" > "$WORK/script.sh"
chmod +x "$WORK/script.sh"

run_case() {
  local desc="$1"
  set +e
  sh "$WORK/script.sh" > "$WORK/out.log" 2>&1
  local rc=$?
  set -e
  echo "--- [$desc] exit=$rc"
  cat "$WORK/out.log"
  return $rc
}

# 模拟 compose 单文件 bind mount：把宿主机证书/私钥复制到容器固定路径
mount_certs() {
  cp "$1" "$WORK/certs/tls.crt"
  cp "$2" "$WORK/certs/tls.key"
}

# 场景 A：正常挂载 + Basic Auth 开启
mount_certs "$WORK/src_certs/a.pem" "$WORK/src_certs/a.key"
FRONT_BASIC_AUTH_USER=admin FRONT_BASIC_AUTH_PASSWORD=pw run_case "A mounted + auth"
[ "$(head -c 27 "$WORK/certs/tls.crt")" = "-----BEGIN CERTIFICATE-----" ] || { echo "FAIL A: tls.crt not PEM"; exit 1; }
[ -f "$WORK/auth/htpasswd" ] || { echo "FAIL A: htpasswd missing"; exit 1; }
grep -q '^admin:' "$WORK/auth/htpasswd" || { echo "FAIL A: htpasswd malformed"; exit 1; }
grep -q 'TLS cert/key validated' "$WORK/out.log" || { echo "FAIL A: no validation log"; exit 1; }
echo "PASS A"

# 场景 B：证书文件缺失 -> fail-fast
rm -f "$WORK/certs/tls.crt" "$WORK/certs/tls.key" "$WORK/auth/htpasswd"
set +e
FRONT_BASIC_AUTH=false sh "$WORK/script.sh" > "$WORK/out.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then echo "FAIL B: should exit non-zero"; exit 1; fi
grep -q "missing or empty" "$WORK/out.log" || { echo "FAIL B: wrong error"; exit 1; }
echo "PASS B"

# 场景 C：证书内容非法 -> fail-fast
mount_certs /etc/hostname "$WORK/src_certs/a.key"
set +e
FRONT_BASIC_AUTH=false sh "$WORK/script.sh" > "$WORK/out.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then echo "FAIL C: should exit non-zero"; exit 1; fi
grep -q "not a valid PEM certificate" "$WORK/out.log" || { echo "FAIL C: wrong error"; exit 1; }
echo "PASS C"

# 场景 D：证书/私钥不匹配 -> fail-fast
mount_certs "$WORK/src_certs/a.pem" "$WORK/src_certs/b.key"
set +e
FRONT_BASIC_AUTH=false sh "$WORK/script.sh" > "$WORK/out.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then echo "FAIL D: should exit non-zero"; exit 1; fi
grep -q "do not match" "$WORK/out.log" || { echo "FAIL D: wrong error"; exit 1; }
echo "PASS D"

# 场景 E：Basic Auth 关闭 + 正常证书 -> 渲染结果不含 auth_basic 指令
mount_certs "$WORK/src_certs/a.pem" "$WORK/src_certs/a.key"
FRONT_BASIC_AUTH=false run_case "E mounted + no auth"
if grep -q 'auth_basic "Restricted"' "$WORK/conf.d/default.conf"; then echo "FAIL E: auth line present"; exit 1; fi
if grep -q 'auth_basic_user_file' "$WORK/conf.d/default.conf"; then echo "FAIL E: auth_user_file line present"; exit 1; fi
[ ! -f "$WORK/auth/htpasswd" ] || { echo "FAIL E: htpasswd should not exist"; exit 1; }
echo "PASS E"

echo "ALL PASS"
