// Package kubebackend implements api.ClusterBackend against a live Kubernetes
// API server using a minimal REST client. It serves the same JSON contract as
// SampleBackend, so the mobile app cannot tell direct-kube from gateway-kube
// data apart — by design.
package kubebackend

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubeconfig"
)

// KubeBackend talks to a single Kubernetes cluster resolved from a kubeconfig
// context. Multi-cluster support would be a wrapper on top of this — out of
// scope for the MVP.
type KubeBackend struct {
	client  *RestClient
	cluster *kubeconfig.ResolvedCluster
	profile api.ClusterProfile
	now     func() time.Time

	// Drain job registry. Jobs are keyed by their generated ID and mutated by
	// a background goroutine, so every access goes through drainMu.
	drainMu   sync.Mutex
	drainJobs map[string]*api.DrainJob
	// drainBackoff is the initial wait before retrying a PDB-blocked (429)
	// eviction; it doubles up to drainMaxBackoff. drainTimeout caps the whole
	// drain. Overridable in tests to keep them fast.
	drainBackoff    time.Duration
	drainMaxBackoff time.Duration
	drainTimeout    time.Duration
	// newJobID mints unique job identifiers; overridable in tests for
	// deterministic IDs.
	newJobID func() string
}

// NewKubeBackend builds a backend for the given resolved kubeconfig cluster.
// The cluster must have at minimum a server URL; bearer token and CA data are
// optional but typically present.
func NewKubeBackend(cluster *kubeconfig.ResolvedCluster) (*KubeBackend, error) {
	if cluster == nil {
		return nil, errors.New("nil cluster")
	}
	client, err := NewRestClient(cluster)
	if err != nil {
		return nil, err
	}
	return &KubeBackend{
		client:          client,
		cluster:         cluster,
		profile:         profileFromCluster(cluster),
		now:             time.Now,
		drainJobs:       map[string]*api.DrainJob{},
		drainBackoff:    1 * time.Second,
		drainMaxBackoff: 15 * time.Second,
		drainTimeout:    5 * time.Minute,
		newJobID:        randomJobID,
	}, nil
}

func profileFromCluster(c *kubeconfig.ResolvedCluster) api.ClusterProfile {
	id := c.ContextName
	if id == "" {
		id = c.ClusterName
	}
	if id == "" {
		id = "kube"
	}
	return api.ClusterProfile{
		ID:               id,
		Name:             orDefault(c.ContextName, c.ClusterName),
		APIServerHost:    c.APIServerHost(),
		EnvironmentLabel: orDefault(c.EnvironmentLabel, "Direct access"),
		ConnectionMode:   "gateway",
	}
}

// ListClusters returns a single-element list with the resolved cluster's
// profile. ClusterOrbit is single-cluster-per-gateway today.
func (b *KubeBackend) ListClusters(_ context.Context) ([]api.ClusterProfile, error) {
	return []api.ClusterProfile{b.profile}, nil
}

// LoadSnapshot fetches nodes, pods, services, workloads, and replicasets in
// parallel and transforms them into a ClusterSnapshot.
func (b *KubeBackend) LoadSnapshot(ctx context.Context, clusterID string) (api.ClusterSnapshot, error) {
	if clusterID != "" && clusterID != b.profile.ID {
		return api.ClusterSnapshot{}, api.ErrNotFound
	}

	// resourceVersion=0 lets the apiserver answer these cluster-wide LISTs
	// from its watch cache instead of a quorum read.
	cached := url.Values{"resourceVersion": []string{"0"}}
	var raw rawLists
	fetches := []struct {
		name string
		path string
		dst  *map[string]any
	}{
		{"nodes", "/api/v1/nodes", &raw.nodes},
		{"pods", "/api/v1/pods", &raw.pods},
		{"services", "/api/v1/services", &raw.services},
		{"deployments", "/apis/apps/v1/deployments", &raw.deployments},
		{"daemonsets", "/apis/apps/v1/daemonsets", &raw.daemonSets},
		{"statefulsets", "/apis/apps/v1/statefulsets", &raw.statefulSets},
		{"jobs", "/apis/batch/v1/jobs", &raw.jobs},
		{"replicasets", "/apis/apps/v1/replicasets", &raw.replicaSets},
	}

	// Each goroutine writes only its own raw field, and wg.Wait orders those
	// writes before the transform reads them.
	var wg sync.WaitGroup
	errCh := make(chan error, len(fetches))
	for i := range fetches {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			body, err := b.client.GetJSON(ctx, fetches[i].path, cached)
			if err != nil {
				errCh <- fmt.Errorf("%s: %w", fetches[i].name, err)
				return
			}
			*fetches[i].dst = body
		}(i)
	}
	wg.Wait()
	close(errCh)
	for err := range errCh {
		if err != nil {
			return api.ClusterSnapshot{}, err
		}
	}

	return transformSnapshot(b.profile, b.now(), raw), nil
}

