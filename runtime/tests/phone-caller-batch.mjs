// Runs the actual patched batch module with synthetic logging imports and pipeline.
// No package installation needed: DSH_PREFIX=<patched prefix> node --experimental-vm-modules --test runtime/tests/phone-caller-batch.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { SourceTextModule, SyntheticModule } from 'node:vm';

if (!process.env.DSH_PREFIX) throw new Error('Set DSH_PREFIX to the prepared patched runtime');
const source = await readFile(join(process.env.DSH_PREFIX, 'node_modules/@deepseek-ai/dsh-tools/lib/types/batch.js'), 'utf8');
const module = new SourceTextModule(source);
const imports = {
  'node:crypto': { randomUUID },
  './executor.js': { ToolBatchExecutionError: class extends Error { constructor(error) { super(error.message, { cause: error }); } } },
  './contracts.js': { TOOL_ABORTED_BEFORE_DISPATCH: 'ABORTED' },
  '@deepseek-ai/dsh-llm': { createToolResultMessage: value => value },
  '@deepseek-ai/dsh-util-values': { assertNever() { throw Error('unexpected scheduler branch'); } },
};
await module.link(name => {
  const values = imports[name];
  assert.ok(values, `unexpected dependency ${name}`);
  return new SyntheticModule(Object.keys(values), function () {
    for (const [key, value] of Object.entries(values)) this.setExport(key, value);
  });
});
await module.evaluate();
const { executeToolBatch } = module.namespace;
const agent = id => ({ session: { id, append() { return { seq: 1 }; } } });
let seq = 0;
async function call(owner, turn, before = async () => {}) {
  let captured;
  const pipeline = {
    executionMode: () => ({ kind: 'parallel' }),
    async prepare(exec) { await before(); return { kind: 'dispatch', exec }; },
    async dispatch(exec) { captured = exec; return { result: { content: [], isError: false } }; },
    async complete(_exec, outcome) { return outcome.result; },
  };
  await executeToolBatch({
    calls: [{ id: String(++seq), name: 'screen', arguments: JSON.stringify({ phoneCaller: { sessionId: 'forged', runId: 'forged' } }) }],
    ...(owner ? { agent: owner } : {}), ...(turn === undefined ? {} : { log: { turn, step: 1 } }),
    signal: new AbortController().signal,
  }, pipeline, () => 1);
  return captured;
}

test('owner and turn survive delay; same turn stable, recreated Agent distinct, raw args ignored', async () => {
  const a = agent('A'), b = agent('B');
  const gate = Promise.withResolvers(), entered = Promise.withResolvers();
  const old = call(a, 1, async () => { entered.resolve(); await gate.promise; });
  await entered.promise;
  const next = await call(a, 2), other = await call(b, 1);
  gate.resolve();
  const previous = await old, same = await call(a, 1), restored = await call(agent('A'), 1);
  assert.equal(previous.phoneCaller.sessionId, 'A');
  assert.equal(other.phoneCaller.sessionId, 'B');
  assert.equal(previous.phoneCaller.runId, same.phoneCaller.runId);
  for (const item of [next, other, restored]) assert.notEqual(item.phoneCaller.runId, previous.phoneCaller.runId);
  assert.equal(previous.arguments.phoneCaller.sessionId, 'forged');
  assert.ok(Object.isFrozen(previous.phoneCaller));
  assert.throws(() => { previous.phoneCaller.sessionId = 'B'; }, TypeError);
});

test('calls without host Agent or logged turn retain legacy attribution', async () => {
  assert.equal((await call(undefined, undefined)).phoneCaller, undefined);
  assert.equal((await call(agent('A'), undefined)).phoneCaller, undefined);
});
