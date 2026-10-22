# tinydav — runner-native WebDAV test fixture

A minimal WebDAV server (over HTTPS, with HTTP basic auth) that hosts the
fixture content in `MobileOrgTests/Resources/WebDavTests/content` for the
`WebDavTests` suite. It replaces the former Docker-based server
(`phylor/webdav-ssl`) so the tests run on machines without Docker — in
particular GitHub Actions macOS runners, which cannot host containers.

The only dependency, `golang.org/x/net/webdav`, is **vendored** — build with
no network access:

```sh
go build -mod=vendor -o tinydav .
```

You normally do not build or start it by hand: `Scripts/WebDAV-Server-Start.sh`
(builds if needed, adds the loopback hosts entry, starts the server) and
`Scripts/WebDAV-Server-Stop.sh` wrap it, and the `All Tests` scheme's
pre-/post-actions invoke those scripts.

Manual invocation:

```sh
./tinydav -root ../../MobileOrgTests/Resources/WebDavTests/content \
  -port 32773 -user schnuddelhuddel -password schnuddelhuddel \
  -tls-cert ../../MobileOrgTests/Resources/WebDavTests/certs/web.crt \
  -tls-key ../../MobileOrgTests/Resources/WebDavTests/certs/web.key
```

Details worth knowing:

- Listens on **127.0.0.1 only** — the fixture credentials are public test
  values committed to this repo, and the iOS simulator shares the host
  network stack, so there is no reason to bind beyond loopback.
- Serves the fixture's self-signed certificate (`web.crt`); the app's
  URLSession challenge handler accepts any server certificate, exactly as it
  did against the Docker server.
- Credentials are passed as flags rather than read from the fixture's
  `htpasswd` (an Apache `$apr1$` hash) to keep this tool dependency-free.

## Upgrading the vendored dependency

```sh
go get golang.org/x/net@latest && go mod tidy && go mod vendor && go vet ./...
```

Commit the updated `go.mod`, `go.sum`, and `vendor/` together. The `go`
directive in `go.mod` is the minimum toolchain required; CI installs a
matching Go from the runner's preinstalled tool cache via
`actions/setup-go` with `go-version-file`.
