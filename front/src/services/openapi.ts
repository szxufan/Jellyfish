import { OpenAPI } from './generated'

declare global {
  interface Window {
    __ENV?: {
      BACKEND_URL?: string
    }
  }
}

/**
 * 初始化由 OpenAPI 生成的请求客户端。
 *
 * 说明：
 * - 生成接口的路径已包含 `/api/v1/...`，因此 BASE 默认应为空串（同源，经 nginx 反代 /api 到后端），
 *   或显式配置完整后端地址（直连场景）。
 * - 优先级：运行时 env.js（Docker 注入）> 构建期 VITE_BACKEND_URL > 同源（空串）。
 */
export function initOpenAPI(base: string = '') {
  OpenAPI.BASE = base
}

// 运行时 env.js（Docker 注入）> 构建期 VITE_BACKEND_URL > 同源（空串）。
// 注意用 || 而非 ??：env.js 注入空串时也应回退到下一优先级，最终落到同源。
const runtimeBackendUrl = window.__ENV?.BACKEND_URL || undefined
const buildtimeBackendUrl = import.meta.env.VITE_BACKEND_URL || undefined

initOpenAPI(runtimeBackendUrl ?? buildtimeBackendUrl ?? '')
