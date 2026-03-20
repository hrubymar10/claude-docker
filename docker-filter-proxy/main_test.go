package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// newTestHandler creates the filter handler backed by a dummy upstream that
// returns 200 OK for every request it receives. It returns the handler and a
// pointer to a bool that is set to true whenever the upstream is hit.
func newTestHandler() (http.Handler, *bool) {
	upstreamHit := new(bool)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*upstreamHit = true
		w.WriteHeader(http.StatusOK)
	}))
	// We intentionally never close this server — it lives for the duration
	// of the test process and Go's test runner handles cleanup.

	proxy := newProxy(upstream.URL)
	return proxy, upstreamHit
}

func postJSON(handler http.Handler, path string, body any) *httptest.ResponseRecorder {
	b, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	return rr
}

// ---------------------------------------------------------------------------
// Container create tests
// ---------------------------------------------------------------------------

func TestContainerCreate_Privileged_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	body := ContainerCreateRequest{HostConfig: HostConfig{Privileged: true}}
	rr := postJSON(h, "/containers/create", body)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

func TestContainerCreate_CapAdd_ALL_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	body := ContainerCreateRequest{HostConfig: HostConfig{CapAdd: []string{"ALL"}}}
	rr := postJSON(h, "/containers/create", body)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

func TestContainerCreate_CapAdd_SYS_ADMIN_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	body := ContainerCreateRequest{HostConfig: HostConfig{CapAdd: []string{"SYS_ADMIN"}}}
	rr := postJSON(h, "/containers/create", body)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

func TestContainerCreate_PidMode_Host_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	body := ContainerCreateRequest{HostConfig: HostConfig{PidMode: "host"}}
	rr := postJSON(h, "/containers/create", body)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

func TestContainerCreate_NetworkMode_Host_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	body := ContainerCreateRequest{HostConfig: HostConfig{NetworkMode: "host"}}
	rr := postJSON(h, "/containers/create", body)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

func TestContainerCreate_UTSMode_Host_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	body := ContainerCreateRequest{HostConfig: HostConfig{UTSMode: "host"}}
	rr := postJSON(h, "/containers/create", body)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

func TestContainerCreate_CgroupnsMode_Host_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	body := ContainerCreateRequest{HostConfig: HostConfig{CgroupnsMode: "host"}}
	rr := postJSON(h, "/containers/create", body)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

func TestContainerCreate_SecurityOpt_SyspathsUnmasked_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	body := ContainerCreateRequest{HostConfig: HostConfig{SecurityOpt: []string{"systempaths=unmasked"}}}
	rr := postJSON(h, "/containers/create", body)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

func TestContainerCreate_SecurityOpt_NoNewPrivilegesFalse_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	body := ContainerCreateRequest{HostConfig: HostConfig{SecurityOpt: []string{"no-new-privileges:false"}}}
	rr := postJSON(h, "/containers/create", body)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

func TestContainerCreate_Devices_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	body := map[string]any{
		"HostConfig": map[string]any{
			"Devices": []map[string]string{
				{"PathOnHost": "/dev/sda", "PathInContainer": "/dev/sda", "CgroupPermissions": "rwm"},
			},
		},
	}
	rr := postJSON(h, "/containers/create", body)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

func TestContainerCreate_Clean_PassesThrough(t *testing.T) {
	h, hit := newTestHandler()
	body := ContainerCreateRequest{HostConfig: HostConfig{}}
	rr := postJSON(h, "/containers/create", body)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d; body: %s", rr.Code, rr.Body.String())
	}
	if !*hit {
		t.Fatal("request should have reached upstream")
	}
}

func TestContainerCreate_MalformedJSON_Returns400(t *testing.T) {
	h, hit := newTestHandler()
	req := httptest.NewRequest("POST", "/containers/create", strings.NewReader("{bad json"))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("malformed request should not have reached upstream")
	}
}

// ---------------------------------------------------------------------------
// Container update test
// ---------------------------------------------------------------------------

func TestContainerUpdate_Privileged_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	body := ContainerCreateRequest{HostConfig: HostConfig{Privileged: true}}
	rr := postJSON(h, "/containers/abc123/update", body)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

// ---------------------------------------------------------------------------
// Exec create tests
// ---------------------------------------------------------------------------

func TestExecCreate_Privileged_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	body := ExecCreateRequest{Privileged: true}
	rr := postJSON(h, "/containers/abc123/exec", body)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

func TestExecCreate_NotPrivileged_PassesThrough(t *testing.T) {
	h, hit := newTestHandler()
	body := ExecCreateRequest{Privileged: false}
	rr := postJSON(h, "/containers/abc123/exec", body)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d; body: %s", rr.Code, rr.Body.String())
	}
	if !*hit {
		t.Fatal("request should have reached upstream")
	}
}

// ---------------------------------------------------------------------------
// Network connect/disconnect tests
// ---------------------------------------------------------------------------

func TestNetworkConnect_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	rr := postJSON(h, "/networks/bridge/connect", map[string]string{"Container": "abc"})
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

func TestNetworkDisconnect_Blocked(t *testing.T) {
	h, hit := newTestHandler()
	rr := postJSON(h, "/networks/bridge/disconnect", map[string]string{"Container": "abc"})
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("request should not have reached upstream")
	}
}

// ---------------------------------------------------------------------------
// Non-matching path passes through
// ---------------------------------------------------------------------------

func TestNonMatchingPath_PassesThrough(t *testing.T) {
	h, hit := newTestHandler()
	req := httptest.NewRequest("GET", "/containers/abc123/logs", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	if !*hit {
		t.Fatal("request should have reached upstream")
	}
}

// ---------------------------------------------------------------------------
// Body size limit
// ---------------------------------------------------------------------------

func TestBodySizeLimit_Rejected(t *testing.T) {
	h, hit := newTestHandler()
	// Create a body larger than 10MB
	bigBody := strings.Repeat("x", 10*1024*1024+1)
	req := httptest.NewRequest("POST", "/containers/create", strings.NewReader(bigBody))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	// The LimitReader will truncate, then json.Unmarshal will fail on the
	// truncated (and invalid) data, returning 400.
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for oversized body, got %d", rr.Code)
	}
	if *hit {
		t.Fatal("oversized request should not have reached upstream")
	}
}
