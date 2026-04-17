package kubebackend

import (
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
)

// This file mirrors the transformation logic in
// app/mobile/lib/core/connectivity/kubernetes_snapshot_loader.dart.
// Wire-format fields use the same names as the Dart ClusterSnapshot model so
// the gateway JSON contract is identical regardless of backend.

// workloadKindDeployment / etc. mirror the Dart WorkloadKind enum.
const (
	workloadKindDeployment  = "deployment"
	workloadKindDaemonSet   = "daemonSet"
	workloadKindStatefulSet = "statefulSet"
	workloadKindJob         = "job"
)

// health levels mirror the Dart ClusterHealthLevel enum (lowercase name()).
const (
	healthHealthy  = "healthy"
	healthWarning  = "warning"
	healthCritical = "critical"
)

// listItems returns the `items` array of a Kubernetes list response.
func listItems(response map[string]any) []map[string]any {
	raw, ok := response["items"].([]any)
	if !ok {
		return nil
	}
	out := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		if m, ok := item.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func stringAt(src map[string]any, path ...string) string {
	v := valueAt(src, path)
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func boolAt(src map[string]any, path ...string) bool {
	v := valueAt(src, path)
	if b, ok := v.(bool); ok {
		return b
	}
	return false
}

func intAt(src map[string]any, path ...string) int {
	v := valueAt(src, path)
	switch x := v.(type) {
	case float64:
		return int(x)
	case int:
		return x
	case string:
		if n, err := strconv.Atoi(x); err == nil {
			return n
		}
	}
	return 0
}

func mapAt(src map[string]any, path ...string) map[string]string {
	v := valueAt(src, path)
	m, ok := v.(map[string]any)
	if !ok {
		return nil
	}
	out := make(map[string]string, len(m))
	for k, val := range m {
		out[k] = toString(val)
	}
	return out
}

func listAt(src map[string]any, path ...string) []any {
	v := valueAt(src, path)
	if l, ok := v.([]any); ok {
		return l
	}
	return nil
}

func valueAt(src map[string]any, path []string) any {
	var cur any = src
	for _, seg := range path {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = m[seg]
	}
	return cur
}

func toString(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case nil:
		return ""
	default:
		return ""
	}
}

func resourceKey(namespace, name string) string {
	return namespace + "/" + name
}

func resourceID(prefix, namespace, name string) string {
	return prefix + ":" + namespace + "/" + name
}

func workloadID(kind, namespace, name string) string {
	return resourceID(kind, namespace, name)
}

// transformSnapshot builds a ClusterSnapshot from raw Kubernetes API list
// responses. Mirrors the Dart transformation 1:1 for the entities supported
// here (nodes, pods, services, deployments, daemonsets, statefulsets, jobs,
// replicasets).
func transformSnapshot(
	profile api.ClusterProfile,
	generatedAt time.Time,
	nodes, pods, services, deployments, daemonSets, statefulSets, jobs, replicaSets map[string]any,
) api.ClusterSnapshot {
	nodeItems := listItems(nodes)
	podItems := listItems(pods)
	serviceItems := listItems(services)
	deploymentItems := listItems(deployments)
	daemonSetItems := listItems(daemonSets)
	statefulSetItems := listItems(statefulSets)
	jobItems := listItems(jobs)
	replicaSetItems := listItems(replicaSets)

	nodePodCounts := map[string]int{}
	replicaSetOwners := replicaSetOwnerMap(replicaSetItems)
	podWorkloadIDs := map[string]string{}
	workloadNodeIDs := map[string]map[string]struct{}{}
	workloadHealthSignals := map[string]string{}

	for _, pod := range podItems {
		if nodeName := stringAt(pod, "spec", "nodeName"); nodeName != "" {
			nodePodCounts[nodeName]++
		}

		wid := workloadIDForPod(pod, replicaSetOwners)
		if wid == "" {
			continue
		}

		namespace := stringAt(pod, "metadata", "namespace")
		if namespace == "" {
			namespace = "default"
		}
		name := stringAt(pod, "metadata", "name")
		if name == "" {
			name = wid
		}
		podWorkloadIDs[resourceKey(namespace, name)] = wid

		if nodeName := stringAt(pod, "spec", "nodeName"); nodeName != "" {
			if _, ok := workloadNodeIDs[wid]; !ok {
				workloadNodeIDs[wid] = map[string]struct{}{}
			}
			workloadNodeIDs[wid][nodeName] = struct{}{}
		}

		phase := strings.ToLower(stringAt(pod, "status", "phase"))
		containerStatuses := listAt(pod, "status", "containerStatuses")
		hasRestart := false
		for _, cs := range containerStatuses {
			m, ok := cs.(map[string]any)
			if !ok {
				continue
			}
			if intAt(m, "restartCount") > 0 ||
				stringAt(m, "state", "waiting", "reason") == "CrashLoopBackOff" {
				hasRestart = true
				break
			}
		}

		var signal string
		switch phase {
		case "running", "succeeded":
			if hasRestart {
				signal = healthWarning
			} else {
				signal = healthHealthy
			}
		case "pending":
			signal = healthWarning
		default:
			signal = healthCritical
		}

		workloadHealthSignals[wid] = maxHealth(workloadHealthSignals[wid], signal)
	}

	nodesOut := make([]api.ClusterNode, 0, len(nodeItems))
	for _, item := range nodeItems {
		nodesOut = append(nodesOut, nodeFromItem(item, nodePodCounts))
	}

	var workloads []api.ClusterWorkload
	workloads = append(workloads, workloadsFromItems(deploymentItems, workloadKindDeployment, workloadNodeIDs, workloadHealthSignals)...)
	workloads = append(workloads, workloadsFromItems(daemonSetItems, workloadKindDaemonSet, workloadNodeIDs, workloadHealthSignals)...)
	workloads = append(workloads, workloadsFromItems(statefulSetItems, workloadKindStatefulSet, workloadNodeIDs, workloadHealthSignals)...)
	workloads = append(workloads, workloadsFromItems(jobItems, workloadKindJob, workloadNodeIDs, workloadHealthSignals)...)

	workloadsByID := make(map[string]api.ClusterWorkload, len(workloads))
	for _, w := range workloads {
		workloadsByID[w.ID] = w
	}
	podLabelsByWorkload := podLabelsByWorkloadMap(podItems, podWorkloadIDs)

	servicesOut := make([]api.ClusterService, 0, len(serviceItems))
	for _, item := range serviceItems {
		servicesOut = append(servicesOut, serviceFromItem(item, workloadsByID, podLabelsByWorkload))
	}

	alerts := []api.ClusterAlert{}
	alerts = append(alerts, nodeAlerts(nodesOut)...)
	alerts = append(alerts, workloadAlerts(workloads)...)
	alerts = append(alerts, serviceAlerts(servicesOut)...)

	links := []api.TopologyLink{}
	for _, w := range workloads {
		for _, nodeID := range w.NodeIDs {
			links = append(links, api.TopologyLink{
				SourceID: nodeID,
				TargetID: w.ID,
				Kind:     "workload",
			})
		}
	}
	for _, s := range servicesOut {
		for _, wid := range s.TargetWorkloadIDs {
			links = append(links, api.TopologyLink{
				SourceID: s.ID,
				TargetID: wid,
				Kind:     "service",
				Label:    serviceExposureLabel(s.Exposure),
			})
		}
	}

	return api.ClusterSnapshot{
		Profile:     profile,
		GeneratedAt: generatedAt.UnixMilli(),
		Nodes:       nodesOut,
		Workloads:   workloads,
		Services:    servicesOut,
		Alerts:      alerts,
		Links:       links,
	}
}

func replicaSetOwnerMap(items []map[string]any) map[string]string {
	owners := map[string]string{}
	for _, rs := range items {
		namespace := stringAt(rs, "metadata", "namespace")
		name := stringAt(rs, "metadata", "name")
		if namespace == "" || name == "" {
			continue
		}
		for _, ref := range listAt(rs, "metadata", "ownerReferences") {
			m, ok := ref.(map[string]any)
			if !ok {
				continue
			}
			if stringAt(m, "kind") != "Deployment" {
				continue
			}
			depName := stringAt(m, "name")
			if depName == "" {
				continue
			}
			owners[resourceKey(namespace, name)] = workloadID(workloadKindDeployment, namespace, depName)
			break
		}
	}
	return owners
}

func workloadIDForPod(pod map[string]any, replicaSetOwners map[string]string) string {
	namespace := stringAt(pod, "metadata", "namespace")
	if namespace == "" {
		return ""
	}
	for _, ref := range listAt(pod, "metadata", "ownerReferences") {
		m, ok := ref.(map[string]any)
		if !ok {
			continue
		}
		kind := stringAt(m, "kind")
		name := stringAt(m, "name")
		if name == "" {
			continue
		}
		switch kind {
		case "ReplicaSet":
			return replicaSetOwners[resourceKey(namespace, name)]
		case "DaemonSet":
			return workloadID(workloadKindDaemonSet, namespace, name)
		case "StatefulSet":
			return workloadID(workloadKindStatefulSet, namespace, name)
		case "Job":
			return workloadID(workloadKindJob, namespace, name)
		}
	}
	return ""
}

func podLabelsByWorkloadMap(pods []map[string]any, podWorkloadIDs map[string]string) map[string][]map[string]string {
	out := map[string][]map[string]string{}
	for _, pod := range pods {
		namespace := stringAt(pod, "metadata", "namespace")
		name := stringAt(pod, "metadata", "name")
		if namespace == "" || name == "" {
			continue
		}
		wid, ok := podWorkloadIDs[resourceKey(namespace, name)]
		if !ok {
			continue
		}
		labels := mapAt(pod, "metadata", "labels")
		if labels == nil {
			labels = map[string]string{}
		}
		out[wid] = append(out[wid], labels)
	}
	return out
}

func nodeFromItem(item map[string]any, podCounts map[string]int) api.ClusterNode {
	name := stringAt(item, "metadata", "name")
	if name == "" {
		name = "unknown-node"
	}
	labels := mapAt(item, "metadata", "labels")
	conditions := listAt(item, "status", "conditions")
	ready := false
	pressure := false
	for _, c := range conditions {
		m, ok := c.(map[string]any)
		if !ok {
			continue
		}
		ctype := stringAt(m, "type")
		status := stringAt(m, "status")
		if ctype == "Ready" && status == "True" {
			ready = true
		}
		if strings.Contains(ctype, "Pressure") && status == "True" {
			pressure = true
		}
	}
	unschedulable := boolAt(item, "spec", "unschedulable")
	schedulable := !unschedulable

	var health string
	switch {
	case !ready:
		health = healthCritical
	case pressure || !schedulable:
		health = healthWarning
	default:
		health = healthHealthy
	}

	role := "worker"
	if _, ok := labels["node-role.kubernetes.io/control-plane"]; ok {
		role = "controlPlane"
	} else if _, ok := labels["node-role.kubernetes.io/master"]; ok {
		role = "controlPlane"
	}

	zone := labels["topology.kubernetes.io/zone"]
	if zone == "" {
		zone = labels["failure-domain.beta.kubernetes.io/zone"]
	}
	if zone == "" {
		zone = "unassigned"
	}

	return api.ClusterNode{
		ID:             name,
		Name:           name,
		Role:           role,
		Version:        orDefault(stringAt(item, "status", "nodeInfo", "kubeletVersion"), "unknown"),
		Zone:           zone,
		PodCount:       podCounts[name],
		Schedulable:    schedulable,
		Health:         health,
		CPUCapacity:    orDefault(stringAt(item, "status", "capacity", "cpu"), "unknown"),
		MemoryCapacity: orDefault(stringAt(item, "status", "capacity", "memory"), "unknown"),
		OSImage:        orDefault(stringAt(item, "status", "nodeInfo", "osImage"), "unknown"),
	}
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func workloadsFromItems(
	items []map[string]any,
	kind string,
	nodeIDs map[string]map[string]struct{},
	healthSignals map[string]string,
) []api.ClusterWorkload {
	out := make([]api.ClusterWorkload, 0, len(items))
	for _, item := range items {
		namespace := stringAt(item, "metadata", "namespace")
		if namespace == "" {
			namespace = "default"
		}
		name := stringAt(item, "metadata", "name")
		if name == "" {
			name = "unknown"
		}
		wid := workloadID(kind, namespace, name)

		var desired, ready int
		switch kind {
		case workloadKindDeployment, workloadKindStatefulSet:
			desired = intAt(item, "spec", "replicas")
			ready = intAt(item, "status", "readyReplicas")
		case workloadKindDaemonSet:
			desired = intAt(item, "status", "desiredNumberScheduled")
			ready = intAt(item, "status", "numberReady")
		case workloadKindJob:
			desired = intAt(item, "spec", "completions")
			ready = intAt(item, "status", "succeeded")
			if desired == 0 {
				if intAt(item, "status", "active") > 0 {
					desired = 1
				} else {
					desired = ready
				}
			}
		}

		var health string
		if ready < desired {
			health = healthWarning
		} else if signal := healthSignals[wid]; signal != "" {
			health = signal
		} else {
			health = healthHealthy
		}

		ids := make([]string, 0, len(nodeIDs[wid]))
		for id := range nodeIDs[wid] {
			ids = append(ids, id)
		}
		sort.Strings(ids)

		containers := listAt(item, "spec", "template", "spec", "containers")
		images := make([]string, 0, len(containers))
		for _, c := range containers {
			m, ok := c.(map[string]any)
			if !ok {
				continue
			}
			if img := stringAt(m, "image"); img != "" {
				images = append(images, img)
			}
		}

		out = append(out, api.ClusterWorkload{
			ID:              wid,
			Namespace:       namespace,
			Name:            name,
			Kind:            kind,
			DesiredReplicas: desired,
			ReadyReplicas:   ready,
			NodeIDs:         ids,
			Health:          health,
			Images:          images,
		})
	}
	return out
}

func serviceFromItem(
	item map[string]any,
	workloadsByID map[string]api.ClusterWorkload,
	podLabelsByWorkload map[string][]map[string]string,
) api.ClusterService {
	namespace := stringAt(item, "metadata", "namespace")
	if namespace == "" {
		namespace = "default"
	}
	name := stringAt(item, "metadata", "name")
	if name == "" {
		name = "unknown-service"
	}
	selector := mapAt(item, "spec", "selector")

	var targets []string
	if len(selector) > 0 {
		for wid := range workloadsByID {
			if matchesSelector(selector, podLabelsByWorkload[wid]) {
				targets = append(targets, wid)
			}
		}
		sort.Strings(targets)
	}

	ports := []api.ServicePort{}
	for _, p := range listAt(item, "spec", "ports") {
		m, ok := p.(map[string]any)
		if !ok {
			continue
		}
		ports = append(ports, api.ServicePort{
			Name:       stringPtr(stringAt(m, "name")),
			Port:       intAt(m, "port"),
			TargetPort: targetPort(m["targetPort"]),
			Protocol:   orDefault(stringAt(m, "protocol"), "TCP"),
		})
	}

	exposure := serviceExposure(item)
	health := healthHealthy
	if len(targets) == 0 {
		health = healthWarning
	}

	var clusterIP *string
	if ip := stringAt(item, "spec", "clusterIP"); ip != "" && ip != "None" {
		clusterIP = &ip
	}

	return api.ClusterService{
		ID:                resourceID("service", namespace, name),
		Namespace:         namespace,
		Name:              name,
		Exposure:          exposure,
		TargetWorkloadIDs: targets,
		Ports:             ports,
		Health:            health,
		ClusterIP:         clusterIP,
	}
}

func targetPort(v any) int {
	switch x := v.(type) {
	case float64:
		return int(x)
	case int:
		return x
	case string:
		if n, err := strconv.Atoi(x); err == nil {
			return n
		}
	}
	return 0
}

func matchesSelector(selector map[string]string, podLabels []map[string]string) bool {
	for _, labels := range podLabels {
		match := true
		for k, v := range selector {
			if labels[k] != v {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

func serviceExposure(item map[string]any) string {
	switch stringAt(item, "spec", "type") {
	case "NodePort":
		return "nodePort"
	case "LoadBalancer":
		return "loadBalancer"
	case "ExternalName":
		return "ingress"
	default:
		return "clusterIp"
	}
}

func serviceExposureLabel(exposure string) *string {
	var label string
	switch exposure {
	case "clusterIp":
		label = "ClusterIP"
	case "nodePort":
		label = "NodePort"
	case "loadBalancer":
		label = "LoadBalancer"
	case "ingress":
		label = "Ingress"
	default:
		return nil
	}
	return &label
}

func maxHealth(current, next string) string {
	if current == "" {
		return next
	}
	if current == healthCritical || next == healthCritical {
		return healthCritical
	}
	if current == healthWarning || next == healthWarning {
		return healthWarning
	}
	return healthHealthy
}

func nodeAlerts(nodes []api.ClusterNode) []api.ClusterAlert {
	var out []api.ClusterAlert
	for _, n := range nodes {
		switch {
		case n.Health == healthCritical:
			out = append(out, api.ClusterAlert{
				ID:      "node-critical-" + n.ID,
				Title:   "Node not ready",
				Summary: n.Name + " is reporting an unhealthy ready condition.",
				Level:   healthCritical,
				Scope:   "Node health",
			})
		case !n.Schedulable:
			out = append(out, api.ClusterAlert{
				ID:      "node-drain-" + n.ID,
				Title:   "Node unschedulable",
				Summary: n.Name + " is cordoned or draining.",
				Level:   healthWarning,
				Scope:   "Node lifecycle",
			})
		case n.Health == healthWarning:
			out = append(out, api.ClusterAlert{
				ID:      "node-warning-" + n.ID,
				Title:   "Node pressure detected",
				Summary: n.Name + " is healthy but reporting pressure conditions.",
				Level:   healthWarning,
				Scope:   "Node health",
			})
		}
	}
	return out
}

func workloadAlerts(workloads []api.ClusterWorkload) []api.ClusterAlert {
	var out []api.ClusterAlert
	for _, w := range workloads {
		if w.ReadyReplicas < w.DesiredReplicas {
			out = append(out, api.ClusterAlert{
				ID:      "workload-" + w.ID,
				Title:   "Replica skew detected",
				Summary: w.Name + " is at " + itoa(w.ReadyReplicas) + "/" + itoa(w.DesiredReplicas) + " ready replicas.",
				Level:   healthWarning,
				Scope:   "Workload health",
			})
		}
	}
	return out
}

func serviceAlerts(services []api.ClusterService) []api.ClusterAlert {
	var out []api.ClusterAlert
	for _, s := range services {
		if len(s.TargetWorkloadIDs) == 0 {
			out = append(out, api.ClusterAlert{
				ID:      "service-" + s.ID,
				Title:   "Service has no backing workloads",
				Summary: s.Name + " does not currently match any discovered workload pods.",
				Level:   healthWarning,
				Scope:   "Service routing",
			})
		}
	}
	return out
}

func itoa(n int) string { return strconv.Itoa(n) }

func stringPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// parseTimestamp parses a Kubernetes RFC3339 timestamp. Returns zero
// time on failure so the caller can decide whether to skip the event.
func parseTimestamp(v any) time.Time {
	s, ok := v.(string)
	if !ok || s == "" {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return t.UTC()
}
