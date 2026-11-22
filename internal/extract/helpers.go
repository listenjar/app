package extract

// ListenJar port: helpers the YouTube extractor calls that live in other
// downbit files, copied verbatim: dedupeIDs (generic.go), segments (sites.go),
// fbFirst (facebook.go) and ytPicture (peek.go). The providers they come from
// are not ported.

import (
	"context"
	"net/url"
	"strconv"
	"strings"

	"github.com/listenjar/desktop/internal/engine"
)

func dedupeIDs(fs []engine.Format) {
	seen := map[string]int{}
	for i := range fs {
		id := fs[i].ID
		if n := seen[id]; n > 0 {
			fs[i].ID = id + "-" + strconv.Itoa(n+1)
		}
		seen[id]++
	}
}

func segments(u *url.URL) []string {
	var p []string
	for _, s := range strings.Split(u.Path, "/") {
		if s != "" {
			p = append(p, s)
		}
	}
	return p
}

func fbFirst(values ...string) string { // RECOVERY: name unknown; always inlined in the original
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func ytPicture(ctx context.Context, c *engine.Client, id string) string {
	for _, name := range []string{"maxresdefault", "sddefault", "hqdefault"} {
		raw := "https://i.ytimg.com/vi/" + id + "/" + name + ".jpg"
		r, e := c.Do(ctx, engine.Request{URL: raw})
		if e == nil {
			r.Body.Close()
			return raw
		}
	}
	return ""
}
