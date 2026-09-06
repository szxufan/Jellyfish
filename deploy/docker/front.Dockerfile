FROM node:20-alpine AS build

WORKDIR /app

RUN corepack enable
RUN corepack prepare pnpm@9.15.9 --activate

COPY front/package.json front/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY front/ ./
RUN pnpm run build


FROM nginx:1.27-alpine AS runtime

# entrypoint 脚本需要 openssl CLI 生成自签证书与 htpasswd
RUN apk add --no-cache openssl

COPY deploy/docker/nginx.conf.template /etc/nginx/templates/nginx.conf.template
COPY deploy/docker/docker-entrypoint.d/10-generate-env-js.sh /docker-entrypoint.d/10-generate-env-js.sh
COPY deploy/docker/docker-entrypoint.d/20-generate-certs.sh /docker-entrypoint.d/20-generate-certs.sh
RUN chmod +x /docker-entrypoint.d/*.sh

WORKDIR /usr/share/nginx/html
COPY --from=build /app/dist/ ./

# Provide a default env.js for non-docker runs
RUN printf 'window.__ENV = window.__ENV || {};\\n' > /usr/share/nginx/html/env.js

EXPOSE 80
EXPOSE 443
