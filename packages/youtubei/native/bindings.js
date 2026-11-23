// Thin bindings to the live YouTube.js API, ported from the Go youtubei crate.
// They call upstream methods and read upstream properties; they never build
// YouTube requests or parse responses themselves. Live objects stay here
// behind numeric handles until a continuation consumes them or Dart releases
// them.
const __handles = new Map(); let __nextHandle = 0; let __innertube;
const __retain = value => { const id = ++__nextHandle; __handles.set(id, value); return id; };
const __text = value => value?.text ?? null;
const __playability = status => {
  if (!status) return null;
  const screen = status.error_screen; const message = screen?.content ?? screen;
  return {status: status.status, reason: status.reason ?? '', subreason: message?.subreason?.toString() ?? message?.reason?.toString() ?? ''};
};
const __playlist = page => ({
  handle: __retain(page), title: page.info?.title ?? '', thumbnails: page.info?.thumbnails ?? [],
  has_continuation: page.has_continuation, is_complete: page.is_complete,
  alerts: Array.from(page.page?.alerts ?? [], a => ({type: a.type, alert_type: a.alert_type})),
  items: Array.from(page.items, n => {
    if (n.type === 'PlaylistVideo') return {type: n.type, id: n.id, title: n.title.toString(), source_title: __text(n.title), is_playable: n.is_playable, duration_seconds: n.duration?.seconds ?? 0, upcoming_ms: n.upcoming?.getTime()};
    if (n.type === 'LockupView') return {type: n.type, id: n.content_id, title: n.metadata?.title?.toString() ?? '', source_title: __text(n.metadata?.title), content_type: n.content_type, duration_badges: Array.from(n.content_image?.overlays ?? []).flatMap(o => Array.from(o.badges ?? [], b => b.text).filter(Boolean))};
    return {type: n.type};
  }),
});
globalThis.__bridge = {
  async initialize(options) {
    const data = new Map();
    class Cache { get cache_dir() { return ''; } async get(k) { return data.get(k); } async set(k, v) { data.set(k, v); } async remove(k) { data.delete(k); } }
    YouTubeJS.Platform.load({...YouTubeJS.Platform.shim, runtime: 'unknown', Cache, eval: (data, env) => Function(...Object.keys(env), data.output)(...Object.values(env))});
    __innertube = await YouTubeJS.Innertube.create({...options, cache: new YouTubeJS.UniversalCache(false), fetch});
    return {user_agent: __innertube.session.user_agent, visionos_user_agent: YouTubeJS.Constants.CLIENTS.VISIONOS.USER_AGENT, tv_user_agent: YouTubeJS.Constants.CLIENTS.TV.USER_AGENT};
  },
  async playlistHead(id) {
    const response = await __innertube.actions.execute('/browse', {browseId: 'VL' + id, params: 'wgYCCAA='});
    return __playlist(new YouTubeJS.YT.Playlist(__innertube.actions, response, false));
  },
  async continuation(handle) {
    const page = __handles.get(handle);
    if (!page) throw new Error('Released upstream playlist');
    __handles.delete(handle);
    return __playlist(await page.getContinuation());
  },
  async videoInfo({id, client}) {
    const info = await __innertube.getBasicInfo(id, {client});
    const formats = [...(info.streaming_data?.formats ?? []), ...(info.streaming_data?.adaptive_formats ?? [])];
    const micro = info.page[0].microformat;
    return {basic_info: info.basic_info, playability_status: __playability(info.playability_status), publish_date: micro?.publish_date ?? '', upload_date: micro?.upload_date ?? '', cpn: info.cpn,
      formats: formats.map(f => ({handle: __retain(f), itag: f.itag, mime_type: f.mime_type, bitrate: f.bitrate, width: f.width, height: f.height, fps: f.fps, content_length: f.content_length, has_audio: f.has_audio, has_video: f.has_video, is_type_otf: f.is_type_otf, drm_families: f.drm_families, audio_track: f.audio_track, url: f.url, cipher: f.cipher, signature_cipher: f.signature_cipher}))};
  },
  async decipher(handle) {
    const format = __handles.get(handle);
    if (!format) throw new Error('Released upstream format');
    if ((format.cipher || format.signature_cipher || (format.url && new URL(format.url).searchParams.has('n'))) && !__innertube.session.player) {
      __innertube.session.player = await YouTubeJS.Player.create(__innertube.session.cache, fetch);
    }
    return format.decipher(__innertube.session.player);
  },
  async channel(url) {
    let id = /^https:\/\/www\.youtube\.com\/channel\/(UC[\w-]{22})$/.exec(url)?.[1];
    if (!id) {
      const endpoint = await __innertube.resolveURL(url);
      id = endpoint?.payload?.browseId;
      if (!id?.startsWith('UC')) throw new Error('Not a YouTube channel: ' + url);
    }
    const metadata = (await __innertube.getChannel(id)).metadata ?? {};
    return {id: metadata.external_id || id, title: metadata.title ?? '', thumbnails: metadata.avatar ?? metadata.thumbnail ?? []};
  },
  async search(query) {
    const search = await __innertube.search(query);
    return Array.from(search.results, n => {
      if (n.type === 'Video') return {type: n.type, id: n.video_id, title: n.title?.toString() ?? '', author: n.author?.name ?? '', thumbnails: n.thumbnails ?? [], duration: n.duration?.text ?? '', view_count: n.short_view_count?.toString() ?? '', is_live: n.is_live, is_upcoming: !!n.is_upcoming};
      if (n.type === 'Channel') return {type: n.type, id: n.id, title: n.author?.name ?? '', thumbnails: n.author?.thumbnails ?? [], subscriber_count: n.subscriber_count?.toString() ?? '', video_count: n.video_count?.toString() ?? ''};
      if (n.type === 'LockupView') {
        const image = n.content_image?.primary_thumbnail ?? n.content_image;
        return {type: n.type, id: n.content_id, content_type: n.content_type, title: n.metadata?.title?.toString() ?? '', thumbnails: image?.image ?? [],
          metadata_rows: Array.from(n.metadata?.metadata?.metadata_rows ?? [], r => Array.from(r.metadata_parts ?? [], p => p.text?.toString() ?? '')),
          badges: Array.from(image?.overlays ?? []).flatMap(o => Array.from(o.badges ?? [], b => b.text).filter(Boolean))};
      }
      return {type: n.type};
    });
  },
  release(handles) { for (const handle of handles) __handles.delete(handle); },
};
