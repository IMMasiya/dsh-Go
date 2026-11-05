// dsh-app boot cache for `dsh web`, preloaded by the /usr/local/bin/dsh shim (`--import`).
//
// Under proot every path lookup traps into the tracer. While DSH boots, its plugin loader
// canonicalizes and probes the same read-only package tree thousands of times (realpath walks
// every component, `existsSync` probes each node_modules level, the same package.json is read
// again and again). Until the server prints its URL line, those calls for paths below ROOTS are
// answered from a per-component cache: one lstat per path component, misses remembered. Other
// paths, other call shapes, and everything after boot go straight to node:fs.
//
// ROOTS only holds trees nothing writes to while DSH runs (the runtime replaces them only while
// DSH is stopped; the app's own files under /opt/dsh-app are written before the launch, and are
// not cached anyway). Symbolic links are followed only into ROOTS; ambiguous path
// spellings and links outside those trees fall back to node:fs.
import fs from 'node:fs';
import { registerHooks, syncBuiltinESMExports } from 'node:module';
import { dirname, join, normalize, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { isMainThread } from 'node:worker_threads';

export const ROOTS = ['/opt/dsh/', '/opt/node/', '/opt/dsh-go/'];

/** Answer for "not cacheable here": the caller uses node:fs. */
export const PASS = Symbol('pass');

/**
 * The cache itself, over an fs-like object (lstatSync, realpathSync and its native, readFileSync).
 * `real(p)` returns the canonical path, `{code, at}` when component `at` is missing, or PASS.
 */
export function createBootCache({ roots = ROOTS, fsImpl = fs } = {}) {
  const lstat = fsImpl.lstatSync.bind(fsImpl);
  const canonical = fsImpl.realpathSync.native.bind(fsImpl.realpathSync);
  const logical = fsImpl.realpathSync.bind(fsImpl);
  // "<canonical parent>/<name>" -> its canonical path (key itself unless a link) | {link} | {code, at}
  const components = new Map();
  const manifests = new Map(); // package.json path -> text
  const kinds = new Map(); // regular (non-link) component -> Module._stat code: 0 file, 1 dir
  const inRoots = (p) => roots.some((r) => (p + '/').startsWith(r));
  // Components inside ROOTS, and the directories above them (/opt).
  const cacheable = (p) => inRoots(p) || roots.some((r) => r.startsWith(p + '/'));
  const eligible = (p) => typeof p === 'string' && p.startsWith('/') && !p.endsWith('/') &&
    !/(?:^|\/)\.{1,2}(?:\/|$)/u.test(p) && inRoots(p);

  function real(p) {
    const parts = resolve(p).split('/');
    const last = parts.length - 1;
    let cur = '';
    for (let i = 1; i <= last; i++) {
      const key = cur + '/' + parts[i];
      let hit = components.get(key);
      if (hit === undefined) {
        let st;
        try {
          st = lstat(key);
        } catch (error) {
          if (error?.code !== 'ENOENT' && error?.code !== 'ENOTDIR') return PASS;
          hit = { code: error.code, at: key };
          if (cacheable(cur)) components.set(key, hit);
          return hit;
        }
        if (st.isSymbolicLink()) {
          let target;
          try {
            target = canonical(key);
            if (!inRoots(target) || logical(key) !== target) return PASS;
          } catch { return PASS; }
          hit = { link: target };
        } else {
          hit = key;
        }
        if (cacheable(key)) components.set(key, hit);
      }
      if (typeof hit === 'object') {
        if (hit.code !== undefined) return hit;
        cur = hit.link;
        continue;
      }
      cur = hit;
    }
    return cur || '/';
  }

  // Module._stat code (0 file, 1 dir, -errno) for an eligible path, answering
  // from the shared component cache. `stat` follows links; a final link resolves
  // its target's kind (one cached lstat). Returns PASS for uncacheable shapes.
  function statCached(p) {
    const parts = resolve(p).split('/');
    const last = parts.length - 1;
    let cur = '';
    for (let i = 1; i <= last; i++) {
      const key = cur + '/' + parts[i];
      let hit = components.get(key);
      if (hit === undefined) {
        let st;
        try {
          st = lstat(key);
        } catch (error) {
          if (error?.code !== 'ENOENT' && error?.code !== 'ENOTDIR') return PASS;
          hit = { code: error.code, at: key };
          if (cacheable(cur)) components.set(key, hit);
          return hit.code === 'ENOTDIR' ? -20 : -2;
        }
        if (st.isSymbolicLink()) {
          let target;
          try {
            target = canonical(key);
            if (!inRoots(target) || logical(key) !== target) return PASS;
          } catch { return PASS; }
          hit = { link: target };
        } else {
          hit = key;
          if (cacheable(key)) kinds.set(key, st.isDirectory() ? 1 : 0);
        }
        if (cacheable(key)) components.set(key, hit);
      }
      if (typeof hit === 'object') {
        if (hit.code !== undefined) return hit.code === 'ENOTDIR' ? -20 : -2;
        cur = hit.link;
        if (i === last) {
          const known = kinds.get(cur);
          if (known !== undefined) return known;
          let st;
          try { st = lstat(cur); } catch { return -2; }
          const kind = st.isDirectory() ? 1 : 0;
          kinds.set(cur, kind);
          return kind;
        }
        continue;
      }
      cur = hit;
    }
    let kind = kinds.get(cur);
    if (kind === undefined) {
      // Seen through real()/manifest which do not record kinds; one cached lstat.
      let st;
      try { st = lstat(cur); } catch { return -2; }
      kind = st.isDirectory() ? 1 : 0;
      kinds.set(cur, kind);
    }
    return kind;
  }

  return {
    eligible,
    real(p) {
      return eligible(p) ? real(p) : PASS;
    },
    statCached(p) {
      return eligible(p) ? statCached(p) : PASS;
    },
    manifest(p, read) {
      if (!eligible(p) || !p.endsWith('/package.json')) return PASS;
      let text = manifests.get(p);
      if (text === undefined) {
        if (typeof real(p) !== 'string') return PASS;
        text = read();
        manifests.set(p, text);
      }
      return text;
    },
    clear() {
      components.clear();
      manifests.clear();
      kinds.clear();
    },
  };
}

function missing(code, syscall, path) {
  const text = code === 'ENOTDIR' ? 'not a directory' : 'no such file or directory';
  return Object.assign(new Error(`${code}: ${text}, ${syscall} '${path}'`), {
    errno: code === 'ENOTDIR' ? -20 : -2,
    code,
    syscall,
    path,
  });
}

const utf8 = (o) =>
  o === 'utf8' || o === 'utf-8' || (o !== null && typeof o === 'object' && /^utf-?8$/i.test(o.encoding ?? '') && o.flag === undefined);
const stringResult = (o) => o === undefined || o === 'utf8' || o === 'utf-8' || (o !== null && typeof o === 'object' && (o.encoding === undefined || /^utf-?8$/i.test(o.encoding)));

// Node's exports resolution: subpath maps, condition maps, arrays (fallbacks)
// and `*` patterns. `null` and unknown subpaths mean "not exported"; the caller
// then falls through to nextResolve, which reports the same error. Mirrors
// node:internal/modules/esm/resolve's resolveExports for the shapes DSH ships.
export function resolveExports(exports, subpath, conditions) {
  if (typeof exports === 'string') return subpath === '.' ? exports : null;
  if (Array.isArray(exports)) {
    for (const item of exports) {
      const hit = resolveExports(item, subpath, conditions);
      if (hit !== null) return hit;
    }
    return null;
  }
  if (exports === null || typeof exports !== 'object') return null;
  const keys = Object.keys(exports);
  if (keys.length > 0 && keys.every((k) => k.startsWith('.'))) {
    if (subpath === '.') return keys.includes('.') ? resolveExports(exports['.'], '.', conditions) : null;
    if (keys.includes(subpath)) return resolveExports(exports[subpath], '.', conditions);
    for (const key of keys) {
      const star = key.indexOf('*');
      if (star < 0) continue;
      const prefix = key.slice(0, star);
      const suffix = key.slice(star + 1);
      // The key carries its own './'; match the whole subpath against it.
      if (subpath.startsWith(prefix) && subpath.endsWith(suffix) && subpath.length >= prefix.length + suffix.length) {
        const target = resolveExports(exports[key], '.', conditions);
        if (target === null) return null;
        return target.replace('*', subpath.slice(prefix.length, subpath.length - suffix.length));
      }
    }
    return null;
  }
  for (const cond of conditions) {
    if (!Object.prototype.hasOwnProperty.call(exports, cond)) continue;
    const value = exports[cond];
    if (value === null) return null;
    if (typeof value === 'string') return value;
    if (typeof value === 'object') return resolveExports(value, subpath, conditions);
    return null;
  }
  return null;
}

/**
 * Patches fsImpl's realpathSync (and .native), existsSync and readFileSync until the URL line
 * reaches `stdout` (or `maxMs` passes), then puts the originals back. Returns `uninstall`.
 */
export function install({ roots = ROOTS, fsImpl = fs, stdout = process.stdout, maxMs = 120_000 } = {}) {
  const cache = createBootCache({ roots, fsImpl });
  const original = {
    realpathSync: fsImpl.realpathSync,
    native: fsImpl.realpathSync.native,
    existsSync: fsImpl.existsSync,
    readFileSync: fsImpl.readFileSync,
    write: stdout.write,
  };
  let active = true;

  function realpathSync(p, options) {
    if (active && stringResult(options)) {
      const hit = cache.real(p);
      if (typeof hit === 'string') return hit;
      // node:fs's JS realpath reports the first missing component, from lstat.
      if (hit !== PASS) throw missing(hit.code, 'lstat', hit.at);
    }
    return Reflect.apply(original.realpathSync, this, arguments);
  }
  realpathSync.native = function native(p, options) {
    if (active && stringResult(options)) {
      const hit = cache.real(p);
      if (typeof hit === 'string') return hit;
      if (hit !== PASS) throw missing(hit.code, 'realpath', p);
    }
    return Reflect.apply(original.native, this, arguments);
  };
  function existsSync(p) {
    if (active) {
      const hit = cache.real(p);
      if (hit !== PASS) return typeof hit === 'string';
    }
    return Reflect.apply(original.existsSync, this, arguments);
  }
  function readFileSync(p, options) {
    if (active && utf8(options)) {
      const args = arguments;
      const text = cache.manifest(p, () => Reflect.apply(original.readFileSync, this, args));
      if (text !== PASS) return text;
    }
    return Reflect.apply(original.readFileSync, this, arguments);
  }
  // --- ESM resolve short-circuit -------------------------------------------
  // The built-in ESM resolver probes the filesystem through the native
  // `internalModuleStat` (getPackageJSONURL walks up to every package scope,
  // finalizeResolution stats each candidate), which the fs.* patches above do
  // NOT reach. While the boot loads bundles from the read-only ROOTS, resolve
  // those specifiers from the shared component cache and short-circuit, so Node
  // never runs the probing resolver. `exports` maps are honored with the
  // caller's own conditions (import vs require); anything ambiguous falls
  // through to nextResolve, where the cache still absorbs the fs.* calls.
  const inRoots = (p) => roots.some((r) => (p + '/').startsWith(r));
  const EXTENSIONS = ['.js', '.mjs', '.json', '.cjs', '.node'];
  const kindAt = (p) => (inRoots(p) ? cache.statCached(p) : PASS);
  function readManifest(p) {
    const text = cache.manifest(p, () => Reflect.apply(original.readFileSync, null, [p, 'utf8']));
    if (text === PASS) return undefined;
    try { return JSON.parse(text); } catch { return undefined; }
  }
  function nearestPackageType(from) {
    let dir = dirname(from);
    for (;;) {
      const manifest = readManifest(join(dir, 'package.json'));
      if (manifest) return typeof manifest.type === 'string' ? manifest.type : undefined;
      const parent = dirname(dir);
      if (parent === dir) return undefined;
      dir = parent;
    }
  }
  function formatFor(file) {
    if (file.endsWith('.mjs')) return 'module';
    if (file.endsWith('.cjs')) return 'commonjs';
    if (file.endsWith('.json')) return 'json';
    if (file.endsWith('.node')) return 'addon';
    return nearestPackageType(file) === 'module' ? 'module' : 'commonjs';
  }
  function resolveFile(candidate) {
    const kind = kindAt(candidate);
    if (kind === PASS) return null;
    if (kind === 0) return candidate;
    if (kind === 1) {
      const manifest = readManifest(join(candidate, 'package.json'));
      if (manifest?.main && typeof manifest.main === 'string') {
        // A main that points back to the directory itself (e.g. "main": ".")
        // cannot advance; fall through to the index entries, as Node does.
        const mainTarget = join(candidate, manifest.main);
        if (mainTarget !== candidate) {
          const viaMain = resolveFile(mainTarget);
          if (viaMain) return viaMain;
        }
      }
      for (const ext of EXTENSIONS) {
        const viaIndex = resolveFile(join(candidate, 'index' + ext));
        if (viaIndex) return viaIndex;
      }
      return null;
    }
    if (kind < 0) {
      // Node appends each extension once to a missing path; it never appends a
      // second extension to an already-appended one, so check them directly.
      for (const ext of EXTENSIONS) {
        const withExt = candidate + ext;
        if (kindAt(withExt) === 0) return withExt;
      }
    }
    return null;
  }
  function resolvePackage(specifier, parentPath, conditions) {
    const [first, second, ...rest] = specifier.split('/');
    const packageName = first.startsWith('@') ? `${first}/${second}` : first;
    const subpath = first.startsWith('@') ? rest.join('/') : [second, ...rest].filter(Boolean).join('/');
    let dir = dirname(parentPath);
    for (;;) {
      const pkgDir = join(dir, 'node_modules', packageName);
      if (kindAt(pkgDir) === 1) {
        const manifest = readManifest(join(pkgDir, 'package.json'));
        if (manifest?.exports !== undefined) {
          const target = resolveExports(manifest.exports, subpath === '' ? '.' : './' + subpath, conditions);
          if (typeof target !== 'string') return null;
          return resolveFile(join(pkgDir, target));
        }
        if (subpath === '') {
          const viaMain = manifest?.main && typeof manifest.main === 'string'
            ? resolveFile(join(pkgDir, manifest.main)) : null;
          return viaMain ?? resolveFile(pkgDir);
        }
        return resolveFile(join(pkgDir, subpath));
      }
      const parent = dirname(dir);
      if (parent === dir) return null;
      dir = parent;
    }
  }
  function resolveUnderRoots(specifier, context) {
    if (typeof specifier !== 'string' || specifier.startsWith('node:') || specifier.startsWith('data:') ||
        specifier.startsWith('http:') || specifier.startsWith('https:')) return null;
    const conditions = [...new Set([...(context?.conditions ?? ['node', 'import']), 'default'])];
    const parentURL = typeof context?.parentURL === 'string' ? context.parentURL : undefined;
    let candidate;
    if (specifier.startsWith('file:')) {
      try { candidate = fileURLToPath(specifier); } catch { return null; }
    } else if (specifier.startsWith('/')) {
      candidate = specifier;
    } else if (parentURL?.startsWith('file:')) {
      let parentPath;
      try { parentPath = fileURLToPath(parentURL); } catch { return null; }
      if (specifier.startsWith('./') || specifier.startsWith('../')) {
        candidate = normalize(join(dirname(parentPath), specifier));
      } else {
        return resolvePackage(specifier, parentPath, conditions);
      }
    } else {
      return null;
    }
    if (!inRoots(candidate)) return null;
    const file = resolveFile(candidate);
    return file && inRoots(file) ? file : null;
  }
  function resolveHook(specifier, context, nextResolve) {
    if (!active) return nextResolve(specifier, context);
    const file = resolveUnderRoots(specifier, context);
    if (file) return { url: pathToFileURL(file).href, format: formatFor(file), shortCircuit: true };
    return nextResolve(specifier, context);
  }
  // The cache is never in the way of the launch: if custom hooks are
  // unavailable, the fs.* patches still work and DSH just boots a bit slower.
  let hooks;
  try { hooks = registerHooks({ resolve: resolveHook }); } catch { hooks = null; }

  let timer;
  function uninstall() {
    if (!active) return;
    active = false;
    cache.clear();
    clearTimeout(timer);
    if (fsImpl.realpathSync === realpathSync) fsImpl.realpathSync = original.realpathSync;
    if (fsImpl.existsSync === existsSync) fsImpl.existsSync = original.existsSync;
    if (fsImpl.readFileSync === readFileSync) fsImpl.readFileSync = original.readFileSync;
    hooks?.deregister?.();
    if (stdout.write === watch) stdout.write = original.write;
    // ESM named imports taken during boot keep the wrappers, which now pass straight through;
    // not re-syncing leaves whatever else patched node builtins meanwhile as it was.
  }
  function watch(chunk, ...rest) {
    const result = Reflect.apply(original.write, this, [chunk, ...rest]);
    const text = typeof chunk === 'string' ? chunk : ArrayBuffer.isView(chunk) ? Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength).toString() : String(chunk);
    if (text.includes('?token=')) uninstall();
    return result;
  }

  fsImpl.realpathSync = realpathSync;
  fsImpl.existsSync = existsSync;
  fsImpl.readFileSync = readFileSync;
  stdout.write = watch;
  if (fsImpl === fs) syncBuiltinESMExports();
  timer = setTimeout(uninstall, maxMs);
  timer.unref?.();
  return uninstall;
}

// Preloaded by the shim for `dsh web` only; inert anywhere else (workers, other commands).
if (isMainThread && process.argv[2] === 'web' && process.env.DSH_GO_BOOT_CACHE !== '0') {
  try {
    const root = globalThis[Symbol.for('dsh.go.direct')]?.root;
    install({ roots: root ? ROOTS.map((path) => root + path) : ROOTS });
  } catch {
    // Never in the way of the launch: without the cache DSH just boots slower.
  }
}