// LoadEvents fetches recent events for the given object. Kubernetes returns
// them ordered by creation time; we sort by lastTimestamp desc and truncate to
// limit so recent-first ordering matches the mobile UI.
func (b *KubeBackend) LoadEvents(
	ctx context.Context,
	clusterID, kind, objectName, namespace string,
	limit int,
) ([]api.ClusterEvent, error) {
	if clusterID != "" && clusterID != b.profile.ID {
		return nil, api.ErrNotFound
	}
	if limit <= 0 {
		limit = 5
	}
	if objectName == "" {
		return nil, errors.New("objectName is required")
	}

	path := "/api/v1/events"
	if namespace != "" {
		path = "/api/v1/namespaces/" + namespace + "/events"
	}

	query := url.Values{}
	selectors := []string{"involvedObject.name=" + objectName}
	if kind != "" {
		selectors = append(selectors, "involvedObject.kind="+kubernetesKind(kind))
	}
	query.Set("fieldSelector", strings.Join(selectors, ","))

	body, err := b.client.GetJSON(ctx, path, query)
	if err != nil {
		return nil, fmt.Errorf("list events: %w", err)
	}

	items := listItems(body)
	events := make([]api.ClusterEvent, 0, len(items))
	for _, item := range items {
		events = append(events, eventFromItem(item))
	}

	// Sort newest first by lastTimestamp, then truncate.
	sortEventsDesc(events)
	if len(events) > limit {
		events = events[:limit]
	}
	return events, nil
}

func eventFromItem(item map[string]any) api.ClusterEvent {
	last := parseTimestamp(item["lastTimestamp"])
	if last.IsZero() {
		last = parseTimestamp(item["eventTime"])
	}
	if last.IsZero() {
		last = parseTimestamp(valueAt(item, []string{"metadata", "creationTimestamp"}))
	}
	count := intAt(item, "count")
	if count == 0 {
		count = 1
	}
	etype := strings.ToLower(orDefault(stringAt(item, "type"), "Normal"))
	var source *string
	if s := stringAt(item, "source", "component"); s != "" {
		source = &s
	} else if s := stringAt(item, "reportingComponent"); s != "" {
		source = &s
	}
	return api.ClusterEvent{
		Type:            etype,
		Reason:          stringAt(item, "reason"),
		Message:         stringAt(item, "message"),
		LastTimestamp:   last.UnixMilli(),
		Count:           count,
		SourceComponent: source,
	}
}

func sortEventsDesc(events []api.ClusterEvent) {
	// tiny slice — insertion sort keeps the impl obvious and avoids pulling in
	// sort.Slice's allocation overhead for what is typically <20 entries.
	for i := 1; i < len(events); i++ {
		j := i
		for j > 0 && events[j-1].LastTimestamp < events[j].LastTimestamp {
			events[j-1], events[j] = events[j], events[j-1]
			j--
		}
	}
}

// ScaleWorkload updates the replica count of a Deployment or StatefulSet.
// DaemonSets and Jobs don't have a meaningful "replicas" scale; callers get
// ErrBadRequest there so the mobile side doesn't let users attempt it.
func (b *KubeBackend) ScaleWorkload(
	ctx context.Context,
	clusterID, workloadID string,
	replicas int,
) error {
	if clusterID != "" && clusterID != b.profile.ID {
		return api.ErrNotFound
	}
	if replicas < 0 {
		return fmt.Errorf("%w: replicas must be >=0", api.ErrBadRequest)
	}
	kind, namespace, name, err := parseWorkloadID(workloadID)
	if err != nil {
		return err
	}
	resource, ok := scaleResourceFor(kind)
	if !ok {
		return fmt.Errorf("%w: kind %q cannot be scaled", api.ErrBadRequest, kind)
	}

	path := fmt.Sprintf("/apis/apps/v1/namespaces/%s/%s/%s/scale", namespace, resource, name)
	body := []byte(fmt.Sprintf(`{"spec":{"replicas":%d}}`, replicas))
	_, err = b.client.Patch(ctx, path, "application/merge-patch+json", body)
	if err != nil {
		return fmt.Errorf("scale %s %s/%s: %w", kind, namespace, name, mutationErr(err))
	}
	return nil
}

func scaleResourceFor(kind string) (string, bool) {
	switch kind {
	case workloadKindDeployment:
		return "deployments", true
	case workloadKindStatefulSet:
		return "statefulsets", true
	default:
		return "", false
	}
}

