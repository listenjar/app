package extract

// ListenJar entry point. Everything else in this package is ported from
// downbit (see NOTICE.md); this file is new.

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"time"

	"github.com/listenjar/desktop/internal/engine"
)

// YouTubeAudio is a YouTube video resolved for an audio-only download.
type YouTubeAudio struct {
	// ID is the 11-character video id.
	ID     string
	Title  string
	Author string
	// Description is the video description as YouTube shows it.
	Description string
	// Duration is the video length; zero when YouTube does not say.
	Duration time.Duration
	// Date is the publish date, "2006-01-02", or "" when unknown.
	Date      string
	PageURL   string
	Thumbnail string
	// Stream is the best audio-only format (a muxed one only when YouTube
	// offers no audio-only stream). Fetch Stream.URL with every
	// header in Stream.Headers; YouTube refuses (403) a different User-Agent.
	// Stream.Ext is the file extension ("m4a" or "webm") and Stream.Size the
	// length in bytes when YouTube says.
	Stream engine.Format
	// AvailableAt, when in the future, is when YouTube starts serving the
	// stream (the preroll ad delay downbit waits out); fetching earlier fails.
	AvailableAt time.Time
}

// ResolveYouTube resolves a YouTube video id or watch/short/embed/shorts URL
// to its metadata and best audio-only stream. Set JSRunner first (for example
// to jsrun.Run) so that clients and streams that need the player JavaScript
// can be used; without it only the native client is tried.
//
// Playlists, channels and live streams are refused.
func ResolveYouTube(ctx context.Context, c *engine.Client, idOrURL string) (*YouTubeAudio, error) {
	raw := idOrURL
	if ytIDPattern.MatchString(idOrURL) {
		raw = "https://www.youtube.com/watch?v=" + idOrURL
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("parse YouTube video %q: %w", idOrURL, err)
	}
	var y youtube
	if !y.Match(u) {
		return nil, fmt.Errorf("%q is not a YouTube link", idOrURL)
	}
	if ytVideoID(u) == "" {
		return nil, fmt.Errorf("%q is not a YouTube video", idOrURL)
	}
	// A watch URL inside a playlist would list the playlist instead.
	q := u.Query()
	q.Del("list")
	u.RawQuery = q.Encode()
	m, err := y.Extract(ctx, c, u)
	if err != nil {
		return nil, err
	}
	if m.IsLive {
		return nil, fmt.Errorf("YouTube video %s is a live stream", m.ID)
	}
	formats, err := engine.Select(m, engine.Options{Mode: "audio"}, false)
	if err != nil {
		return nil, fmt.Errorf("YouTube video %s: %w", m.ID, err)
	}
	if len(formats) == 0 {
		return nil, errors.New("no audio formats")
	}
	return &YouTubeAudio{
		ID:          m.ID,
		Title:       m.Title,
		Author:      m.Author,
		Description: m.Description,
		Duration:    time.Duration(m.Duration * float64(time.Second)),
		Date:        m.Date,
		PageURL:     m.PageURL,
		Thumbnail:   m.Thumbnail,
		Stream:      formats[0],
		AvailableAt: m.AvailableAt,
	}, nil
}
