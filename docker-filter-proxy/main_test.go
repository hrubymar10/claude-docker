package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// ──────────────────────────────────────────────────────────────────
// Path classification
// ──────────────────────────────────────────────────────────────────

func TestIsExecCreate(t *testing.T) {
	cases := map[string]bool{
		"/containers/claude-docker/exec":        true,
		"/v1.46/containers/claude-docker/exec":  true,
		"/v1.46/containers/abc123/exec":         true,
		"/containers/claude-docker/exec?x=1":    true,
		"/containers/create":                    false,
		"/exec/abc/start":                       false,
		"/containers/claude-docker/json":        false,
		"/containers/claude-docker/exec/extra":  false,
	}
	for path, want := range cases {
		got := isExecCreate(path)
		if got != want {
			t.Errorf("isExecCreate(%q) = %v, want %v", path, got, want)
		}
	}
}

func TestIsExecStart(t *testing.T) {
	cases := map[string]bool{
		"/exec/abc/start":          true,
		"/v1.46/exec/deadbeef/start": true,
		"/exec/abc/start?x=1":      true,
		"/exec/abc/resize":         false,
		"/exec/abc/json":           false,
		"/containers/foo/exec":     false,
	}
	for path, want := range cases {
		got := isExecStart(path)
		if got != want {
			t.Errorf("isExecStart(%q) = %v, want %v", path, got, want)
		}
	}
}

func TestExtractContainerIDFromExecPath(t *testing.T) {
	cases := map[string]string{
		"/containers/claude-docker/exec":       "claude-docker",
		"/v1.46/containers/claude-docker/exec": "claude-docker",
		"/v1.46/containers/abc123/exec?x=1":    "abc123",
		"/containers/create":                   "",
		"/containers//exec":                    "",
	}
	for path, want := range cases {
		got := extractContainerIDFromExecPath(path)
		if got != want {
			t.Errorf("extractContainerIDFromExecPath(%q) = %q, want %q", path, got, want)
		}
	}
}

// ──────────────────────────────────────────────────────────────────
// Body checks
// ──────────────────────────────────────────────────────────────────

func TestCheckExecConfig(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string // substring expected in returned reason; "" = allowed
	}{
		{"empty body allowed", `{}`, ""},
		{"non-root user allowed", `{"User":"1000"}`, ""},
		{"named non-root user allowed", `{"User":"alice"}`, ""},
		{"privileged blocked", `{"Privileged":true}`, "privileged"},
		{"user 0 blocked", `{"User":"0"}`, "root"},
		{"user root blocked", `{"User":"root"}`, "root"},
		{"user 0:0 blocked", `{"User":"0:0"}`, "root"},
		{"user root:group blocked", `{"User":"root:wheel"}`, "root"},
		{"user with leading space root blocked", `{"User":" root "}`, "root"},
		{"user uppercase ROOT blocked", `{"User":"ROOT"}`, "root"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := checkExecConfig([]byte(tc.body))
			if tc.want == "" && got != "" {
				t.Fatalf("expected allowed, got %q", got)
			}
			if tc.want != "" && !strings.Contains(strings.ToLower(got), tc.want) {
				t.Fatalf("expected reason containing %q, got %q", tc.want, got)
			}
		})
	}
}

// ──────────────────────────────────────────────────────────────────
// Container allowlist
// ──────────────────────────────────────────────────────────────────

func TestMatchesAllowedContainer(t *testing.T) {
	const fullID = "abcd1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab"
	const name = "claude-docker"

	cases := []struct {
		id   string
		want bool
	}{
		{name, true},
		{fullID, true},
		{fullID[:12], true},
		{fullID[:5], true},
		{strings.ToUpper(fullID[:12]), true},
		{"postgres", false},
		{"", false},
		{"claude-docker-evil", false},
		{"abce1234", false},                // hex but doesn't match prefix
		{"claude", false},                  // partial name, not allowed
		{fullID + "00", false},             // longer than full id
	}
	for _, tc := range cases {
		got := matchesAllowedContainer(tc.id, name, fullID)
		if got != tc.want {
			t.Errorf("matchesAllowedContainer(%q, %q, fullID) = %v, want %v", tc.id, name, got, tc.want)
		}
	}
}

func TestMatchesAllowedContainerNoIDResolved(t *testing.T) {
	// Before container ID is resolved, only the configured name should match.
	if !matchesAllowedContainer("claude-docker", "claude-docker", "") {
		t.Error("name should match even when full ID unknown")
	}
	if matchesAllowedContainer("abcd1234", "claude-docker", "") {
		t.Error("hex prefix must NOT match when full ID unknown")
	}
}

// ──────────────────────────────────────────────────────────────────
// HTTP handler integration
// ──────────────────────────────────────────────────────────────────

// newProxy builds a handler wired to a fake upstream so we can verify which
// requests get forwarded vs blocked.
func newProxy(t *testing.T, allowedName, allowedID string) (http.Handler, *recordingUpstream) {
	t.Helper()
	rec := &recordingUpstream{}
	upstream := httptest.NewServer(rec)
	t.Cleanup(upstream.Close)

	target, err := url.Parse(upstream.URL)
	if err != nil {
		t.Fatalf("parse upstream: %v", err)
	}
	cfg := &proxyConfig{
		target:        target,
		containerName: allowedName,
		containerID:   allowedID,
	}
	return newProxyHandler(cfg), rec
}

type recordingUpstream struct {
	hits []*http.Request // only forwarded mutations; resolve lookups are ignored
}

