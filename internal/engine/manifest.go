package engine

// ListenJar port: only HLSFormats is copied from downbit's
// internal/engine/manifest.go. DASHFormats, Expand, ExpandAs, MediaKind,
// ContentKind and FileFormat are not ported (DASH needs downbit's mux
// package, and the YouTube extractor uses none of them).

import (
	"context"
)

// HLSFormats fetches an HLS master playlist and lists its variants and
// audio renditions as formats. A media playlist yields a single format.
//
// The request headers are kept on every format for the download.
func (c *Client) HLSFormats(ctx context.Context, raw string, h map[string]string) ([]Format, error) {
	s, err := c.Text(ctx, raw, h)
	if err != nil {
		return nil, err
	}
	f, err := hlsFormats(raw, s)
	for i := range f {
		f[i].Headers = h
	}
	return f, err
}
