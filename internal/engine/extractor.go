package engine

// ListenJar port: the Extractor interface and registry below are copied
// verbatim from downbit's internal/engine/engine.go. The rest of engine.go
// (Engine, Extract, Download, FFmpeg handling, licensing) is not ported.

import (
	"context"
	"net/url"
)

type Extractor interface {
	Extract(context.Context, *Client, *url.URL) (*Media, error)
	Match(*url.URL) bool
	Name() string
}

// Neutral recovered names for original globals whose identifiers were stripped.
var Extractors []Extractor

// Register appends an extractor (inlined in the original, engine.go:46).
func Register(x Extractor) { Extractors = append(Extractors, x) }
