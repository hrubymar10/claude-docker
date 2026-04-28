package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

type Mount struct {
	Type   string `json:"Type"`
	Source string `json:"Source"`
	Target string `json:"Target"`
}

type HostConfig struct {
	Privileged  bool     `json:"Privileged"`
	PidMode     string   `json:"PidMode"`
	NetworkMode string   `json:"NetworkMode"`
	UsernsMode  string   `json:"UsernsMode"`
	IpcMode     string   `json:"IpcMode"`
	CapAdd      []string `json:"CapAdd"`
	SecurityOpt []string `json:"SecurityOpt"`
	Devices     []any    `json:"Devices"`
	Binds       []string `json:"Binds,omitempty"`
	Mounts      []Mount  `json:"Mounts,omitempty"`
}

type ContainerCreateRequest struct {
	HostConfig HostConfig `json:"HostConfig"`
}

var dangerousCaps = map[string]bool{
	"SYS_ADMIN": true, "SYS_PTRACE": true, "SYS_RAWIO": true,
	"DAC_READ_SEARCH": true, "NET_ADMIN": true, "SYS_MODULE": true,
}

func checkHostConfig(hc HostConfig) string {
	if hc.Privileged {
		return "privileged containers are not allowed"
	}
	if hc.PidMode == "host" {
		return "host PID mode is not allowed"
	}
	if hc.NetworkMode == "host" {
		return "host network mode is not allowed"
	}
	for _, cap := range hc.CapAdd {
		if dangerousCaps[strings.ToUpper(cap)] {
			return fmt.Sprintf("capability %s is not allowed", cap)
		}
	}
	if hc.UsernsMode == "host" {
		return "host user namespace mode is not allowed"
	}
	if hc.IpcMode == "host" {
		return "host IPC mode is not allowed"
	}
	for _, opt := range hc.SecurityOpt {
		if strings.Contains(opt, "unconfined") || strings.Contains(opt, "apparmor=") {
			return fmt.Sprintf("security option %q is not allowed", opt)
		}
	}
	if len(hc.Devices) > 0 {
		return "device mappings are not allowed"
	}
	return ""
}

// isDockerSocket returns true if the path looks like a Docker daemon socket.
func isDockerSocket(path string) bool {
	return path == "/var/run/docker.sock" ||
		path == "/run/docker.sock" ||
		strings.HasSuffix(path, "/docker.sock")
}

// stripDockerSocketMounts removes Docker socket bind mounts from the request
// body and returns the (possibly modified) body. In a TCP-only Docker setup
// (DOCKER_HOST=tcp://...), containers should use TCP, not the socket. Mounts
// that reference the socket would be rejected by the socket-proxy allowlist
// anyway, so stripping them here gives a cleaner experience.
func stripDockerSocketMounts(body []byte) ([]byte, bool) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		return body, false
	}

	hcRaw, ok := raw["HostConfig"]
	if !ok {
		return body, false
	}

	var hc map[string]json.RawMessage
	if err := json.Unmarshal(hcRaw, &hc); err != nil {
		return body, false
	}

	modified := false

	// Strip from Binds (string format: "/host/path:/container/path[:opts]")
	if bindsRaw, ok := hc["Binds"]; ok {
		var binds []string
		if err := json.Unmarshal(bindsRaw, &binds); err == nil {
			var filtered []string
			for _, b := range binds {
				src := strings.SplitN(b, ":", 2)[0]
				if isDockerSocket(src) {
					log.Printf("stripped docker socket bind mount: %s", b)
					modified = true
					continue
				}
				filtered = append(filtered, b)
			}
			if modified {
				if data, err := json.Marshal(filtered); err == nil {
					hc["Binds"] = data
				}
			}
		}
	}

	// Strip from Mounts (structured format)
	if mountsRaw, ok := hc["Mounts"]; ok {
		var mounts []Mount
		if err := json.Unmarshal(mountsRaw, &mounts); err == nil {
			var filtered []Mount
			for _, m := range mounts {
				if (m.Type == "bind" || m.Type == "") && isDockerSocket(m.Source) {
					log.Printf("stripped docker socket mount: %s -> %s", m.Source, m.Target)
					modified = true
					continue
				}
				filtered = append(filtered, m)
			}
			if modified || len(filtered) != len(mounts) {
				if data, err := json.Marshal(filtered); err == nil {
					hc["Mounts"] = data
				}
			}
		}
	}

	if !modified {
		return body, false
	}

	// Re-serialize HostConfig back into the request
	if hcData, err := json.Marshal(hc); err == nil {
		raw["HostConfig"] = hcData
	}
	if newBody, err := json.Marshal(raw); err == nil {
		return newBody, true
	}
	return body, false
}

