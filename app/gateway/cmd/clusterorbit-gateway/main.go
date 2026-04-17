package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
)

const scaffoldMessage = "ClusterOrbit gateway scaffold"

// message is retained for the pre-existing smoke test; the real binary now
// starts an HTTP server. See internal/api for request handling.
func message() string {
	return scaffoldMessage
}

func main() {
	addr := envOrDefault("CLUSTERORBIT_GATEWAY_ADDR", ":8080")
	token := os.Getenv("CLUSTERORBIT_GATEWAY_TOKEN")

	server := &api.Server{
		Backend: api.NewSampleBackend(),
		Token:   token,
	}

	httpServer := &http.Server{
		Addr:              addr,
		Handler:           server.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	fmt.Printf("%s listening on %s (auth=%t)\n", scaffoldMessage, addr, token != "")
	if err := httpServer.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
