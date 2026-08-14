#!/usr/bin/env node
/**
 * DeepSeekSpend 数据采集器
 * -----------------------
 * 从 DeepSeek Harness 的会话日志中提取每一步的 token 用量（含时间戳），
 * 按 DeepSeek 官方价格表换算成人民币消费，生成快照 JSON 供菜单栏 App 读取。
 *
 * 数据来源：
 *  1. POST {apiBase}/api/session.list  —— 会话列表（running 状态 / cwd / 标题）
 *  2. {dshDataDir}/sessions/.../session.jsonl.zstd —— 每个任务的完整事件日志
 *     （zstd 多帧格式，用 node:zlib 的 zstdDecompressSync 逐帧解压）
 *  3. GET https://api.deepseek.com/user/balance —— 账户余额（需 API Key）
 *
 * 用法：
 *   node collector.mjs --config <config.json> [--once]
 *   --once：只跑一轮就退出（用于测试）
 */

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { pathToFileURL } from 'node:url'
import { zstdDecompressSync } from 'node:zlib'

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]) // zstd 帧魔数
const DEFAULT_CONFIG_PATH = path.join(os.homedir(), 'Library', 'Application Support', 'DeepSeekSpend', 'config.json')

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

function expandHome(p) {
  if (typeof p === 'string' && p.startsWith('~/')) return path.join(os.homedir(), p.slice(2))
  return p
}

function localHourStart(tsMs) {
  const d = new Date(tsMs)
  d.setMinutes(0, 0, 0)
  return d.getTime()
}

