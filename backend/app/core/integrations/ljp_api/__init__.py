"""ljp-api 网关集成：OpenAI 兼容生命周期 + 统一素材具名键。

网关能力：
- 视频：POST /videos + GET /videos/{task_id}（OpenAI 风格），支持 metadata 具名键
  （first_frame_image / last_frame_image / reference_images / reference_videos / reference_audios）
  与 vidu 的 metadata.action；错误体为 {code, message, data}。
- 图片：标准 OpenAI 兼容 /v1/images，直接复用 openai 集成实现，本目录不重复实现。
"""
