package engine

// ListenJar port: the segment and track types below are copied verbatim from
// downbit's internal/engine/segments.go so that hls.go compiles. The segment
// downloader that uses them (downloadTrack, keyCache, joinSegments) is not
// ported.

// Reconstructed from runtime descriptor 0x1474bc8.
type segment struct {
	URL      string
	Range    *byteRange
	Key      *hlsKey
	Seq      int64
	Duration float64
}

// Reconstructed from runtime descriptor 0x147ecd0.
type track struct {
	Init     *segment
	Segments []segment
	Ext      string
	Live     bool
	URL      string
	Target   float64
}
