import { CompanionError, MAX_BODY_BYTES, invalid, ioError } from "./schema.js";
import { createCompanionStore } from "./store.js";
import { createRecallCoordinator } from "./recall.js";
import { recallError } from "./recall-schema.js";

const ROOT = "/dsh-go/v1/companion";

// Recall requests are flat objects. Reject duplicate keys before a
// JSON parser's last-value-wins rule can make a CAS target ambiguous. Strings
// (including escaped quotes and key-like text in values) are scanned as tokens.
function duplicateTopLevelKey(text) {
  const seen = new Set();
  let depth = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '"') {
      const start = i++;
      for (; i < text.length && text[i] !== '"'; i++) if (text[i] === '\\') i++;
      let next = i + 1;
      while (/\s/.test(text[next] ?? '') && next < text.length) next++;
      if (depth === 1 && text[next] === ':') {
        const key = JSON.parse(text.slice(start, i + 1));
        if (seen.has(key)) return true;
        seen.add(key);
      }
    } else if (text[i] === '{' || text[i] === '[') depth++;
    else if (text[i] === '}' || text[i] === ']') depth--;
  }
  return false;
}

function readJson(req, maxBytes = MAX_BODY_BYTES, strictKeys = false) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const cleanup = () => {
      req.off("data", data);
      req.off("end", end);
      req.off("error", fail);
      req.off("aborted", abort);
    };
    const fail = () => { cleanup(); reject(invalid()); };
    const abort = () => {
      cleanup();
      // IncomingMessage emits ECONNRESET after 'aborted'; keep that expected error handled.
      req.once("error", () => {});
      reject(invalid());
    };
    const data = (chunk) => {
      size += chunk.length;
      if (size <= maxBytes) chunks.push(chunk);
    };
    const end = () => {
      cleanup();
      if (size > maxBytes) return reject(new CompanionError(413, "too-large", "Companion request body is too large"));
      try {
        const text = new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks));
        const parsed = JSON.parse(text);
        if (strictKeys && duplicateTopLevelKey(text)) throw invalid();
        resolve(parsed);
      }
      catch { reject(invalid()); }
    };
    if (req.aborted || req.destroyed) return reject(invalid());
    req.on("data", data);
    req.on("end", end);
    req.on("error", fail);
    req.on("aborted", abort);
  });
}

// Called only after the bridge's existing connection.requestRejection guard.
// Store construction does no I/O, including on hosts that never open this page.
export function createCompanionRoutes({ send, store = createCompanionStore(), signals,
  recall = createRecallCoordinator({ store }) }) {
  const routes = new Map([
    [ROOT, { method: "GET", run: () => store.getSnapshot() }],
    [`${ROOT}/events`, { method: "POST", run: (body) => store.event(body) }],
    [`${ROOT}/memories/delete`, { method: "POST", run: (body) => recall.mutateMemory("deleteMemory", body) }],
    [`${ROOT}/memories/clear`, { method: "POST", run: (body) => recall.mutateMemory("clearMemories", body) }],
    [`${ROOT}/context`, { method: "POST", run: (body) => store.getContext(body) }],
    [`${ROOT}/export`, { method: "GET", run: () => store.exportData() }],
    [`${ROOT}/recall`, { method: "GET", run: () => recall.capability() }],
    [`${ROOT}/recall/bind`, { method: "POST", strictKeys: true, run: (body) => recall.bind(body) }],
    [`${ROOT}/recall/revoke`, { method: "POST", strictKeys: true, run: (body) => recall.revoke(body) }],
  ]);
  return {
    async handle(req, res, path) {
      if (path !== ROOT && !path.startsWith(`${ROOT}/`)) return false;
      if (signals && await signals.handle(req, res, path, send)) return true;
      const isRecall = path === `${ROOT}/recall` || path.startsWith(`${ROOT}/recall/`);
      try {
        const statusMatch = path.match(/^\/dsh-go\/v1\/companion\/recall\/bindings\/([^/]+)$/);
        const route = path === `${ROOT}/memories`
          ? (req.method === "GET" ? { method: "GET", run: () => store.getMemories() }
            : { method: "POST", run: (body) => recall.mutateMemory("upsertMemory", body) })
          : statusMatch ? { method: "GET", run: () => recall.status(statusMatch[1]) } : routes.get(path);
        if (route === undefined) {
          req.resume();
          throw new CompanionError(404, "not-found", "Companion route not found");
        }
        if (req.method !== route.method) {
          req.resume();
          throw new CompanionError(405, "invalid-request", "Method not allowed");
        }
        let body;
        if (route.method === "POST") {
          if (String(req.headers["content-type"]).split(";", 1)[0].trim().toLowerCase() !== "application/json") {
            req.resume();
            throw new CompanionError(415, "content-type", "Content-Type must be application/json");
          }
          body = await readJson(req, route.maxBytes, route.strictKeys);
        } else {
          req.resume();
        }
        const result = await route.run(body);
        if (!res.destroyed) send(res, 200, result);
      } catch (error) {
        let failure = error instanceof CompanionError ? error : isRecall
          ? recallError(503, "adapter-unavailable", "Automatic recall is unavailable on this host") : ioError();
        if (isRecall && !failure.code.startsWith("companion/recall-")) {
          failure = recallError(failure.status, failure.code.slice("companion/".length), failure.message);
        }
        if (!res.destroyed) send(res, failure.status, { error: { code: failure.code, message: failure.message } });
      }
      return true;
    },
  };
}
