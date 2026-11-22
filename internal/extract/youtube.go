package extract

import (
	"context"
	"crypto/sha1"
	"github.com/listenjar/desktop/internal/engine"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

// Reconstructed from the Downbit 0.2.8 darwin/arm64 disassembly of youtube.go.
func init() { engine.Extractors = append(engine.Extractors, youtube{}) }

type youtube struct{}

func (youtube) Name() string { return "YouTube" }

func (youtube) Match(u *url.URL) bool {
	h := strings.TrimPrefix(strings.ToLower(u.Hostname()), "www.")
	return h == "youtube.com" || h == "m.youtube.com" || h == "music.youtube.com" || h == "youtu.be" ||
		h == "youtube-nocookie.com" || strings.HasSuffix(h, ".youtube.com") || h == "youtubekids.com"
}

var ytIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{11}$`)

// ytVideoID returns the 11-character video id of a watch, short or embed URL.
func ytVideoID(u *url.URL) string {
	if strings.TrimPrefix(u.Hostname(), "www.") == "youtu.be" {
		id := strings.Trim(u.Path, "/")
		if ytIDPattern.MatchString(id) {
			return id
		}
	}
	if id := u.Query().Get("v"); ytIDPattern.MatchString(id) {
		return id
	}
	p := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(p) == 2 {
		switch p[0] {
		case "e", "v", "live", "embed", "shorts":
			if ytIDPattern.MatchString(p[1]) {
				return p[1]
			}
		}
	}
	return ""
}

// ytClient layout matches the 0.2.8 runtime type descriptor exactly.
type ytClient struct {
	name    string
	version string
	ua      string
	id      int
	extra   map[string]any
	js      bool
	signIn  bool
}

// The two native clients tried before the embedded player (static slice at
// 0x1011b9ee0 in the 0.2.8 darwin/arm64 binary). The TVHTML5 client needs the
// web player's JavaScript (js) and may use the signed-in cookies (signIn).
var ytClients = []ytClient{
	{
		"VISIONOS", "1.02", "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", 101,
		map[string]any{"deviceMake": "Apple", "deviceModel": "RealityDevice17,1", "osName": "visionOS", "osVersion": "26.5.23O471"}, false, false,
	},
	{
		"TVHTML5", "5.20260707", "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1", 7,
		map[string]any{"deviceMake": "Samsung", "deviceModel": "UKS9800", "osName": "Tizen", "osVersion": "2.4.0"}, true, true,
	},
}

// Extract tries the native clients in order, then the embedded player.
func (y youtube) Extract(ctx context.Context, c *engine.Client, u *url.URL) (*engine.Media, error) {
	id := ytVideoID(u)
	if list := u.Query().Get("list"); list != "" && !strings.HasPrefix(list, "RD") {
		m, e := y.playlist(ctx, c, list)
		if e == nil || id == "" {
			return m, e
		}
	}
	if id == "" {
		if m, e := y.page(ctx, c, u); m != nil || e != nil {
			return m, e
		}
		if m, e := y.channel(ctx, c, u); m != nil || e != nil {
			return m, e
		}
		return nil, errors.New("this YouTube page isn't a video or a playlist")
	}
	visitor := y.visitorData(ctx, c)
	tries := []func() (*engine.Media, error){}
	for _, client := range ytClients {
		if client.js && JSRunner == nil {
			continue
		}
		tries = append(tries, func() (*engine.Media, error) { return y.player(ctx, c, id, client, visitor) })
	}
	// The embedded player is the last resort; it always needs the player
	// JavaScript.
	if JSRunner != nil {
		tries = append(tries, func() (*engine.Media, error) { return y.embedded(ctx, c, id) })
	}
	var firstErr error
	for _, try := range tries {
		m, e := try()
		if e == nil {
			e = ytPlays(ctx, c, m)
		}
		if e == nil {
			return m, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		// Keep the first error, but prefer any other error over the network
		// limit message.
		if firstErr == nil || ytLimited(firstErr) && !ytLimited(e) {
			firstErr = e
		}
	}
	return nil, firstErr
}

// ytLimited reports whether e is YouTube refusing this network.
func ytLimited(e error) bool {
	return strings.Contains(e.Error(), "YouTube is limiting this network")
}

// ytPlays probes the first separate audio or video stream with a one-byte
// range request. A 403 means YouTube handed out streams this client cannot
// fetch, so the next client is tried.
func ytPlays(ctx context.Context, c *engine.Client, m *engine.Media) error {
	if m.IsLive || time.Now().Before(m.AvailableAt) {
		return nil
	}
	// Muxed formats are skipped: the probe needs an adaptive stream.
	//
	i := slices.IndexFunc(m.Formats, func(f engine.Format) bool { return f.Protocol == "http" && f.Audio != f.Video })
	if i < 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	f := m.Formats[i]
	r, e := c.Do(ctx, engine.Request{URL: f.URL, Headers: f.Headers}, map[string]string{"Range": "bytes=0-0"})
	if e != nil {
		var status *engine.StatusError
		if errors.As(e, &status) && status.Status == 403 {
			return errors.New("YouTube refused this video's streams (403).")
		}
		return nil
	}
	r.Body.Close()
	return nil
}

// ytStatus turns a non-OK playabilityStatus into a user-facing error.
func ytStatus(c *engine.Client, v any) error {
	status := str(v, "playabilityStatus", "status")
	if status == "OK" {
		return nil
	}
	reason := str(v, "playabilityStatus", "reason")
	if reason == "" {
		reason = "YouTube won't play this video (" + strings.ToLower(status) + ")"
	}
	if strings.Contains(reason, "not a bot") || status == "LOGIN_REQUIRED" {
		if JSRunner != nil && ytSAPISID(c) == "" {
			return errors.New(reason + ". YouTube is limiting this network: sign in to YouTube in Downbit's browser, or try again later.")
		}
		reason += ". YouTube is limiting this network: try again later or from another network."
	}
	return errors.New(reason)
}


// ytSAPISID returns the signed-in session cookie, if any.
func ytSAPISID(c *engine.Client) string {
	if s := c.Cookie("https://www.youtube.com", "SAPISID"); s != "" {
		return s
	}
	return c.Cookie("https://www.youtube.com", "__Secure-3PAPISID")
}

// ytAuth builds the SAPISIDHASH authorization header from the signed-in
// browser cookies.
func ytAuth(c *engine.Client, session string) string {
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	var parts []string
	for _, item := range [][2]string{{"SAPISIDHASH", ytSAPISID(c)},
		{"SAPISID1PHASH", c.Cookie("https://www.youtube.com", "__Secure-1PAPISID")},
		{"SAPISID3PHASH", c.Cookie("https://www.youtube.com", "__Secure-3PAPISID")}} {
		if item[1] == "" {
			continue
		}
		raw := ts + " " + item[1] + " https://www.youtube.com"
		if session != "" {
			raw = session + " " + raw
		}
		digest := sha1.Sum([]byte(raw))
		s := item[0] + " " + ts + "_" + hex.EncodeToString(digest[:])
		if session != "" {
			s += "_u"
		}
		parts = append(parts, s)
	}
	return strings.Join(parts, " ")
}

// embedded asks the player API as the embedded web player of a third-party
// page. Its formats need the player JavaScript to decode signatures and the
// n parameter.

// embedded extracts through the web embed player, whose stream URLs
// need the player script to solve n and signature challenges.
func (y youtube) embedded(ctx context.Context, c *engine.Client, id string) (*engine.Media, error) {
	//
	page, e := c.Text(ctx, "https://www.youtube.com/embed/"+id+"?html5=1", map[string]string{"Referer": "https://www.reddit.com/"})
	if e != nil {
		return nil, e
	}
	cfg := ytConfig(page)
	web, _ := cfg["INNERTUBE_CONTEXT"].(map[string]any) // RECOVERY: name chosen to reproduce the original stack layout; the real name is unknown.
	client, _ := web["client"].(map[string]any)
	sm := ytPlayerRE.FindStringSubmatch(page) // RECOVERY: name chosen to reproduce the original stack layout; the real name is unknown.
	if client == nil || sm == nil {
		return nil, errors.New("YouTube's embedded player didn't load")
	}
	third, _ := web["thirdParty"].(map[string]any)
	if third == nil {
		third = map[string]any{}
		web["thirdParty"] = third
	}
	third["embedUrl"] = "https://www.reddit.com/"
	player, e := ytPlayerCode(ctx, c, "https://www.youtube.com/s/player/"+sm[1]+"/player_ias.vflset/en_US/base.js")
	if e != nil {
		return nil, e
	}
	playback := map[string]any{"html5Preference": "HTML5_PREF_WANTS"}
	if ts := ytTimestampRE.FindStringSubmatch(player); ts != nil {
		playback["signatureTimestamp"], _ = strconv.Atoi(ts[1])
	}
	if m := ytFlagsRE.FindStringSubmatch(page); m != nil {
		var flags string
		if json.Unmarshal([]byte(`"`+m[1]+`"`), &flags) == nil {
			playback["encryptedHostFlags"] = flags
		}
	}
	body := map[string]any{
		"context":         web,
		"videoId":         id,
		"contentCheckOk":  true,
		"racyCheckOk":     true,
		"playbackContext": map[string]any{"contentPlaybackContext": playback},
	}
	version, _ := client["clientVersion"].(string)
	headers := map[string]string{
		"X-YouTube-Client-Name":    "56",
		"X-YouTube-Client-Version": version,
		"Origin":                   "https://www.youtube.com",
		"X-Origin":                 "https://www.youtube.com",
	}
	if vd, _ := client["visitorData"].(string); vd != "" { // RECOVERY: name chosen to reproduce the original stack layout; the real name is unknown.
		headers["X-Goog-Visitor-Id"] = vd
	}
	session, _ := cfg["USER_SESSION_ID"].(string)
	if auth := ytAuth(c, session); auth != "" {
		headers["Authorization"] = auth
		headers["X-Goog-AuthUser"] = "0"
	}
	var v any
	if e := c.JSON(ctx, engine.Request{URL: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false", JSON: body, Headers: headers}, &v); e != nil {
		return nil, e
	}
	if e := ytStatus(c, v); e != nil {
		return nil, e
	}
	return y.solved(ctx, c, id, v, c.UserAgent, player)
}

// solved decodes the n parameters and signatures of a player response with
// the player JavaScript before building the media.

func (y youtube) solved(ctx context.Context, c *engine.Client, id string, v any, ua, player string) (*engine.Media, error) {
	var ns, sigs []string
	sd := pathValue(v, "streamingData")
	for _, f := range append(listAt(sd, "formats"), listAt(sd, "adaptiveFormats")...) {
		if u, s, _ := ytLink(f); u != nil {
			ns = append(ns, u.Query().Get("n"))
			sigs = append(sigs, s)
		}
	}
	// Manifest URLs carry the n parameter as a path segment.
	//
	manifest, _ := sd.(map[string]any)
	for _, k := range []string{"hlsManifestUrl", "dashManifestUrl"} {
		if m := ytNRE.FindStringSubmatch(str(manifest, k)); m != nil {
			ns = append(ns, m[1])
		}
	}
	nmap, sigmap, e := ytSolve(ctx, player, ytUnique(ns), ytUnique(sigs))
	if e != nil {
		return nil, e
	}
	for _, k := range []string{"hlsManifestUrl", "dashManifestUrl"} {
		if m := ytNRE.FindStringSubmatch(str(manifest, k)); m != nil && nmap[m[1]] != "" {
			manifest[k] = strings.Replace(str(manifest, k), "/n/"+m[1]+"/", "/n/"+nmap[m[1]]+"/", 1)
		}
	}
	return y.media(ctx, c, id, v, ua, func(f any) string {
		u, s, sp := ytLink(f)
		if u == nil {
			return ""
		}
		q := u.Query()
		if n := q.Get("n"); n != "" {
			if nmap[n] == "" {
				return ""
			}
			q.Set("n", nmap[n])
		}
		if s != "" {
			if sigmap[s] == "" {
				return ""
			}
			q.Set(fbFirst(sp, "signature"), sigmap[s])
		}
		u.RawQuery = q.Encode()
		return u.String()
	})
}

// ytAdsEnd reconstructs the original preroll availability delay. It does not
// request ads, alter access tokens, or remove the upstream waiting period.

func ytAdsEnd(v any) time.Time {
	var renderers []any
	for _, p := range listAt(v, "adPlacements") {
		if str(p, "adPlacementRenderer", "config", "adPlacementConfig", "kind") == "AD_PLACEMENT_KIND_START" {
			renderers = append(renderers, pathValue(p, "adPlacementRenderer", "renderer"))
		}
	}
	for _, s := range listAt(v, "adSlots") {
		if str(s, "adSlotRenderer", "adSlotMetadata", "triggerEvent") != "SLOT_TRIGGER_EVENT_BEFORE_CONTENT" {
			continue
		}
		layout := pathValue(s, "adSlotRenderer", "fulfillmentContent", "fulfilledLayout", "playerBytesAdLayoutRenderer", "renderingContent")
		renderers = append(renderers, layout)
		for _, l := range listAt(layout, "playerBytesSequentialLayoutRenderer", "sequentialLayouts") {
			renderers = append(renderers, pathValue(l, "playerBytesAdLayoutRenderer", "renderingContent"))
		}
	}
	seconds := 0.0
	for _, r := range renderers {
		ad, ok := pathValue(r, "instreamVideoAdRenderer").(map[string]any)
		if !ok {
			continue
		}
		q, _ := url.ParseQuery(str(ad, "playerVars"))
		sec, e := strconv.ParseFloat(q.Get("length_seconds"), 64)
		if ms, ok := ad["skipOffsetMilliseconds"].(float64); ok {
			sec, e = ms/1000, nil
		}
		if e == nil {
			seconds += sec
		}
	}
	if seconds == 0 {
		return time.Time{}
	}
	// One extra second of margin after the rounded-up preroll length.
	//
	return time.Now().Add(time.Duration(math.Ceil(seconds)+1) * time.Second)
}

// ytLink resolves a renderer navigation endpoint into its URL, video id
// and playlist id.
func ytLink(v any) (u *url.URL, sig, sp string) {
	raw := str(v, "url")
	if cipher := str(v, "signatureCipher"); cipher != "" {
		q, _ := url.ParseQuery(cipher)
		raw, sig, sp = q.Get("url"), q.Get("s"), q.Get("sp")
	}
	u, e := url.Parse(raw)
	if e != nil || raw == "" {
		return nil, "", ""
	}
	return u, sig, sp
}

// RECOVERY: always inlined into youtube.solved; its name is not recoverable.
func ytUnique(values []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, s := range values {
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// Player script, encrypted host flags and n-parameter patterns.
var ytPlayerRE = regexp.MustCompile(`/s/player/([\w-]+)/`)
var ytFlagsRE = regexp.MustCompile(`"encryptedHostFlags":"([^"]+)"`)
var ytNRE = regexp.MustCompile(`/n/([^/]+)/`)
var ytConfigRE = regexp.MustCompile(`ytcfg\.set\(`)

