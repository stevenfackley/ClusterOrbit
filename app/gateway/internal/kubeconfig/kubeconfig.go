// Package kubeconfig reads and resolves a kubeconfig file into the
// subset of data the gateway needs to reach a cluster's API server.
// It intentionally covers only what ClusterOrbit exercises today:
// bearer-token auth and CA certificate validation (inline or file).
// Client certificates, exec plugins, and auth providers are out of
// scope for this MVP.
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
	InsecureSkipTLS  bool
	EnvironmentLabel string
}

// Document is the parsed kubeconfig file.
type Document struct {
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
	Name      string
	Token     string
	TokenFile string
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
			Token     string `yaml:"token"`
			TokenFile string `yaml:"tokenFile"`
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
		doc.Users = append(doc.Users, UserEntry{
			Name:      u.Name,
			Token:     u.User.Token,
			TokenFile: u.User.TokenFile,
		})
	}
	return doc, nil
}

// LoadFile parses the kubeconfig at path.
func LoadFile(path string) (*Document, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read kubeconfig: %w", err)
	}
	return ParseDocument(data)
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
		data, err := os.ReadFile(cluster.CAFile)
		if err != nil {
			return nil, fmt.Errorf("read CA file: %w", err)
		}
		resolved.CAData = data
	}

	if ctx.User != "" {
		var user *UserEntry
		for i := range doc.Users {
			if doc.Users[i].Name == ctx.User {
				user = &doc.Users[i]
				break
			}
		}
		if user != nil {
			switch {
			case user.Token != "":
				resolved.BearerToken = user.Token
			case user.TokenFile != "":
				data, err := os.ReadFile(user.TokenFile)
				if err != nil {
					return nil, fmt.Errorf("read token file: %w", err)
				}
				resolved.BearerToken = strings.TrimSpace(string(data))
			}
		}
	}

	return resolved, nil
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
