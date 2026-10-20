// Package kubeconfig reads and resolves a kubeconfig file into the
// subset of data the gateway needs to reach a cluster's API server.
// It intentionally covers only what ClusterOrbit exercises today:
// bearer-token auth, client-certificate auth and CA certificate
// validation (inline or file). Exec plugins and auth providers are out
// of scope; contexts whose user relies only on them are rejected.
package kubeconfig

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"gopkg.in/yaml.v3"
)

// EnvVarKubeconfig is ClusterOrbit's preferred override variable. If set,
// it takes precedence over the standard KUBECONFIG variable.
const EnvVarKubeconfig = "CLUSTERORBIT_GATEWAY_KUBECONFIG"

// EnvVarContext overrides which context to use. When empty the document's
// current-context is used.
const EnvVarContext = "CLUSTERORBIT_GATEWAY_KUBE_CONTEXT"

// ResolvedCluster is a kubeconfig context that has been joined with its
// referenced cluster and user entries.
type ResolvedCluster struct {
	ContextName      string
	ClusterName      string
	Server           string
	Namespace        string
	BearerToken      string
	CAData           []byte
	ClientCertData   []byte
	ClientKeyData    []byte
	InsecureSkipTLS  bool
	EnvironmentLabel string
}

// Document is the parsed kubeconfig file.
type Document struct {
	// Dir is the directory of the kubeconfig file (set by LoadFile). Relative
	// file references in the document resolve against it; empty means the
	// process working directory.
	Dir            string
	CurrentContext string
	Contexts       []ContextEntry
	Clusters       []ClusterEntry
	Users          []UserEntry
}

type ContextEntry struct {
	Name      string
	Cluster   string
	User      string
	Namespace string
}

type ClusterEntry struct {
	Name                  string
	Server                string
	CAData                []byte
	CAFile                string
	InsecureSkipTLSVerify bool
}

type UserEntry struct {
	Name           string
	Token          string
	TokenFile      string
	ClientCertData []byte
	ClientCertFile string
	ClientKeyData  []byte
	ClientKeyFile  string
	// UsesExec / UsesAuthProvider record credential plugins the gateway
	// cannot run, so Resolve can reject users that depend on them.
	UsesExec         bool
	UsesAuthProvider bool
}

// rawKubeconfig mirrors the on-disk YAML shape. Fields unused by the
// gateway are omitted so yaml.v3 silently ignores them.
type rawKubeconfig struct {
	CurrentContext string `yaml:"current-context"`
	Contexts       []struct {
		Name    string `yaml:"name"`
		Context struct {
			Cluster   string `yaml:"cluster"`
			User      string `yaml:"user"`
			Namespace string `yaml:"namespace"`
		} `yaml:"context"`
	} `yaml:"contexts"`
	Clusters []struct {
		Name    string `yaml:"name"`
		Cluster struct {
			Server                   string `yaml:"server"`
			CertificateAuthority     string `yaml:"certificate-authority"`
			CertificateAuthorityData string `yaml:"certificate-authority-data"`
			InsecureSkipTLSVerify    bool   `yaml:"insecure-skip-tls-verify"`
		} `yaml:"cluster"`
	} `yaml:"clusters"`
	Users []struct {
		Name string `yaml:"name"`
		User struct {
			Token                 string `yaml:"token"`
			TokenFile             string `yaml:"tokenFile"`
			ClientCertificate     string `yaml:"client-certificate"`
			ClientCertificateData string `yaml:"client-certificate-data"`
			ClientKey             string `yaml:"client-key"`
			ClientKeyData         string `yaml:"client-key-data"`
			Exec                  any    `yaml:"exec"`
			AuthProvider          any    `yaml:"auth-provider"`
		} `yaml:"user"`
	} `yaml:"users"`
}

