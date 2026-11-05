// Real dsh web HTTP + remote.mux authorization, isolated HOME, no model requests.
// DSH_PREFIX=<patched prefix> node runtime/tests/schedule-authorization-live.mjs
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { once } from 'node:events';
import net from 'node:net';

if (!process.env.DSH_PREFIX) throw Error('Set DSH_PREFIX to an isolated patched runtime');
const prefix = resolve(process.env.DSH_PREFIX);
const { default: WebSocket } = await import(pathToFileURL(join(prefix, 'node_modules/ws/wrapper.mjs')));
const home = await mkdtemp(join(tmpdir(), 'dsh-schedule-live-'));
// Offline synthetic existing-profile fixtures; no execution or model calls.
const { createAfterScheduleRecord } = await import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai/dsh-schedule/lib/index.js')));
const seeded = {};
for (const kind of ['new_once', 'new']) {
  const id = `seed-${kind}`;
  seeded[id] = { record: createAfterScheduleRecord(id, 'Synthetic paused task', 86400, Date.now(), id),
    target: kind === 'new_once' ? { kind, sessionId: 'reserved-only', create: {} } : { kind, create: {} },
    involvedSessionIds: [], status: 'paused', deliveryHistory: { records: [], earlierRecordsUnavailable: false, earlierRecordsPruned: false } };
}
await mkdir(join(home, 'dsh/storages'), { recursive: true });
await writeFile(join(home, 'dsh/storages/schedule.json'), JSON.stringify({ unit: { name: 'schedule', version: 2 }, global: null, tables: { tasks: seeded } }));
const reservation = net.createServer();
reservation.listen(0, '127.0.0.1'); await once(reservation, 'listening');
const port = reservation.address().port; await new Promise(done => reservation.close(done));
const origin = `http://127.0.0.1:${port}`;
const processHandle = spawn(process.execPath, [join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js'), 'web', '--host', '127.0.0.1', '--port', String(port), '--no-open'], {
  env: { ...process.env, HOME: home, DSH_HOME: join(home, 'dsh'), TZ: 'UTC' }, stdio: ['ignore', 'pipe', 'pipe'],
});
let socket;
const lifetime = AbortSignal.timeout(30000);
try {
  const token = await new Promise((done, fail) => {
    let output = '';
    const abort = () => fail(Error('Isolated dsh web startup timed out'));
    lifetime.addEventListener('abort', abort, { once: true });
    processHandle.on('error', fail);
    processHandle.on('exit', code => fail(Error(`Isolated dsh web exited before startup (${code})`)));
    const consume = chunk => {
      output += chunk.toString();
      const match = output.match(/token=([\w-]+)/);
      if (match) { lifetime.removeEventListener('abort', abort); done(match[1]); }
    };
    processHandle.stdout.on('data', consume);
    processHandle.stderr.on('data', consume);
  });
  const login = await fetch(`${origin}/?token=${token}`, { redirect: 'manual', signal: lifetime });
  const cookie = login.headers.getSetCookie().map(value => value.split(';')[0]).join('; ');
  assert(cookie, 'isolated login establishes a cookie');
  let sequence = 0;
  async function rpc(method, args = {}) {
    const response = await fetch(`${origin}/api/${method}`, { method: 'POST', headers: { cookie, 'content-type': 'application/json' }, body: JSON.stringify({ type: 'client-request', rpcId: `schedule-live-${++sequence}`, method, payload: { args } }), signal: lifetime });
    assert.equal(response.status, 200);
    const body = await response.json();
    return body.result;
  }
  socket = new WebSocket(origin.replace('http:', 'ws:') + '/api/remote.mux', { headers: { cookie } });
  const messages = [], waiters = [];
  socket.on('message', data => {
    const frame = JSON.parse(String(data));
    if (frame.type !== 'item' || frame.streamId !== 'events') return;
    const i = waiters.findIndex(waiter => waiter.match(frame.value));
    if (i < 0) messages.push(frame.value);
    else waiters.splice(i, 1)[0].resolve(frame.value);
  });
  function next(match) {
    const i = messages.findIndex(match);
    if (i >= 0) return Promise.resolve(messages.splice(i, 1)[0]);
    return new Promise((resolve, reject) => {
      const waiter = { match, resolve };
      waiters.push(waiter);
      lifetime.addEventListener('abort', () => reject(Error('Expected remote event timed out')), { once: true });
    });
  }
  await once(socket, 'open');
  socket.send(JSON.stringify({ type: 'open', streamId: 'events', endpoint: '$events', payload: { args: {} } }));
  const ready = await next(frame => frame.type === 'ready');
  const created = await rpc('session/create', { request: { sessionId: 'schedule-live', cwd: home } });
  assert.equal(created.ok, true);
  const request = { title: 'Synthetic live schedule', prompt: 'Never sent to a model in this test', timing: { kind: 'after', after_seconds: 86400 }, target: { kind: 'session', sessionId: 'schedule-live' } };
  const before = (await rpc('schedule/catalog')).value;
  assert.equal(before.length, 2, 'real Host loaded offline existing-profile fixtures');
  for (const kind of ['new_once', 'new']) {
    const create = await rpc('schedule/create', { request: { ...request, target: { kind } } });
    assert.equal(create.ok, false); assert.equal(create.error.code, 'schedule-authorization-required');
    const edit = await rpc('schedule/edit', { request: { id: `seed-${kind}`, action: 'update', patch: { prompt: 'Must not be saved' } } });
    assert.equal(edit.ok, false); assert.equal(edit.error.code, 'schedule-authorization-required');
    assert.deepEqual((await rpc('schedule/catalog')).value, before, 'denied page-form mutations preserve tasks');
  }
  for (const allowed of [false, true]) {
    const pending = rpc('schedule/create', { request });
    const question = await next(frame => frame.type === 'waterfall' && frame.event === 'user-questions/request');
    assert.equal(question.agentId, 'schedule-live');
    assert.equal(question.request.purpose, 'schedule-authorization');
    assert.equal((await rpc('schedule/catalog')).value.length, 2, 'no new task exists while the real question is pending');
    const answer = allowed ? { kind: 'result', value: { answers: [{ id: question.request.questions[0].id, selected: ['授权 / Authorize'] }] } } : { kind: 'rejected', error: { name: 'UserQuestionError', message: 'Synthetic user rejection' } };
    assert.equal((await rpc('$events/result', { clientId: ready.clientId, eventId: question.eventId, outcome: answer })).ok, true);
    const result = await pending;
    assert.equal(result.ok, allowed);
    if (!allowed) assert.equal(result.error.code, 'schedule-authorization-required');
    assert.equal((await rpc('schedule/catalog')).value.length, allowed ? 3 : 2);
  }
  const noCarrier = await rpc('schedule/create', { request: { ...request, target: { kind: 'new_once' } } });
  assert.equal(noCarrier.ok, false);
  assert.equal(noCarrier.error.code, 'schedule-authorization-required');
  assert.equal((await rpc('schedule/catalog')).value.length, 3);
  console.log('PASS: page-form new/new_once create and seeded task edit reject unchanged; real dsh web HTTP/mux routes Session authorization; rejection never saves, explicit consent saves once, Host-only task rejects without saving.');
} finally {
  socket?.terminate();
  if (processHandle.exitCode === null && processHandle.signalCode === null) {
    processHandle.kill('SIGTERM');
    await once(processHandle, 'exit').catch(() => {});
  }
  await rm(home, { recursive: true, force: true });
}