func (r *recordingUpstream) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	body, _ := io.ReadAll(req.Body)
	// Container-name → ID resolution is a GET .../json. We don't count it as a
	// forwarded hit because tests want to assert whether the *exec* request
	// got through.
	if req.Method == http.MethodGet && strings.HasSuffix(req.URL.Path, "/json") {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"Id":"deadbeef"}`))
		return
	}
	clone := req.Clone(req.Context())
	clone.Body = io.NopCloser(bytes.NewReader(body))
	r.hits = append(r.hits, clone)
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"Id":"deadbeef"}`))
}

func doExec(t *testing.T, h http.Handler, id string, body any) *httptest.ResponseRecorder {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/containers/"+id+"/exec", bytes.NewReader(raw))
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	return rr
}

func TestExec_BlocksOtherContainerByName(t *testing.T) {
	h, rec := newProxy(t, "claude-docker", "")
	rr := doExec(t, h, "postgres", map[string]any{"Cmd": []string{"sh"}})
	if rr.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403; body: %s", rr.Code, rr.Body)
	}
	if len(rec.hits) != 0 {
		t.Fatalf("upstream should not have been called, got %d hits", len(rec.hits))
	}
}

func TestExec_BlocksRootUser(t *testing.T) {
	h, rec := newProxy(t, "claude-docker", "")
	rr := doExec(t, h, "claude-docker", map[string]any{"User": "root", "Cmd": []string{"sh"}})
	if rr.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403; body: %s", rr.Code, rr.Body)
	}
	if len(rec.hits) != 0 {
		t.Fatalf("upstream should not have been called")
	}
}

func TestExec_BlocksUserZero(t *testing.T) {
	h, rec := newProxy(t, "claude-docker", "")
	rr := doExec(t, h, "claude-docker", map[string]any{"User": "0", "Cmd": []string{"sh"}})
	if rr.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rr.Code)
	}
	if len(rec.hits) != 0 {
		t.Fatalf("upstream should not have been called")
	}
}

func TestExec_BlocksPrivileged(t *testing.T) {
	h, rec := newProxy(t, "claude-docker", "")
	rr := doExec(t, h, "claude-docker", map[string]any{"Privileged": true, "Cmd": []string{"sh"}})
	if rr.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rr.Code)
	}
	if len(rec.hits) != 0 {
		t.Fatalf("upstream should not have been called")
	}
}

func TestExec_AllowsSafeRequestForOwnContainerByName(t *testing.T) {
	h, rec := newProxy(t, "claude-docker", "")
	rr := doExec(t, h, "claude-docker", map[string]any{"Cmd": []string{"ls"}})
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", rr.Code, rr.Body)
	}
	if len(rec.hits) != 1 {
		t.Fatalf("upstream hits = %d, want 1", len(rec.hits))
	}
}

func TestExec_AllowsSafeRequestByFullID(t *testing.T) {
	const fullID = "abcd1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab"
	h, rec := newProxy(t, "claude-docker", fullID)
	rr := doExec(t, h, fullID[:12], map[string]any{"Cmd": []string{"ls"}})
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", rr.Code, rr.Body)
	}
	if len(rec.hits) != 1 {
		t.Fatalf("upstream hits = %d, want 1", len(rec.hits))
	}
}

func TestExec_BlocksUnknownIDPrefixWhenIDResolved(t *testing.T) {
	const fullID = "abcd1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab"
	h, rec := newProxy(t, "claude-docker", fullID)
	rr := doExec(t, h, "ffff0000", map[string]any{"Cmd": []string{"ls"}})
	if rr.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rr.Code)
	}
	if len(rec.hits) != 0 {
		t.Fatalf("upstream should not have been called")
	}
}

// /exec/{id}/start carries no privilege bits, but only exec instances created
// through our filtered /containers/{id}/exec can produce a usable id, so we
// forward starts unchanged.
func TestExec_StartIsForwarded(t *testing.T) {
	h, rec := newProxy(t, "claude-docker", "")
	req := httptest.NewRequest(http.MethodPost, "/exec/anything/start", strings.NewReader(`{}`))
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", rr.Code, rr.Body)
	}
	if len(rec.hits) != 1 {
		t.Fatalf("upstream hits = %d, want 1", len(rec.hits))
	}
}

func TestExec_StartBlocksPrivilegedOverride(t *testing.T) {
	// Some Docker API versions accept Privileged in /exec/{id}/start; reject it
	// defensively even though create-time filtering should already cover this.
	h, rec := newProxy(t, "claude-docker", "")
	req := httptest.NewRequest(http.MethodPost, "/exec/anything/start", strings.NewReader(`{"Privileged":true}`))
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403; body: %s", rr.Code, rr.Body)
	}
	if len(rec.hits) != 0 {
		t.Fatalf("upstream should not have been called")
	}
}

// Existing protections must still work after refactoring.
func TestContainerCreate_BlocksPrivileged(t *testing.T) {
	h, rec := newProxy(t, "claude-docker", "")
	body, _ := json.Marshal(map[string]any{"HostConfig": map[string]any{"Privileged": true}})
	req := httptest.NewRequest(http.MethodPost, "/containers/create", bytes.NewReader(body))
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rr.Code)
	}
	if len(rec.hits) != 0 {
		t.Fatalf("upstream should not have been called")
	}
}

func TestNetworkConnect_StillBlocked(t *testing.T) {
	h, rec := newProxy(t, "claude-docker", "")
	req := httptest.NewRequest(http.MethodPost, "/networks/foo/connect", strings.NewReader(`{}`))
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rr.Code)
	}
	if len(rec.hits) != 0 {
		t.Fatalf("upstream should not have been called")
	}
}
