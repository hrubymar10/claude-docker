package main

import (
	"log"
	"net/http"
	"os/exec"
)

func beep(w http.ResponseWriter, _ *http.Request) {
	_ = exec.Command("afplay", "/System/Library/Sounds/Ping.aiff").Start()
	w.WriteHeader(http.StatusOK)
}

// Bind to loopback only. Containers reach this via host.docker.internal
// on Docker Desktop, so 0.0.0.0 would needlessly expose the beeper to
// anyone on the same LAN.
const addr = "127.0.0.1:9999"

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /beep", beep)
	mux.HandleFunc("GET /play/{category}", beep)
	return mux
}

func main() {
	log.Printf("Beeper listening on http://%s", addr)
	if err := http.ListenAndServe(addr, newMux()); err != nil {
		log.Fatal(err)
	}
}
