package main

import "github.com/egoist/mygo"

// config is everything the app needs to know about its environment: only
// where the ListenJar API (public.yaml) is. The app sends nothing anywhere
// else: no telemetry, tracing or crash reports.
type config struct {
	apiURL string
}

var (
	// prodConfig is for builds of `mygo build`.
	prodConfig = config{apiURL: "https://api.listenjar.com"}
	// devConfig is for `mygo dev`: the backend's local dev server.
	devConfig = config{apiURL: "http://localhost:8787"}
)

func currentConfig() config {
	if mygo.IsDev() {
		return devConfig
	}
	return prodConfig
}
