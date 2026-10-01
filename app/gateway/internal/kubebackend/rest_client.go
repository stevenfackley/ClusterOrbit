package kubebackend

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubeconfig"
)

// RestClient is a minimal client for the Kubernetes API server: JSON GETs,
// PATCHes and POSTs. It supports bearer-token and client-certificate auth plus
// CA validation (or the explicit insecure-skip option); exec plugins and auth
// providers are not supported. Anything fancier should go through client-go.
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

	if len(cluster.ClientCertData) > 0 {
		cert, err := tls.X509KeyPair(cluster.ClientCertData, cluster.ClientKeyData)
		if err != nil {
			return nil, fmt.Errorf("load client certificate: %w", err)
		}
		tlsConfig.Certificates = []tls.Certificate{cert}
	}

	// Clone the default transport to keep proxy-from-environment, HTTP/2 and
	// the dial/handshake timeouts. The snapshot's 8 parallel LISTs need more
	// than the default 2 idle connections per host to be reused.
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = tlsConfig
	transport.MaxIdleConnsPerHost = 8
	return &RestClient{
		baseURL:     base,
		bearerToken: cluster.BearerToken,
		httpClient: &http.Client{
			Transport: transport,
			Timeout:   30 * time.Second,
		},
	}, nil
}

// maxStatusMessage caps the apiserver message kept in a StatusError so a
// verbose Status body never reaches clients or job records.
const maxStatusMessage = 256

// StatusError is a non-2xx response from the API server, reduced to the HTTP
// code plus the Status object's reason and (truncated) message. It never
// carries the raw response body.
type StatusError struct {
	Code    int
	Reason  string
	Message string
}

func (e *StatusError) Error() string {
	msg := fmt.Sprintf("kube api returned %d %s", e.Code, e.Reason)
	if e.Message != "" {
		msg += ": " + e.Message
	}
	return msg
}

// newStatusError builds a StatusError from a response, decoding the body as a
// Kubernetes metav1.Status when possible.
func newStatusError(code int, body []byte) *StatusError {
	var st struct {
		Reason  string `json:"reason"`
		Message string `json:"message"`
	}
	_ = json.Unmarshal(body, &st)
	e := &StatusError{Code: code, Reason: st.Reason, Message: st.Message}
	if e.Reason == "" {
		e.Reason = http.StatusText(code)
	}
	if len(e.Message) > maxStatusMessage {
		e.Message = e.Message[:maxStatusMessage] + "…"
	}
	return e
}

// do issues one request against path joined to the base URL, keeping any path
// prefix in the server URL (e.g. Rancher's /k8s/clusters/c-1). path is already
// escaped: callers url.PathEscape each variable segment, so a "/" inside one
// goes out as %2F rather than as a separator. The error slot is reserved for
// transport/read failures; callers inspect the status.
func (c *RestClient) do(
	ctx context.Context,
	method, path string,
	query url.Values,
	contentType string,
	body []byte,
) (int, []byte, error) {
	u := *c.baseURL
	u.RawPath = strings.TrimSuffix(c.baseURL.EscapedPath(), "/") + path
	decoded, err := url.PathUnescape(u.RawPath)
	if err != nil {
		return 0, nil, fmt.Errorf("invalid request path %q: %w", path, err)
	}
	u.Path = decoded
	u.RawQuery = query.Encode()

	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), reader)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Accept", "application/json")
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if c.bearerToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.bearerToken)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("kube api request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, fmt.Errorf("read response body: %w", err)
	}
	return resp.StatusCode, respBody, nil
}

func isSuccess(status int) bool { return status >= 200 && status < 300 }

// GetJSON issues GET against a path (joined to the base URL) with an
// optional query. The response body is decoded into a generic map so the
// rest of the package can walk it the same way the Dart transformer does.
// Non-2xx responses return a *StatusError.
func (c *RestClient) GetJSON(ctx context.Context, path string, query url.Values) (map[string]any, error) {
	status, body, err := c.do(ctx, http.MethodGet, path, query, "", nil)
	if err != nil {
		return nil, err
	}
	if !isSuccess(status) {
		return nil, newStatusError(status, body)
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

// Patch issues a PATCH against path with the given body + Content-Type. The
// response body is returned raw so callers can decide whether to decode it;
// non-2xx responses return a *StatusError.
func (c *RestClient) Patch(ctx context.Context, path, contentType string, body []byte) ([]byte, error) {
	status, respBody, err := c.do(ctx, http.MethodPatch, path, nil, contentType, body)
	if err != nil {
		return nil, err
	}
	if !isSuccess(status) {
		return nil, newStatusError(status, respBody)
	}
	return respBody, nil
}

// Post issues a POST against path and returns the HTTP status code alongside
// the raw body. Unlike GetJSON/Patch it does NOT fold non-2xx into the error —
// the error slot is reserved for transport/read failures. Callers inspect the
// status themselves, which the eviction flow relies on: a 429 means a
// PodDisruptionBudget would be violated and the caller should back off and
// retry, not treat it as fatal.
func (c *RestClient) Post(ctx context.Context, path, contentType string, body []byte) (int, []byte, error) {
	return c.do(ctx, http.MethodPost, path, nil, contentType, body)
}
