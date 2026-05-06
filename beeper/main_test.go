package main

import (
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
)

func TestResolveBindAddrDefault(t *testing.T) {
	t.Setenv("BEEPER_BIND", "")
	got, err := resolveBindAddr()
	if err != nil {
		t.Fatalf("default resolution should not error: %v", err)
	}
	if got != defaultBindAddr {
		t.Errorf("expected %q, got %q", defaultBindAddr, got)
	}
}

func TestResolveBindAddrOverrideHonoured(t *testing.T) {
	for _, val := range []string{"0.0.0.0:9999", "172.28.47.1:9999", "[::1]:9999", "[::]:9999"} {
		t.Run(val, func(t *testing.T) {
			t.Setenv("BEEPER_BIND", val)
			got, err := resolveBindAddr()
			if err != nil {
				t.Fatalf("%q should be accepted: %v", val, err)
			}
			if got != val {
				t.Errorf("expected verbatim %q, got %q", val, got)
			}
		})
	}
}

func TestResolveBindAddrRejectsInvalid(t *testing.T) {
	cases := []struct{ name, val string }{
		{"empty host", ":9999"},
		{"hostname", "localhost:9999"},
		{"bad port", "127.0.0.1:abc"},
		{"no port", "garbage"},
		{"port out of range", "127.0.0.1:99999"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("BEEPER_BIND", tc.val)
			if _, err := resolveBindAddr(); err == nil {
				t.Errorf("expected error for %q, got nil", tc.val)
			}
		})
	}
}

func TestResolveAllowDefault(t *testing.T) {
	t.Setenv("BEEPER_ALLOW", "")
	prefixes, err := resolveAllow()
	if err != nil {
		t.Fatalf("default resolution should not error: %v", err)
	}
	want := []string{"127.0.0.0/8", "::1/128"}
	if len(prefixes) != len(want) {
		t.Fatalf("expected %d prefixes, got %d (%v)", len(want), len(prefixes), prefixes)
	}
	for i, w := range want {
		if prefixes[i].String() != w {
			t.Errorf("prefix[%d]: expected %q, got %q", i, w, prefixes[i].String())
		}
	}
}

func TestResolveAllowMixedIPAndCIDR(t *testing.T) {
	t.Setenv("BEEPER_ALLOW", "127.0.0.1, 172.28.47.0/24,172.28.47.62")
	prefixes, err := resolveAllow()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"127.0.0.1/32", "172.28.47.0/24", "172.28.47.62/32"}
	if len(prefixes) != len(want) {
		t.Fatalf("expected %d prefixes, got %d (%v)", len(want), len(prefixes), prefixes)
	}
	for i, w := range want {
		if prefixes[i].String() != w {
			t.Errorf("prefix[%d]: expected %q, got %q", i, w, prefixes[i].String())
		}
	}
}

func TestResolveAllowDedupes(t *testing.T) {
	t.Setenv("BEEPER_ALLOW", "127.0.0.1, 127.0.0.1/32, 172.28.47.0/24, 172.28.47.0/24")
	prefixes, err := resolveAllow()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(prefixes) != 2 {
		t.Errorf("expected dedupe to 2 entries, got %d (%v)", len(prefixes), prefixes)
	}
}

func TestResolveAllowAcceptsIPv6(t *testing.T) {
	t.Setenv("BEEPER_ALLOW", "::1, fe80::/10")
	prefixes, err := resolveAllow()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"::1/128", "fe80::/10"}
	if len(prefixes) != len(want) {
		t.Fatalf("expected %d prefixes, got %d (%v)", len(want), len(prefixes), prefixes)
	}
	for i, w := range want {
		if prefixes[i].String() != w {
			t.Errorf("prefix[%d]: expected %q, got %q", i, w, prefixes[i].String())
		}
	}
}

func TestResolveAllowRejectsInvalid(t *testing.T) {
	cases := []struct{ name, val string }{
		{"trailing comma", "127.0.0.1,"},
		{"leading comma", ",127.0.0.1"},
		{"empty middle", "127.0.0.1,,127.0.0.2"},
		{"hostname", "localhost"},
		{"malformed CIDR", "172.28.47.0/33"},
		{"garbage", "not-an-ip"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("BEEPER_ALLOW", tc.val)
			if _, err := resolveAllow(); err == nil {
				t.Errorf("expected error for %q, got nil", tc.val)
			}
		})
	}
}

func TestAllowMiddleware(t *testing.T) {
	allow := []netip.Prefix{
		netip.MustParsePrefix("127.0.0.0/8"),
		netip.MustParsePrefix("172.28.47.0/24"),
		netip.MustParsePrefix("::1/128"),
	}
	handler := allowMiddleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}), allow)

	cases := []struct {
		name       string
		remoteAddr string
		wantStatus int
	}{
		{"loopback v4", "127.0.0.1:54321", http.StatusOK},
		{"loopback v4 in /8 range", "127.5.6.7:54321", http.StatusOK},
		{"vpn v4 in /24", "172.28.47.62:54321", http.StatusOK},
		{"vpn v4 boundary low", "172.28.47.0:54321", http.StatusOK},
		{"vpn v4 boundary high", "172.28.47.255:54321", http.StatusOK},
		{"non-allowlisted v4", "10.0.0.1:54321", http.StatusForbidden},
		{"adjacent /24", "172.28.48.1:54321", http.StatusForbidden},
		{"v4-mapped v6 loopback", "[::ffff:127.0.0.1]:54321", http.StatusOK},
		{"v4-mapped v6 non-allowed", "[::ffff:10.0.0.1]:54321", http.StatusForbidden},
		{"v6 loopback", "[::1]:54321", http.StatusOK},
		{"unparseable", "notanip", http.StatusForbidden},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/beep", nil)
			req.RemoteAddr = tc.remoteAddr
			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, req)
			if rr.Code != tc.wantStatus {
				t.Errorf("RemoteAddr %q: status got %d, want %d", tc.remoteAddr, rr.Code, tc.wantStatus)
			}
		})
	}
}
