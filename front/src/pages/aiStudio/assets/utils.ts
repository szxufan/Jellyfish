import { OpenAPI } from '../../../services/generated'

function tryExtractFileIdFromUrl(value: string): string | null {
  try {
    const url = new URL(value)
    const m = url.pathname.match(/\/api\/v1\/studio\/files\/([^/]+)\/download\/?$/)
    if (m?.[1]) return decodeURIComponent(m[1])
  } catch {
    // ignore parse error
  }
  return null
}

export function resolveAssetUrl(value?: string | null): string | undefined {
  if (!value) return undefined
  const trimmed = value.trim()
  if (!trimmed) return undefined

  if (/^(?:[a-z][a-z\d+\-.]*:)?\/\//i.test(trimmed) || trimmed.startsWith('data:') || trimmed.startsWith('blob:')) {
    const fileId = tryExtractFileIdFromUrl(trimmed)
    if (fileId) return buildFileDownloadUrl(fileId)
    return trimmed
  }

  // 后端有些缩略图字段可能直接返回 file_id（不包含 / 或 :）。
  // 这种情况下需要拼接下载地址，否则 new URL 会生成错误路径。
  if (!trimmed.includes('/') && !trimmed.includes(':')) {
    return buildFileDownloadUrl(trimmed)
  }

  try {
    // 同源优先：OpenAPI.BASE 为空串时 new URL(path, location.origin) 走站点自身，
    // 由 nginx 把 /api 反代到后端；仅直连部署时才通过 env 拿到完整后端地址。
    const fallbackBase =
      import.meta.env.VITE_API_BASE_URL ||
      import.meta.env.VITE_BACKEND_URL ||
      window.__ENV?.BACKEND_URL ||
      window.location.origin
    return new URL(trimmed, OpenAPI.BASE || fallbackBase).toString()
  } catch {
    return trimmed
  }
}

export function buildFileDownloadUrl(fileId?: string | null): string | undefined {
  if (!fileId) return undefined
  return resolveAssetUrl(`/api/v1/studio/files/${encodeURIComponent(fileId)}/download`)
}
