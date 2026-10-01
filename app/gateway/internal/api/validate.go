package api

import (
	"fmt"
	"strings"
)

// Object names from clients end up in Kubernetes API paths and fieldSelector
// values, so every one is checked against the Kubernetes naming rules before a
// policy gate or backend sees it. A valid name can't hold "/", "%", ",", "=" or
// "..", so it can't move a request to another object or subresource, or add
// selector terms.

// workloadKinds are the kind prefixes of snapshot workload IDs. They mirror the
// mobile WorkloadKind enum.
var workloadKinds = map[string]bool{
	"deployment":  true,
	"daemonSet":   true,
	"statefulSet": true,
	"job":         true,
}

// eventKinds maps each accepted GET /events kind filter to the Kubernetes kind
// it selects (involvedObject.kind). The mobile app sends its entity kinds
// (node, workload, service); the workload kinds, pod and the PascalCase API
// kinds are accepted too. "workload" doesn't say which controller kind, so it
// maps to "" and only the object name filters, as in direct mode.
var eventKinds = map[string]string{
	"node":        "Node",
	"Node":        "Node",
	"service":     "Service",
	"Service":     "Service",
	"pod":         "Pod",
	"Pod":         "Pod",
	"deployment":  "Deployment",
	"Deployment":  "Deployment",
	"daemonSet":   "DaemonSet",
	"DaemonSet":   "DaemonSet",
	"statefulSet": "StatefulSet",
	"StatefulSet": "StatefulSet",
	"job":         "Job",
	"Job":         "Job",
	"workload":    "",
}

// ParseWorkloadID splits a "{kind}:{namespace}/{name}" workload ID and checks
// each part: a known workload kind, a DNS-1123 label namespace and a DNS-1123
// subdomain name. Errors wrap ErrBadRequest.
func ParseWorkloadID(id string) (kind, namespace, name string, err error) {
	kind, rest, ok := strings.Cut(id, ":")
	if ok {
		namespace, name, ok = strings.Cut(rest, "/")
	}
	switch {
	case !ok:
		err = fmt.Errorf("%w: workload id %q must be kind:namespace/name", ErrBadRequest, id)
	case !workloadKinds[kind]:
		err = fmt.Errorf("%w: unknown workload kind %q", ErrBadRequest, kind)
	case !isDNS1123Label(namespace):
		err = fmt.Errorf("%w: invalid namespace %q", ErrBadRequest, namespace)
	case !isDNS1123Subdomain(name):
		err = fmt.Errorf("%w: invalid workload name %q", ErrBadRequest, name)
	default:
		return kind, namespace, name, nil
	}
	return "", "", "", err
}

// ValidateNodeID checks that id is a valid Kubernetes node name (a DNS-1123
// subdomain). Errors wrap ErrBadRequest.
func ValidateNodeID(id string) error {
	if !isDNS1123Subdomain(id) {
		return fmt.Errorf("%w: invalid node id %q", ErrBadRequest, id)
	}
	return nil
}

// ValidateEventQuery checks the GET /events filters: kind, when set, must be
// one InvolvedObjectKind accepts, objectName a DNS-1123 subdomain and
// namespace, when set, a DNS-1123 label. Errors wrap ErrBadRequest.
func ValidateEventQuery(kind, objectName, namespace string) error {
	if _, ok := eventKinds[kind]; kind != "" && !ok {
		return fmt.Errorf("%w: unknown event kind %q", ErrBadRequest, kind)
	}
	if !isDNS1123Subdomain(objectName) {
		return fmt.Errorf("%w: invalid object name %q", ErrBadRequest, objectName)
	}
	if namespace != "" && !isDNS1123Label(namespace) {
		return fmt.Errorf("%w: invalid namespace %q", ErrBadRequest, namespace)
	}
	return nil
}

// InvolvedObjectKind returns the Kubernetes kind an events kind filter selects
// ("" for "workload", meaning any kind), and false for a kind the gateway
// doesn't accept.
func InvolvedObjectKind(kind string) (string, bool) {
	k, ok := eventKinds[kind]
	return k, ok
}

// isDNS1123Label reports whether s is an RFC 1123 label as Kubernetes defines
// it: at most 63 lowercase alphanumerics or '-', starting and ending with an
// alphanumeric. Namespace names must be labels.
func isDNS1123Label(s string) bool {
	return len(s) <= 63 && isLabelChars(s)
}

// isDNS1123Subdomain reports whether s is an RFC 1123 subdomain as Kubernetes
// defines it: at most 253 chars of labels joined by '.'. Most object names,
// node names included, must be subdomains.
func isDNS1123Subdomain(s string) bool {
	if len(s) > 253 {
		return false
	}
	for _, label := range strings.Split(s, ".") {
		if !isLabelChars(label) {
			return false
		}
	}
	return true
}

// isLabelChars reports whether s is non-empty, uses only [a-z0-9-], and starts
// and ends with an alphanumeric.
func isLabelChars(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		alnum := c >= 'a' && c <= 'z' || c >= '0' && c <= '9'
		if !alnum && (c != '-' || i == 0 || i == len(s)-1) {
			return false
		}
	}
	return true
}
