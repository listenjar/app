// Thin bindings to the live YouTube.js API. Dart's classes (lib/src/) mirror
// YouTube.js's: each Dart method calls the upstream method of the same name
// here and gets back what it returned, serialized by __serialize. They never
// build YouTube requests or parse responses themselves. Objects a later call
// needs (formats, the player, playlists, API responses) stay here behind
// numeric handles until the Dart object holding them is collected.
const __handles = new Map(); let __nextHandle = 0; let __innertube;
const __retain = value => { const id = ++__nextHandle; __handles.set(id, value); return id; };
const __live = handle => {
  if (!__handles.has(handle)) throw new Error('Released YouTube.js object');
  return __handles.get(handle);
};
// Where Platform's Cache keeps files; set before YouTube.js builds one.
let __cacheDirectory = '';

// A YouTube.js value as JSON: data properties and getters, by the names
// YouTube.js gives them. Text is its `text`; Formats, Players and pages a
// later call continues from carry a `$handle`.
const __serialize = (value, seen = new Set()) => {
  if (value === undefined || value === null) return null;
  switch (typeof value) {
    case 'string': case 'boolean': return value;
    case 'number': return Number.isFinite(value) ? value : null;
    case 'bigint': return String(value);
    case 'function': case 'symbol': return undefined;
  }
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value.toISOString();
  if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return undefined;
  if (value instanceof YouTubeJS.Misc.Text) return {text: value.text ?? null};
  // Its `data` is the player's whole solver script.
  if (value instanceof YouTubeJS.Player) return {$handle: __retain(value), player_id: value.player_id, signature_timestamp: value.signature_timestamp, po_token: value.po_token ?? null, url: value.url};
  if (seen.has(value)) return null;
  seen.add(value);
  try {
    if (Array.isArray(value)) return value.map(v => __serialize(v, seen) ?? null);
    const out = {};
    if (value instanceof YouTubeJS.Misc.Format) out.$handle = __retain(value);
    for (const key of Object.keys(value)) {
      const v = __serialize(value[key], seen);
      if (v !== undefined) out[key] = v;
    }
    // Getters (Video's is_live, duration) live on the prototypes.
    for (let proto = Object.getPrototypeOf(value); proto && proto !== Object.prototype; proto = Object.getPrototypeOf(proto)) {
      for (const [key, d] of Object.entries(Object.getOwnPropertyDescriptors(proto))) {
        if (!d.get || key in out || key.startsWith('_')) continue;
        try {
          const v = __serialize(value[key], seen);
          if (v !== undefined) out[key] = v;
        } catch { /* a getter that needs what this value lacks */ }
      }
    }
    return out;
  } finally {
    seen.delete(value);
  }
};
const __playlist = playlist => ({
  $handle: __retain(playlist), info: __serialize(playlist.info), items: __serialize(playlist.items),
  has_continuation: playlist.has_continuation, is_complete: playlist.is_complete,
  page: {alerts: __serialize(playlist.page?.alerts ?? [])},
});
const __session = session => ({user_agent: session.user_agent, logged_in: session.logged_in, player: __serialize(session.player)});

globalThis.__bridge = {
  async create({cache, ...config}) {
    // Platform's Cache asks the caller (engine.dart's cache asks), which
    // keeps files as YouTube.js's Node cache does.
    class Cache {
      #directory = __cacheDirectory;
      get cache_dir() { return this.#directory; }
      async get(key) { return (await ask('cacheGet', {directory: this.#directory, key})).bytes; }
      async set(key, value) { await ask('cacheSet', {directory: this.#directory, key, data: toBase64(value)}); }
      async remove(key) { await ask('cacheRemove', {directory: this.#directory, key}); }
    }
    YouTubeJS.Platform.load({...YouTubeJS.Platform.shim, runtime: 'unknown', Cache, eval: (data, env) => Function(...Object.keys(env), data.output)(...Object.values(env))});
    const {Level} = YouTubeJS.Log;
    YouTubeJS.Log.setLevel(Level.ERROR, Level.WARNING, Level.INFO);
    let universal;
    if (cache) {
      __cacheDirectory = cache.cache_dir;
      universal = new YouTubeJS.UniversalCache(cache.persistent, cache.persistent_directory ?? undefined);
    }
    __innertube = await YouTubeJS.Innertube.create({...config, cache: universal, fetch});
    return {session: __session(__innertube.session), constants: {CLIENTS: __serialize(YouTubeJS.Constants.CLIENTS)}};
  },
  async getBasicInfo({video_id, options}) {
    const info = await __innertube.getBasicInfo(video_id, options);
    return {basic_info: __serialize(info.basic_info), playability_status: __serialize(info.playability_status),
      streaming_data: __serialize(info.streaming_data), page: [{microformat: __serialize(info.page[0]?.microformat)}], cpn: info.cpn};
  },
  async search({query, filters}) {
    const search = await __innertube.search(query, filters);
    return {results: __serialize(search.results), estimated_results: search.estimated_results, has_continuation: search.has_continuation};
  },
  async getPlaylist({id}) { return __playlist(await __innertube.getPlaylist(id)); },
  async getChannel({id}) {
    const channel = await __innertube.getChannel(id);
    return {metadata: __serialize(channel.metadata)};
  },
  async resolveURL({url}) { return __serialize(await __innertube.resolveURL(url)); },
  async execute({endpoint, args}) {
    const response = await __innertube.actions.execute(endpoint, args);
    return {$handle: __retain(response), success: response.success, status_code: response.status_code};
  },
  // `new YT.Playlist(actions, data, already_parsed)`.
  async newPlaylist({data, already_parsed}) {
    return __playlist(new YouTubeJS.YT.Playlist(__innertube.actions, __live(data), already_parsed));
  },
  async getContinuation({playlist}) { return __playlist(await __live(playlist).getContinuation()); },
  async decipher({format, player}) { return __live(format).decipher(player ? __live(player) : undefined); },
  release(handles) { for (const handle of handles) __handles.delete(handle); },
};
