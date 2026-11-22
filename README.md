# ListenJar desktop

The [ListenJar](https://listenjar.com) desktop app, in Go with
[MyGo](https://github.com/egoist/mygo)'s native UI.

It talks to the ListenJar API described in [public.yaml](public.yaml) (OpenAPI 3.2), through
a Go client that [oasmith](https://github.com/responsibleapi/oasmith) generates into the
Git-ignored `internal/backend`.

## Run

Go 1.27.4 or newer; MyGo, oasmith and golangci-lint are tools of [go.mod](go.mod).

```sh
go generate .      # public.yaml → internal/backend
go tool mygo dev   # run with live reload
go tool mygo build # package into build/
```

## Configuration

There are two configurations, in [config.go](config.go), and nothing else to set:

- `go tool mygo dev` calls a local backend on `http://localhost:8787`.
- `go tool mygo build` calls `https://api.listenjar.com`.

The app sends nothing anywhere else: no telemetry, tracing or crash reports.