function localDayStart(tsMs) {
  const d = new Date(tsMs)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

/** 北京时间的“小时”（用于峰谷时段判断），返回 0-23 */
function beijingHour(tsMs) {
  return new Date(tsMs + 8 * 3600_000).getUTCHours()
}

/** 读取 YAML 格式的 credentials 文件中的 DEEPSEEK_API_KEY（宽松解析，仅取这一行） */
function readApiKey(filePath) {
  try {
    const text = fs.readFileSync(filePath, 'utf8')
    const m = text.match(/^\s*DEEPSEEK_API_KEY\s*:\s*(\S+)\s*$/m)
    return m ? m[1] : null
  } catch {
    return null
  }
}

// ---------------------------------------------------------------------------
// 日志解析（zstd 多帧 → 事件）
// ---------------------------------------------------------------------------

/** 找到 buffer 中所有 zstd 帧魔数的起始偏移 */
function scanFrames(buf) {
  const starts = []
  for (let i = 0; i + 4 <= buf.length; i++) {
    if (buf[i] === 0x28 && buf[i + 1] === 0xb5 && buf[i + 2] === 0x2f && buf[i + 3] === 0xfd) {
      starts.push(i)
      i += 3 // 跳过本帧魔数，继续扫描
    }
  }
  return starts
}

/**
 * 解压整个日志文件为文本。
 * 返回 { text, framesDecoded, tailDropped }。
 * 最后一个不完整帧（正在写入中）解码失败时静默丢弃。
 */
function decodeLogFile(filePath) {
  const buf = fs.readFileSync(filePath)
  if (buf.length === 0) return { text: '', framesDecoded: 0, tailDropped: false }
  const starts = scanFrames(buf)
  let text = ''
  let framesDecoded = 0
  let tailDropped = false
  for (let f = 0; f < starts.length; f++) {
    const end = f + 1 < starts.length ? starts[f + 1] : buf.length
    try {
      text += zstdDecompressSync(buf.subarray(starts[f], end)).toString('utf8')
      framesDecoded++
    } catch {
      if (f === starts.length - 1) {
        tailDropped = true // 正在写入的最后一个帧，下轮再读
      }
      break
    }
  }
  return { text, framesDecoded, tailDropped }
}

/**
 * 把日志文本解析成紧凑事件数组。
 * 只保留我们需要的信息：usage / 模型选择 / 会话头 / 标题。
 */
function parseEvents(text) {
  const lines = text.split('\n')
  const events = []
  let firstUserText = null
  for (const line of lines) {
    if (!line) continue
    let e
    try {
      e = JSON.parse(line)
    } catch {
      continue
    }
    if (!e || typeof e !== 'object') continue
    const t = e.type
    const time = typeof e.time === 'number' ? e.time : null
    const d = e.data
    if (t === 'assistant/message' && d && typeof d.usage === 'object' && d.usage !== null) {
      const u = d.usage
      events.push({
        kind: 'usage',
        time,
        inputTokens: num(u.inputTokens),
        outputTokens: num(u.outputTokens),
        cacheReadTokens: num(u.cacheReadTokens),
        cacheWriteTokens: num(u.cacheWriteTokens),
        reasoningTokens: num(u.reasoningTokens),
      })
    } else if (t === 'request/header' && d && d.header && d.header.config && d.header.config.model) {
      events.push({ kind: 'model', time, model: d.header.config.model })
    } else if (t === 'request/context' && d && d.model) {
      events.push({ kind: 'model', time, model: d.model })
    } else if (t === 'session' && d && d.cwd) {
      events.push({
        kind: 'header',
        time: typeof d.createdAt === 'number' ? d.createdAt : time,
        cwd: d.cwd,
        delegationDepth: typeof d.delegationDepth === 'number' ? d.delegationDepth : 0,
      })
    } else if (t === 'session/title' && d && typeof d.title === 'string' && d.title) {
      events.push({ kind: 'title', time, title: d.title })
    } else if (t === 'user/message' && firstUserText == null && d && Array.isArray(d.content)) {
      // 无标题会话用第一条用户消息当任务名
      const block = d.content.find((b) => b && b.type === 'text' && typeof b.text === 'string' && b.text.trim())
      if (block) {
        firstUserText = block.text.trim().slice(0, 60)
        events.push({ kind: 'user-text', time, text: firstUserText })
      }
    }
  }
  return events
}

function num(v) {
  return typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : 0
}

// ---------------------------------------------------------------------------
// WorkBuddy 绑定的 DeepSeek 用量（金额）解析
// ---------------------------------------------------------------------------
// WorkBuddy 的 trace 文件里保存了每次模型调用的 rawUsage（token 明细、
// 缓存命中拆分、模型名、时间戳）。我们只提取 model 以 deepseek 开头的调用，
// 按 DeepSeek 官方价格表换算成人民币。
// traces 目录有 1.5GB+：trace 文件写完即不可变，因此按 (size, mtime) 缓存，
// 只解析新增/变化的文件，并把结果持久化到磁盘，重启后免全量扫描。

let wbTraceState = null // { files: Map, events: Map, dirty: bool, loaded: bool }

function wbCacheFilePath(cfg) {
  const dir = path.dirname(cfg.snapshotPath)
  return path.join(dir, 'workbuddy-trace-cache.json')
}

/** 递归收集对象树中 deepseek 模型且带用量的调用记录（inToolOutput 标记来源） */
function collectDeepseekUsage(node, out, inToolOutput) {
  if (node == null) return
  if (Array.isArray(node)) {
    for (const v of node) collectDeepseekUsage(v, out, inToolOutput)
    return
  }
  if (typeof node === 'object') {
    const usage = node.rawUsage ?? node.usage
    if (usage && typeof usage === 'object'
      && typeof node.model === 'string' && /(^|:)deepseek/i.test(node.model)) {
      out.push({
        model: node.model,
        convId: typeof node.conversationRequestId === 'string' ? node.conversationRequestId : null,
        messageId: typeof node.messageId === 'string' ? node.messageId : null,
        id: typeof node.id === 'string' ? node.id : null,
        usage,
        inToolOutput,
      })
    }
    for (const v of Object.values(node)) collectDeepseekUsage(v, out, inToolOutput)
  } else if (typeof node === 'string' && node.length > 24
    && (node.includes('rawUsage') || node.includes('"usage"'))) {
    try {
      collectDeepseekUsage(JSON.parse(node), out, inToolOutput)
    } catch { /* 不是 JSON 的普通文本，跳过 */ }
  }
}

/** 归一化模型名：去掉 custom-local: 等前缀 */
function normalizeWbModel(model) {
  return String(model).replace(/^custom-local:/i, '')
}

/** 从 span 记录中提取 startedAt 时间戳（毫秒） */
function spanTimeMs(span, traceObj) {
  const t = span && span.startedAt
  if (typeof t === 'string') {
    const ms = Date.parse(t)
    if (Number.isFinite(ms)) return ms
  }
  const tt = traceObj && traceObj.startedAt
  if (typeof tt === 'string') {
    const ms = Date.parse(tt)
    if (Number.isFinite(ms)) return ms
  }
  return null
}

/** 解析一个 trace 文件，返回 deepseek 用量事件数组 */
export function parseWbTraceFile(filePath) {
  const text = fs.readFileSync(filePath, 'utf8')
  if (!text.includes('"usage"') && !text.includes('rawUsage')) return []
  let doc
  try {
    doc = JSON.parse(text)
  } catch {
    return []
  }
  const traceObj = doc && typeof doc === 'object' ? doc.trace : null
  const spans = doc && Array.isArray(doc.spans) ? doc.spans : []
  const events = []
  for (const sp of spans) {
    const t0 = spanTimeMs(sp, traceObj)
    if (t0 == null) continue
    const found = []
    // 分别解析 toolOutput（真实响应，时间可信）与 toolInput（历史回显，仅作补充）
    if (typeof sp.toolOutput === 'string') collectDeepseekUsage(sp.toolOutput, found, true)
    if (typeof sp.toolInput === 'string') collectDeepseekUsage(sp.toolInput, found, false)
    for (const f of found) {
      const u = f.usage
      const prompt = num(u.prompt_tokens)
      const completion = num(u.completion_tokens)
      if (prompt + completion <= 0) continue
      const cached = num(u.cached_tokens ?? u.prompt_tokens_details?.cached_tokens ?? u.prompt_cache_hit_tokens)
      events.push({
        t: t0,
        model: normalizeWbModel(f.model),
        inputTokens: Math.max(0, prompt - cached),
        cacheReadTokens: cached,
        outputTokens: completion,
        total: prompt + completion,
        key: f.convId || f.messageId || f.id || `${t0}-${f.model}-${prompt}-${completion}`,
        fresh: f.inToolOutput,
      })
    }
  }
  return events
}

/** 扫描 traces 目录，增量解析新/变化的文件，返回 WorkBuddy DeepSeek 总览（元） */
function updateWorkbuddyTraces(cfg) {
  if (!wbTraceState) {
    wbTraceState = { files: new Map(), events: new Map(), dirty: false, loaded: false }
  }
  const st = wbTraceState
  const cachePath = wbCacheFilePath(cfg)

  // 首次加载持久化缓存（重启后免全量扫描）
  if (!st.loaded) {
    st.loaded = true
    try {
      const saved = JSON.parse(fs.readFileSync(cachePath, 'utf8'))
      if (saved && typeof saved.files === 'object' && Array.isArray(saved.events)) {
        for (const [p, meta] of Object.entries(saved.files)) {
          st.files.set(p, { size: meta.size ?? 0, mtimeMs: meta.mtime ?? 0 })
        }
        for (const e of saved.events) {
          if (Array.isArray(e) && e.length >= 6) {
            st.events.set(e[0], {
              key: e[0], t: e[1], model: e[2], inputTokens: e[3], cacheReadTokens: e[4], outputTokens: e[5],
              fresh: e[6] === true,
            })
          }
        }
      }
    } catch { /* 首次运行无缓存 */ }
  }

  // 枚举 trace 文件
  const root = expandHome(cfg.workbuddyTracesDir) || path.join(os.homedir(), '.workbuddy', 'traces')
  const files = []
  try {
    for (const e of fs.readdirSync(root, { withFileTypes: true })) {
      if (!e.isDirectory()) continue
      const dir = path.join(root, e.name)
      let subs = []
      try { subs = fs.readdirSync(dir) } catch { continue }
      for (const f of subs) {
        if (f.endsWith('.json')) files.push(path.join(dir, f))
      }
    }
  } catch {
    // traces 目录不存在
  }

  for (const p of files) {
    let fstat
    try { fstat = fs.statSync(p) } catch { continue }
    const prev = st.files.get(p)
    if (prev && prev.size === fstat.size && prev.mtimeMs === fstat.mtimeMs) continue
    let events = []
    try { events = parseWbTraceFile(p) } catch { /* 忽略单个文件解析失败 */ }
    st.files.set(p, { size: fstat.size, mtimeMs: fstat.mtimeMs })
    for (const ev of events) {
      const old = st.events.get(ev.key)
      const total = ev.inputTokens + ev.cacheReadTokens + ev.outputTokens
      const oldTotal = old ? old.inputTokens + old.cacheReadTokens + old.outputTokens : -1
      // 去重优先级：toolOutput 的真实记录 > toolInput 的历史回显；
      // 同一来源取 token 总数最大（流式最后一块）的那条
      if (!old) {
        st.events.set(ev.key, ev)
        st.dirty = true
      } else if (ev.fresh && !old.fresh) {
        st.events.set(ev.key, ev)
        st.dirty = true
      } else if (ev.fresh === old.fresh && total > oldTotal) {
        st.events.set(ev.key, ev)
        st.dirty = true
      }
    }
    if (events.length > 0) st.dirty = true
  }

  // 持久化缓存（仅在有新数据时）
  if (st.dirty) {
    st.dirty = false
    try {
      const saved = {
        files: Object.fromEntries([...st.files.entries()].map(([p, m]) => [p, m])),
        events: [...st.events.values()].map((e) => [e.key ?? `${e.t}-${e.model}`, e.t, e.model, e.inputTokens, e.cacheReadTokens, e.outputTokens, e.fresh === true]),
      }
      fs.mkdirSync(path.dirname(cachePath), { recursive: true })
      const tmp = cachePath + '.tmp'
      fs.writeFileSync(tmp, JSON.stringify(saved))
      fs.renameSync(tmp, cachePath)
    } catch { /* 缓存写失败不影响主流程 */ }
  }

  // 汇总（按 DeepSeek 价格表计费）
  const hourNow = localHourStart(Date.now())
  const dayNow = localDayStart(Date.now())
  let hour = 0, today = 0, total = 0
  let lastEventAt = null
  for (const e of st.events.values()) {
    const cost = costForCall(e, e.model || cfg.defaultModel || 'deepseek-v4-pro', e.t, cfg)
    total += cost
    if (e.t >= dayNow) today += cost
    if (e.t >= hourNow) hour += cost
    if (lastEventAt == null || e.t > lastEventAt) lastEventAt = e.t
  }
  return { hour: round4(hour), today: round4(today), total: round4(total), lastEventAt, calls: st.events.size }
}

// ---------------------------------------------------------------------------
// 计价
// ---------------------------------------------------------------------------

/**
 * 计算一次模型调用的费用（元）。
 * DSH 日志中 inputTokens 已扣除缓存命中部分（cacheReadTokens），
 * outputTokens 已包含思考（reasoningTokens），因此三部分直接乘单价即可。
 */
function costForCall(tok, model, timeMs, cfg) {
  const peakEpoch = new Date(cfg.peakEpochIso).getTime()
  if (Number.isFinite(peakEpoch) && timeMs >= peakEpoch) {
    const tier = cfg.prices.peakOffPeak && cfg.prices.peakOffPeak[model]
    if (tier) {
      const h = beijingHour(timeMs)
      const isPeak = (cfg.peakHoursBeijing || []).some(([s, e]) => h >= s && h < e)
      const p = isPeak ? tier.peak : tier.offPeak
      return (tok.inputTokens * p.miss + tok.cacheReadTokens * p.hit + tok.outputTokens * p.out) / 1_000_000
    }
  }
  const p = (cfg.prices.flat && cfg.prices.flat[model]) || (cfg.prices.flat && cfg.prices.flat['deepseek-v4-pro'])
  if (!p) return 0
  return (tok.inputTokens * p.miss + tok.cacheReadTokens * p.hit + tok.outputTokens * p.out) / 1_000_000
}

// ---------------------------------------------------------------------------
// DeepSeek Harness API
// ---------------------------------------------------------------------------

async function fetchSessionList(cfg) {
  const res = await fetch(`${cfg.apiBase}/api/session.list`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'client-request', rpcId: crypto.randomUUID(), method: 'session.list', payload: {} }),
    signal: AbortSignal.timeout(10_000),
  })
  if (!res.ok) throw new Error(`session.list HTTP ${res.status}`)
  const body = await res.json()
  if (!body || body.result?.ok !== true) {
    throw new Error(`session.list 返回错误: ${JSON.stringify(body?.result?.error ?? body).slice(0, 200)}`)
  }
  return body.result.value.items || []
}

