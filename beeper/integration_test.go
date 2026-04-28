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
// loopback-only bind, a sibling Docker container can still reach the beeper
// via host.docker.internal — the use case documented in
// config/claude-notifier.example. Docker Desktop forwards
// host.docker.internal to the host's loopback interface, which is why
// 127.0.0.1 binding remains reachable from containers.
//
// Requires Docker Desktop (or equivalent host.docker.internal support) on
// the host. Run with:
//
//	go test -tags=integration ./...
func TestContainerReachesBeeperViaHostDockerInternal(t *testing.T) {
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("docker not available on PATH")
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatalf("listen on %s (is the host beeper already running?): %v", addr, err)
	}
	srv := &http.Server{Handler: newMux()}
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
		"alpine:3.23",
		"wget", "-q", "--spider", "--timeout=5",
		"http://host.docker.internal:9999/beep",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("container could not reach beeper at host.docker.internal:9999/beep: %v\noutput: %s", err, out)
	}
}
