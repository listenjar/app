package engine

// ListenJar port: Mode and Options are copied from downbit's
// internal/engine/options.go for NewClient and Select. The Section field is
// dropped (its type lives in section.go, which is not ported), and the
// connections, FileName and SanitizeFilename helpers are not ported (they need
// downbit's license and media-server code).

// Mode selects what Download keeps: "video" or "audio".
type Mode string

// Options controls one download. The zero value downloads the best
// compatible video into the working directory.
type Options struct {
	// Dir is the destination directory.
	Dir string
	// Template is the file name template, e.g. "{author}/{title}". Each
	// path element is filled in and sanitized separately. Placeholders:
	// {title} {id} {site} {author} {quality} {date} {year} {playlist}
	// {show}.
	Template string
	// MediaServer arranges files for Plex/Jellyfin: one folder per show,
	// season folders, NFO sidecars and poster images.
	MediaServer bool
	// Title overrides the media title in file names and metadata.
	Title string

	// Mode is "video" or "audio".
	Mode Mode
	// MaxHeight caps the video height (0 means best).
	MaxHeight int
	// PreferCompatible prefers H.264/AAC in MP4 over newer codecs.
	PreferCompatible bool
	// Format forces a format ID (from Media.Formats).
	Format string
	// AudioFormat and VideoFormat are the target containers; anything other
	// than m4a/mp4 is converted with FFmpeg.
	AudioFormat string
	VideoFormat string

	// Subtitles downloads subtitles in SubtitleLangs (comma separated;
	// English by default), embedding them when EmbedSubtitles is set.
	Subtitles      bool
	SubtitleLangs  string
	EmbedSubtitles bool

	// RateLimit caps the transfer rate in bytes per second (0: unlimited).
	RateLimit int64
	// Connections is the number of parallel connections per file.
	Connections int
	// Proxy is the proxy URL for every request.
	//
	Proxy string
	// CookiesFile is a Netscape cookies.txt file.
	CookiesFile string
	// Referer, UserAgent and Headers are sent with every request.
	Referer   string
	UserAgent string
	Headers   map[string]string

	// SponsorMark and SponsorRemove are SponsorBlock categories to mark as
	// chapters or cut out.
	SponsorMark   []string
	SponsorRemove []string

	// NoPlaylist downloads the single video of a playlist URL.
	NoPlaylist bool
	// PlaylistLimit caps how many playlist entries are listed.
	PlaylistLimit int

	// EmbedMetadata writes title, artist, date and description tags.
	EmbedMetadata bool
	// EmbedThumbnail embeds the thumbnail as cover art.
	EmbedThumbnail bool
	// SaveThumbnail writes the thumbnail next to the file.
	SaveThumbnail bool
	// UseUploadDate sets the file time to the upload date instead of the
	// download time.
	UseUploadDate bool

	// StopLive ends a live recording (closed by the caller); what was
	// recorded so far is kept.
	StopLive <-chan struct{}
}
