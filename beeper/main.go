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

func main() {
	http.HandleFunc("GET /beep", beep)
	http.HandleFunc("GET /play/{category}", beep)

	log.Println("Beeper listening on http://127.0.0.1:9999")
	if err := http.ListenAndServe("127.0.0.1:9999", nil); err != nil {
		log.Fatal(err)
	}
}
