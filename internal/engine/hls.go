package engine

import (
	"bufio"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// ErrDRM is returned for media that uses DRM (FairPlay, Widevine, PlayReady
// or SAMPLE-AES); such media cannot be downloaded.
var ErrDRM = errors.New("this media is protected by DRM and can't be downloaded")

// rendition is one #EXT-X-MEDIA audio rendition of an HLS master playlist.
type rendition struct {
	group string
	lang  string
	name  string
	uri   string
	def   bool
}

// hlsKey is the #EXT-X-KEY in effect for a segment. Without an IV the
// segment's media sequence number is the IV.
type hlsKey struct {
	Method string
	URI    string
	IV     []byte
}

// byteRange is an #EXT-X-BYTERANGE (or DASH range): len bytes at off.
type byteRange struct {
	off int64
	len int64
}


// parseAttrs parses an HLS attribute list: KEY=VALUE pairs separated by
// commas, where quoted values may contain commas. Keys are trimmed, values
// are kept as is.
func parseAttrs(s string) map[string]string {
	m := map[string]string{}
	for s != "" {
		eq := strings.IndexByte(s, '=')
		if eq < 0 {
			break
		}
		key := strings.TrimSpace(s[:eq])
		s = s[eq+1:]
		var val string
		if strings.HasPrefix(s, `"`) {
			end := strings.IndexByte(s[1:], '"')
			if end < 0 {
				val, s = s[1:], ""
			} else {
				val, s = s[1:end+1], s[end+2:]
			}
		} else {
			end := strings.IndexByte(s, ',')
			if end < 0 {
				val, s = s, ""
			} else {
				val, s = s[:end], s[end:]
			}
		}
		m[key] = val
		s = strings.TrimPrefix(s, ",")
	}
	return m
}

// hlsFormats lists the variants and audio renditions of a master playlist,
// or the playlist itself for a media playlist.
func hlsFormats(base, text string) ([]Format, error) {
	if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(text, "\ufeff")), "#EXTM3U") {
		return nil, errors.New("not an HLS playlist")
	}
	if !strings.Contains(text, "#EXT-X-STREAM-INF") {
		if strings.Contains(text, "METHOD=SAMPLE-AES") || strings.Contains(text, `KEYFORMAT="com.apple.streamingkeydelivery"`) {
			return nil, ErrDRM
		}
		ext := "ts"
		if strings.Contains(text, "#EXT-X-MAP") {
			ext = "mp4"
		}
		return []Format{{ID: "hls", Protocol: "hls", URL: base, Ext: ext, Video: true, Audio: true}}, nil
	}

	// Audio renditions by group, from #EXT-X-MEDIA. A variant that names a
	// group with its own URIs carries no audio itself; the renditions are
	// listed after the variants.
	groups := map[string][]rendition{}
	// Variants follow in the order of the playlist; each URL is listed
	// once.
	var formats []Format
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#EXT-X-MEDIA:") {
			a := parseAttrs(line[len("#EXT-X-MEDIA:"):])
			if a["TYPE"] == "AUDIO" {
				groups[a["GROUP-ID"]] = append(groups[a["GROUP-ID"]], rendition{a["GROUP-ID"], a["LANGUAGE"], a["NAME"], a["URI"], a["DEFAULT"] == "YES"})
			}
		}
	}
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 64*1024), 4<<20)
	var attrs map[string]string // of the pending #EXT-X-STREAM-INF
	seen := map[string]bool{}
	audioCodec := map[string]string{}
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		switch {
		case strings.HasPrefix(line, "#EXT-X-STREAM-INF:"):
			attrs = parseAttrs(line[len("#EXT-X-STREAM-INF:"):])
		case strings.HasPrefix(line, "#EXT-X-SESSION-KEY") && strings.Contains(line, "SAMPLE-AES"):
			return nil, ErrDRM
		case line != "" && !strings.HasPrefix(line, "#") && attrs != nil:
			a := attrs
			attrs = nil
			u := resolve(base, line)
			if seen[u] {
				continue
			}
			seen[u] = true
			f := Format{Protocol: "hls", URL: u, Ext: "ts", Video: true, Audio: true}
			f.Bitrate, _ = strconv.Atoi(a["AVERAGE-BANDWIDTH"])
			if f.Bitrate == 0 {
				f.Bitrate, _ = strconv.Atoi(a["BANDWIDTH"])
			}
			if res := a["RESOLUTION"]; res != "" {
				w, h, _ := strings.Cut(res, "x")
				f.Width, _ = strconv.Atoi(w)
				f.Height, _ = strconv.Atoi(h)
			}
			f.FPS, _ = strconv.ParseFloat(a["FRAME-RATE"], 64)
			for _, c := range strings.Split(a["CODECS"], ",") {
				c = strings.TrimSpace(c)
				switch {
				case strings.HasPrefix(c, "mp4a"), strings.HasPrefix(c, "ac-3"), strings.HasPrefix(c, "ec-3"), c == "opus":
					f.ACodec = c
				case c != "":
					f.VCodec = c
				}
			}
			if f.VCodec == "" && f.Height == 0 && f.ACodec != "" {
				f.Video = false
			}
			if g := a["AUDIO"]; g != "" && f.ACodec != "" {
				audioCodec[g] = f.ACodec
			}
			if g := a["AUDIO"]; g != "" {
				for _, r := range groups[g] {
					if r.uri != "" {
						f.Audio = false
						break
					}
				}
			}
			if strings.HasPrefix(f.VCodec, "hvc") || strings.HasPrefix(f.VCodec, "hev") || strings.HasPrefix(f.VCodec, "av01") {
				f.Ext = "mp4"
			}
			f.ID = "hls-" + strconv.Itoa(f.Bitrate/1000)
			if f.Height > 0 {
				f.ID = "hls-" + strconv.Itoa(f.Height) + "p-" + strconv.Itoa(f.Bitrate/1000)
			}
			formats = append(formats, f)
		}
	}
	for g, rs := range groups {
		for i, r := range rs {
			if r.uri == "" {
				continue
			}
			f := Format{
				ID: "hls-audio-" + SanitizeID(g) + "-" + strconv.Itoa(i), Protocol: "hls", URL: resolve(base, r.uri),
				Ext: "ts", Audio: true, Lang: r.lang, Note: r.name,
			}
			if r.def {
				f.Note = strings.TrimSpace(r.name + " (default)")
			}
			// The variants name the codec of their audio group.
			f.ACodec = audioCodec[g]
			formats = append(formats, f)
		}
	}





	return formats, nil
}







