// The web and Node primitives the embedded YouTube.js bundle uses: the subset
// it needs, not a general browser or Node runtime. Ported from the Go youtubei
// crate's hostPrimitives. Native helpers from bridge.c: __randomBytes(length),
// __utf8Encode(string) and __utf8Decode(buffer, offset, length).
//
// Dart calls JavaScript; JavaScript never calls Dart. What it needs from
// outside (a fetch, a digest, the cache, a timer, a finished call, a log
// line) goes into the outbox, which engine.dart takes after each call in
// with __takeOutbox(). Dart answers an ask with __answer(message, bytes) and
// fires a timer with __fireTimer({id}).
globalThis.__hostErrorID = function find(error, seen = new Set()) {
  if (!error || typeof error !== 'object' || seen.has(error)) return 0;
  seen.add(error);
  if (error.__hostError) return error.__hostError;
  return find(error.cause, seen) || find(error.info?.error, seen) || find(error.info?.cause, seen);
};
globalThis.self = globalThis;
globalThis.window = globalThis;
globalThis.require = specifier => {
  if (specifier === 'module' || specifier === 'node:module') return {createRequire: path => {
    if (typeof path !== 'string' || (!path.startsWith('/') && !path.startsWith('file://'))) throw new TypeError('createRequire requires an absolute path or file URL');
    return name => { if (name === 'buffer' || name === 'node:buffer') return {Buffer: globalThis.Buffer}; throw new ReferenceError('Native module unavailable: ' + name); };
  }};
  throw new ReferenceError('Native module unavailable: ' + specifier);
};
const outbox = [];
globalThis.__takeOutbox = () => outbox.length ? JSON.stringify(outbox.splice(0)) : '';
// ask(kind, fields): what Dart answers, as {value, bytes}.
const asks = new Map(); let nextAsk = 0;
const ask = (kind, fields) => new Promise((resolve, reject) => {
  const id = ++nextAsk;
  asks.set(id, {resolve, reject});
  outbox.push({kind, id, ...fields});
});
globalThis.__answer = ({id, value, error}, bytes) => {
  const waiter = asks.get(id);
  if (!waiter) return;
  asks.delete(id);
  if (!error) return waiter.resolve({value, bytes});
  const failure = new Error(error.message);
  if (error.host_error) failure.__hostError = error.host_error;
  waiter.reject(failure);
};

const logText = value => {
  if (typeof value === 'string') return value;
  if (value instanceof Error) return value.stack ? `${value}\n${value.stack}` : String(value);
  try { return JSON.stringify(value) ?? String(value); } catch { return String(value); }
};
const logTo = level => (...args) => outbox.push({kind: 'log', level, message: args.map(logText).join(' ').slice(0, 4000)});
globalThis.console = {log: logTo('info'), info: logTo('info'), warn: logTo('warning'), error: logTo('error'), debug: logTo('debug'), trace: logTo('debug')};
const asBytes = value => value instanceof ArrayBuffer ? new Uint8Array(value) : new Uint8Array(value.buffer, value.byteOffset, value.byteLength);

const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const alphabetIndex = new Int16Array(128).fill(-1);
for (let i = 0; i < alphabet.length; i++) alphabetIndex[alphabet.charCodeAt(i)] = i;
const toBase64 = value => {
  const bytes = asBytes(value);
  const parts = [];
  let chunk = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0);
    chunk += alphabet[(n >> 18) & 63] + alphabet[(n >> 12) & 63] + (i + 1 < bytes.length ? alphabet[(n >> 6) & 63] : '=') + (i + 2 < bytes.length ? alphabet[n & 63] : '=');
    if (chunk.length > 8192) { parts.push(chunk); chunk = ''; }
  }
  parts.push(chunk);
  return parts.join('');
};
const fromBase64 = value => {
  const text = String(value ?? '').replace(/[\s=]/g, '');
  const bytes = new Uint8Array(Math.floor(text.length * 3 / 4));
  let bits = 0, count = 0, j = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    const digit = code < 128 ? alphabetIndex[code] : -1;
    if (digit < 0) throw new DOMException('Invalid base64', 'InvalidCharacterError');
    bits = (bits << 6) | digit; count += 6;
    if (count >= 8) { count -= 8; bytes[j++] = (bits >> count) & 255; }
  }
  return bytes.subarray(0, j);
};
globalThis.DOMException = class DOMException extends Error { constructor(message = '', name = 'Error') { super(message); this.name = name; } };
globalThis.btoa = value => {
  const text = String(value);
  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) { const c = text.charCodeAt(i); if (c > 255) throw new DOMException('Invalid character', 'InvalidCharacterError'); bytes[i] = c; }
  return toBase64(bytes);
};
globalThis.atob = value => {
  const bytes = fromBase64(value);
  let text = '';
  for (let i = 0; i < bytes.length; i += 8192) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
  return text;
};

