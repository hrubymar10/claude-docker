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

type HostConfig struct {
	Privileged  bool     `json:"Privileged"`
	PidMode     string   `json:"PidMode"`
	NetworkMode string   `json:"NetworkMode"`
	UsernsMode  string   `json:"UsernsMode"`
	IpcMode     string   `json:"IpcMode"`
	CapAdd      []string `json:"CapAdd"`
	SecurityOpt []string `json:"SecurityOpt"`
	Devices     []any    `json:"Devices"`
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
