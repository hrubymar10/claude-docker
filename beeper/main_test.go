package main

import (
	"net"
	"testing"
)

// TestBindAddrIsLoopback verifies the beeper binds only to a loopback
// address. Binding to 0.0.0.0 would expose the service to anyone on the
// same LAN (e.g. coffee-shop Wi-Fi), letting them spam the developer's
// machine and fingerprint claude-docker installs.
func TestBindAddrIsLoopback(t *testing.T) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatalf("invalid bind addr %q: %v", addr, err)
	}
	if port != "9999" {
		t.Errorf("expected port 9999, got %q", port)
	}
	ip := net.ParseIP(host)
	if ip == nil {
		t.Fatalf("bind host %q is not a valid IP literal", host)
	}
	if !ip.IsLoopback() {
		t.Errorf("bind addr must be loopback to prevent cross-LAN exposure, got %s", host)
	}
}
