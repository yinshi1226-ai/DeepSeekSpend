# 安全与隐私

## 数据处理

- Harness 与 WorkBuddy 的会话用量在本机解析，不上传会话内容。
- 如 Harness 已配置 DeepSeek API Key，采集器会把该 Key 发送给 DeepSeek 官方余额接口 `https://api.deepseek.com/user/balance`。除此之外不发送遥测。
- 快照、配置和增量缓存保存在 `~/Library/Application Support/DeepSeekSpend/`。
- Release 内置官方 Node.js 运行时及其许可证，不执行来自网络的脚本。

## 签名边界

当前 Release 使用 ad-hoc 签名。构建脚本不会创建证书、私钥、钥匙串或系统信任根，也不会修改 macOS 安全设置。首次打开时需要由用户在 macOS 中确认。

## 报告漏洞

请不要公开提交包含密钥、日志内容或私人路径的 Issue。请使用 GitHub 的 [Private vulnerability reporting](https://github.com/yinshi1226-ai/DeepSeekSpend/security/advisories/new) 私密报告。
