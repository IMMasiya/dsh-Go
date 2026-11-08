// Synthetic MCP peer: no phone access. Only tests consume the echoed metadata.
import { createInterface } from 'node:readline';

const ends = [];
for await (const line of createInterface({ input: process.stdin })) {
  const request = JSON.parse(line);
  if (request.id === undefined) continue;
  let result;
  switch (request.method) {
    case 'initialize':
      result = {
        protocolVersion: request.params.protocolVersion,
        capabilities: {
          tools: { listChanged: false },
          ...(['supported', 'lifecycle'].includes(process.argv[2]) ? {
            experimental: { 'dsh-go/phone-caller': { v: 1, taskIsolation: 0, ...(process.argv[2] === 'lifecycle' ? { runLifecycle: 1 } : {}) } },
          } : {}),
        },
        serverInfo: { name: 'synthetic-phone-caller', version: '1' },
      };
      break;
    case 'tools/list':
      result = { tools: [{ name: 'screen', description: 'Synthetic caller probe', inputSchema: { type: 'object' } }] };
      break;
    case 'tools/call':
      result = { content: [{ type: 'text', text: JSON.stringify({
        args: request.params.arguments,
        ends,
        caller: request.params._meta?.['dsh-go/phone-caller'] ?? null,
      }) }] };
      break;
    case 'dsh-go/phone-run-end':
      ends.push(request.params);
      result = {}; // ACK records intent only; this fixture has no device work.
      break;
    case 'ping':
      result = {};
      break;
    default:
      process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, error: { code: -32601, message: 'Method not found' } }) + '\n');
      continue;
  }
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\n');
}
