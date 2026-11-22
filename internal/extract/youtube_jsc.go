package extract

// Reconstructed from the Downbit 0.2.8 darwin/arm64 youtube_jsc.go functions
// (ytPlayerCode, ytSolve, ytWebPlayer) and the package initializer.
// The embedded JavaScript is byte-for-byte extracted from the executable.
import (
	"context"
	"github.com/listenjar/desktop/internal/engine"
	_ "embed"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"sync"
	"time"
)

// JSRunner is the host-provided JavaScript evaluator.
// RECOVERY: the original global identifier was not retained.
var JSRunner func(context.Context, string) (string, error)

//go:embed assets/youtube-library.js
var youtubeLibrary string

//go:embed assets/youtube-solver.js
var youtubeSolver string

// youtubePlayerCache maps a player script URL to its source.
var youtubePlayerCache sync.Map

// ytPlayerCode downloads a YouTube player script once per process.
//
// RECOVERY: keyed by URL.
// The player is large (more than a megabyte) and is the same for every video
// that uses that player version, so it is fetched once and kept for the life
// of the process.
func ytPlayerCode(ctx context.Context, c *engine.Client, url string) (string, error) {
	if v, ok := youtubePlayerCache.Load(url); ok {
		return v.(string), nil
	}
	code, err := c.Text(ctx, url)
	if err != nil {
		return "", err
	}
	youtubePlayerCache.Store(url, code)
	return code, nil
}

var ytTimestampRE = regexp.MustCompile(`(?:signatureTimestamp|sts)\s*:\s*([0-9]{5})`)

// ytSolve runs the embedded yt-dlp/ejs solver, returning solved n and sig challenges.
// RECOVERY: named results and the names out/dst reproduce the original stack layout; real names unknown.
func ytSolve(ctx context.Context, player string, nChallenges, sigChallenges []string) (ns, sigs map[string]string, err error) {
	var requests []any
	if len(nChallenges) > 0 {
		requests = append(requests, map[string]any{"type": "n", "challenges": nChallenges})
	}
	if len(sigChallenges) > 0 {
		requests = append(requests, map[string]any{"type": "sig", "challenges": sigChallenges})
	}
	if len(requests) == 0 {
		return nil, nil, nil
	}
	request, err := json.Marshal(map[string]any{"type": "player", "player": player, "requests": requests})
	if err != nil {
		return nil, nil, err
	}
	out, err := JSRunner(ctx, youtubeLibrary+"\nObject.assign(globalThis, lib);\n"+youtubeSolver+
		"\nreturn JSON.stringify(jsc("+string(request)+"));")
	if err != nil {
		return nil, nil, err
	}
	var response struct {
		Responses []struct {
			Error string
			Data  map[string]*string
		}
	}
	if err = json.Unmarshal([]byte(out), &response); err != nil {
		return nil, nil, err
	}
	ns, sigs = map[string]string{}, map[string]string{}
	for i, r := range response.Responses {
		if r.Error != "" {
			return nil, nil, errors.New("YouTube's player: " + strings.SplitN(r.Error, "\n", 2)[0])
		}
		dst := ns
		if requests[i].(map[string]any)["type"] == "sig" {
			dst = sigs
		}
		for k, v := range r.Data {
			if v != nil {
				dst[k] = *v
			}
		}
	}
	return ns, sigs, nil
}

var ytIframePlayerRE = regexp.MustCompile(`player\\?/([0-9a-fA-F]{8})\\?/`)

// ytWebPlayerCache remembers the current web player id for an hour.
// RECOVERY: names are not recoverable; layout follows the global's accesses.
var ytWebPlayerCache struct {
	sync.Mutex
	id string
	at time.Time
}

// ytWebPlayer returns the current web player script.
// RECOVERY: layout approximated; Unlock shares the stale line and `if stale` is one line to match the line table.
func ytWebPlayer(ctx context.Context, c *engine.Client) (string, error) {
	ytWebPlayerCache.Lock()
	id := ytWebPlayerCache.id
	stale := time.Since(ytWebPlayerCache.at) > time.Hour; ytWebPlayerCache.Unlock()

	// refresh the id from the iframe API when missing or older than an hour
	if stale { id = "" }
	if id == "" {
		page, err := c.Text(ctx, "https://www.youtube.com/iframe_api")
		if err != nil {
			return "", err
		}
		match := ytIframePlayerRE.FindStringSubmatch(page)
		if match == nil {
			return "", errors.New("YouTube's web player didn't load")
		}
		id = match[1]
		ytWebPlayerCache.Lock()
		ytWebPlayerCache.id, ytWebPlayerCache.at = id, time.Now()
		ytWebPlayerCache.Unlock()
	}
	return ytPlayerCode(ctx, c, "https://www.youtube.com/s/player/"+id+"/player_ias.vflset/en_US/base.js")
}

// Provenance notes carried over from the 0.2.1 (Linux) reconstruction:
// ytPlayerCode/ytSolve were reconstructed from Downbit 0.2.1 functions
// 0xb2cba0/0xb2cd40; the embedded JavaScript is byte-for-byte extracted, Go
// formatting/locals are new. JSRunner is the host-provided evaluator at 0.2.1
// global 0x1547830; the original global identifier was not retained, and main
// must wire this callback. The original caller checks JSRunner != nil before
// entering ytSolve. 0.2.1 also returned an "unexpected response count" error
// when the solver answered more responses than requests; 0.2.8 indexes the
// request list directly (a bounds panic), as reconstructed above.