// ytConfig merges every ytcfg.set({...}) object on a page into one
// configuration map.
func ytConfig(page string) map[string]any {
	cfg := map[string]any{}
	for _, idx := range ytConfigRE.FindAllStringIndex(page, -1) {
		var v map[string]any
		if json.NewDecoder(strings.NewReader(page[idx[1]:])).Decode(&v) == nil {
			for k, x := range v {
				cfg[k] = x
			}
		}
	}
	return cfg
}

// visitorData fetches a fresh visitor id for anonymous InnerTube calls,
// returning "" when YouTube does not answer.
func (y youtube) visitorData(ctx context.Context, c *engine.Client) string {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	s, e := c.Text(ctx, "https://www.youtube.com/sw.js_data")
	if e != nil {
		return ""
	}
	s = strings.TrimPrefix(s, ")]}'")
	var v any
	if json.Unmarshal([]byte(s), &v) != nil {
		return ""
	}
	return str(v, 0, 2, 0, 0, 13)
}

func (y youtube) player(ctx context.Context, c *engine.Client, id string, client ytClient, visitor string) (*engine.Media, error) {
	a := c // RECOVERY: name chosen to reproduce the original stack layout; the real name is unknown.
	if !client.signIn {
		a = c.WithoutCookies()
	}
	c1 := map[string]any{"clientName": client.name, "clientVersion": client.version, "hl": "en", "gl": "US"} // RECOVERY: name chosen to reproduce the original stack layout; the real name is unknown.
	for k, v := range client.extra {
		c1[k] = v
	}
	if visitor != "" {
		c1["visitorData"] = visitor
	}
	playback := map[string]any{"html5Preference": "HTML5_PREF_WANTS"}
	var c2 string // RECOVERY: name chosen to reproduce the original stack layout; the real name is unknown.
	if client.js {
		var e error
		if c2, e = ytWebPlayer(ctx, c); e != nil {
			return nil, e
		}
		if ts := ytTimestampRE.FindStringSubmatch(c2); ts != nil {
			playback["signatureTimestamp"], _ = strconv.Atoi(ts[1])
		}
	}
	body := map[string]any{
		"context":         map[string]any{"client": c1},
		"videoId":         id,
		"contentCheckOk":  true,
		"racyCheckOk":     true,
		"playbackContext": map[string]any{"contentPlaybackContext": playback},
	}
	c3 := map[string]string{ // RECOVERY: name chosen to reproduce the original stack layout; the real name is unknown.
		"User-Agent":               client.ua,
		"X-YouTube-Client-Name":    strconv.Itoa(client.id),
		"X-YouTube-Client-Version": client.version,
		"Origin":                   "https://www.youtube.com",
	}
	if visitor != "" {
		c3["X-Goog-Visitor-Id"] = visitor
	}
	if auth := ytAuth(a, ""); client.signIn && auth != "" {
		c3["Authorization"] = auth
		c3["X-Goog-AuthUser"] = "0"
		c3["X-Origin"] = "https://www.youtube.com"
	}
	var v any
	if e := a.JSON(ctx, engine.Request{URL: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false", JSON: body, Headers: c3}, &v); e != nil {
		return nil, e
	}
	if e := ytStatus(c, v); e != nil {
		return nil, e
	}
	if client.js {
		return y.solved(ctx, c, id, v, client.ua, c2)
	}
	return y.media(ctx, c, id, v, client.ua, func(f any) string {
		return str(f, "url")
	})
}

// media builds the media from a player response; link returns the playable
// URL of a format, or "" when it can't be used.
func (y youtube) media(ctx context.Context, c *engine.Client, id string, v any, ua string, link func(any) string) (*engine.Media, error) {
	ytDetails(ctx, c, id, v)
	d := pathValue(v, "videoDetails")
	m := &engine.Media{
		AvailableAt: ytAdsEnd(v),
		ID:          id,
		Title:       str(d, "title"),
		Author:      str(d, "author"),
		Description: str(d, "shortDescription"),
		Duration:    num(d, "lengthSeconds"),
		PageURL:     "https://www.youtube.com/watch?v=" + id,
		Thumbnail:   "https://i.ytimg.com/vi/" + id + "/hqdefault.jpg",
		IsLive:      pathValue(d, "isLive") == true,
	}
	if a := listAt(d, "thumbnail", "thumbnails"); len(a) > 0 {
		m.Thumbnail = str(a[len(a)-1], "url")
	}
	// The largest still frame wins when it exists.
	if p := ytPicture(ctx, c, id); p != "" {
		m.Thumbnail = p
	}
	if date := str(v, "microformat", "playerMicroformatRenderer", "publishDate"); len(date) >= 10 {
		m.Date = date[:10]
	}
	sd := pathValue(v, "streamingData")
	headers := map[string]string{"User-Agent": ua}
	if m.IsLive {
		// Live streams are recorded from the HLS manifest; the adaptive formats
		// of a live video only cover the last few seconds.
		hls := str(sd, "hlsManifestUrl")
		if hls == "" {
			return nil, errors.New("YouTube gave no stream of this live video that Downbit can record.")
		}
		fs, e := c.HLSFormats(ctx, hls, headers)
		if e != nil {
			return nil, e
		}
		m.Formats = fs
		dedupeIDs(m.Formats)
		return m, nil
	}
	add := func(f any, adaptive bool) {
		// Segmented (OTF) and post-live formats can't be fetched as one
		// range-addressable file.
		//
		if pathValue(f, "targetDurationSec") != nil || str(f, "type") == "FORMAT_STREAM_TYPE_OTF" {
			return
		}
		raw := link(f)
		if raw == "" {
			return
		}
		mimeType := str(f, "mimeType")
		mime, codecs := parseMime(mimeType)
		//
		format := engine.Format{ID: str(f, "itag"), Protocol: "http", URL: raw, Headers: headers,
			Width: int(num(f, "width")), Height: int(num(f, "height")), FPS: num(f, "fps"),
			Bitrate: int(num(f, "averageBitrate")), Size: int64(num(f, "contentLength"))}
		//
		if format.Bitrate == 0 {
			format.Bitrate = int(num(f, "bitrate"))
		}
		kind, sub, _ := strings.Cut(mime, "/")
		format.Ext = sub
		if kind == "audio" && sub == "mp4" {
			format.Ext = "m4a"
		}
		if !adaptive {
			// Muxed formats carry both tracks.
			format.Video, format.Audio = true, true
			if len(codecs) == 2 {
				format.VCodec, format.ACodec = codecs[0], codecs[1]
			}
		} else if kind == "video" {
			format.Video = true
			if len(codecs) > 0 {
				format.VCodec = codecs[0]
			}
		} else {
			format.Audio = true
			if len(codecs) > 0 {
				format.ACodec = codecs[0]
			}
			if name := str(f, "audioTrack", "displayName"); name != "" {
				format.Note = name
				if pathValue(f, "audioTrack", "audioIsDefault") == true {
					format.Note += " (default)"
				}
				format.ID += "-" + SanitizeLang(str(f, "audioTrack", "id"))
			}
			if q := str(f, "audioQuality"); q != "" && format.Note == "" {
				format.Note = strings.ToLower(strings.TrimPrefix(q, "AUDIO_QUALITY_"))
			}
		}
		if strings.Contains(str(f, "qualityLabel"), "HDR") {
			format.Note = strings.TrimSpace(format.Note + " HDR")
		}
		m.Formats = append(m.Formats, format)
	}
	for _, f := range listAt(sd, "formats") {
		add(f, false)
	}
	for _, f := range listAt(sd, "adaptiveFormats") {
		add(f, true)
	}
	if hls := str(sd, "hlsManifestUrl"); hls != "" && len(m.Formats) == 0 {
		list, e := c.HLSFormats(ctx, hls, headers)
		if e == nil {
			m.Formats = append(m.Formats, list...)
		}
	}
	if len(m.Formats) == 0 {
		return nil, errors.New("YouTube gave no streams this app can read")
	}
	dedupeIDs(m.Formats)
	m.Chapters = engine.ChaptersFromDescription(m.Description, m.Duration)
	for _, t := range listAt(v, "captions", "playerCaptionsTracklistRenderer", "captionTracks") {
		base := str(t, "baseUrl")
		if base == "" {
			continue
		}
		name := str(t, "name", "simpleText")
		if name == "" {
			name = str(t, "name", "runs", 0, "text")
		}
		// Automatic captions are marked "asr" or have an "a." track ID.
		auto := str(t, "kind") == "asr" || strings.HasPrefix(str(t, "vssId"), "a.")
		m.Subtitles = append(m.Subtitles, engine.Subtitle{Lang: str(t, "languageCode"), Name: name, URL: base + "&fmt=vtt", Ext: "vtt", Auto: auto})
	}
	return m, nil
}

// ytDetails completes a player response without video details (some clients
// omit them) from the web client's player endpoint.

func ytDetails(ctx context.Context, c *engine.Client, id string, v any) {
	m, ok := v.(map[string]any)
	if !ok || str(m, "videoDetails", "title") != "" {
		return
	}
	r, e := ytCall(ctx, c, "player", map[string]any{"videoId": id, "contentCheckOk": true, "racyCheckOk": true})
	d, _ := pathValue(r, "videoDetails").(map[string]any)
	if e != nil || str(d, "videoId") != id {
		return
	}
	// The original client's own details win over the web client's.
	old, _ := m["videoDetails"].(map[string]any)
	for k, o := range old {
		d[k] = o
	}
	m["videoDetails"] = d
	for _, k := range []string{"microformat", "captions"} {
		if m[k] == nil {
			m[k] = pathValue(r, k)
		}
	}
}

// SanitizeLang turns a caption language code into a file-name-safe tag.
func SanitizeLang(s string) string { return engine.SanitizeID(strings.ReplaceAll(s, ".", "")) }

func parseMime(s string) (string, []string) {
	mime, rest, _ := strings.Cut(s, ";")
	var codecs []string
	if i := strings.Index(rest, `codecs="`); i >= 0 {
		for _, c := range strings.Split(strings.TrimSuffix(rest[i+8:], `"`), ",") {
			codecs = append(codecs, strings.TrimSpace(c))
		}
	}
	return strings.TrimSpace(mime), codecs
}

// ytCall POSTs an InnerTube request with the web client context.
func ytCall(ctx context.Context, c *engine.Client, endpoint string, body map[string]any) (any, error) {
	body["context"] = map[string]any{"client": map[string]any{"clientName": "WEB", "clientVersion": "2.20260708.00.00", "hl": "en", "gl": "US"}}
	headers := map[string]string{"X-YouTube-Client-Name": "1", "X-YouTube-Client-Version": "2.20260708.00.00", "Origin": "https://www.youtube.com"}
	if auth := ytAuth(c, ""); auth != "" {
		headers["Authorization"] = auth
	}
	var v any
	e := c.JSON(ctx, engine.Request{URL: "https://www.youtube.com/youtubei/v1/" + endpoint + "?prettyPrint=false", JSON: body, Headers: headers}, &v)
	return v, e
}

// ytText flattens simpleText or runs[].text.
func ytText(v any) string {
	if s := fbFirst(str(v, "simpleText"), str(v, "content")); s != "" {
		return s
	}
	var b strings.Builder
	for _, r := range listAt(v, "runs") {
		b.WriteString(str(r, "text"))
	}
	return b.String()
}

// ytItems adds the videos, shorts and playlists of a browse, search or next
// response to m and returns its continuation token.
func ytItems(data any, m *engine.Media, seen map[string]bool) (next string) {
	add := func(e engine.Entry) {
		if e.ID == "" || seen[e.ID] {
			return
		}
		seen[e.ID] = true
		if e.URL == "" {
			e.URL = "https://www.youtube.com/watch?v=" + e.ID
		}
		if e.Thumbnail == "" && !strings.Contains(e.URL, "/playlist?") {
			e.Thumbnail = "https://i.ytimg.com/vi/" + e.ID + "/mqdefault.jpg"
		}
		m.Entries = append(m.Entries, e)
	}
	playlist := func(id, title, author, thumb string) {
		if strings.HasPrefix(id, "RD") {
			return
		}
		add(engine.Entry{ID: id, URL: "https://www.youtube.com/playlist?list=" + id, Title: title, Author: author, Thumbnail: thumb})
	}
	byline := func(v any) string {
		for _, k := range []string{"shortBylineText", "ownerText", "longBylineText"} {
			if s := str(v, k, "runs", 0, "text"); s != "" {
				return s
			}
		}
		return ""
	}
	// Only the page contents are walked: the sidebar and header hold
	// unrelated recommendations.
	var roots []any
	for _, k := range []string{"contents", "continuationContents", "onResponseReceivedActions", "onResponseReceivedEndpoints"} {
		roots = append(roots, pathValue(data, k))
	}
	walk(roots, func(key string, v any) {
		switch key {
		case "videoRenderer", "gridVideoRenderer", "compactVideoRenderer", "playlistVideoRenderer", "videoCardRenderer":
			e := engine.Entry{ID: str(v, "videoId"), Title: ytText(pathValue(v, "title")), Author: byline(v), Duration: num(v, "lengthSeconds")}
			if e.Duration == 0 {
				e.Duration = parseClock(ytText(pathValue(v, "lengthText")))
			}
			for _, o := range listAt(v, "thumbnailOverlays") {
				if e.Duration == 0 {
					e.Duration = parseClock(ytText(pathValue(o, "thumbnailOverlayTimeStatusRenderer", "text")))
				}
			}
			add(e)
		case "lockupViewModel":
			id, meta := str(v, "contentId"), pathValue(v, "metadata", "lockupMetadataViewModel")
			title := str(meta, "title", "content")
			parts := listAt(meta, "metadata", "contentMetadataViewModel", "metadataRows", 0, "metadataParts")
			author := str(parts, 0, "text", "content")
			switch str(v, "contentType") {
			case "LOCKUP_CONTENT_TYPE_VIDEO":
				e := engine.Entry{ID: id, Title: title, Author: author}
				walk(pathValue(v, "contentImage"), func(k string, x any) {
					if s, ok := x.(string); ok && k == "text" && e.Duration == 0 {
						e.Duration = parseClock(s)
					}
				})
				add(e)
			case "LOCKUP_CONTENT_TYPE_ALBUM", "LOCKUP_CONTENT_TYPE_PODCAST", "LOCKUP_CONTENT_TYPE_PLAYLIST":
				// A single metadata part is the video count, not the
				// author.
				if len(parts) < 2 {
					author = ""
				}
				playlist(id, title, author, str(v, "contentImage", "collectionThumbnailViewModel", "primaryThumbnail", "thumbnailViewModel", "image", "sources", 0, "url"))
			}
		case "playlistRenderer", "gridPlaylistRenderer":
			image := str(v, "thumbnail", "thumbnails", 0, "url")
			if image == "" {
				image = str(v, "thumbnails", 0, "thumbnails", 0, "url")
			}
			playlist(str(v, "playlistId"), ytText(pathValue(v, "title")), byline(v), image)
		case "gridShowRenderer":
			playlist(strings.TrimPrefix(str(v, "navigationEndpoint", "browseEndpoint", "browseId"), "VL"), ytText(pathValue(v, "title")),
				"", str(v, "thumbnailRenderer", "showCustomThumbnailRenderer", "thumbnail", "thumbnails", 0, "url"))
		case "shortsLockupViewModel":
			id := str(v, "onTap", "innertubeCommand", "reelWatchEndpoint", "videoId")
			add(engine.Entry{ID: id, URL: "https://www.youtube.com/shorts/" + id, Title: str(v, "overlayMetadata", "primaryText", "content")})
		case "reelItemRenderer":
			id := str(v, "videoId")
			add(engine.Entry{ID: id, URL: "https://www.youtube.com/shorts/" + id, Title: ytText(pathValue(v, "headline"))})
		case "continuationItemRenderer", "continuationItemViewModel":
			// The first continuation command is the next page; later ones
			// belong to nested shelves.
			walk(v, func(k string, x any) {
				if s := str(x, "token"); k == "continuationCommand" && s != "" && next == "" {
					next = s
				}
			})
		}
	})
	return next
}

// more follows up to 20 continuation pages of a browse or search response.

func (youtube) more(ctx context.Context, c *engine.Client, endpoint string, data any, m *engine.Media, limit int) {
	seen := map[string]bool{}
	for try := 0; try < 20; try++ {
		token := ytItems(data, m, seen)
		if token == "" || limit > 0 && len(m.Entries) >= limit {
			return
		}
		var e error
		if data, e = ytCall(ctx, c, endpoint, map[string]any{"continuation": token}); e != nil {
			return
		}
	}
}

// playlist lists the videos of a playlist, following continuations.
func (y youtube) playlist(ctx context.Context, c *engine.Client, id string) (*engine.Media, error) {
	data, e := ytCall(ctx, c, "browse", map[string]any{"browseId": "VL" + id})
	if e != nil {
		return nil, e
	}
	m := &engine.Media{ID: id, PageURL: "https://www.youtube.com/playlist?list=" + id,
		Title: fbFirst(str(data, "metadata", "playlistMetadataRenderer", "title"),
			str(data, "header", "playlistHeaderRenderer", "title", "simpleText"),
			str(data, "microformat", "microformatDataRenderer", "title")),
		Author: str(data, "header", "playlistHeaderRenderer", "ownerText", "runs", 0, "text")}
	// Only channel upload playlists (UU...) honor the playlist limit while
	// paging.
	limit := 0
	if strings.HasPrefix(id, "UU") {
		limit = c.PlaylistLimit
	}
	y.more(ctx, c, "browse", data, m, limit)
	// Drop nested playlists.
	entries := m.Entries[:0]
	for _, cur := range m.Entries {
		if !strings.Contains(cur.URL, "/playlist?") {
			entries = append(entries, cur)
		}
	}
	m.Entries = entries
	return ytEntries(m, "the playlist is empty or private")
}

// channel resolves /@handle, /channel/UC..., /c/... and /user/... pages and
// lists the requested tab.

func (y youtube) channel(ctx context.Context, c *engine.Client, u *url.URL) (*engine.Media, error) {
	p := segments(u)
	// RECOVERY: the statement layout of these prefix checks is approximate.
	var n int
	if len(p) == 0 {
		return nil, nil
	}; if strings.HasPrefix(p[0], "@") { n = 1
	} else if len(p) >= 2 && (p[0] == "channel" || p[0] == "c" || p[0] == "user") { n = 2
	} else {
		// Not a channel page.
		return nil, nil
	}
	tab := ""
	if len(p) > n {
		tab = p[n]
	}
	id := ""
	if p[0] == "channel" && strings.HasPrefix(p[1], "UC") {
		id = p[1]
	}
	if id == "" || tab == "live" {
		// Handles and legacy URLs resolve to a channel ID; /live resolves to
		// the current live video when there is one.
		ref := &url.URL{Path: "/" + strings.Join(p[:n], "/")}
		if tab == "live" {
			ref.Path += "/live"
		}
		r, e := ytCall(ctx, c, "navigation/resolve_url", map[string]any{"url": "https://www.youtube.com" + ref.EscapedPath()})
		if e != nil {
			return nil, e
		}
		//
		if v := str(r, "endpoint", "watchEndpoint", "videoId"); v != "" {
			w, _ := url.Parse("https://www.youtube.com/watch?v=" + v)
			return y.Extract(ctx, c, w)
		}
		if id == "" {
			id = str(r, "endpoint", "browseEndpoint", "browseId")
		}
		if !strings.HasPrefix(id, "UC") {
			return nil, errors.New("This YouTube channel doesn't exist.")
		}
	}
	uploads := func() (*engine.Media, error) { return y.uploads(ctx, c, id, tab) }
	tabbed := func() (*engine.Media, error) { return y.tab(ctx, c, id, tab) }
	home := func() (*engine.Media, error) { return y.tab(ctx, c, id, "") }
	var tries []func() (*engine.Media, error)
	switch tab {
	case "", "home", "videos",
		"featured":
		//
		tries = append(tries, uploads, home)
	case "shorts", "streams":
		tries = append(tries, uploads)
	case "live":
		// Past streams when the channel isn't live now.
		tries = append(tries, tabbed, uploads)
	default:
		tries = append(tries, tabbed, uploads, home)
	}
	for _, try := range tries {
		if m, _ := try(); m != nil {
			m.ID = id
			m.PageURL = "https://www.youtube.com/" + strings.Join(p[:n], "/")
			if tab != "" {
				m.PageURL += "/" + tab
			}
			return m, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	if tab == "live" {
		return nil, errors.New("This YouTube channel isn't live now, and has no past streams.")
	}
	return nil, errors.New("This YouTube channel has no " + fbFirst(tab, "videos") + ".")
}

// uploads lists a channel tab from its upload playlist: UC... channel IDs map
// to UULF (videos), UUSH (shorts) and UULV (streams) playlists.
func (y youtube) uploads(ctx context.Context, c *engine.Client, id, tab string) (*engine.Media, error) {
	prefixes := []string{"UULF", "UU"}
	switch tab {
	case "shorts":
		prefixes = []string{"UUSH"}
	case "live", "streams":
		prefixes = []string{"UULV"}
	}
	var e error
	for _, prefix := range prefixes {
		var m *engine.Media
		if m, e = y.playlist(ctx, c, prefix+id[2:]); e == nil {
			if m.Author != "" && !strings.Contains(m.Title, m.Author) {
				m.Title = m.Author + " - " + m.Title
			}
			return m, nil
		}
	}
	return nil, e
}

// tab lists a channel tab through the server-advertised browse endpoint and
// params; opaque tab params are never synthesized.
func (y youtube) tab(ctx context.Context, c *engine.Client, id, wanted string) (*engine.Media, error) {
	if wanted == "home" || wanted == "featured" {
		wanted = ""
	}
	page, e := ytCall(ctx, c, "browse", map[string]any{"browseId": id})
	if e != nil {
		return nil, e
	}
	var selected any
	for _, r := range listAt(page, "contents", "twoColumnBrowseResultsRenderer", "tabs") {
		t := pathValue(r, "tabRenderer")
		if t == nil {
			t = pathValue(r, "expandableTabRenderer")
		}
		link := str(t, "endpoint", "commandMetadata", "webCommandMetadata", "url")
		if wanted == "" && pathValue(t, "selected") == true || wanted != "" && strings.HasSuffix(link, "/"+wanted) {
			selected = t
			break
		}
	}
	if selected == nil {
		return nil, nil
	}
	if pathValue(selected, "selected") != true {
		ep := pathValue(selected, "endpoint", "browseEndpoint")
		if page, e = ytCall(ctx, c, "browse", map[string]any{"browseId": str(ep, "browseId"), "params": str(ep, "params")}); e != nil {
			return nil, e
		}
	}
	title := fbFirst(str(page, "metadata", "channelMetadataRenderer", "title"),
		str(page, "header", "pageHeaderRenderer", "pageTitle"),
		ytText(pathValue(page, "header", "interactiveTabbedHeaderRenderer", "title")),
		str(page, "microformat", "microformatDataRenderer", "title"), id)
	m := &engine.Media{ID: id, Title: title, Author: title}
	if s := str(selected, "title"); s != "" {
		m.Title += " - " + s
	}
	y.more(ctx, c, "browse", page, m, c.PlaylistLimit)
	if len(m.Entries) == 0 {
		return nil, nil
	}
	m.Thumbnail = m.Entries[0].Thumbnail
	return m, nil
}

//
// page handles browse/show IDs (VL playlists, UC channels, MPREb_ YouTube
// Music albums), hashtag pages and search results.
func (y youtube) page(ctx context.Context, c *engine.Client, u *url.URL) (*engine.Media, error) {
	p := segments(u)
	//
	if len(p) == 2 && (p[0] == "browse" || p[0] == "show") {
		id := p[1]
		//
		if strings.HasPrefix(id, "VL") {
			return y.playlist(ctx, c, id[2:])
		} else if strings.HasPrefix(id, "UC") {
			ch := *u
			ch.Path, ch.RawPath = "/channel/"+id, ""
			return y.channel(ctx, c, &ch)
		} else if strings.HasPrefix(id, "MPREb_") {
			// An album resolves to its audio playlist.
			v, e := ytCall(ctx, c, "browse", map[string]any{"browseId": id})
			if e != nil {
				return nil, e
			}
			var list string
			walk(v, func(k string, x any) {
				if s, ok := x.(string); ok && k == "audioPlaylistId" && list == "" {
					list = s
				}
			})
			if list == "" {
				return nil, errors.New("YouTube Music gave no playlist of this album.")
			}
			return y.playlist(ctx, c, list)
		}
	} else if len(p) == 2 && p[0] == "hashtag" {
		r, e := ytCall(ctx, c, "navigation/resolve_url", map[string]any{"url": "https://www.youtube.com" + u.EscapedPath()})
		if e != nil {
			return nil, e
		}
		ep := pathValue(r, "endpoint", "browseEndpoint")
		if str(ep, "browseId") == "" {
			return nil, errors.New("This YouTube hashtag has no videos.")
		}
		if r, e = ytCall(ctx, c, "browse", map[string]any{"browseId": str(ep, "browseId"), "params": str(ep, "params")}); e != nil {
			return nil, e
		}
		m := &engine.Media{ID: p[1], Title: "#" + p[1], PageURL: "https://www.youtube.com/hashtag/" + url.PathEscape(p[1])}
		y.more(ctx, c, "browse", r, m, c.PlaylistLimit)
		return ytEntries(m, "This YouTube hashtag has no videos.")
	} else if len(p) == 1 && p[0] == "results" {
		q := fbFirst(u.Query().Get("search_query"), u.Query().Get("q"))
		if q == "" {
			return nil, nil
		}
		body := map[string]any{"query": q}
		if sp := u.Query().Get("sp"); sp != "" {
			body["params"] = sp
		}
		v, e := ytCall(ctx, c, "search", body)
		if e != nil {
			return nil, e
		}
		//
		m := &engine.Media{ID: q, Title: q, PageURL: "https://www.youtube.com/results?search_query=" + url.QueryEscape(q)}
		ytItems(v, m, map[string]bool{})
		return ytEntries(m, "YouTube found nothing for "+strconv.Quote(q)+".")
	}
	return nil, nil
}

// RECOVERY: always inlined (playlist, hashtag, search); name not recoverable.

func ytEntries(m *engine.Media, empty string) (*engine.Media, error) {
	if len(m.Entries) == 0 {
		return nil, errors.New(empty)
	}
	m.Thumbnail = m.Entries[0].Thumbnail
	return m, nil
}

// parseClock parses m:ss or h:mm:ss into seconds; 0 when malformed.
func parseClock(s string) float64 {
	var n float64
	p := strings.Split(strings.TrimSpace(s), ":")
	if len(p) < 2 || len(p) > 3 {
		return 0
	}
	for _, v := range p {
		x, e := strconv.Atoi(v)
		if e != nil {
			return 0
		}
		n = n*60 + float64(x)
	}
	return n
}

// walk calls fn for every key/value pair in a decoded JSON tree.
func walk(v any, fn func(string, any)) {
	switch x := v.(type) {
	case map[string]any:
		for k, value := range x {
			fn(k, value)
			walk(value, fn)
		}
	case []any:
		for _, value := range x {
			walk(value, fn)
		}
	}
}

// Provenance notes carried over from the 0.2.1 (Linux) reconstruction. They are
// kept at the end of the file so that the 0.2.8 source layout is unchanged.
//
// Evidence-guided reconstruction of youtube.embedded, ytConfig and ytStatus.
// See RECOVERY.md for remaining high-level fidelity limitations. (0.2.1 kept the
// native client retry matrix in youtube_clients.go; 0.2.8 has it here.)
//
// ytAdsEnd reconstructs the original preroll availability delay. It does not
// request ads, alter access tokens, or remove the upstream waiting period.
//
// ytClients: 0.2.1 had an exact static slice at 0x153b8a0 (3 records, 64 bytes
// each: ANDROID_VR first); 0.2.8 has two clients (VISIONOS, TVHTML5).
//
// Page parsing: 0.2.1's ytMore reconstructed the original 20-page continuation
// cap, which youtube.more keeps in 0.2.8.
//
// ytItems: shapes and key paths survive in original ytItems.func4; UI-specific
// author fallbacks remain approximate.
//
// youtube.uploads: the original transforms UC channel IDs into UULF/UU, UUSH or
// UULV playlists.
//
// youtube.tab: select the server-advertised browse endpoint and params, never
// synthesize opaque tab params.
