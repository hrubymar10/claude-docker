//go:build integration

package main

import (
	"context"
	"net"
	"net/http"
	"os/exec"
	"testing"
	"time"
)

// TestContainerReachesBeeperViaHostDockerInternal verifies that, with the
// loopback-only default bind + 127.0.0.0/8 allowlist, a sibling Docker
// container can still reach the beeper via host.docker.internal — Docker
// Desktop forwards that hostname to the host's loopback interface, so the
// allowlist accepts the connection.
//
// Requires Docker Desktop (or equivalent host.docker.internal support) on
// the host. Run with:
//
//	go test -tags=integration ./...
func TestContainerReachesBeeperViaHostDockerInternal(t *testing.T) {
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("docker not available on PATH")
	}

	t.Setenv("BEEPER_BIND", "127.0.0.1:9999")
	t.Setenv("BEEPER_ALLOW", "127.0.0.0/8")

	addr, err := resolveBindAddr()
	if err != nil {
		t.Fatalf("resolveBindAddr: %v", err)
	}
	allow, err := resolveAllow()
	if err != nil {
		t.Fatalf("resolveAllow: %v", err)
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatalf("listen on %s (is the host beeper already running?): %v", addr, err)
	}
	srv := &http.Server{Handler: allowMiddleware(newMux(), allow)}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	})

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx,
		"docker", "run", "--rm",
		"alpine:3.24",
		"wget", "-q", "--spider", "--timeout=5",
		"http://host.docker.internal:9999/beep",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("container could not reach beeper at host.docker.internal:9999/beep: %v\noutput: %s", err, out)
	}
}
