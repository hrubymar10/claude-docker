package main

import (
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
)

func main() {
	profilesRaw := os.Getenv("AWS_CRED_PROXY_PROFILES")
	if profilesRaw == "" {
		log.Fatal("AWS_CRED_PROXY_PROFILES is required (comma-separated: name:region,name:region)")
	}

	allowed := make(map[string]bool)
	for _, entry := range strings.Split(profilesRaw, ",") {
		name := strings.TrimSpace(strings.SplitN(entry, ":", 2)[0])
		if name != "" {
			allowed[name] = true
		}
	}

	port := os.Getenv("AWS_CRED_PROXY_PORT")
	if port == "" {
		port = "9998"
	}

	mux := http.NewServeMux()

	mux.HandleFunc("GET /credentials/{profile}", func(w http.ResponseWriter, r *http.Request) {
		profile := r.PathValue("profile")
		if !allowed[profile] {
			http.Error(w, "profile not allowed", http.StatusForbidden)
			log.Printf("DENIED: %q", profile)
			return
		}

		cmd := exec.Command("aws", "configure", "export-credentials", "--profile", profile)
		out, err := cmd.Output()
		if err != nil {
			var stderr string
			if exitErr, ok := err.(*exec.ExitError); ok {
				stderr = string(exitErr.Stderr)
			}
			http.Error(w, "credential export failed: "+stderr, http.StatusBadGateway)
			log.Printf("ERROR: %q: %v: %s", profile, err, stderr)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(out)
		log.Printf("OK: %q", profile)
	})

	mux.HandleFunc("GET /profiles", func(w http.ResponseWriter, _ *http.Request) {
		profiles := make([]string, 0, len(allowed))
		for p := range allowed {
			profiles = append(profiles, p)
		}
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte(strings.Join(profiles, "\n") + "\n"))
	})

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	addr := "127.0.0.1:" + port
	names := make([]string, 0, len(allowed))
	for p := range allowed {
		names = append(names, p)
	}
	log.Printf("AWS credential proxy on http://%s (profiles: %s)", addr, strings.Join(names, ", "))

	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}