async function fetchBalance(cfg) {
  const key = cfg.apiKey
  if (!key) return { balance: null, balanceError: '未配置 DeepSeek API Key' }
  try {
    const res = await fetch('https://api.deepseek.com/user/balance', {
      headers: { Authorization: `Bearer ${key}`, Accept: 'application/json' },
      signal: AbortSignal.timeout(15_000),
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const data = await res.json()
    const infos = data.balance_infos || []
    if (!infos.length) throw new Error('返回内容异常')
    // 优先人民币，其次第一个
    const info = infos.find((x) => x.currency === 'CNY') || infos[0]
    return {
      balance: {
        currency: info.currency || 'CNY',
        totalBalance: info.total_balance ?? null,
        grantedBalance: info.granted_balance ?? null,
        toppedUpBalance: info.topped_up_balance ?? null,
        fetchedAt: Date.now(),
      },
      balanceError: null,
    }
  } catch (err) {
    return { balance: null, balanceError: `余额获取失败: ${String(err.message || err)}` }
  }
}

// ---------------------------------------------------------------------------
// 会话目录扫描
// ---------------------------------------------------------------------------

/** 扫描 data/sessions 下所有会话日志文件，返回 Map<sessionId, filePath> */
function scanSessionFiles(cfg) {
  const sessionsRoot = path.join(cfg.dshDataDir, 'sessions')
  const map = new Map()
  let dir
  try {
    dir = fs.readdirSync(sessionsRoot, { withFileTypes: true })
  } catch {
    return map
  }
  for (const entry of dir) {
    if (!entry.isDirectory()) continue
    const projectDir = path.join(sessionsRoot, entry.name)
    let sub
    try {
      sub = fs.readdirSync(projectDir, { withFileTypes: true })
    } catch {
      continue
    }
    for (const s of sub) {
      if (!s.isDirectory()) continue
      const sessionId = s.name
      const dirPath = path.join(projectDir, sessionId)
      for (const name of ['session.jsonl.zstd', 'session.jsonl']) {
        const p = path.join(dirPath, name)
        if (fs.existsSync(p)) {
          map.set(sessionId, p)
          break
        }
      }
    }
  }
  return map
}

// ---------------------------------------------------------------------------
// 主循环
// ---------------------------------------------------------------------------

export async function runOnce(cfg) {  const snapshot = {
    generatedAt: Date.now(),
    hourStart: localHourStart(Date.now()),
    overall: { hour: 0, today: 0, total: 0 },
    hourly: [], // 最近 24 个自然小时（整体）
    tasks: [],
    projects: [],
    balance: null,
    balanceError: null,
    workbuddy: null,
    workbuddyError: null,
    errors: [],
    stats: { sessionsParsed: 0, usageEvents: 0, framesDecoded: 0 },
  }

  // 1. 会话列表（running 状态 / cwd / 标题）
  let listItems = []
  try {
    listItems = await fetchSessionList(cfg)
  } catch (err) {
    snapshot.errors.push(String(err.message || err))
  }
  // 2. 扫描会话日志文件
  const files = scanSessionFiles(cfg)

  // 会话统计临时结构
  const sessions = new Map() // sessionId -> stat
  const ensure = (sessionId) => {
    let s = sessions.get(sessionId)
    if (!s) {
      s = {
        sessionId,
        cwd: null,
        title: null,
        firstText: null,
        running: false,
        model: null,
        parentSessionId: null,
        isSubagent: false,
        delegationDepth: 0,
        blank: false,
        hour: 0, today: 0, total: 0,
        tokens: { input: 0, output: 0, cacheRead: 0 },
        lastEventAt: null,
        updatedAt: null,
      }
      sessions.set(sessionId, s)
    }
    return s
  }
  for (const item of listItems) {
    const s = ensure(item.sessionId)
    s.running = !!item.running
    s.cwd = item.cwd || s.cwd
    s.updatedAt = item.updatedAt || s.updatedAt
    s.parentSessionId = item.parentSessionId || null
    s.isSubagent = item.origin === 'subagent' || !!item.parentSessionId
    s.blank = item.blank === true
    if (item.projections?.values?.title) s.title = item.projections.values.title
  }
  // 父链：子代理会话 → 顶层会话
  const parentOf = new Map()
  for (const item of listItems) {
    if (item.parentSessionId) parentOf.set(item.sessionId, item.parentSessionId)
  }
  const rootOf = (sessionId) => {
    const seen = new Set()
    let cur = sessionId
    while (parentOf.has(cur) && !seen.has(cur)) {
      seen.add(cur)
      cur = parentOf.get(cur)
    }
    return cur
  }

  // 解析每个会话日志
  const hourNow = snapshot.hourStart
  const dayNow = localDayStart(Date.now())
  const hourlyMap = new Map()
  const horizon = hourNow - 23 * 3600_000 // 最近 24 个桶

  for (const [sessionId, filePath] of files) {
    const s = ensure(sessionId)
    let decoded
    try {
      const st = fs.statSync(filePath)
      decoded = decodeLogFile(filePath)
      snapshot.stats.framesDecoded += decoded.framesDecoded
    } catch (err) {
      snapshot.errors.push(`${sessionId} 日志读取失败: ${err.message}`)
      continue
    }
    snapshot.stats.sessionsParsed++
    let events
    try {
      events = parseEvents(decoded.text)
    } catch (err) {
      snapshot.errors.push(`${sessionId} 日志解析失败: ${err.message}`)
      continue
    }
    let model = null
    for (const e of events) {
      if (e.kind === 'header') {
        if (!s.cwd && e.cwd) s.cwd = e.cwd
        if (typeof e.delegationDepth === 'number') s.delegationDepth = e.delegationDepth
      } else if (e.kind === 'title' && !s.title) s.title = e.title
      else if (e.kind === 'model' && !model) model = e.model
      else if (e.kind === 'user-text' && !s.firstText) s.firstText = e.text
    }
    if (model) s.model = model
    const effModel = s.model || cfg.defaultModel || 'deepseek-v4-pro'

    for (const e of events) {
      if (e.kind !== 'usage' || e.time == null) continue
      const cost = costForCall(e, effModel, e.time, cfg)
      snapshot.stats.usageEvents++
      s.total += cost
      s.tokens.input += e.inputTokens
      s.tokens.output += e.outputTokens
      s.tokens.cacheRead += e.cacheReadTokens
      if (e.time >= dayNow) s.today += cost
      if (e.time >= hourNow) s.hour += cost
      if (e.time >= horizon) {
        const hs = localHourStart(e.time)
        hourlyMap.set(hs, (hourlyMap.get(hs) || 0) + cost)
      }
      if (s.lastEventAt == null || e.time > s.lastEventAt) s.lastEventAt = e.time
    }
  }

  // 3. 空白会话过滤：DSH 工作区侧边栏不显示的空白会话（blank 标记，
  //    或既无标题、无用户消息、也无任何用量的会话）不生成任务行。
  for (const s of sessions.values()) {
    if (!s.blank && s.total === 0 && !s.title && !s.firstText) s.blank = true
  }

  // 4. 子代理归并：把每个会话的用量挂到它的顶层会话（root）上。
  //    DSH 里一个任务 = 一个顶层会话，任务内派生的子代理会话不算独立任务。
  for (const s of sessions.values()) {
    if (s.blank) continue
    if (s.parentSessionId == null && s.delegationDepth === 0) continue
    const rid = rootOf(s.sessionId)
    if (rid === s.sessionId) continue // 父链缺失（列表里没有），按独立会话处理
    const root = ensure(rid)
    if (!root.models) root.models = new Set()
    root.total += s.total
    root.today += s.today
    root.hour += s.hour
    root.tokens.input += s.tokens.input
    root.tokens.output += s.tokens.output
    root.tokens.cacheRead += s.tokens.cacheRead
    root.running = root.running || s.running
    root.subCount = (root.subCount || 0) + 1
    if (!root.cwd && s.cwd) root.cwd = s.cwd
    if (!root.title && s.title) root.title = s.title
    if (!root.firstText && s.firstText) root.firstText = s.firstText
    if (s.model) root.models.add(s.model)
    if (s.lastEventAt != null && (root.lastEventAt == null || s.lastEventAt > root.lastEventAt)) {
      root.lastEventAt = s.lastEventAt
    }
    s.attributedTo = rid
  }

  // 5. 汇总（只统计顶层会话；子代理的用量已经并入 root）
  let totalHour = 0, totalToday = 0, totalAll = 0
  for (const s of sessions.values()) {
    if (s.attributedTo || s.blank) continue
    totalHour += s.hour
    totalToday += s.today
    totalAll += s.total
  }
  snapshot.overall = { hour: totalHour, today: totalToday, total: totalAll }

  const buckets = [...hourlyMap.entries()].sort((a, b) => a[0] - b[0])
  snapshot.hourly = buckets.map(([start, cost]) => ({ start, cost }))

  // 6. 项目汇总：一行项目 = 该目录下所有顶层任务之和；
  //    一个顶层会话 = 一个任务（含它派生的全部子代理）
  const projMap = new Map()
  const taskNameOf = (s) => {
    if (s.title) return s.title
    if (s.firstText) return s.firstText.slice(0, 40)
    return `未命名·${s.sessionId.slice(-4)}`
  }

  for (const s of sessions.values()) {
    if (s.attributedTo) continue
    if (s.blank && s.total === 0) continue // 空白会话不生成任务
    const key = s.cwd || '(未知)'
    let p = projMap.get(key)
    if (!p) {
      p = { cwd: s.cwd, name: s.cwd ? path.basename(s.cwd) : '未知项目', hour: 0, today: 0, total: 0, running: false, sessionCount: 0, lastEventAt: null, tasks: [] }
      projMap.set(key, p)
    }
    p.hour += s.hour
    p.today += s.today
    p.total += s.total
    p.running = p.running || s.running
    p.sessionCount++
    if (s.lastEventAt != null && (p.lastEventAt == null || s.lastEventAt > p.lastEventAt)) p.lastEventAt = s.lastEventAt
    const modelSet = new Set([...(s.models || []), s.model].filter(Boolean))
    p.tasks.push({
      key: s.sessionId,
      name: taskNameOf(s),
      running: s.running,
      hour: round4(s.hour),
      today: round4(s.today),
      total: round4(s.total),
      sessionCount: 1 + (s.subCount || 0),
      subCount: s.subCount || 0,
      model: modelSet.size === 1 ? [...modelSet][0] : null,
      tokens: s.tokens,
      lastEventAt: s.lastEventAt,
    })
  }

  const finishProject = (p) => ({
    cwd: p.cwd,
    name: p.name,
    hour: round4(p.hour),
    today: round4(p.today),
    total: round4(p.total),
    running: p.running,
    sessionCount: p.sessionCount,
    lastEventAt: p.lastEventAt,
    tasks: p.tasks.sort((a, b) => b.total - a.total),
  })

  snapshot.projects = [...projMap.values()]
    .sort((a, b) => b.total - a.total)
    .map(finishProject)

  // 全局任务列表（与项目内任务一致，加上项目名方便展示）
  snapshot.tasks = [...projMap.values()]
    .flatMap((p) => p.tasks.map((t) => ({ ...t, project: p.name, cwd: p.cwd })))
    .sort((a, b) => (b.lastEventAt ?? 0) - (a.lastEventAt ?? 0))

  // WorkBuddy 绑定的 DeepSeek 用量总览（元，独立于 Harness 金额）
  try {
    snapshot.workbuddy = updateWorkbuddyTraces(cfg)
    snapshot.workbuddyError = null
  } catch (err) {
    snapshot.workbuddy = null
    snapshot.workbuddyError = `WorkBuddy 数据读取失败: ${err.message}`
  }

  return snapshot
}

function round4(v) {
  return Math.round(v * 10000) / 10000
}

export async function main() {
  const args = process.argv.slice(2)
  let configPath = DEFAULT_CONFIG_PATH
  let once = false
  let parentPid = null
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--config' && args[i + 1]) configPath = args[++i]
    else if (args[i] === '--once') once = true
    else if (args[i] === '--parent-pid' && args[i + 1]) parentPid = Number(args[++i])
  }

  let cfg
  try {
    cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'))
  } catch (err) {
    console.error(`[DeepSeekSpend] 无法读取配置文件 ${configPath}: ${err.message}`)
    process.exit(2)
  }
  // 展开路径与默认值
  cfg.dshDataDir = expandHome(cfg.dshDataDir)
  cfg.snapshotPath = expandHome(cfg.snapshotPath)
  cfg.triggerPath = expandHome(cfg.triggerPath)
  cfg.pollIntervalMs = cfg.pollIntervalMs || 8000
  cfg.balanceIntervalMs = cfg.balanceIntervalMs || 300_000

  // 数据目录自动识别：配置的目录不可用时，按常见位置探测
  // （换机器/下载安装后无需手改配置即可自动找到 DSH 数据）
  {
    const candidates = [
      cfg.dshDataDir,
      process.env.DSH_HOME,
      path.join(os.homedir(), 'Documents', 'DeepSeek-Harness', 'data'),
    ].filter(Boolean)
    let resolved = null
    for (const c of candidates) {
      try {
        if (fs.existsSync(path.join(c, 'sessions'))) { resolved = c; break }
      } catch {}
    }
    if (resolved) {
      cfg.dshDataDir = resolved
    } else {
      // 都找不到时用最常见位置兜底（错误会体现在快照里）
      cfg.dshDataDir = candidates[0] || path.join(os.homedir(), 'Documents', 'DeepSeek-Harness', 'data')
    }
  }
  if (!cfg.apiKey) {
    const credPath = path.join(cfg.dshDataDir, '.credentials.yaml')
    cfg.apiKey = readApiKey(credPath)
  }

  let lastBalanceAt = 0
  let balance = null
  let balanceError = null
  let lastTriggerMtime = 0

  const run = async (forced) => {
    // 每轮开始也重新探测 trigger 文件
    try {
      const tm = fs.statSync(cfg.triggerPath).mtimeMs
      if (tm > lastTriggerMtime) {
        lastTriggerMtime = tm
        forced = true
      }
    } catch {}

    let snap
    try {
      snap = await runOnce(cfg)
    } catch (err) {
      snap = {
        generatedAt: Date.now(),
        hourStart: localHourStart(Date.now()),
        overall: { hour: 0, today: 0, total: 0 },
        hourly: [],
        tasks: [],
        projects: [],
        balance: null,
        balanceError: null,
        errors: [`采集失败: ${err.message}`],
        stats: {},
      }
    }

    // 余额（首次 + 定时 + 强制刷新）
    if (forced || Date.now() - lastBalanceAt >= cfg.balanceIntervalMs) {
      const r = await fetchBalance(cfg)
      balance = r.balance
      balanceError = r.balanceError
      lastBalanceAt = Date.now()
    }
    snap.balance = balance
    snap.balanceError = balanceError

    // 原子写入快照
    const dir = path.dirname(cfg.snapshotPath)
    fs.mkdirSync(dir, { recursive: true })
    const tmp = cfg.snapshotPath + '.tmp'
    fs.writeFileSync(tmp, JSON.stringify(snap))
    fs.renameSync(tmp, cfg.snapshotPath)
    return snap
  }

  if (once) {
    await run(true)
    return
  }

  // 监控父进程：App 退出后自杀，避免孤儿进程（被 launchd 收养后 ppid 会变，
  // 所以用启动时记录的父 PID 判断）
  const ownerAlive = () => {
    if (parentPid) {
      try {
        process.kill(parentPid, 0)
        return true
      } catch {
        return false
      }
    }
    try {
      process.kill(process.ppid, 0)
      return true
    } catch {
      return false
    }
  }

  await run(true)
  const tick = async () => {
    if (!ownerAlive()) {
      process.exit(0)
    }
    try {
      await run(false)
    } catch (err) {
      console.error(`[DeepSeekSpend] 轮询失败: ${err.message}`)
    }
    setTimeout(tick, cfg.pollIntervalMs)
  }
  setTimeout(tick, cfg.pollIntervalMs)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(`[DeepSeekSpend] 致命错误: ${err.stack || err}`)
    process.exit(1)
  })
}