// ParseDocument parses kubeconfig YAML bytes. base64-encoded CA data is
// decoded; file references are left untouched and resolved by Resolve.
func ParseDocument(data []byte) (*Document, error) {
	var raw rawKubeconfig
	if err := yaml.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("parse kubeconfig: %w", err)
	}

	doc := &Document{CurrentContext: raw.CurrentContext}
	for _, c := range raw.Contexts {
		doc.Contexts = append(doc.Contexts, ContextEntry{
			Name:      c.Name,
			Cluster:   c.Context.Cluster,
			User:      c.Context.User,
			Namespace: c.Context.Namespace,
		})
	}
	for _, cl := range raw.Clusters {
		entry := ClusterEntry{
			Name:                  cl.Name,
			Server:                cl.Cluster.Server,
			CAFile:                cl.Cluster.CertificateAuthority,
			InsecureSkipTLSVerify: cl.Cluster.InsecureSkipTLSVerify,
		}
		if cl.Cluster.CertificateAuthorityData != "" {
			decoded, err := base64.StdEncoding.DecodeString(
				cl.Cluster.CertificateAuthorityData,
			)
			if err != nil {
				return nil, fmt.Errorf(
					"decode CA data for cluster %q: %w", cl.Name, err,
				)
			}
			entry.CAData = decoded
		}
		doc.Clusters = append(doc.Clusters, entry)
	}
	for _, u := range raw.Users {
		entry := UserEntry{
			Name:             u.Name,
			Token:            u.User.Token,
			TokenFile:        u.User.TokenFile,
			ClientCertFile:   u.User.ClientCertificate,
			ClientKeyFile:    u.User.ClientKey,
			UsesExec:         u.User.Exec != nil,
			UsesAuthProvider: u.User.AuthProvider != nil,
		}
		var err error
		if entry.ClientCertData, err = decodeBase64(u.User.ClientCertificateData); err != nil {
			return nil, fmt.Errorf("decode client certificate data for user %q: %w", u.Name, err)
		}
		if entry.ClientKeyData, err = decodeBase64(u.User.ClientKeyData); err != nil {
			return nil, fmt.Errorf("decode client key data for user %q: %w", u.Name, err)
		}
		doc.Users = append(doc.Users, entry)
	}
	return doc, nil
}

func decodeBase64(s string) ([]byte, error) {
	if s == "" {
		return nil, nil
	}
	return base64.StdEncoding.DecodeString(s)
}

// LoadFile parses the kubeconfig at path and records its directory so
// relative file references resolve next to it, like kubectl does.
func LoadFile(path string) (*Document, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read kubeconfig: %w", err)
	}
	doc, err := ParseDocument(data)
	if err != nil {
		return nil, err
	}
	doc.Dir = filepath.Dir(path)
	return doc, nil
}

// readRef reads a file referenced from the kubeconfig. Relative paths
// resolve against the kubeconfig's directory.
func (d *Document) readRef(path string) ([]byte, error) {
	if d.Dir != "" && !filepath.IsAbs(path) {
		path = filepath.Join(d.Dir, path)
	}
	return os.ReadFile(path)
}

// ResolvePath picks the kubeconfig location using ClusterOrbit's preferred
// override, then KUBECONFIG, then the standard home path.
func ResolvePath(env func(string) string) string {
	if env == nil {
		env = os.Getenv
	}
	if override := env(EnvVarKubeconfig); override != "" {
		return override
	}
	if kc := env("KUBECONFIG"); kc != "" {
		sep := ":"
		if runtime.GOOS == "windows" {
			sep = ";"
		}
		for _, part := range strings.Split(kc, sep) {
			trimmed := strings.TrimSpace(part)
			if trimmed != "" {
				return trimmed
			}
		}
	}
	home := env("HOME")
	if home == "" {
		home = env("USERPROFILE")
	}
	if home == "" {
		return ""
	}
	return filepath.Join(home, ".kube", "config")
}

