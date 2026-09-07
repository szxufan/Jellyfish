// 本地开发/容器部署均默认同源（空串 = 走当前站点自身的 /api，由 Vite proxy 或 Nginx 反代到后端）。
// 仅在需要直连后端（绕过反代）时，由部署环境注入 BACKEND_URL 覆盖。
window.__ENV = window.__ENV || {
  BACKEND_URL: '',
}
