// Command desktop is the ListenJar desktop app: a MyGo window that lists the
// listener's feeds from the ListenJar API (public.yaml) through the oasmith Go
// client in internal/backend.
package main

// internal/backend is Git-ignored; run `go generate` after changing public.yaml.
//go:generate rm -rf internal/backend
//go:generate go tool oasmith --openapi public.yaml --mode client --lang go --out internal/backend

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	backend "github.com/listenjar/desktop/internal/backend"
)

// app is the state the window shows. The view reads it on the main thread;
// loads run on a goroutine and publish their result through Window.Update.
type app struct {
	win     *mygo.Window
	api     *backend.Client
	feeds   []backend.Feed
	err     error
	loading bool
}

func (a *app) view(c *ui.Context) {
	t := c.Theme()
	ui.Column(c).Fill().Gap(12).Padding(24).Children(func() {
		ui.Row(c).Gap(12).AlignItems(ui.Center).Children(func() {
			ui.Text(c, "ListenJar").FontSize(26).Bold().Grow(1)
			if ui.Button(c, "Refresh").Clicked() {
				a.load()
			}
		})
		switch {
		case a.err != nil:
			ui.Text(c, "Could not load feeds: "+a.err.Error()).TextColor(t.TextMuted)
		case a.loading && len(a.feeds) == 0:
			ui.Text(c, "Loading feeds…").TextColor(t.TextMuted)
		case len(a.feeds) == 0:
			ui.Text(c, "No feeds yet.").TextColor(t.TextMuted)
		}
		for _, feed := range a.feeds {
			c.Key(feed.Id)
			ui.Text(c, feed.Title)
		}
	})
}

// load fetches the feeds off the main thread. It runs at most once at a time.
func (a *app) load() {
	if a.loading || a.win == nil {
		return
	}
	a.loading = true
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		feeds, err := listFeeds(ctx, a.api)
		a.win.Update(func() {
			a.loading = false
			a.err = err
			if err == nil {
				a.feeds = feeds
			}
		})
	}()
}

func listFeeds(ctx context.Context, api *backend.Client) ([]backend.Feed, error) {
	res, err := api.ListFeeds(ctx)
	if err != nil {
		return nil, err
	}
	if res.Status200 == nil {
		return nil, fmt.Errorf("unexpected status %d", res.StatusCode)
	}
	return *res.Status200, nil
}

func main() {
	api, err := backend.NewClient(backend.ClientOptions{
		BaseURL: currentConfig().apiURL,
	})
	if err != nil {
		log.Fatal(err)
	}
	a := &app{api: api}
	mygo.App.WhenReady(func() {
		a.win = mygo.NewWindow(mygo.WindowOptions{
			Title:     "ListenJar",
			Width:     480,
			Height:    360,
			MinWidth:  320,
			MinHeight: 280,
			// Opens where the user left it last time.
			StateKey: "main",
			// The window shows the interface MyGo draws, not a web page.
			Content: ui.View(a.view),
		})
		a.load()
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}
