package kubebackend

import (
	"context"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
	"github.com/stevenfackley/clusterorbit/app/gateway/internal/kubeconfig"
)

// MultiClusterBackend fans api.ClusterBackend requests out to a per-cluster
// KubeBackend. Clusters are keyed by profile ID (context name). Empty set
// returns ErrNotFound on every lookup; callers should fall back to sample
// data upstream if zero contexts resolve.
type MultiClusterBackend struct {
	backends map[string]*KubeBackend
	profiles []api.ClusterProfile
}

// NewMultiClusterBackend builds a backend per resolved cluster. Any single
// cluster failing client init is skipped with the error returned alongside so
// the caller can log it. Returns a backend with whatever succeeded, plus the
// per-cluster errors.
func NewMultiClusterBackend(clusters []*kubeconfig.ResolvedCluster) (*MultiClusterBackend, []error) {
	m := &MultiClusterBackend{
		backends: map[string]*KubeBackend{},
	}
	var errs []error
	for _, c := range clusters {
		kb, err := NewKubeBackend(c)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		m.backends[kb.profile.ID] = kb
		m.profiles = append(m.profiles, kb.profile)
	}
	return m, errs
}

// Len reports the number of successfully registered clusters. Useful for
// deciding whether to fall back to sample data.
func (m *MultiClusterBackend) Len() int { return len(m.backends) }

func (m *MultiClusterBackend) ListClusters(_ context.Context) ([]api.ClusterProfile, error) {
	// Return a copy so callers can't mutate our slice.
	out := make([]api.ClusterProfile, len(m.profiles))
	copy(out, m.profiles)
	return out, nil
}

func (m *MultiClusterBackend) LoadSnapshot(ctx context.Context, clusterID string) (api.ClusterSnapshot, error) {
	kb, ok := m.backends[clusterID]
	if !ok {
		return api.ClusterSnapshot{}, api.ErrNotFound
	}
	return kb.LoadSnapshot(ctx, clusterID)
}

func (m *MultiClusterBackend) LoadEvents(
	ctx context.Context,
	clusterID, kind, objectName, namespace string,
	limit int,
) ([]api.ClusterEvent, error) {
	kb, ok := m.backends[clusterID]
	if !ok {
		return nil, api.ErrNotFound
	}
	return kb.LoadEvents(ctx, clusterID, kind, objectName, namespace, limit)
}

func (m *MultiClusterBackend) ScaleWorkload(
	ctx context.Context,
	clusterID, workloadID string,
	replicas int,
) error {
	kb, ok := m.backends[clusterID]
	if !ok {
		return api.ErrNotFound
	}
	return kb.ScaleWorkload(ctx, clusterID, workloadID, replicas)
}