// hlsTrack parses an HLS media playlist into a track. Live playlists (no
// #EXT-X-ENDLIST) are refreshed by recordHLS; the segments carry their
// media sequence numbers for that.
func hlsTrack(base, text string) (track, error) {
	t := track{Ext: "ts", Live: !strings.Contains(text, "#EXT-X-ENDLIST"), URL: base}
	var (
		seq    int64
		next   int64
		dur    float64
		key    *hlsKey
		rng    *byteRange
		mapped bool
	)
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 64*1024), 8<<20)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		switch {
		case strings.HasPrefix(line, "#EXT-X-MEDIA-SEQUENCE:"):
			seq, _ = strconv.ParseInt(line[len("#EXT-X-MEDIA-SEQUENCE:"):], 10, 64)
		case strings.HasPrefix(line, "#EXT-X-TARGETDURATION:"):
			t.Target, _ = strconv.ParseFloat(line[len("#EXT-X-TARGETDURATION:"):], 64)
		case strings.HasPrefix(line, "#EXT-X-KEY:"):
			a := parseAttrs(line[len("#EXT-X-KEY:"):])
			switch a["METHOD"] {
			case "", "NONE":
				key = nil
			case "AES-128":
				key = &hlsKey{Method: "AES-128", URI: resolve(base, a["URI"])}
				if iv := a["IV"]; iv != "" {
					b, err := hex.DecodeString(strings.TrimPrefix(strings.TrimPrefix(iv, "0x"), "0X"))
					if err == nil && len(b) == 16 {
						key.IV = b
					}
				}
			default:
				return t, ErrDRM
			}
		case strings.HasPrefix(line, "#EXT-X-MAP:"):
			a := parseAttrs(line[len("#EXT-X-MAP:"):])
			if !mapped {
				init := &segment{URL: resolve(base, a["URI"])}
				if r := a["BYTERANGE"]; r != "" {
					init.Range = parseByteRange(r, 0)
				}
				t.Init, t.Ext, mapped = init, "mp4", true
			}
		case strings.HasPrefix(line, "#EXTINF:"):
			d, _, _ := strings.Cut(line[len("#EXTINF:"):], ",")
			dur, _ = strconv.ParseFloat(d, 64)
		case strings.HasPrefix(line, "#EXT-X-BYTERANGE:"):
			rng = parseByteRange(line[len("#EXT-X-BYTERANGE:"):], next)
		case line != "" && !strings.HasPrefix(line, "#"):
			seg := segment{URL: resolve(base, line), Range: rng, Key: key, Seq: seq, Duration: dur}
			if rng != nil {
				next = rng.off + rng.len
			}
			t.Segments = append(t.Segments, seg)
			seq, dur, rng = seq+1, 0, nil
		}
	}

	if len(t.Segments) == 0 {
		return t, errors.New("the HLS playlist has no segments")
	}
	return t, nil
}

func parseByteRange(s string, next int64) *byteRange { // "<len>[@<off>]"
	n, o, ok := strings.Cut(strings.TrimSpace(s), "@")
	length, err := strconv.ParseInt(n, 10, 64)
	if err != nil {
		return nil
	}
	off := next
	if ok {
		off, _ = strconv.ParseInt(o, 10, 64)
	}
	return &byteRange{off: off, len: length}
}

// decryptAES128 decrypts one AES-128-CBC segment and strips the PKCS#7
// padding. Without an explicit IV the IV is the media sequence number.
func decryptAES128(data, key []byte, k *hlsKey, seq int64) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	iv := k.IV
	if iv == nil {
		iv = make([]byte, 16)
		binary.BigEndian.PutUint64(iv[8:], uint64(seq))
	}
	if len(data)%16 != 0 {
		return nil, fmt.Errorf("an encrypted segment of %d bytes", len(data))
	}
	out := make([]byte, len(data))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, data)

	if len(out) > 0 {
		pad := int(out[len(out)-1])
		if pad > 0 && pad <= 16 && pad <= len(out) {
			out = out[:len(out)-pad]
		}
	}
	return out, nil
}

// loadHLSTrack fetches f's playlist, following the best video variant.
func (c *Client) loadHLSTrack(ctx context.Context, f Format) (track, error) {
	s, err := c.Text(ctx, f.URL, f.Headers)
	if err != nil {
		return track{}, err
	}

	if strings.Contains(s, "#EXT-X-STREAM-INF") {
		formats, err := hlsFormats(f.URL, s)
		if err != nil {
			return track{}, err
		}
		var best Format
		for _, v := range formats {
			if v.Video && v.Bitrate >= best.Bitrate {
				best = v
			}
		}
		if best.URL == "" {
			return track{}, errors.New("the HLS playlist has no variants")
		}
		best.Headers = f.Headers
		return c.loadHLSTrack(ctx, best)
	}
	return hlsTrack(f.URL, s)
}

// SanitizeID keeps the characters that are safe in a format ID.
func SanitizeID(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
			return r
		}
		return -1
	}, s)
}
