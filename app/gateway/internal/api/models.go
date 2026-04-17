// Package api defines the JSON wire shapes the gateway exposes and the HTTP
// handlers that serve them. The field tags here must stay in lock-step with
// the Dart domain model in app/mobile/lib/core/cluster_domain/cluster_models.dart
// — changing either side without the other will break clients silently.
package api

// ClusterProfile is the gateway-facing identity of a cluster.
type ClusterProfile struct {
	ID               string `json:"id"`
	Name             string `json:"name"`
	APIServerHost    string `json:"apiServerHost"`
	EnvironmentLabel string `json:"environmentLabel"`
	ConnectionMode   string `json:"connectionMode"`
}

type ClusterNode struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Role           string `json:"role"`
	Version        string `json:"version"`
	Zone           string `json:"zone"`
	PodCount       int    `json:"podCount"`
	Schedulable    bool   `json:"schedulable"`
	Health         string `json:"health"`
	CPUCapacity    string `json:"cpuCapacity"`
	MemoryCapacity string `json:"memoryCapacity"`
	OSImage        string `json:"osImage"`
}

type ClusterWorkload struct {
	ID              string   `json:"id"`
	Namespace       string   `json:"namespace"`
	Name            string   `json:"name"`
	Kind            string   `json:"kind"`
	DesiredReplicas int      `json:"desiredReplicas"`
	ReadyReplicas   int      `json:"readyReplicas"`
	NodeIDs         []string `json:"nodeIds"`
	Health          string   `json:"health"`
	Images          []string `json:"images"`
}

type ServicePort struct {
	Port       int     `json:"port"`
	TargetPort int     `json:"targetPort"`
	Protocol   string  `json:"protocol"`
	Name       *string `json:"name"`
}

type ClusterService struct {
	ID                string        `json:"id"`
	Namespace         string        `json:"namespace"`
	Name              string        `json:"name"`
	Exposure          string        `json:"exposure"`
	TargetWorkloadIDs []string      `json:"targetWorkloadIds"`
	Ports             []ServicePort `json:"ports"`
	Health            string        `json:"health"`
	ClusterIP         *string       `json:"clusterIp"`
}

type ClusterAlert struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Summary string `json:"summary"`
	Level   string `json:"level"`
	Scope   string `json:"scope"`
}

type TopologyLink struct {
	SourceID string  `json:"sourceId"`
	TargetID string  `json:"targetId"`
	Kind     string  `json:"kind"`
	Label    *string `json:"label"`
}

type ClusterSnapshot struct {
	Profile     ClusterProfile    `json:"profile"`
	GeneratedAt int64             `json:"generatedAt"`
	Nodes       []ClusterNode     `json:"nodes"`
	Workloads   []ClusterWorkload `json:"workloads"`
	Services    []ClusterService  `json:"services"`
	Alerts      []ClusterAlert    `json:"alerts"`
	Links       []TopologyLink    `json:"links"`
}

type ClusterEvent struct {
	Type            string  `json:"type"`
	Reason          string  `json:"reason"`
	Message         string  `json:"message"`
	LastTimestamp   int64   `json:"lastTimestamp"`
	Count           int     `json:"count"`
	SourceComponent *string `json:"sourceComponent"`
}
