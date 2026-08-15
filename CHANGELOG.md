# 更新日志

## [1.1.0] - 2026-08-15

### 修复
- 自动识别 `~/Library/Application Support/DeepSeek-Harness/data`，兼容 Harness 新版数据目录。
- 删除会创建自签名证书、钥匙串和信任根的构建逻辑，统一改为透明的 ad-hoc 签名。
- Release 内置兼容 zstd 的 Node.js 运行时，下载后不再要求用户另外安装 Node。
- 移除没有官方依据的未来峰谷价格；V4 Pro / Flash 单价按 DeepSeek 官方价格页核对。
- 未知模型不再静默套用 V4 Pro 单价，而是显示缺价错误并按 ¥0 估算。

### 新增
- Node 计价与日志解析单元测试。
- GitHub Actions 构建、测试和自动 Release。
- 安全与隐私说明。
- 匿名 `--demo` 展示模式，用于生成不含用户项目、消费和凭据的真实界面截图。
- 中英文 README 与中英文产品说明图。