// ──────────────────────────────────────────────────────────────────
// Path classification
// ──────────────────────────────────────────────────────────────────

var (
	execCreatePathRE = regexp.MustCompile(`^(?:/v\d+(?:\.\d+)?)?/containers/([^/]+)/exec$`)
	execStartPathRE  = regexp.MustCompile(`^(?:/v\d+(?:\.\d+)?)?/exec/([^/]+)/start$`)
	hexRE            = regexp.MustCompile(`^[0-9a-fA-F]+$`)
)

func pathOnly(p string) string {
	if i := strings.IndexByte(p, '?'); i >= 0 {
		return p[:i]
	}
	return p
}

func isContainerCreate(path string) bool {
	return strings.HasSuffix(pathOnly(path), "/containers/create")
}

func isNetworkMutation(path string) bool {
	p := pathOnly(path)
	return strings.HasSuffix(p, "/connect") || strings.HasSuffix(p, "/disconnect")
}

func isExecCreate(path string) bool {
	return execCreatePathRE.MatchString(pathOnly(path))
}

func isExecStart(path string) bool {
	return execStartPathRE.MatchString(pathOnly(path))
}

func extractContainerIDFromExecPath(path string) string {
	m := execCreatePathRE.FindStringSubmatch(pathOnly(path))
	if len(m) < 2 {
		return ""
	}
	return m[1]
}

// ──────────────────────────────────────────────────────────────────
// Exec body inspection
// ──────────────────────────────────────────────────────────────────

type execConfig struct {
	User       string `json:"User"`
	Privileged bool   `json:"Privileged"`
}

// checkExecConfig parses a Docker exec-create (or exec-start) request body and
// returns a non-empty reason string when the request must be blocked.
func checkExecConfig(body []byte) string {
	if len(bytes.TrimSpace(body)) == 0 {
		return ""
	}
	var cfg execConfig
	if err := json.Unmarshal(body, &cfg); err != nil {
		// Unparseable body — let upstream decide on shape, but don't allow
		// privileged escalation by accident.
		return ""
	}
	if cfg.Privileged {
		return "privileged exec is not allowed"
	}
	if isRootUser(cfg.User) {
		return "exec as root is not allowed"
	}
	return ""
}

func isRootUser(user string) bool {
	u := strings.TrimSpace(user)
	if u == "" {
		return false
	}
	// User can be "uid", "uid:gid", "name", or "name:group". The uid/name
	// portion is everything before the first colon.
	if i := strings.IndexByte(u, ':'); i >= 0 {
		u = u[:i]
	}
	u = strings.TrimSpace(u)
	return u == "0" || strings.EqualFold(u, "root")
}

// ──────────────────────────────────────────────────────────────────
// Container allowlist
// ──────────────────────────────────────────────────────────────────

// matchesAllowedContainer reports whether the {id} from a Docker URL refers to
// the Claude container. A name match is always accepted; an ID prefix match is
// accepted only when the full container ID has been resolved.
func matchesAllowedContainer(id, allowedName, allowedFullID string) bool {
	if id == "" {
		return false
	}
	if allowedName != "" && id == allowedName {
		return true
	}
	if allowedFullID == "" {
		return false
	}
	if !hexRE.MatchString(id) {
		return false
	}
	if len(id) > len(allowedFullID) {
		return false
	}
	return strings.EqualFold(allowedFullID[:len(id)], id)
}

// ──────────────────────────────────────────────────────────────────
// HTTP handler
// ──────────────────────────────────────────────────────────────────

type proxyConfig struct {
	target        *url.URL
	containerName string

	mu          sync.RWMutex
	containerID string
}

func (c *proxyConfig) allowedID() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.containerID
}

func (c *proxyConfig) setID(id string) {
	c.mu.Lock()
	c.containerID = id
	c.mu.Unlock()
}

