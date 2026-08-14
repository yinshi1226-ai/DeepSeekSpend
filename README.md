# DeepSeekSpend 🪙

macOS 菜单栏实时消费显示器：**DeepSeek Harness 的消费金额** + **WorkBuddy 绑定的 DeepSeek 用量**。

所有数据都从本机读取（会话日志 / trace 文件），不经过任何第三方服务器。

## 功能

**状态栏**：常驻显示 `● ¥X.XX` —— 本自然小时（如 22:00–23:00）内 DeepSeek Harness 全部任务的总消费。绿点 = 有任务在跑，灰点 = 空闲，橙点 = 有异常。

**弹窗**：

- 头部：DeepSeek 账户余额（官方接口，每 5 分钟刷新；点击跳转 DeepSeek 平台查看/充值）
- 本自然小时总消费大数字 + 今日 / 累计
- 近 24 小时消费柱状图（点击柱子显示该小时金额）
- 「DeepSeek 消费」合计行 + 项目明细表：每行项目显示**实时 + 累计**，点击展开任务明细；表头可点击排序（Excel 式，上下箭头指示）
  - 一个顶层会话 = 一个任务（与 Harness 工作区侧边栏一致），任务派生的子代理（Agent）消费自动归并，不单独成行
  - 空白会话（无标题无内容）自动过滤，不会出现「未命名任务」
- WorkBuddy · DeepSeek 用量总览：本小时 / 今日 / 累计 **¥** + 调用次数（只做总览不列明细）

**计价口径**：`输入(未命中缓存)×输入价 + 缓存命中×缓存命中价 + 输出×输出价`，思考 token 已包含在输出中，与 DeepSeek 账单一致。默认内置 DeepSeek 官方价格表（含 2026-08-17 起生效的峰谷价，按每条记录的时间戳精确计价），可在配置文件中自行修改。

## 安装

### 方式一：下载 Release（推荐）

1. 从 [Releases](../../releases) 下载 `DeepSeekSpend-v*.zip`
2. 解压，把 `DeepSeekSpend.app` 拖入「应用程序」（或任意位置）
3. **首次打开**：右键 App → 打开（本地签名的应用，macOS 会要求确认一次）
4. 可选：弹窗底部打开「开机自启」

要求：macOS 13+（Apple Silicon）。运行依赖 Node.js ≥ 22.15（已安装 DeepSeek Harness 则自带，无需额外安装）。

### 方式二：源码构建

```bash
git clone <本仓库>
cd deepseek-spend
./build.sh            # 本机构建；./build.sh release 生成分发 zip
open ../DeepSeekSpend.app
```

## 数据来源

| 数据 | 来源 |
|------|------|
| DeepSeek Harness 任务与 token 用量 | `~/Documents/DeepSeek-Harness/data/sessions/**/session.jsonl.zstd`（zstd 多帧解压）+ 本地 API `http://127.0.0.1:3080/api/session.list` |
| DeepSeek 账户余额 | `https://api.deepseek.com/user/balance`（API Key 读取自 Harness 的 `.credentials.yaml`，仅本机使用） |
| WorkBuddy 的 DeepSeek 用量 | `~/.workbuddy/traces/**/*.json` 中每次 DeepSeek 调用的 token 记录（增量解析 + 本地缓存） |

数据目录会自动探测（配置文件路径 → `$DSH_HOME` → `~/Documents/DeepSeek-Harness/data`），换机器不用改配置。所有数据只在本机处理，不上传任何内容。

## 配置

运行期配置在 `~/Library/Application Support/DeepSeekSpend/config.json`（首次启动自动从 App 内复制，之后保留你的修改）：

- `prices` —— DeepSeek 价格表（元 / 百万 tokens），改了在弹窗点「刷新」生效
- `apiBase` —— DeepSeek Harness Web 端口
- `pollIntervalMs` / `balanceIntervalMs` —— 轮询与余额刷新间隔
- `workbuddyTracesDir` —— WorkBuddy traces 目录（默认 `~/.workbuddy/traces`）

## 目录结构

```
├── App/main.swift    Swift 菜单栏界面（AppKit + SwiftUI，无第三方依赖）
├── collector.mjs     Node 数据采集器（日志解析 + 计价 + 快照）
├── config.json       默认配置模板
├── build.sh          构建脚本（local / release 两种模式）
├── genicon.swift     图标生成
└── README.md
```

## 许可

MIT License，详见 [LICENSE](LICENSE)。
