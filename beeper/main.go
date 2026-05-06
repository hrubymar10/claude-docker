package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"strings"
)

const (
	defaultBindAddr  = "127.0.0.1:9999"
	defaultAllowList = "127.0.0.0/8,::1/128"
)

func beep(w http.ResponseWriter, _ *http.Request) {
	_ = exec.Command("afplay", "/System/Library/Sounds/Ping.aiff").Start()
	w.WriteHeader(http.StatusOK)
}

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /beep", beep)
	mux.HandleFunc("GET /play/{category}", beep)
	return mux
}

// resolveBindAddr reads BEEPER_BIND and validates it as a host:port pair
// where host is an IP literal. Empty / unset → defaultBindAddr.
func resolveBindAddr() (string, error) {
	raw := os.Getenv("BEEPER_BIND")
	if raw == "" {
		raw = defaultBindAddr
	}
	host, port, err := net.SplitHostPort(raw)
	if err != nil {
		return "", fmt.Errorf("BEEPER_BIND=%q: %w", raw, err)
	}
	if host == "" {
		return "", fmt.Errorf("BEEPER_BIND=%q: empty host; use 0.0.0.0:%s to bind all interfaces", raw, port)
	}
	if _, err := netip.ParseAddr(host); err != nil {
		return "", fmt.Errorf("BEEPER_BIND=%q: host must be an IP literal (got %q): %w", raw, host, err)
	}
	if _, err := net.LookupPort("tcp", port); err != nil {
		return "", fmt.Errorf("BEEPER_BIND=%q: invalid port %q: %w", raw, port, err)
	}
	return raw, nil
}

// resolveAllow parses BEEPER_ALLOW into a list of CIDR prefixes. Bare IPs
// are normalised to /32 (v4) or /128 (v6). Whitespace is trimmed; exact
// duplicates are dropped; stray empty entries (",,", trailing comma) are
// rejected as malformed.
func resolveAllow() ([]netip.Prefix, error) {
	raw := os.Getenv("BEEPER_ALLOW")
	if raw == "" {
		raw = defaultAllowList
	}
	parts := strings.Split(raw, ",")
	prefixes := make([]netip.Prefix, 0, len(parts))
	seen := map[netip.Prefix]struct{}{}
	for _, p := range parts {
		entry := strings.TrimSpace(p)
		if entry == "" {
			return nil, fmt.Errorf("BEEPER_ALLOW=%q: empty entry — drop the stray comma", raw)
		}
		var pref netip.Prefix
		if strings.Contains(entry, "/") {
			parsed, err := netip.ParsePrefix(entry)
			if err != nil {
				return nil, fmt.Errorf("BEEPER_ALLOW: %q: %w", entry, err)
			}
			pref = parsed.Masked()
		} else {
			addr, err := netip.ParseAddr(entry)
			if err != nil {
				return nil, fmt.Errorf("BEEPER_ALLOW: %q is not an IP or CIDR: %w", entry, err)
			}
			addr = addr.Unmap()
			bits := 32
			if addr.Is6() {
				bits = 128
			}
			pref = netip.PrefixFrom(addr, bits)
		}
		if _, dup := seen[pref]; dup {
			continue
		}
		seen[pref] = struct{}{}
		prefixes = append(prefixes, pref)
	}
	return prefixes, nil
}

// allowMiddleware drops any request whose RemoteAddr IP is not contained in
// one of the allow prefixes. Direct-connection service: X-Forwarded-For
// is intentionally not trusted.
func allowMiddleware(next http.Handler, allow []netip.Prefix) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ap, err := netip.ParseAddrPort(r.RemoteAddr)
		if err != nil {
			log.Printf("WARN: blocked request with unparseable RemoteAddr %q: %v", r.RemoteAddr, err)
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		ip := ap.Addr().Unmap()
		for _, p := range allow {
			if p.Contains(ip) {
				next.ServeHTTP(w, r)
				return
			}
		}
		log.Printf("WARN: blocked %s — not in BEEPER_ALLOW", ip)
		http.Error(w, "forbidden", http.StatusForbidden)
	})
}

func main() {
	addr, err := resolveBindAddr()
	if err != nil {
		log.Fatal(err)
	}
	allow, err := resolveAllow()
	if err != nil {
		log.Fatal(err)
	}
	host, _, _ := net.SplitHostPort(addr)
	log.Printf("Beeper listening on http://%s (allow: %v)", addr, allow)
	if ip, err := netip.ParseAddr(host); err == nil && !ip.IsLoopback() {
		log.Printf("WARN: bound to %s — anyone reachable on this interface can attempt to call /beep (BEEPER_ALLOW gates by source IP)", host)
	}
	if err := http.ListenAndServe(addr, allowMiddleware(newMux(), allow)); err != nil {
		log.Fatal(err)
	}
}
