// Real locked batch/pipeline/MCP client, shared stdio connection, and real Agents.
// PTC's program runtime is a fixture that invokes the actual production SDK binding.
// DSH_PREFIX=<prepared patched prefix> node --test runtime/tests/phone-caller-context.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

if (!process.env.DSH_PREFIX) throw new Error('Set DSH_PREFIX to the prepared patched runtime');
const base = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
const load = name => import(pathToFileURL(join(base, name, 'lib/index.js')));
const { Context } = await load('cordis');
const { NativeToolExecutor } = await load('dsh-tool-executor-native');
const { PtcExecutor } = await load('dsh-tool-executor-ptc');
let serial = 0;

async function fixture(t, { enabled = true, supported = true } = {}) {
  const ctx = new Context();
  t.after(() => ctx.fiber.dispose());
  for (const name of ['dsh-session', 'dsh-session-projection', 'dsh-agent', 'dsh-llm',
    'dsh-tools', 'dsh-system-prompt', 'dsh-mcp-resources']) await ctx.plugin((await load(name)).default);
  await ctx.plugin((await load('dsh-agent-loop')).AgentLoop, { agents: [] });
  await ctx.plugin(await load('dsh-mcp-client'), {
    serverName: 'phone', transport: 'stdio', command: process.execPath,
    args: [fileURLToPath(new URL('./fixtures/phone-caller-mcp.mjs', import.meta.url)), supported ? 'supported' : 'legacy'],
    dshGoPhoneCaller: enabled, failOnStartupError: true, reconnect: { enabled: false },
  });
  const native = new NativeToolExecutor(ctx);
  const create = async () => (await ctx.agents.create({ sessionId: `phone-caller-${++serial}` })).agent;
  const run = async (agent, turn = 1, args = {}, log = true, executor = native) => {
    const id = `phone-call-${++serial}`;
    const ptc = executor !== native;
    const batch = await executor.execute({
      calls: [{ id, name: ptc ? 'run_code' : 'mcp__phone__screen', arguments: JSON.stringify(
        ptc ? { code: 'fixture invokes the SDK binding', description: 'Caller propagation fixture' } : args) }],
      ...(agent === undefined ? {} : { agent }),
      ...(log ? { log: { turn, step: 1 } } : {}), signal: new AbortController().signal,
    });
    const result = batch.results[0].result;
    assert.equal(result.isError, false, JSON.stringify(result));
    const value = ptc ? result.value.result : result.value;
    return { id, ...JSON.parse(value.content[0].text) };
  };
  return { ctx, create, run, native };
}

test('shared MCP client keeps two Agents and each turn separate, arguments cannot replace caller', async t => {
  const f = await fixture(t), a = await f.create(), b = await f.create();
  const forged = { sessionId: b.session.id, phoneCaller: { sessionId: b.session.id, runId: 'forged' } };
  const [one, other] = await Promise.all([f.run(a, 1, forged), f.run(b)]);
  assert.equal(one.caller.sessionId, a.session.id);
  assert.equal(other.caller.sessionId, b.session.id);
  assert.notEqual(one.caller.runId, other.caller.runId);
  assert.equal(one.caller.callId, one.id);
  assert.deepEqual(one.args, forged);
  const same = await f.run(a, 1), next = await f.run(a, 2);
  assert.equal(same.caller.runId, one.caller.runId);
  assert.notEqual(next.caller.runId, one.caller.runId);
});

test('a delayed call keeps its admitted turn while a later turn completes', async t => {
  const f = await fixture(t), a = await f.create();
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  const prepare = f.native.pipeline.prepare.bind(f.native.pipeline);
  let first = true;
  f.native.pipeline.prepare = async input => {
    if (first) { first = false; entered.resolve(); await release.promise; }
    return prepare(input);
  };
  const old = f.run(a, 1);
  await entered.promise;
  try {
    const next = await f.run(a, 2);
    release.resolve();
    const previous = await old;
    assert.notEqual(previous.caller.runId, next.caller.runId);
    assert.equal((await f.run(a, 1)).caller.runId, previous.caller.runId);
  } finally { release.resolve(); }
});

test('PTC inherits the outer caller through the real nested binding, with its own cancellation signal', async t => {
  const f = await fixture(t), a = await f.create();
  f.ctx.provide('workingDirectory', { ensure: async () => process.cwd() });
  f.ctx.provide('ptcRuntime', {
    language: 'typescript', programFormat: 'function-body',
    resolve: request => request,
    async run(request) {
      const value = await request.bindings[0].functions.mcp__phone__screen({
        phoneCaller: { sessionId: 'forged', runId: 'forged' },
      });
      return { logs: [], value };
    },
    release() {},
  });
  const native = await f.run(a, 1);
  const ptc = await f.run(a, 1, {}, true, new PtcExecutor(f.ctx));
  assert.equal(ptc.caller.sessionId, a.session.id);
  assert.equal(ptc.caller.runId, native.caller.runId);
  assert.equal(ptc.caller.callId, `${ptc.id}:ptc:1`);
});

test('no host Agent/log, no opt-in, or old server capability preserves legacy wire', async t => {
  const f = await fixture(t), a = await f.create();
  assert.equal((await f.run(a, 1, {}, false)).caller, null);
  assert.equal((await f.run(undefined, 1, {}, false)).caller, null);
  for (const options of [{ enabled: false }, { supported: false }]) {
    const old = await fixture(t, options);
    assert.equal((await old.run(await old.create())).caller, null);
  }
});
