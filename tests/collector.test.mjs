import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import { costForCall, parseEvents } from '../collector.mjs'

const config = JSON.parse(readFileSync(new URL('../config.json', import.meta.url), 'utf8'))

test('uses the verified DeepSeek V4 Pro CNY price table', () => {
  const cost = costForCall(
    { inputTokens: 1_000_000, cacheReadTokens: 1_000_000, outputTokens: 1_000_000 },
    'deepseek-v4-pro',
    Date.now(),
    config,
  )

  assert.equal(cost, 9.025)
})

test('uses the verified DeepSeek V4 Flash CNY price table', () => {
  const cost = costForCall(
    { inputTokens: 1_000_000, cacheReadTokens: 1_000_000, outputTokens: 1_000_000 },
    'deepseek-v4-flash',
    Date.now(),
    config,
  )

  assert.equal(cost, 3.02)
})

test('does not silently price an unknown model as V4 Pro', () => {
  const cost = costForCall(
    { inputTokens: 1_000_000, cacheReadTokens: 0, outputTokens: 0 },
    'unknown-model',
    Date.now(),
    config,
  )

  assert.equal(cost, 0)
})

test('extracts model and token usage from Harness events', () => {
  const events = parseEvents([
    JSON.stringify({ type: 'request/context', time: 1, data: { model: 'deepseek-v4-flash' } }),
    JSON.stringify({
      type: 'assistant/message',
      time: 2,
      data: { usage: { inputTokens: 20, cacheReadTokens: 10, outputTokens: 5 } },
    }),
  ].join('\n'))

  assert.deepEqual(events, [
    { kind: 'model', time: 1, model: 'deepseek-v4-flash' },
    {
      kind: 'usage',
      time: 2,
      inputTokens: 20,
      outputTokens: 5,
      cacheReadTokens: 10,
      cacheWriteTokens: 0,
      reasoningTokens: 0,
    },
  ])
})
