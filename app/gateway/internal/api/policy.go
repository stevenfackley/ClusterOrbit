package api

import "fmt"

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

// Evaluate returns a non-empty reason when scaling a workload in namespace to
// replicas violates policy. The reason is surfaced both in the HTTP error and
// the audit record so an operator sees exactly which rule fired.
func (p *ScalePolicy) Evaluate(namespace string, replicas int) string {
	if p == nil {
		return ""
	}
	if p.MaxReplicas > 0 && replicas > p.MaxReplicas {
		return fmt.Sprintf("replicas %d exceeds max %d", replicas, p.MaxReplicas)
	}
	return p.EvaluateNamespace(namespace)
}

// EvaluateNamespace runs only the namespace-allowlist portion of the policy.
// Restart has no replica dimension, so it calls this to share scale's
// allowlist gate without the ceiling. namespace is the one ParseWorkloadID
// validated; an empty one fails closed.
func (p *ScalePolicy) EvaluateNamespace(namespace string) string {
	if p == nil || len(p.AllowedNamespaces) == 0 {
		return ""
	}
	if namespace == "" {
		return "workload namespace is empty"
	}
	if !containsString(p.AllowedNamespaces, namespace) {
		return fmt.Sprintf("namespace %q not in allowlist", namespace)
	}
	return ""
}

// NodePolicy gates node-level mutations (cordon, drain) before they reach the
// backend. Like ScalePolicy, the zero value is "no policy" — every request
// allowed. A nil Server.NodePolicy skips the check entirely.
//
// Uncordon is deliberately NOT gated: it makes a node schedulable again (a
// recovery action), and blocking recovery is more dangerous than allowing it.
type NodePolicy struct {
	// AllowedNodes, if non-empty, restricts cordon/drain to nodes whose name
	// appears in the set. Matched exact, case-sensitive. Empty == any node.
	AllowedNodes []string
	// ProtectedNodes may never be cordoned or drained — a denylist for
	// control-plane or otherwise load-bearing nodes. Checked before the
	// allowlist, so a node listed in both is still protected (fail safe).
	ProtectedNodes []string
	// DisableDrain, when true, rejects every drain request regardless of the
	// node lists. Cordon/uncordon are unaffected. The blunt kill switch for
	// the single most destructive operation in the gateway.
	DisableDrain bool
}

// EvaluateCordon gates a cordon/uncordon request. unschedulable is true for a
// cordon, false for an uncordon. Uncordon always passes (recovery action).
// Returns a non-empty reason when a cordon violates policy.
func (p *NodePolicy) EvaluateCordon(nodeID string, unschedulable bool) string {
	if p == nil || !unschedulable {
		return ""
	}
	return p.evaluateNode(nodeID)
}

// EvaluateDrain gates a node drain. Runs the kill switch first, then the same
// node-name check cordon uses — drain is a strict superset of cordon's blast
// radius, so it must never be more permissive than cordon.
func (p *NodePolicy) EvaluateDrain(nodeID string) string {
	if p == nil {
		return ""
	}
	if p.DisableDrain {
		return "node drain is disabled by policy"
	}
	return p.evaluateNode(nodeID)
}

// evaluateNode runs the shared allow/deny check for node mutations. Returns ""
// when nodeID may be mutated, otherwise a human-readable reason surfaced in
// both the HTTP 403 and the audit record.
//
// TODO(you): implement the decision. The failing tests in policy_test.go
// (TestNodePolicyEvaluateCordon / TestNodePolicyEvaluateDrain) are the spec.
// Evaluate in this order so the most restrictive rule wins:
//
//  1. empty nodeID                                  → "node id is empty"
//  2. nodeID in p.ProtectedNodes                    → `node %q is protected`
//  3. p.AllowedNodes non-empty AND nodeID not in it → `node %q not in allowlist`
//  4. otherwise                                     → "" (allowed)
//
// containsString(haystack, needle) is defined just below this function.
func (p *NodePolicy) evaluateNode(nodeID string) string {
	if nodeID == "" {
		return "node id is empty"
	}
	if containsString(p.ProtectedNodes, nodeID) {
		return fmt.Sprintf("node %q is protected", nodeID)
	}
	if len(p.AllowedNodes) > 0 && !containsString(p.AllowedNodes, nodeID) {
		return fmt.Sprintf("node %q not in allowlist", nodeID)
	}
	return ""
}

func containsString(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
