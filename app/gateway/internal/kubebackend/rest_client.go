package kubebackend

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubeconfig"
)

// RestClient is a minimal read-only client for the Kubernetes API server.
// It only supports bearer-token auth and CA validation (or the explicit
// insecure-skip option) because those are the only paths the mobile app
// exercises today. Anything fancier should go through client-go.
type RestClient struct {
	baseURL     *url.URL
	bearerToken string
	httpClient  *http.Client
}

// NewRestClient constructs a client against the resolved cluster's API
// server. Errors if the server URL is unparseable or the CA data is
// provided but unusable.
func NewRestClient(cluster *kubeconfig.ResolvedCluster) (*RestClient, error) {
	if cluster == nil {
		return nil, errors.New("nil cluster")
	}
	base, err := url.Parse(cluster.Server)
	if err != nil {
		return nil, fmt.Errorf("parse server url: %w", err)
	}
	if base.Scheme == "" || base.Host == "" {
		return nil, fmt.Errorf("server url missing scheme or host: %q", cluster.Server)
	}

	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12}
	if cluster.InsecureSkipTLS {
		tlsConfig.InsecureSkipVerify = true
	} else if len(cluster.CAData) > 0 {
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(cluster.CAData) {
			return nil, errors.New("CA data did not parse as PEM certificates")
		}
		tlsConfig.RootCAs = pool
	}

	transport := &http.Transport{TLSClientConfig: tlsConfig}
	return &RestClient{
		baseURL:     base,
		bearerToken: cluster.BearerToken,
		httpClient: &http.Client{
			Transport: transport,
			Timeout:   30 * time.Second,
		},
	}, nil
}

// GetJSON issues GET against a path (joined to the base URL) with an
// optional query. The response body is decoded into a generic map so the
// rest of the package can walk it the same way the Dart transformer does.
func (c *RestClient) GetJSON(ctx context.Context, path string, query url.Values) (map[string]any, error) {
	u := *c.baseURL
	u.Path = path
	u.RawQuery = query.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	if c.bearerToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.bearerToken)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("kube api request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response body: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("kube api %s returned %d: %s", u.Path, resp.StatusCode, string(body))
	}

	out := map[string]any{}
	if len(body) == 0 {
		return out, nil
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode kube api response: %w", err)
	}
	return out, nil
}

// BaseURL returns the API server base URL (for logging and error context).
func (c *RestClient) BaseURL() string {
	return c.baseURL.String()
}
