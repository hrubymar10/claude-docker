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
	"regexp"
	"strings"
)

type HostConfig struct {
	Privileged   bool     `json:"Privileged"`
	PidMode      string   `json:"PidMode"`
	NetworkMode  string   `json:"NetworkMode"`
	UsernsMode   string   `json:"UsernsMode"`
	IpcMode      string   `json:"IpcMode"`
	UTSMode      string   `json:"UTSMode"`
	CgroupnsMode string   `json:"CgroupnsMode"`
	CapAdd       []string `json:"CapAdd"`
	SecurityOpt  []string `json:"SecurityOpt"`
	Devices      []any    `json:"Devices"`
}

type ContainerCreateRequest struct {
	HostConfig HostConfig `json:"HostConfig"`
}

type ExecCreateRequest struct {
	Privileged bool `json:"Privileged"`
}

var dangerousCaps = map[string]bool{
	"ALL":             true,
	"SYS_ADMIN":      true,
	"SYS_PTRACE":     true,
	"SYS_RAWIO":      true,
	"DAC_READ_SEARCH": true,
	"NET_ADMIN":      true,
	"SYS_MODULE":     true,
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
	if hc.UTSMode == "host" {
		return "host UTS mode is not allowed"
	}
	if hc.CgroupnsMode == "host" {
		return "host cgroup namespace mode is not allowed"
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
		lower := strings.ToLower(opt)
		if strings.Contains(lower, "unconfined") ||
			strings.Contains(lower, "apparmor=") ||
			strings.Contains(lower, "systempaths=unmasked") ||
			lower == "no-new-privileges:false" || lower == "no-new-privileges=false" {
			return fmt.Sprintf("security option %q is not allowed", opt)
		}
	}
	if len(hc.Devices) > 0 {
		return "device mappings are not allowed"
	}
	return ""
}

// maxBodySize limits request body reads to 10MB to prevent OOM.
const maxBodySize = 10 * 1024 * 1024

var containerCreateRe = regexp.MustCompile(`/containers/create(\?.*)?$`)
var containerUpdateRe = regexp.MustCompile(`/containers/[^/]+/update(\?.*)?$`)
var execCreateRe = regexp.MustCompile(`/containers/[^/]+/exec(\?.*)?$`)
var networkMutationRe = regexp.MustCompile(`/networks/[^/]+/(connect|disconnect)(\?.*)?$`)

// newProxy creates the filtering HTTP handler backed by the given upstream URL.
func newProxy(upstreamURL string) http.Handler {
	target, err := url.Parse(upstreamURL)
	if err != nil {
		log.Fatalf("invalid upstream URL: %v", err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path

		if r.Method == "POST" && networkMutationRe.MatchString(path) {
			log.Printf("BLOCKED network connect/disconnect: %s", path)
			http.Error(w, "Forbidden: network connect/disconnect is not allowed", http.StatusForbidden)
			return
		}

		// Inspect body for container create, container update, and exec create
		if r.Method == "POST" && (containerCreateRe.MatchString(path) || containerUpdateRe.MatchString(path)) {
			body, err := io.ReadAll(io.LimitReader(r.Body, maxBodySize))
			r.Body.Close()
			if err != nil {
				http.Error(w, "failed to read body", http.StatusInternalServerError)
				return
			}

			var req ContainerCreateRequest
			if err := json.Unmarshal(body, &req); err != nil {
				log.Printf("BLOCKED container create/update: malformed JSON: %v", err)
				http.Error(w, "Forbidden: malformed JSON in request body", http.StatusBadRequest)
				return
			}
			if reason := checkHostConfig(req.HostConfig); reason != "" {
				log.Printf("BLOCKED container create/update: %s", reason)
				http.Error(w, fmt.Sprintf("Forbidden: %s", reason), http.StatusForbidden)
				return
			}

			r.Body = io.NopCloser(bytes.NewReader(body))
			r.ContentLength = int64(len(body))
		}

		// Block privileged exec sessions
		if r.Method == "POST" && execCreateRe.MatchString(path) {
			body, err := io.ReadAll(io.LimitReader(r.Body, maxBodySize))
			r.Body.Close()
			if err != nil {
				http.Error(w, "failed to read body", http.StatusInternalServerError)
				return
			}

			var req ExecCreateRequest
			if err := json.Unmarshal(body, &req); err != nil {
				log.Printf("BLOCKED exec create: malformed JSON: %v", err)
				http.Error(w, "Forbidden: malformed JSON in request body", http.StatusBadRequest)
				return
			}
			if req.Privileged {
				log.Printf("BLOCKED exec create: privileged exec is not allowed")
				http.Error(w, "Forbidden: privileged exec is not allowed", http.StatusForbidden)
				return
			}

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

	handler := newProxy(upstream)
	log.Printf("docker-filter-proxy listening on %s, upstream %s", listen, upstream)
	if err := http.ListenAndServe(listen, handler); err != nil {
		log.Fatal(err)
	}
}
