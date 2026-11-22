// Package jsrun evaluates JavaScript in a hidden MyGo web view. It is the
// evaluator behind extract.JSRunner, which the YouTube extractor uses to solve
// the player's signature and n-parameter challenges.
//
// ListenJar port: runJS is copied from downbit's jsrun.go (Downbit 0.2.8
// reconstruction) and exported as Run. runPage, runCLI and withScripts are not
// ported: the desktop app already runs MyGo's application loop, so nothing
// needs to start it on demand, and no ported extractor loads pages.
// See ../extract/NOTICE.md for provenance.
package jsrun

import (
	"context"
	"errors"
	"sync"

	"github.com/egoist/mygo"
)

// jsMu serializes the temporary hidden web views.
var jsMu sync.Mutex

// Run evaluates script in a temporary hidden web view, one at a time. It
// needs MyGo's application loop running (mygo.App.Run); called before the app
// is ready, it waits for it. The script runs as the body of an async function
// and must return a string.
func Run(ctx context.Context, script string) (string, error) {
	jsMu.Lock()
	defer jsMu.Unlock()
	w := mygo.NewWindow(mygo.WindowOptions{URL: "about:blank", Width: 1, Height: 1, Hidden: true, SkipTaskbar: true, Page: mygo.PageOptions{Untrusted: true}})
	// WindowOptions recovered directly from the static record.
	defer w.Close()
	value, err := w.Page().EvalContext(ctx, script)
	if err != nil {
		return "", err
	}
	text, ok := value.(string)
	if !ok {
		return "", errors.New("the script returned no text")
	}
	return text, nil
}
