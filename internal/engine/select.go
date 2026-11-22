package engine

import (
	"errors"
	"fmt"
	"sort"
	"strings"
)









func compatibleVideo(f Format) bool {
	c := strings.ToLower(f.VCodec)
	return c == "" || strings.HasPrefix(c, "avc") || strings.HasPrefix(c, "h264")
}

func compatibleAudio(f Format) bool {
	c := strings.ToLower(f.ACodec)
	return c == "" || strings.HasPrefix(c, "mp4a") || c == "aac" || f.Ext == "m4a"
}



// Select's data shape follows the native caller. Ranking is a reconstruction;
// cross-codec tie breaks have not yet been differentially verified.
func Select(m *Media, o Options, hasFFmpeg bool) ([]Format, error) {
	if m == nil {
		return nil, errors.New("no media")
	}
	if o.Format != "" {
		var out []Format
		for _, id := range strings.Split(o.Format, "+") {
			f, ok := m.FormatByID(strings.TrimSpace(id))
			if !ok {
				return nil, fmt.Errorf("format %q not found", id)
			}
			out = append(out, f)
		}
		return out, nil
	}
	fs := append([]Format(nil), m.Formats...)
	sort.SliceStable(fs, func(i, j int) bool {
		a, b := fs[i], fs[j]
		if a.Height != b.Height {
			return a.Height > b.Height
		}
		if a.FPS != b.FPS {
			return a.FPS > b.FPS
		}
		if a.Audio != b.Audio {
			return a.Audio
		}
		if nativeFormat(a) != nativeFormat(b) {
			return nativeFormat(a)
		}
		return a.Bitrate > b.Bitrate
	})
	audio, audioOK := bestAudio(m.Formats, o.PreferCompatible, "", hasFFmpeg, true)
	if o.Mode == "audio" {
		if !audioOK {
			return nil, errors.New("no audio formats")
		}
		return []Format{audio}, nil
	}
	var videos []Format
	for _, f := range fs {
		if f.Video {
			videos = append(videos, f)
		}
	}
	if o.MaxHeight > 0 && len(videos) > 0 {
		var under []Format
		for _, f := range videos {
			if f.Resolution() <= o.MaxHeight {
				under = append(under, f)
			}
		}
		if len(under) > 0 {
			videos = under
		} else {
			sort.SliceStable(videos, func(i, j int) bool { return videos[i].Height < videos[j].Height })
			videos = videos[:1]
		}
	}
	if o.PreferCompatible {
		var compatible []Format
		for _, f := range videos {
			if compatibleVideo(f) {
				compatible = append(compatible, f)
			}
		}
		if len(compatible) > 0 {
			videos = compatible
		}
	}
	for _, f := range videos {
		if !f.Video {
			continue
		}
		if f.Audio {
			return []Format{f}, nil
		}
		if a, ok := bestAudio(m.Formats, o.PreferCompatible, containerGroup(f), hasFFmpeg, false); ok {
			return []Format{f, a}, nil
		}
	}
	if len(videos) > 0 {
		return []Format{videos[0]}, nil
	}
	if audioOK {
		return []Format{audio}, nil
	}










	return nil, errors.New("no suitable format found")
}

// bestAudio translates 0xabcd60 and comparator0xac2ec0. Native tracks can
// pair without FFmpeg; nonnative pairing needs FFmpeg. Standalone audio can
// fall back to a combined format only if no audio-only format exists.
func bestAudio(fs []Format, compatible bool, container string, hasFFmpeg, allowCombined bool) (Format, bool) {
	var candidates []Format
	for _, f := range fs {
		if !f.Audio || f.Video {
			continue
		}
		if container != "" && !hasFFmpeg && !nativeFormat(f) {
			continue
		}
		candidates = append(candidates, f)
	}
	if len(candidates) == 0 {
		if !allowCombined {
			return Format{}, false
		}
		for _, f := range fs {
			if f.Audio {
				candidates = append(candidates, f)
			}
		}
		sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].Bitrate > candidates[j].Bitrate })
	} else {
		sort.SliceStable(candidates, func(i, j int) bool {
			a, b := candidates[i], candidates[j]
			if compatible && compatibleAudio(a) != compatibleAudio(b) {
				return compatibleAudio(a)
			}
			if container != "" && (containerGroup(a) == container) != (containerGroup(b) == container) {
				return containerGroup(a) == container
			}
			return audioBetter(a, b, false)
		})
	}
	if len(candidates) == 0 {
		return Format{}, false
	}










	return candidates[0], true
}

// Native-mux support predicate in Select.func2 at 0xac2900.
func nativeFormat(f Format) bool {
	switch f.Ext {
	case "ts", "mp4", "m4a", "m4v", "mov":
		return true
	}
	return f.Protocol == "hls" || f.Protocol == "dash" && f.Ext != "webm"
}

func audioBetter(a, b Format, compatible bool) bool {
	if compatible && compatibleAudio(a) != compatibleAudio(b) {
		return compatibleAudio(a)
	}
	preferred := func(f Format) bool {
		return strings.Contains(f.Note, "default") || strings.Contains(f.Note, "original")
	}
	if preferred(a) != preferred(b) {
		return preferred(a)
	}
	return a.Bitrate > b.Bitrate
}

func containerGroup(f Format) string {
	switch f.Ext {
	case "ts":
		return "ts"
	case "webm", "weba", "opus":
		return "webm"
	default:
		return "mp4"
	}
}
