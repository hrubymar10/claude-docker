package main

import (
	"log"
	"net/http"
	"os/exec"
)

func main() {
	http.HandleFunc("GET /beep", func(w http.ResponseWriter, _ *http.Request) {
		_ = exec.Command("afplay", "/System/Library/Sounds/Ping.aiff").Start()
		w.WriteHeader(http.StatusOK)
	})

	if err := http.ListenAndServe("127.0.0.1:9999", nil); err != nil {
		log.Fatal(err)
	}
}
