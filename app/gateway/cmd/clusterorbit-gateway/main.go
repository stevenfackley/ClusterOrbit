package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubebackend"
	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubeconfig"
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
	mode := envOrDefault("CLUSTERORBIT_GATEWAY_MODE", "sample")

	backend, backendLabel := buildBackend(mode)

	server := &api.Server{
		Backend: backend,
		Token:   token,
	}

	httpServer := &http.Server{
		Addr:              addr,
		Handler:           server.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	fmt.Printf("%s listening on %s (auth=%t backend=%s)\n",
		scaffoldMessage, addr, token != "", backendLabel)
	if err := httpServer.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

// buildBackend resolves the backend the gateway should serve. Mode "kube"
// reads the kubeconfig referenced by CLUSTERORBIT_GATEWAY_KUBECONFIG /
// KUBECONFIG and builds a KubeBackend; any failure falls back to sample data
// with a warning so the gateway still serves something useful during rollout.
func buildBackend(mode string) (api.ClusterBackend, string) {
	if mode != "kube" {
		return api.NewSampleBackend(), "sample"
	}

	path := kubeconfig.ResolvePath(os.Getenv)
	if path == "" {
		log.Printf("gateway: mode=kube but no kubeconfig path resolvable; falling back to sample data")
		return api.NewSampleBackend(), "sample (kube fallback: no kubeconfig path)"
	}
	doc, err := kubeconfig.LoadFile(path)
	if err != nil {
		log.Printf("gateway: load kubeconfig %q: %v; falling back to sample data", path, err)
		return api.NewSampleBackend(), "sample (kube fallback: load failed)"
	}
	cluster, err := kubeconfig.Resolve(doc, os.Getenv(kubeconfig.EnvVarContext))
	if err != nil {
		log.Printf("gateway: resolve kubeconfig context: %v; falling back to sample data", err)
		return api.NewSampleBackend(), "sample (kube fallback: resolve failed)"
	}
	backend, err := kubebackend.NewKubeBackend(cluster)
	if err != nil {
		log.Printf("gateway: build kube backend: %v; falling back to sample data", err)
		return api.NewSampleBackend(), "sample (kube fallback: client init failed)"
	}
	return backend, fmt.Sprintf("kube (%s @ %s)", cluster.ContextName, cluster.APIServerHost())
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