// Resolve joins a context to its referenced cluster and user entries and
// reads any external CA / token files. ctxName may be empty to select the
// document's current-context.
func Resolve(doc *Document, ctxName string) (*ResolvedCluster, error) {
	if doc == nil {
		return nil, errors.New("nil document")
	}
	if ctxName == "" {
		ctxName = doc.CurrentContext
	}
	if ctxName == "" {
		return nil, errors.New("no context specified and no current-context set")
	}

	var ctx *ContextEntry
	for i := range doc.Contexts {
		if doc.Contexts[i].Name == ctxName {
			ctx = &doc.Contexts[i]
			break
		}
	}
	if ctx == nil {
		return nil, fmt.Errorf("context %q not found", ctxName)
	}

	var cluster *ClusterEntry
	for i := range doc.Clusters {
		if doc.Clusters[i].Name == ctx.Cluster {
			cluster = &doc.Clusters[i]
			break
		}
	}
	if cluster == nil || cluster.Server == "" {
		return nil, fmt.Errorf("cluster %q not found or missing server", ctx.Cluster)
	}

	resolved := &ResolvedCluster{
		ContextName:      ctx.Name,
		ClusterName:      cluster.Name,
		Server:           cluster.Server,
		Namespace:        ctx.Namespace,
		CAData:           cluster.CAData,
		InsecureSkipTLS:  cluster.InsecureSkipTLSVerify,
		EnvironmentLabel: environmentLabelFor(ctx.Name, cluster.Name),
	}

	if len(resolved.CAData) == 0 && cluster.CAFile != "" {
		data, err := doc.readRef(cluster.CAFile)
		if err != nil {
			return nil, fmt.Errorf("read CA file: %w", err)
		}
		resolved.CAData = data
	}

	var user *UserEntry
	for i := range doc.Users {
		if doc.Users[i].Name == ctx.User {
			user = &doc.Users[i]
			break
		}
	}
	if ctx.User == "" || user == nil {
		return nil, fmt.Errorf("user %q not found", ctx.User)
	}
	if err := resolveUser(doc, user, resolved); err != nil {
		return nil, err
	}

	return resolved, nil
}

// resolveUser copies the user's credentials into resolved, reading any file
// references. Users whose only credentials come from exec or auth-provider
// plugins are rejected rather than silently resolved with no credentials.
func resolveUser(doc *Document, user *UserEntry, resolved *ResolvedCluster) error {
	switch {
	case user.Token != "":
		resolved.BearerToken = user.Token
	case user.TokenFile != "":
		data, err := doc.readRef(user.TokenFile)
		if err != nil {
			return fmt.Errorf("read token file: %w", err)
		}
		resolved.BearerToken = strings.TrimSpace(string(data))
	}

	cert, key := user.ClientCertData, user.ClientKeyData
	var err error
	if len(cert) == 0 && user.ClientCertFile != "" {
		if cert, err = doc.readRef(user.ClientCertFile); err != nil {
			return fmt.Errorf("read client certificate file: %w", err)
		}
	}
	if len(key) == 0 && user.ClientKeyFile != "" {
		if key, err = doc.readRef(user.ClientKeyFile); err != nil {
			return fmt.Errorf("read client key file: %w", err)
		}
	}
	if (len(cert) == 0) != (len(key) == 0) {
		return fmt.Errorf("user %q needs both a client certificate and a client key", user.Name)
	}
	resolved.ClientCertData, resolved.ClientKeyData = cert, key

	if resolved.BearerToken == "" && len(cert) == 0 && (user.UsesExec || user.UsesAuthProvider) {
		return fmt.Errorf("user %q uses exec or auth-provider credentials, which are not supported", user.Name)
	}
	return nil
}

// ResolveAll walks every context in the document and returns the ones that
// resolve successfully. Errors on individual contexts are collected and
// returned so callers can log skipped entries without failing the whole boot.
func ResolveAll(doc *Document) ([]*ResolvedCluster, []error) {
	if doc == nil {
		return nil, []error{errors.New("nil document")}
	}
	var out []*ResolvedCluster
	var errs []error
	for _, ctx := range doc.Contexts {
		if ctx.Name == "" {
			// Resolve maps an empty name to current-context, which would
			// duplicate that entry under the same ID.
			errs = append(errs, errors.New("context with empty name skipped"))
			continue
		}
		r, err := Resolve(doc, ctx.Name)
		if err != nil {
			errs = append(errs, fmt.Errorf("context %q: %w", ctx.Name, err))
			continue
		}
		out = append(out, r)
	}
	return out, errs
}

// APIServerHost extracts just the host portion of the server URL, matching
// the mobile app's ClusterProfile.apiServerHost convention.
func (r *ResolvedCluster) APIServerHost() string {
	u, err := url.Parse(r.Server)
	if err != nil || u.Host == "" {
		return r.Server
	}
	return u.Hostname()
}

func environmentLabelFor(contextName, clusterName string) string {
	probe := strings.ToLower(contextName) + " " + strings.ToLower(clusterName)
	switch {
	case strings.Contains(probe, "prod"):
		return "Production"
	case strings.Contains(probe, "stage"):
		return "Staging"
	case strings.Contains(probe, "dev"):
		return "Development"
	case strings.Contains(probe, "test"):
		return "Testing"
	case strings.Contains(probe, "home"), strings.Contains(probe, "lab"):
		return "Homelab"
	default:
		return "Direct access"
	}
}