// resolveContainerID asks the upstream for the configured container's full ID
// and caches it. Best-effort: failures are logged and retried on the next
// request.
func (c *proxyConfig) resolveContainerID() {
	if c.containerName == "" {
		return
	}
	if c.allowedID() != "" {
		return
	}
	endpoint := *c.target
	endpoint.Path = "/containers/" + c.containerName + "/json"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("could not resolve container %q: %v", c.containerName, err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return
	}
	var info struct {
		ID string `json:"Id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return
	}
	if info.ID != "" {
		log.Printf("resolved %q to container ID %s", c.containerName, info.ID)
		c.setID(info.ID)
	}
}

func newProxyHandler(cfg *proxyConfig) http.Handler {
	state := cfg
	proxy := httputil.NewSingleHostReverseProxy(state.target)
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && isNetworkMutation(r.URL.Path) {
			log.Printf("BLOCKED network connect/disconnect: %s", r.URL.Path)
			http.Error(w, "Forbidden: network connect/disconnect is not allowed", http.StatusForbidden)
			return
		}

		if r.Method == http.MethodPost && isExecCreate(r.URL.Path) {
			id := extractContainerIDFromExecPath(r.URL.Path)
			if !matchesAllowedContainer(id, state.containerName, state.allowedID()) {
				// Try resolving lazily, then re-check (handles the cold-start
				// case where Claude's container starts after the proxy).
				state.resolveContainerID()
				if !matchesAllowedContainer(id, state.containerName, state.allowedID()) {
					log.Printf("BLOCKED exec create on disallowed container: %s", id)
					http.Error(w, "Forbidden: exec is restricted to the Claude container", http.StatusForbidden)
					return
				}
			}
			body, err := io.ReadAll(r.Body)
			r.Body.Close()
			if err != nil {
				http.Error(w, "failed to read body", http.StatusInternalServerError)
				return
			}
			if reason := checkExecConfig(body); reason != "" {
				log.Printf("BLOCKED exec create: %s", reason)
				http.Error(w, fmt.Sprintf("Forbidden: %s", reason), http.StatusForbidden)
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
			r.ContentLength = int64(len(body))
		}

		if r.Method == http.MethodPost && isExecStart(r.URL.Path) {
			body, err := io.ReadAll(r.Body)
			r.Body.Close()
			if err != nil {
				http.Error(w, "failed to read body", http.StatusInternalServerError)
				return
			}
			if reason := checkExecConfig(body); reason != "" {
				log.Printf("BLOCKED exec start: %s", reason)
				http.Error(w, fmt.Sprintf("Forbidden: %s", reason), http.StatusForbidden)
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
			r.ContentLength = int64(len(body))
		}

		if r.Method == http.MethodPost && isContainerCreate(r.URL.Path) {
			body, err := io.ReadAll(r.Body)
			r.Body.Close()
			if err != nil {
				http.Error(w, "failed to read body", http.StatusInternalServerError)
				return
			}

			var req ContainerCreateRequest
			if err := json.Unmarshal(body, &req); err == nil {
				if reason := checkHostConfig(req.HostConfig); reason != "" {
					log.Printf("BLOCKED container create: %s", reason)
					http.Error(w, fmt.Sprintf("Forbidden: %s", reason), http.StatusForbidden)
					return
				}
			}

			// Strip Docker socket mounts — in TCP-only setups these would be
			// rejected by the socket-proxy allowlist anyway.
			body, _ = stripDockerSocketMounts(body)

			r.Body = io.NopCloser(bytes.NewReader(body))
			r.ContentLength = int64(len(body))
		}

		proxy.ServeHTTP(w, r)
	})
	return mux
}

func main() {
	upstream := os.Getenv("DOCKER_FILTER_UPSTREAM")
	if upstream == "" {
		log.Fatal("DOCKER_FILTER_UPSTREAM not set")
	}
	listen := os.Getenv("DOCKER_FILTER_LISTEN")
	if listen == "" {
		listen = "0.0.0.0:2375"
	}
	containerName := os.Getenv("CLAUDE_CONTAINER_NAME")
	if containerName == "" {
		log.Print("warning: CLAUDE_CONTAINER_NAME not set — exec requests will be blocked")
	}

	target, err := url.Parse(upstream)
	if err != nil {
		log.Fatalf("invalid upstream URL: %v", err)
	}

	cfg := &proxyConfig{target: target, containerName: containerName}
	handler := newProxyHandler(cfg)

	log.Printf("docker-filter-proxy listening on %s, upstream %s, container %q", listen, upstream, containerName)
	if err := http.ListenAndServe(listen, handler); err != nil {
		log.Fatal(err)
	}
}
