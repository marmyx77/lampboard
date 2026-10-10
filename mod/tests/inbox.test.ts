// The Hub's signed commands (D152), checked by `claude plugin test`: the mod
// runs what the panel's key signed for this session, now, once — and nothing
// else, whatever the token or the permission key would allow.
import { expect, mock, test } from 'claude-code/testing'

// RFC 8032's first test key; the vectors were signed with it (and one with another).
const PUB = 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a'
const SID = '8c1d2f3a-0b4e-4c5d-9e6f-7a8b9c0d1e2f'
const TS = 1791000000000
const VALID = {"payload": "{\"args\":{\"asUser\":\"true\",\"text\":\"run the tests\"},\"nonce\":\"a1\",\"op\":\"submit\",\"sid\":\"8c1d2f3a-0b4e-4c5d-9e6f-7a8b9c0d1e2f\",\"ts\":1791000000000,\"v\":2}", "sig": "3866b3fd03f01c1b02b1d006ef6750185573cc2cd8968ac610e486e0f30c8bad382114df0a3290e816ece338cc623b871c873d3a58b262eb58e7b71d40d3020a"}
const FORGED = {"payload": "{\"args\":{\"asUser\":\"true\",\"text\":\"rm -rf ~\"},\"nonce\":\"b2\",\"op\":\"submit\",\"sid\":\"8c1d2f3a-0b4e-4c5d-9e6f-7a8b9c0d1e2f\",\"ts\":1791000000000,\"v\":2}", "sig": "45d44fec87d496d8a07336a44ff270f092186ee15b5ce28427f6d5532a3ec2fbb7580acf11a9b14142a31231947e9eca66dc1c8d6cce45590e1cd7190f8a3603"}
const OTHER_SESSION = {"payload": "{\"args\":{\"text\":\"hello\"},\"nonce\":\"c3\",\"op\":\"submit\",\"sid\":\"1f2e3d4c-5b6a-4987-8a7b-6c5d4e3f2a1b\",\"ts\":1791000000000,\"v\":2}", "sig": "4c3093d87704a3897b499ea51eac21f18156d6615da4f9ae83b8fb8dae04e64abe17c17822e49fd5bb9f6da8c01b5888f5314eda825c064e5a7499b77ecd9c01"}
const STALE = {"payload": "{\"args\":{\"text\":\"late\"},\"nonce\":\"d4\",\"op\":\"submit\",\"sid\":\"8c1d2f3a-0b4e-4c5d-9e6f-7a8b9c0d1e2f\",\"ts\":1790999880000,\"v\":2}", "sig": "d6fd86ef1611b75a73654294e7f9c5a864d9900994685b06f5144cc2bee7f508e740ded90df580d0f2f20d00c9c244be835d0b50239a34021efea5e6ae79f409"}
const COMMAND = {"payload": "{\"args\":{\"args\":\"\",\"name\":\"compact\"},\"nonce\":\"e5\",\"op\":\"command\",\"sid\":\"8c1d2f3a-0b4e-4c5d-9e6f-7a8b9c0d1e2f\",\"ts\":1791000000000,\"v\":2}", "sig": "79d42d993261f4c4ca52924f35eac3163e1c9aafe4c9645a2cd69750d6a6f6f8e00c3988fec88badee05919fd34fc85347db07f88faf5b4fe1d09a574d97f401"}
const MODEL = {"payload": "{\"args\":{\"value\":\"claude-sonnet-5-5\"},\"nonce\":\"f6\",\"op\":\"model\",\"sid\":\"8c1d2f3a-0b4e-4c5d-9e6f-7a8b9c0d1e2f\",\"ts\":1791000000000,\"v\":2}", "sig": "5c09b61cfe7aa3182898a48d3ac922b674380ac302f2e3f71bf3379ce071d8fc0f77511f948d62dbcae8a7f71c597e5e0a5ac317785d9052b66d34afda80b90f"}
const WAKE = 'LampBoard wake [v2]'

function panel(on, inbox: unknown[]) {
  const calls = { submitted: [] as any[], commands: [] as any[], done: [] as any[], fetched: 0 }
  mock.clock(on, { now: TS })
  mock.store(on, {})
  mock.env(on, { HOME: '/home/someone' })
  on('session.id', () => ({ value: SID }))
  on('fs.read', ($, e) => {
    if (e.path.endsWith('/.lampboard/token')) return { value: 'abcdef0123456789abcdef0123456789' }
    if (e.path.endsWith('/.lampboard/port')) return { value: '19877' }
    if (e.path.endsWith('/.lampboard/panel-key.pub')) return { value: PUB + '\n' }
    return { deny: 'no such file' }
  })
  on('http.fetch', ($, e) => {
    if (e.url.endsWith('/mod/inbox')) {
      calls.fetched += 1
      return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify(calls.fetched === 1 ? inbox : []) } }
    }
    if (e.url.endsWith('/mod')) {
      calls.done.push(JSON.parse(e.init.body))
      return { value: { status: 204, ok: true, headers: {}, text: '' } }
    }
    return { deny: 'nothing else answers' }
  })
  on('prompt.submit', ($, e) => { calls.submitted.push(e); return { text: e.text } })
  on('command.run', ($, e) => { calls.commands.push(e); return {} })
  on('session.receive', ($, e) => ({ text: e.text }))
  return calls
}

async function settle(calls, until: () => boolean) {
  for (let i = 0; i < 200 && !until(); i++) await new Promise((r) => setTimeout(r, 5))
}

test('the wake is taken, and a command the panel signed is run once, as the person', async ($, on) => {
  const calls = panel(on, [VALID, VALID])
  const taken = await $.session.receive({ origin: { kind: 'peer-send-message' }, text: WAKE })
  expect(taken.consumed).toBe('lampboard-wake')
  await settle(calls, () => calls.done.length >= 1)
  expect(calls.submitted.length).toBe(1)
  expect(calls.submitted[0].text).toBe('run the tests')
  expect(calls.done[0]).toMatchObject({ kind: 'done', nonce: 'a1', op: 'submit', ok: true })
})

test('a command signed by another key, for another session, or out of its minute is never run', async ($, on) => {
  const calls = panel(on, [FORGED, OTHER_SESSION, STALE])
  await $.session.receive({ origin: { kind: 'peer-send-message' }, text: WAKE })
  await settle(calls, () => calls.fetched >= 1)
  await new Promise((r) => setTimeout(r, 100))
  expect(calls.submitted.length).toBe(0)
  expect(calls.done.length).toBe(0)
})

test('a slash command goes through command.run, and a model is kept for this session alone', async ($, on) => {
  const calls = panel(on, [COMMAND, MODEL])
  on('turn.step', async function* ($, e) {
    return { turnId: e.turnId, index: e.index, answer: e.model, toolUses: [], stopReason: 'end_turn', usage: null }
  })
  await $.session.receive({ origin: { kind: 'peer-send-message' }, text: WAKE })
  await settle(calls, () => calls.done.length >= 2)
  expect(calls.commands.length).toBe(1)
  expect(calls.commands[0].command).toBe('compact')
  const stream = $.turn.step({ turnId: 't1', index: 0, model: 'claude-haiku-5-5', messageCount: 1 })
  let step = await stream.next()
  while (step.done !== true) step = await stream.next()
  expect(step.value.answer).toBe('claude-sonnet-5-5')
})

test('any other message passes to the session untouched', async ($, on) => {
  const calls = panel(on, [])
  const out = await $.session.receive({ origin: { kind: 'peer-send-message' }, text: 'a peer says hello' })
  expect(out.text).toBe('a peer says hello')
  expect(calls.fetched).toBe(0)
})