globalThis.TextEncoder = class TextEncoder {
  get encoding() { return 'utf-8'; }
  encode(value = '') { return new Uint8Array(__utf8Encode(String(value))); }
  encodeInto(value, dest) { const encoded = this.encode(value); const count = Math.min(encoded.length, dest.length); dest.set(encoded.subarray(0, count)); return {read: new TextDecoder().decode(encoded.subarray(0, count)).length, written: count}; }
};
globalThis.TextDecoder = class TextDecoder {
  constructor(encoding = 'utf-8') { if (!['utf-8', 'utf8'].includes(encoding.toLowerCase())) throw new TypeError('Unsupported encoding'); }
  get encoding() { return 'utf-8'; }
  decode(value) {
    if (!value) return '';
    if (value instanceof ArrayBuffer) return __utf8Decode(value, 0, value.byteLength);
    return __utf8Decode(value.buffer, value.byteOffset, value.byteLength);
  }
};

const encodeForm = value => encodeURIComponent(value).replace(/%20/g, '+').replace(/[!'()~]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
const decodeForm = value => { try { return decodeURIComponent(value.replace(/\+/g, ' ')); } catch { return value; } };
globalThis.URLSearchParams = class URLSearchParams {
  constructor(init = '', changed = () => {}) {
    this.changed = changed;
    if (typeof init === 'string') this.pairs = init.replace(/^\?/, '').split('&').filter(Boolean).map(p => { const i = p.indexOf('='); return i < 0 ? [decodeForm(p), ''] : [decodeForm(p.slice(0, i)), decodeForm(p.slice(i + 1))]; });
    else if (init[Symbol.iterator]) this.pairs = Array.from(init, ([k, v]) => [String(k), String(v)]);
    else this.pairs = Object.entries(init).map(([k, v]) => [k, String(v)]);
  }
  get size() { return this.pairs.length; }
  append(k, v) { this.pairs.push([String(k), String(v)]); this.changed(this.toString()); }
  delete(k, v) { this.pairs = this.pairs.filter(p => p[0] !== String(k) || (v !== undefined && p[1] !== String(v))); this.changed(this.toString()); }
  get(k) { return this.pairs.find(p => p[0] === String(k))?.[1] ?? null; }
  getAll(k) { return this.pairs.filter(p => p[0] === String(k)).map(p => p[1]); }
  has(k, v) { return this.pairs.some(p => p[0] === String(k) && (v === undefined || p[1] === String(v))); }
  set(k, v) { let found = false; this.pairs = this.pairs.filter(p => { if (p[0] !== String(k)) return true; if (found) return false; p[1] = String(v); found = true; return true; }); if (!found) this.pairs.push([String(k), String(v)]); this.changed(this.toString()); }
  sort() { this.pairs.sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0); this.changed(this.toString()); }
  *entries() { yield* this.pairs; } *keys() { for (const p of this.pairs) yield p[0]; } *values() { for (const p of this.pairs) yield p[1]; }
  [Symbol.iterator]() { return this.entries(); }
  forEach(fn, thisArg) { for (const [k, v] of this.pairs) fn.call(thisArg, v, k, this); }
  toString() { return this.pairs.map(([k, v]) => encodeForm(k) + '=' + encodeForm(v)).join('&'); }
};
// URL after the WHATWG URL Standard, for the URLs YouTube.js builds: special
// (http, https, ws, wss, ftp, file) and opaque ones, relative references,
// dot segments, default ports and percent-encoding. ASCII hosts only: an
// internationalized domain name throws.
const specialPorts = {'http:': '80', 'https:': '443', 'ws:': '80', 'wss:': '443', 'ftp:': '21', 'file:': ''};
const c0 = c => c < 0x20 || c > 0x7e;
const fragmentSet = c => c0(c) || ' "<>`'.includes(String.fromCharCode(c));
const querySet = c => c0(c) || ' "#<>'.includes(String.fromCharCode(c));
const specialQuerySet = c => querySet(c) || c === 0x27;
const pathSet = c => querySet(c) || '?^`{}'.includes(String.fromCharCode(c));
const userinfoSet = c => pathSet(c) || '/:;=@[\\]|'.includes(String.fromCharCode(c));
const percentEncode = (text, set) => {
  let out = '';
  for (const ch of text) {
    const c = ch.codePointAt(0);
    if (c < 0x80 && !set(c)) { out += ch; continue; }
    let utf8;
    try { utf8 = encodeURIComponent(ch); } catch { utf8 = '%EF%BF%BD'; }
    out += c < 0x80 ? '%' + c.toString(16).toUpperCase().padStart(2, '0') : utf8;
  }
  return out;
};
const isDot = s => s === '.' || s.toLowerCase() === '%2e';
const isDoubleDot = s => ['..', '.%2e', '%2e.', '%2e%2e'].includes(s.toLowerCase());
// Resolves `.` and `..` in an absolute path, as the standard's path state does.
const normalizePath = (path, special) => {
  const segments = path.split('/').slice(1);
  const out = [];
  segments.forEach((s, i) => {
    const last = i === segments.length - 1;
    if (isDoubleDot(s)) { out.pop(); if (last) out.push(''); }
    else if (isDot(s)) { if (last) out.push(''); }
    else out.push(percentEncode(s, pathSet));
  });
  return '/' + out.join('/');
};
const parseHost = (host, special) => {
  if (host.startsWith('[')) {
    if (!host.endsWith(']')) throw new TypeError('Invalid URL');
    return host.toLowerCase();
  }
  if (!special) return percentEncode(host, c0);
  let decoded;
  try { decoded = decodeURIComponent(host); } catch { throw new TypeError('Invalid URL'); }
  if (/[^\x21-\x7e]|[#%/:<>?@[\\\]^|]/.test(decoded)) throw new TypeError('Invalid URL');
  return decoded.toLowerCase();
};
// Splits "user:pass@host:port" into its parts.
const parseAuthority = (authority, protocol) => {
  const special = protocol in specialPorts;
  const at = authority.lastIndexOf('@');
  const userinfo = at < 0 ? '' : authority.slice(0, at);
  let hostport = authority.slice(at + 1);
  const colon = userinfo.indexOf(':');
  const username = percentEncode(colon < 0 ? userinfo : userinfo.slice(0, colon), userinfoSet);
  const password = colon < 0 ? '' : percentEncode(userinfo.slice(colon + 1), userinfoSet);
  let port = '';
  const portAt = hostport.lastIndexOf(':');
  if (portAt >= 0 && !hostport.slice(portAt).includes(']')) {
    port = hostport.slice(portAt + 1);
    hostport = hostport.slice(0, portAt);
    if (!/^\d*$/.test(port)) throw new TypeError('Invalid URL');
    if (port) {
      const n = Number(port);
      if (n > 65535) throw new TypeError('Invalid URL');
      port = n === Number(specialPorts[protocol] ?? NaN) ? '' : String(n);
    }
  }
  const hostname = parseHost(hostport, special);
  if (special && protocol !== 'file:' && !hostname) throw new TypeError('Invalid URL');
  return {username, password, hostname, port};
};
const split = text => {
  const hash = text.indexOf('#');
  const fragment = hash < 0 ? null : text.slice(hash + 1);
  const beforeHash = hash < 0 ? text : text.slice(0, hash);
  const q = beforeHash.indexOf('?');
  return {rest: q < 0 ? beforeHash : beforeHash.slice(0, q), query: q < 0 ? null : beforeHash.slice(q + 1), fragment};
};
const build = (protocol, authority, path, query, fragment, opaque) => {
  const special = protocol in specialPorts;
  const parts = {protocol, username: '', password: '', hostname: '', port: '', opaque, hasAuthority: authority !== null};
  if (authority !== null) Object.assign(parts, parseAuthority(authority, protocol));
  parts.host = parts.hostname + (parts.port ? ':' + parts.port : '');
  if (opaque) parts.pathname = percentEncode(path, c0);
  else if (authority !== null || path.startsWith('/')) parts.pathname = normalizePath(path || '/', special);
  else parts.pathname = path ? normalizePath('/' + path, special).slice(1) : '';
  if (special && !parts.pathname) parts.pathname = '/';
  parts.query = query === null ? null : percentEncode(query, special ? specialQuerySet : querySet);
  parts.fragment = fragment === null ? null : percentEncode(fragment, fragmentSet);
  return parts;
};
const parseURL = function parseURL(input, base) {
  // eslint-disable-next-line no-control-regex
  input = String(input).replace(/^[\x00-\x20]+|[\x00-\x20]+$/g, '').replace(/[\t\n\r]/g, '');
  const baseParts = base === undefined ? null : parseURL(base);
  const scheme = /^([a-zA-Z][a-zA-Z0-9+.-]*):/.exec(input);
  if (scheme) {
    const protocol = scheme[1].toLowerCase() + ':';
    const special = protocol in specialPorts;
    let {rest, query, fragment} = split(input.slice(scheme[0].length));
    if (special) rest = rest.replace(/\\/g, '/');
    if (special && baseParts?.protocol === protocol && !rest.startsWith('/')) {
      return resolve(baseParts, rest, query, fragment);
    }
    if (protocol === 'file:') {
      const body = rest.startsWith('//') ? rest.slice(2) : null;
      const slash = body?.indexOf('/') ?? -1;
      if (body === null) return build(protocol, '', rest.startsWith('/') ? rest : '/' + rest, query, fragment, false);
      return build(protocol, slash < 0 ? body : body.slice(0, slash), slash < 0 ? '' : body.slice(slash), query, fragment, false);
    }
    if (special) {
      const body = rest.replace(/^\/*/, '');
      const slash = body.indexOf('/');
      return build(protocol, slash < 0 ? body : body.slice(0, slash), slash < 0 ? '' : body.slice(slash), query, fragment, false);
    }
    if (rest.startsWith('//')) {
      const body = rest.slice(2);
      const slash = body.indexOf('/');
      return build(protocol, slash < 0 ? body : body.slice(0, slash), slash < 0 ? '' : body.slice(slash), query, fragment, false);
    }
    return build(protocol, null, rest, query, fragment, !rest.startsWith('/'));
  }
  if (!baseParts) throw new TypeError('Invalid URL');
  let {rest, query, fragment} = split(input);
  if (baseParts.protocol in specialPorts) rest = rest.replace(/\\/g, '/');
  if (baseParts.opaque) {
    if (rest || query !== null || fragment === null) throw new TypeError('Invalid URL');
    return {...baseParts, fragment: percentEncode(fragment, fragmentSet)};
  }
  return resolve(baseParts, rest, query, fragment);
};
// A relative reference against [base] (RFC 3986 section 5.2.2).
const resolve = (base, rest, query, fragment) => {
  const special = base.protocol in specialPorts;
  if (rest.startsWith('//')) {
    const body = rest.slice(2);
    const slash = body.indexOf('/');
    return build(base.protocol, slash < 0 ? body : body.slice(0, slash), slash < 0 ? '' : body.slice(slash), query, fragment, false);
  }
  const authority = base.hasAuthority ? (base.username ? base.username + (base.password ? ':' + base.password : '') + '@' : '') + base.host : null;
  let path;
  if (!rest) {
    path = base.pathname;
    if (query === null) query = base.query;
  } else if (rest.startsWith('/')) {
    path = rest;
  } else {
    const dir = base.pathname.slice(0, base.pathname.lastIndexOf('/') + 1);
    path = (dir || (base.hasAuthority || special ? '/' : '')) + rest;
  }
  const parts = build(base.protocol, authority, path, query, fragment, false);
  // The base's userinfo and host are already encoded.
  return {...parts, username: base.username, password: base.password, hostname: base.hostname, port: base.port, host: base.host};
};
globalThis.URL = class URL {
  constructor(value, base) { this._parts = parseURL(value, base === undefined ? undefined : String(base)); this._params = null; }
  get href() {
    const p = this._parts;
    const tail = (p.query === null ? '' : '?' + p.query) + (p.fragment === null ? '' : '#' + p.fragment);
    if (!p.hasAuthority) return p.protocol + p.pathname + tail;
    return p.protocol + '//' + (p.username ? p.username + (p.password ? ':' + p.password : '') + '@' : '') + p.host + p.pathname + tail;
  }
  set href(v) { this._parts = parseURL(v); this._params = null; }
  get origin() { const p = this._parts; return p.protocol in specialPorts && p.protocol !== 'file:' ? p.protocol + '//' + p.host : 'null'; }
  get search() { return this._parts.query ? '?' + this._parts.query : ''; }
  set search(v) { v = String(v).replace(/^\?/, ''); this._parts.query = v ? percentEncode(v, this._parts.protocol in specialPorts ? specialQuerySet : querySet) : null; this._params = null; }
  get hash() { return this._parts.fragment ? '#' + this._parts.fragment : ''; }
  set hash(v) { v = String(v).replace(/^#/, ''); this._parts.fragment = v ? percentEncode(v, fragmentSet) : null; }
  get searchParams() { if (!this._params) this._params = new URLSearchParams(this.search, v => { this._parts.query = v || null; }); return this._params; }
  toString() { return this.href; } toJSON() { return this.href; }
  static canParse(v, b) { try { new URL(v, b); return true; } catch { return false; } }
  static parse(v, b) { try { return new URL(v, b); } catch { return null; } }
};
for (const key of ['protocol', 'username', 'password', 'host', 'hostname', 'port', 'pathname']) Object.defineProperty(URL.prototype, key, {
  get() { return this._parts[key]; },
  set(value) {
    value = String(value); const p = this._parts;
    if (key === 'hostname') { p.hostname = value; p.host = value + (p.port ? ':' + p.port : ''); }
    else if (key === 'port') { p.port = value; p.host = p.hostname + (value ? ':' + value : ''); }
    else p[key] = value;
  },
});
globalThis.Headers = class Headers {
  constructor(init) { this.pairs = []; if (init instanceof Headers) init = init.pairs; if (init) { if (init[Symbol.iterator]) for (const [k, v] of init) this.append(k, v); else for (const [k, v] of Object.entries(init)) this.append(k, v); } }
  append(k, v) { k = String(k).toLowerCase(); v = String(v).trim(); const p = this.pairs.find(p => p[0] === k); if (p) p[1] += ', ' + v; else this.pairs.push([k, v]); }
  set(k, v) { this.delete(k); this.append(k, v); } delete(k) { this.pairs = this.pairs.filter(p => p[0] !== String(k).toLowerCase()); }
  get(k) { return this.pairs.find(p => p[0] === String(k).toLowerCase())?.[1] ?? null; } has(k) { return this.get(k) !== null; }
  *entries() { yield* this.pairs; } *keys() { for (const p of this.pairs) yield p[0]; } *values() { for (const p of this.pairs) yield p[1]; }
  [Symbol.iterator]() { return this.entries(); } forEach(fn, arg) { for (const [k, v] of this.pairs) fn.call(arg, v, k, this); }
};
const bodyBytes = value => value == null ? new Uint8Array() : typeof value === 'string' ? new TextEncoder().encode(value) : value instanceof ArrayBuffer ? new Uint8Array(value) : ArrayBuffer.isView(value) ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : new TextEncoder().encode(String(value));
globalThis.Buffer = class Buffer extends Uint8Array {
  static from(value, encoding = 'utf8') {
    if (typeof value !== 'string') return new Buffer(value instanceof ArrayBuffer ? new Uint8Array(value) : value);
    if (encoding === 'base64' || encoding === 'base64url') return new Buffer(fromBase64(value.replace(/-/g, '+').replace(/_/g, '/')));
    if (encoding === 'hex') { if (value.length % 2) throw new TypeError('Invalid hex'); return new Buffer(value.match(/../g)?.map(v => parseInt(v, 16)) ?? []); }
    if (encoding !== 'utf8' && encoding !== 'utf-8') throw new TypeError('Unsupported buffer encoding'); return new Buffer(new TextEncoder().encode(value));
  }
  static alloc(length, fill = 0) { return new Buffer(length).fill(fill); }
  static isBuffer(value) { return value instanceof Buffer; }
  static byteLength(value, encoding) { return Buffer.from(value, encoding).byteLength; }
  toString(encoding = 'utf8') {
    if (encoding === 'base64') return toBase64(this);
    if (encoding === 'base64url') return toBase64(this).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    if (encoding === 'hex') return Array.from(this, b => b.toString(16).padStart(2, '0')).join('');
    if (encoding !== 'utf8' && encoding !== 'utf-8') throw new TypeError('Unsupported buffer encoding'); return new TextDecoder().decode(this);
  }
};
globalThis.ReadableStream = class ReadableStream {
  constructor(source = {}) { this.queue = []; this.closed = false; this.source = source; this.controller = {enqueue: v => this.queue.push(v), close: () => { this.closed = true; }, error: e => { this.error = e; }}; this.started = Promise.resolve(source.start?.(this.controller)); }
  getReader() { return {read: async () => { await this.started; if (this.error) throw this.error; if (!this.queue.length && !this.closed) await this.source.pull?.(this.controller); if (this.error) throw this.error; return this.queue.length ? {done: false, value: this.queue.shift()} : {done: this.closed, value: undefined}; }, cancel: reason => this.source.cancel?.(reason), releaseLock: () => {}}; }
  async *[Symbol.asyncIterator]() { const r = this.getReader(); for (;;) { const n = await r.read(); if (n.done) return; yield n.value; } }
};
class Body {
  constructor(body) { this._bytes = bodyBytes(body); this.bodyUsed = false; }
  async arrayBuffer() { if (this.bodyUsed) throw new TypeError('Body already consumed'); this.bodyUsed = true; return this._bytes.slice().buffer; }
  async bytes() { return new Uint8Array(await this.arrayBuffer()); }
  async text() { if (this.bodyUsed) throw new TypeError('Body already consumed'); this.bodyUsed = true; return new TextDecoder().decode(this._bytes); }
  async json() { return JSON.parse(await this.text()); }
  get body() { const bytes = this._bytes; return new ReadableStream({start(c) { if (bytes.length) c.enqueue(bytes); c.close(); }}); }
}
globalThis.Request = class Request extends Body {
  constructor(input, options = {}) { super(options.body ?? (input instanceof Request ? input._bytes : null)); this.url = String(input instanceof Request ? input.url : input); this.method = options.method ?? (input instanceof Request ? input.method : 'GET'); this.headers = new Headers(options.headers ?? (input instanceof Request ? input.headers : undefined)); this.signal = options.signal; this.redirect = options.redirect ?? 'follow'; this.credentials = options.credentials ?? 'same-origin'; }
  clone() { return new Request(this); }
};
globalThis.Response = class Response extends Body {
  constructor(body, init = {}) { super(body); this.status = init.status ?? 200; this.statusText = init.statusText ?? ''; this.headers = new Headers(init.headers); this.url = init.url ?? ''; this.redirected = false; this.ok = this.status >= 200 && this.status < 300; }
  clone() { return new Response(this._bytes, {status: this.status, statusText: this.statusText, headers: this.headers, url: this.url}); }
  static json(value, init = {}) { return new Response(JSON.stringify(value), {...init, headers: {'content-type': 'application/json', ...init.headers}}); }
};

// fetch: the caller's transport answers with the response's url, status and
// headers, and its body as bytes.
globalThis.fetch = (input, init = {}) => {
  const request = new Request(input, init);
  const fields = {url: request.url, method: request.method, headers: Array.from(request.headers), body: request._bytes.length ? toBase64(request._bytes) : null};
  return ask('fetch', {request: fields}).then(
    ({value, bytes}) => new Response(bytes ?? null, value),
    error => { error.message = 'fetch: ' + error.message; throw error; },
  );
};
const randomBytes = length => new Uint8Array(__randomBytes(length));
globalThis.crypto = {
  randomUUID: () => {
    const b = randomBytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = Array.from(b, v => v.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  },
  getRandomValues: array => {
    if (array.byteLength > 65536) throw new DOMException('Too many random bytes', 'QuotaExceededError');
    asBytes(array).set(randomBytes(array.byteLength));
    return array;
  },
  subtle: {digest: async (algorithm, bytes) => (await ask('digest', {algorithm: typeof algorithm === 'string' ? algorithm : algorithm.name, data: toBase64(bytes)})).bytes},
};
globalThis.CustomEvent = class CustomEvent { constructor(type, options = {}) { this.type = type; this.detail = options.detail; } };
globalThis.Event = class Event { constructor(type) { this.type = type; } };
globalThis.EventTarget = class EventTarget { constructor() { this.listeners = new Map(); } addEventListener(type, fn) { if (!this.listeners.has(type)) this.listeners.set(type, new Set()); this.listeners.get(type).add(fn); } removeEventListener(type, fn) { this.listeners.get(type)?.delete(fn); } dispatchEvent(event) { for (const fn of this.listeners.get(event.type) || []) fn(event); return true; } };
globalThis.Blob = class Blob extends Body { constructor(parts = [], options = {}) { const chunks = parts.map(bodyBytes); const bytes = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0)); let i = 0; for (const c of chunks) { bytes.set(c, i); i += c.length; } super(bytes); this.type = options.type ?? ''; this.size = bytes.length; } };
globalThis.File = class File extends Blob { constructor(parts, name, options) { super(parts, options); this.name = name; } };
globalThis.FormData = class FormData { constructor() { this.values = []; } append(k, v) { this.values.push([k, v]); } [Symbol.iterator]() { return this.values[Symbol.iterator](); } };
globalThis.AbortSignal = class AbortSignal extends EventTarget { constructor() { super(); this.aborted = false; } throwIfAborted() { if (this.aborted) throw this.reason; } };
globalThis.AbortController = class AbortController { constructor() { this.signal = new AbortSignal(); } abort(reason = new Error('Aborted')) { this.signal.aborted = true; this.signal.reason = reason; this.signal.dispatchEvent(new Event('abort')); } };
globalThis.structuredClone = function clone(value, seen = new Map()) {
  if (value === null || typeof value !== 'object') return value;
  if (seen.has(value)) return seen.get(value);
  if (value instanceof Date) return new Date(value);
  if (value instanceof ArrayBuffer) return value.slice(0);
  if (ArrayBuffer.isView(value)) return new value.constructor(value);
  const result = Array.isArray(value) ? [] : value instanceof Map ? new Map() : value instanceof Set ? new Set() : {};
  seen.set(value, result);
  if (value instanceof Map) { for (const [k, v] of value) result.set(clone(k, seen), clone(v, seen)); }
  else if (value instanceof Set) { for (const v of value) result.add(clone(v, seen)); }
  else for (const [k, v] of Object.entries(value)) result[k] = clone(v, seen);
  return result;
};

// Timers: Dart arms a Timer and calls __fireTimer({id}) when it fires.
const timerCallbacks = new Map(); let nextTimer = 0;
globalThis.setTimeout = (fn, delay = 0, ...args) => { const id = ++nextTimer; timerCallbacks.set(id, () => fn(...args)); outbox.push({kind: 'timer', id, delay: Number(delay) || 0}); return id; };
globalThis.clearTimeout = id => { if (timerCallbacks.delete(id)) outbox.push({kind: 'clearTimer', id}); };
globalThis.__fireTimer = ({id}) => { const fn = timerCallbacks.get(id); timerCallbacks.delete(id); fn?.(); };
globalThis.queueMicrotask = fn => Promise.resolve().then(fn);
globalThis.caches = {async open() { const data = new Map(); return {match: async k => data.get(k)?.clone(), put: async (k, v) => { data.set(k, v.clone()); }, delete: async k => data.delete(k)}; }};
const joining = new WeakSet(), nativeJoin = Array.prototype.join;
Array.prototype.join = function (separator) { if (this == null) return nativeJoin.call(this, separator); const receiver = Object(this); if (joining.has(receiver)) return ''; joining.add(receiver); try { return nativeJoin.call(receiver, separator); } finally { joining.delete(receiver); } };

// __invoke runs one Dart call: fn(args), answered by a `done` in the outbox,
// its result already JSON so that one unserializable value can't spoil the
// rest of the outbox.
globalThis.__invoke = (id, fn, args) => {
  (async () => {
    try { return {value: await fn(args)}; }
    catch (e) {
      let info = null;
      try { info = __serialize(e?.info) ?? null; } catch { /* left out */ }
      return {error: {name: e?.constructor?.name ?? e?.name ?? 'Error', message: String(e?.message ?? e), stack: e?.stack, info, host_error: __hostErrorID(e)}};
    }
  })().then(result => {
    let text;
    try { text = JSON.stringify({id, ...result}); }
    catch (e) { text = JSON.stringify({id, error: {message: 'Unserializable YouTube.js value: ' + String(e?.message ?? e)}}); }
    outbox.push({kind: 'done', id, result: text});
  });
};
