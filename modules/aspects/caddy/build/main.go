// Caddy with plugins. This is upstream's cmd/caddy/main.go with one import
// per plugin added, as xcaddy would generate it. go.mod pins the versions of
// Caddy and each plugin; Dependabot keeps them current.
package main

import (
	_ "time/tzdata"

	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	_ "github.com/caddyserver/caddy/v2/modules/standard"

	// Plugins: one import each, then `go mod tidy` and a new vendorHash.
	_ "github.com/caddy-dns/cloudflare"
)

func main() {
	caddycmd.Main()
}
