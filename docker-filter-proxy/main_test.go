package main

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

type capturedRequest struct {
	method  string
	path    string
	body    []byte
	headers http.Header
}

func newCapturedUpstream(captured *capturedRequest) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		captured.method = r.Method
		captured.path = r.URL.Path
		captured.body = body
		captured.headers = r.Header.Clone()
		w.WriteHeader(http.StatusOK)
	}))
}

func newTestHandler(t *testing.T, upstream string) http.Handler {
	t.Helper()
	target, err := url.Parse(upstream)
	if err != nil {
		t.Fatalf("parse upstream: %v", err)
	}
	return newProxyHandler(target)
}

// Vuln 4 regression: malformed JSON must fail closed (no upstream forward).
func TestContainerCreate_MalformedJSON_FailsClosed(t *testing.T) {
	var captured capturedRequest
	upstream := newCapturedUpstream(&captured)
	defer upstream.Close()
	handler := newTestHandler(t, upstream.URL)

	req := httptest.NewRequest("POST", "/v1.41/containers/create", strings.NewReader(`{not valid`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code < 400 || rec.Code >= 500 {
		t.Errorf("expected 4xx, got %d body=%q", rec.Code, rec.Body.String())
	}
	if captured.method != "" {
		t.Errorf("upstream should not be called for malformed body, got %s %s", captured.method, captured.path)
	}
}

// Vuln 4 regression: Content-Encoding != identity must be rejected (would otherwise bypass HostConfig check).
func TestContainerCreate_GzipEncoding_Rejected(t *testing.T) {
	var captured capturedRequest
	upstream := newCapturedUpstream(&captured)
	defer upstream.Close()
	handler := newTestHandler(t, upstream.URL)

	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	if _, err := gz.Write([]byte(`{"HostConfig":{"Privileged":true}}`)); err != nil {
		t.Fatalf("gzip write: %v", err)
	}
	gz.Close()

	req := httptest.NewRequest("POST", "/v1.41/containers/create", &buf)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Content-Encoding", "gzip")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code < 400 || rec.Code >= 500 {
		t.Errorf("expected 4xx, got %d body=%q", rec.Code, rec.Body.String())
	}
	if captured.method != "" {
		t.Errorf("upstream should not be called for gzip body, got %s %s", captured.method, captured.path)
	}
}

// Vuln 4 regression: non-JSON Content-Type must be rejected.
func TestContainerCreate_NonJSONContentType_Rejected(t *testing.T) {
	var captured capturedRequest
	upstream := newCapturedUpstream(&captured)
	defer upstream.Close()
	handler := newTestHandler(t, upstream.URL)

	// Safe body — only the Content-Type gate should block this. If the gate
	// is missing, the body parses fine and the request is forwarded.
	req := httptest.NewRequest("POST", "/v1.41/containers/create",
		strings.NewReader(`{"HostConfig":{}}`))
	req.Header.Set("Content-Type", "application/octet-stream")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code < 400 || rec.Code >= 500 {
		t.Errorf("expected 4xx, got %d body=%q", rec.Code, rec.Body.String())
	}
	if captured.method != "" {
		t.Errorf("upstream should not be called for non-json body, got %s %s", captured.method, captured.path)
	}
}

// Vuln 4 regression: oversized body must be rejected.
func TestContainerCreate_OversizeBody_Rejected(t *testing.T) {
	var captured capturedRequest
	upstream := newCapturedUpstream(&captured)
	defer upstream.Close()
	handler := newTestHandler(t, upstream.URL)

	// Build body larger than 1 MiB cap.
	huge := bytes.Repeat([]byte("a"), 2*1024*1024)
	body := []byte(`{"HostConfig":{"Image":"` + string(huge) + `"}}`)
	req := httptest.NewRequest("POST", "/v1.41/containers/create", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code < 400 || rec.Code >= 500 {
		t.Errorf("expected 4xx, got %d body=%q", rec.Code, rec.Body.String())
	}
	if captured.method != "" {
		t.Errorf("upstream should not be called for oversize body, got %s %s", captured.method, captured.path)
	}
}

// Charset parameter on application/json must remain accepted.
func TestContainerCreate_JSONWithCharset_Accepted(t *testing.T) {
	var captured capturedRequest
	upstream := newCapturedUpstream(&captured)
	defer upstream.Close()
	handler := newTestHandler(t, upstream.URL)

	req := httptest.NewRequest("POST", "/v1.41/containers/create",
		strings.NewReader(`{"HostConfig":{}}`))
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d body=%q", rec.Code, rec.Body.String())
	}
	if captured.path != "/v1.41/containers/create" {
		t.Errorf("expected upstream forward, got path=%q", captured.path)
	}
}

// Existing behavior regression: privileged must be blocked with 403.
func TestContainerCreate_Privileged_Blocked(t *testing.T) {
	var captured capturedRequest
	upstream := newCapturedUpstream(&captured)
	defer upstream.Close()
	handler := newTestHandler(t, upstream.URL)

	req := httptest.NewRequest("POST", "/v1.41/containers/create",
		strings.NewReader(`{"HostConfig":{"Privileged":true}}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Errorf("expected 403, got %d body=%q", rec.Code, rec.Body.String())
	}
	if captured.method != "" {
		t.Errorf("upstream should not be called for privileged container")
	}
}

// Existing behavior regression: safe body forwarded upstream.
func TestContainerCreate_Safe_Forwarded(t *testing.T) {
	var captured capturedRequest
	upstream := newCapturedUpstream(&captured)
	defer upstream.Close()
	handler := newTestHandler(t, upstream.URL)

	req := httptest.NewRequest("POST", "/v1.41/containers/create",
		strings.NewReader(`{"HostConfig":{}}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d body=%q", rec.Code, rec.Body.String())
	}
	if captured.path != "/v1.41/containers/create" {
		t.Errorf("expected upstream forward, got path=%q", captured.path)
	}
}

// Other endpoints (not containers/create) must not be subject to the
// JSON content-type / encoding gate.
func TestNonCreateEndpoint_PassesThroughUnchanged(t *testing.T) {
	var captured capturedRequest
	upstream := newCapturedUpstream(&captured)
	defer upstream.Close()
	handler := newTestHandler(t, upstream.URL)

	req := httptest.NewRequest("GET", "/v1.41/containers/json", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d body=%q", rec.Code, rec.Body.String())
	}
	if captured.path != "/v1.41/containers/json" {
		t.Errorf("expected upstream forward, got path=%q", captured.path)
	}
}
