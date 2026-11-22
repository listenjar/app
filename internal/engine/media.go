package engine

import (
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Protocol says how a format's URL is fetched: "http" (one file), "hls"
// or "dash" (segmented).
type Protocol string

//
//
//
//
//
// Format is one downloadable rendition of a media item. A format may carry
// video, audio or both; split formats are paired by Select.
type Format struct {
	ID       string            `json:"id"`
	Protocol Protocol          `json:"protocol"`
	URL      string            `json:"url"`
	Ext      string            `json:"ext"`
	Video    bool              `json:"video"`
	Audio    bool              `json:"audio"`
	Width    int               `json:"width,omitempty"`
	Height   int               `json:"height,omitempty"`
	FPS      float64           `json:"fps,omitempty"`
	Bitrate  int               `json:"bitrate,omitempty"`
	VCodec   string            `json:"vcodec,omitempty"`
	ACodec   string            `json:"acodec,omitempty"`
	Size     int64             `json:"size,omitempty"`
	Lang     string            `json:"lang,omitempty"`
	Note     string            `json:"note,omitempty"`
	Headers  map[string]string `json:"headers,omitempty"`

	// ListenJar port: downbit's unexported `rep *dashRep` field (the parsed
	// DASH representation behind a dash format) is dropped with dash.go,
	// which the YouTube extractor does not use.
}





// Codec is the human-readable codec summary, e.g. "H.264 + AAC".
//
// It lists the video codec first.
func (f Format) Codec() string {
	var parts []string
	if f.Video {
		parts = append(parts, CodecName(f.VCodec))
	}
	if f.Audio {
		parts = append(parts, CodecName(f.ACodec))
	}
	return strings.Join(parts, " + ")
}

// Label is the one-line description shown in format pickers.
func (f Format) Label() string {
	var parts []string
	switch {
	case f.Video && f.Height > 0:
		parts = append(parts, QualityLabel(f.Resolution()))
	case f.Video:
		parts = append(parts, "Video")
	default:
		parts = append(parts, "Audio")
		if f.Bitrate > 0 {
			parts = append(parts, itoa(f.Bitrate/1000)+" kbps")
		}
	}
	if c := f.Codec(); c != "" && !strings.Contains(c, "?") {
		parts = append(parts, c)
	}
	parts = append(parts, strings.ToUpper(f.Ext))
	return strings.Join(parts, " · ")
}

// CodecName maps an RFC 6381 codec string or short name to a display name.
func CodecName(c string) string {
	c = strings.ToLower(c)
	switch {
	case strings.HasPrefix(c, "avc"), strings.HasPrefix(c, "h264"):
		return "H.264"
	case strings.HasPrefix(c, "hev"), strings.HasPrefix(c, "hvc"), strings.HasPrefix(c, "h265"):
		return "HEVC"
	case strings.HasPrefix(c, "vp09"), strings.HasPrefix(c, "vp9"):
		return "VP9"
	case strings.HasPrefix(c, "vp8"):
		return "VP8"
	case strings.HasPrefix(c, "av01"), c == "av1":
		return "AV1"
	case strings.HasPrefix(c, "mp4a"), c == "aac":
		return "AAC"
	case c == "opus":
		return "Opus"
	case c == "mp3", c == "mp4a.40.34", c == "mp4a.6b":
		return "MP3"
	case c == "vorbis":
		return "Vorbis"
	case strings.HasPrefix(c, "ac-3"), strings.HasPrefix(c, "ec-3"):
		return "Dolby"
	case c == "":
		return "?"
	}
	return strings.ToUpper(strings.SplitN(c, ".", 2)[0])
}


// Resolution is the short side of the frame, so portrait video is labelled
// like its landscape equivalent. Without a width the height is used as is:
// audio-only and unknown formats report their raw height.
func (f Format) Resolution() int {
	if f.Width > 0 && f.Height > 0 {
		return min(f.Width, f.Height)
	}
	return f.Height
}

func QualityLabel(h int) string {
	switch {
	case h >= 4000:
		return "8K"
	case h >= 2000:
		return "4K"
	case h >= 1400:
		return "1440p"
	case h <= 0:
		return ""
	}
	return itoa(h) + "p"
}

// QualityHeight is the inverse of QualityLabel for quality settings such as
// "1080p", "4K" or "8K (HDR)". It returns 0 for anything else.
func QualityHeight(q string) int {
	q, _, _ = strings.Cut(strings.TrimSpace(q), " ")
	switch q {
	case "8K":
		return 4320
	case "4K":
		return 2160
	}
	if n, err := strconv.Atoi(strings.TrimSuffix(q, "p")); err == nil && n > 0 && strings.HasSuffix(q, "p") {
		return n
	}
	return 0
}

// Media is everything an extractor found for one page: a single item with
// formats, a playlist of entries, or a gallery of images.
//
// Formats, Entries and Images are mutually exclusive in practice: IsPlaylist
// and IsGallery classify the result. Headers apply to every request made for
// the media (formats can add their own). AvailableAt is set for premieres
// and scheduled streams that cannot be downloaded yet. SignInForMore tells
// the UI that a signed-in session would unlock more formats.
type Media struct {
	ID            string            `json:"id"`
	Title         string            `json:"title"`
	Site          string            `json:"site"`
	Author        string            `json:"author,omitempty"`
	Description   string            `json:"description,omitempty"`
	Thumbnail     string            `json:"thumbnail,omitempty"`
	Duration      float64           `json:"duration,omitempty"`
	Date          string            `json:"date,omitempty"`
	PageURL       string            `json:"pageUrl"`
	IsLive        bool              `json:"isLive,omitempty"`
	Formats       []Format          `json:"formats,omitempty"`
	Subtitles     []Subtitle        `json:"subtitles,omitempty"`
	Chapters      []Chapter         `json:"chapters,omitempty"`
	Entries       []Entry           `json:"entries,omitempty"`
	Playlist      string            `json:"playlist,omitempty"`
	Images        []Image           `json:"images,omitempty"`
	Generic       bool              `json:"generic,omitempty"`
	Headers       map[string]string `json:"headers,omitempty"`
	AvailableAt   time.Time         `json:"availableAt,omitzero"`
	SignInForMore bool              `json:"signInForMore,omitempty"`

	// jar keeps the extractor's cookies for the download.
	jar http.CookieJar
}

// Subtitle is one subtitle track; Auto marks machine-generated captions.
// URL may be a data: URL for subtitles embedded in the page.
type Subtitle struct {
	Lang string `json:"lang"`
	Name string `json:"name,omitempty"`
	URL  string `json:"url"`
	Ext  string `json:"ext"`
	Auto bool   `json:"auto,omitempty"`
}

// Chapter is a chapter start in seconds. Chapters are ordered by Start;
// the end of a chapter is the start of the next one (or the duration).
type Chapter struct {
	Start float64 `json:"start"`
	Title string  `json:"title"`
}

// Entry is one item of a playlist or channel. Entries are extracted again
// when they are queued, so only list metadata is kept: the URL to extract,
// the title and duration for the list, and the uploader and thumbnail when
// the listing shows them.
type Entry struct {
	ID        string  `json:"id"`
	URL       string  `json:"url"`
	Title     string  `json:"title"`
	Duration  float64 `json:"duration,omitempty"`
	Author    string  `json:"author,omitempty"`
	Thumbnail string  `json:"thumbnail,omitempty"`
}












// IsPlaylist reports whether the media lists entries instead of formats.
func (m *Media) IsPlaylist() bool { return len(m.Entries) > 0 && len(m.Formats) == 0 }


// IsGallery reports whether the media is a set of pictures only.
func (m *Media) IsGallery() bool {
	return len(m.Images) > 0 && len(m.Formats) == 0 && len(m.Entries) == 0
}


// MaxHeight is the tallest video format's height.
func (m *Media) MaxHeight() int {
	h := 0
	for _, f := range m.Formats {
		if f.Video && f.Height > h {
			h = f.Height
		}
	}
	return h
}

// SortedFormats lists video first, tallest first, then formats with
// audio, then by bitrate.
func (m *Media) SortedFormats() []Format {
	f := append([]Format(nil), m.Formats...)
	sort.SliceStable(f, func(i, j int) bool {
		a, b := f[i], f[j]
		if a.Video != b.Video {
			return a.Video
		}
		if a.Height != b.Height {
			return a.Height > b.Height
		}
		if a.Audio != b.Audio {
			return a.Audio
		}
		return a.Bitrate > b.Bitrate
	})
	return f
}

// FormatByID finds a format by its ID.
func (m *Media) FormatByID(id string) (Format, bool) {
	for _, f := range m.Formats {
		if f.ID == id {
			return f, true
		}
	}
	return Format{}, false
}

// Image is one picture (or short clip) of a gallery post. Ext is a hint;
// the downloader sniffs the real type from the content. Video marks clips
// (live photos, GIF-as-MP4) that are saved next to the pictures; Width and
// Height are informational.
type Image struct {
	URL    string `json:"url"`
	Ext    string `json:"ext,omitempty"`
	Width  int    `json:"width,omitempty"`
	Height int    `json:"height,omitempty"`
	Video  bool   `json:"video,omitempty"`
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
}