// RestartWorkload triggers a rolling restart of a Deployment, StatefulSet, or
// DaemonSet by patching the pod-template annotation (kubectl rollout restart
// semantics). Jobs cannot be restarted this way; callers get ErrBadRequest.
func (b *KubeBackend) RestartWorkload(ctx context.Context, clusterID, workloadID string) error {
	if clusterID != "" && clusterID != b.profile.ID {
		return api.ErrNotFound
	}
	kind, namespace, name, err := parseWorkloadID(workloadID)
	if err != nil {
		return err
	}
	resource, ok := restartResourceFor(kind)
	if !ok {
		return fmt.Errorf("%w: kind %q cannot be restarted", api.ErrBadRequest, kind)
	}

	path := fmt.Sprintf("/apis/apps/v1/namespaces/%s/%s/%s", namespace, resource, name)
	ts := time.Now().UTC().Format(time.RFC3339)
	body := []byte(fmt.Sprintf(
		`{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":%q}}}}}`,
		ts,
	))
	_, err = b.client.Patch(ctx, path, "application/strategic-merge-patch+json", body)
	if err != nil {
		return fmt.Errorf("restart %s %s/%s: %w", kind, namespace, name, mutationErr(err))
	}
	return nil
}

// CordonNode patches a node's spec.unschedulable field (kubectl cordon /
// uncordon semantics). Pass unschedulable=true to cordon, false to uncordon.
func (b *KubeBackend) CordonNode(ctx context.Context, clusterID, nodeID string, unschedulable bool) error {
	if clusterID != "" && clusterID != b.profile.ID {
		return api.ErrNotFound
	}
	if nodeID == "" {
		return fmt.Errorf("%w: nodeID is required", api.ErrBadRequest)
	}
	path := fmt.Sprintf("/api/v1/nodes/%s", nodeID)
	body := []byte(fmt.Sprintf(`{"spec":{"unschedulable":%t}}`, unschedulable))
	_, err := b.client.Patch(ctx, path, "application/merge-patch+json", body)
	if err != nil {
		return fmt.Errorf("cordon node %s: %w", nodeID, mutationErr(err))
	}
	return nil
}

func restartResourceFor(kind string) (string, bool) {
	switch kind {
	case workloadKindDeployment:
		return "deployments", true
	case workloadKindStatefulSet:
		return "statefulsets", true
	case workloadKindDaemonSet:
		return "daemonsets", true
	default:
		return "", false
	}
}

// parseWorkloadID splits "{kind}:{namespace}/{name}" back into its parts.
// Returns api.ErrBadRequest for any malformation so handlers map to 400.
func parseWorkloadID(id string) (kind, namespace, name string, err error) {
	colon := strings.IndexByte(id, ':')
	slash := strings.IndexByte(id, '/')
	if colon <= 0 || slash <= colon+1 || slash == len(id)-1 {
		return "", "", "", fmt.Errorf("%w: workloadID %q must be kind:namespace/name", api.ErrBadRequest, id)
	}
	return id[:colon], id[colon+1 : slash], id[slash+1:], nil
}

// kubernetesKind maps the mobile-side workload kind strings back to the
// Kubernetes API kind value used in fieldSelector (involvedObject.kind).
func kubernetesKind(kind string) string {
	switch kind {
	case workloadKindDeployment:
		return "Deployment"
	case workloadKindDaemonSet:
		return "DaemonSet"
	case workloadKindStatefulSet:
		return "StatefulSet"
	case workloadKindJob:
		return "Job"
	case "node":
		return "Node"
	case "service":
		return "Service"
	case "pod":
		return "Pod"
	default:
		// Preserve PascalCase inputs (e.g. "Deployment") untouched.
		return kind
	}
}

// sentinelError tags a backend error with an api sentinel so handlers map it
// to the right HTTP status, while Error() keeps the original short message.
type sentinelError struct {
	sentinel error
	err      error
}

func (e *sentinelError) Error() string   { return e.err.Error() }
func (e *sentinelError) Unwrap() []error { return []error{e.sentinel, e.err} }

// mutationErr maps an apiserver 404 to api.ErrNotFound and 400/422 to
// api.ErrBadRequest for the mutation methods; anything else passes through
// (and surfaces as a 502).
func mutationErr(err error) error {
	var se *StatusError
	if !errors.As(err, &se) {
		return err
	}
	switch se.Code {
	case http.StatusNotFound:
		return &sentinelError{api.ErrNotFound, err}
	case http.StatusBadRequest, http.StatusUnprocessableEntity:
		return &sentinelError{api.ErrBadRequest, err}
	}
	return err
}
