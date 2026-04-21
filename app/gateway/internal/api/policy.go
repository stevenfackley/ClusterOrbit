package api

import (
	"fmt"
	"strings"
)

// ScalePolicy gates scale mutations before they reach the backend. Zero value
// is "no policy" — every request allowed. Each field can be set independently:
// an unset MaxReplicas means no ceiling, an empty AllowedNamespaces means any
// namespace. Callers build one ScalePolicy from env vars and hang it off
// Server; nil Server.ScalePolicy skips the check entirely.
type ScalePolicy struct {
	// MaxReplicas, if > 0, rejects any scale request whose target count
	// exceeds it. A value of 0 disables the ceiling (not "scale to zero
	// forbidden" — that's a separate concern).
	MaxReplicas int
	// AllowedNamespaces, if non-empty, restricts scale to workloads whose
	// namespace appears in the set. Matched exact, case-sensitive.
	AllowedNamespaces []string
}

// Evaluate returns a non-empty reason when the request violates policy. The
// reason is surfaced both in the HTTP error and the audit record so an
// operator sees exactly which rule fired.
func (p *ScalePolicy) Evaluate(workloadID string, replicas int) string {
	if p == nil {
		return ""
	}
	if p.MaxReplicas > 0 && replicas > p.MaxReplicas {
		return fmt.Sprintf("replicas %d exceeds max %d", replicas, p.MaxReplicas)
	}
	if len(p.AllowedNamespaces) > 0 {
		ns := workloadNamespace(workloadID)
		if ns == "" {
			return "workload id missing namespace"
		}
		if !containsString(p.AllowedNamespaces, ns) {
			return fmt.Sprintf("namespace %q not in allowlist", ns)
		}
	}
	return ""
}

// workloadNamespace extracts the namespace from a "{kind}:{namespace}/{name}"
// workload id. Returns "" when the id has neither a colon nor a slash in the
// expected positions — callers treat that as a policy failure, not a parse
// error, so the gate defaults to closed.
func workloadNamespace(id string) string {
	colon := strings.IndexByte(id, ':')
	if colon < 0 || colon == len(id)-1 {
		return ""
	}
	rest := id[colon+1:]
	slash := strings.IndexByte(rest, '/')
	if slash <= 0 {
		return ""
	}
	return rest[:slash]
}

func containsString(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
