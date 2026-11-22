package engine

import (
	"regexp"
	"strconv"
	"strings"
)

// chapterLine matches one timestamped line of a video description:
// optional bullet/bracket prefix, [h:]mm:ss, optional closing bracket and
// separator, then the chapter title.
//
// RECOVERY: the variable name is not recorded in the binary; the pattern is
// the exact literal compiled by the package initializer at line 15.
var chapterLine = regexp.MustCompile(`^[\s([•*-]*(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[\])]?\s*(?:[-–—:|]\s*)?(.*)$`)

// ChaptersFromDescription parses YouTube-style chapter lists. The list must
// start at 0:00, increase strictly, stay below the duration and contain at
// least three entries; anything else yields nil, so a description with a
// few stray timestamps does not produce bogus chapters.
func ChaptersFromDescription(desc string, duration float64) []Chapter {
	var out []Chapter
	for _, line := range strings.Split(desc, "\n") {
		m := chapterLine.FindStringSubmatch(strings.TrimSpace(line))
		if m == nil {
			continue
		}
		h, _ := strconv.Atoi(m[1])
		min, _ := strconv.Atoi(m[2])
		sec, _ := strconv.Atoi(m[3])
		if sec >= 60 || m[1] != "" && min >= 60 {
			continue
		}
		start := float64(h*3600 + min*60 + sec)
		title := strings.TrimSpace(m[4])
		if title == "" {
			continue
		}
		if len(out) == 0 && start != 0 {
			// Descriptions often mention timestamps before the list starts.
			continue
		}
		if len(out) > 0 && start <= out[len(out)-1].Start || duration > 0 && start >= duration {
			return nil
		}
		out = append(out, Chapter{Start: start, Title: title})
	}
	if len(out) < 3 {
		return nil
	}
	return out
}

// Reconstructed from runtime descriptor 0x143e730.
type mark struct {
	Chapter
	sponsor bool
}
