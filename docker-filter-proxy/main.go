package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
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

func isContainerCreate(path string) bool {
	p := strings.SplitN(path, "?", 2)[0]
	return strings.HasSuffix(p, "/containers/create")
}

func isNetworkMutation(path string) bool {
	p := strings.SplitN(path, "?", 2)[0]
	return strings.HasSuffix(p, "/connect") || strings.HasSuffix(p, "/disconnect")
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

	target, err := url.Parse(upstream)
	if err != nil {
		log.Fatalf("invalid upstream URL: %v", err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" && isNetworkMutation(r.URL.Path) {
			log.Printf("BLOCKED network connect/disconnect: %s", r.URL.Path)
			http.Error(w, "Forbidden: network connect/disconnect is not allowed", http.StatusForbidden)
			return
		}
		if r.Method == "POST" && isContainerCreate(r.URL.Path) {
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

	log.Printf("docker-filter-proxy listening on %s, upstream %s", listen, upstream)
	if err := http.ListenAndServe(listen, mux); err != nil {
		log.Fatal(err)
	}
}
