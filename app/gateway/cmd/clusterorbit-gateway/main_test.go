package main

import (
	"slices"
	"testing"

	"github.com/stevenfackley/clusterorbit/app/gateway/internal/api"
)

// mapEnv is a getenv backed by a map, so env parsing is testable without
// touching the process environment.
func mapEnv(env map[string]string) func(string) string {
	return func(key string) string { return env[key] }
}

func TestCollectTokens(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want []string
	}{
		{"none", nil, nil},
		{"single", map[string]string{"CLUSTERORBIT_GATEWAY_TOKEN": " a "}, []string{"a"}},
		{
			"merged and deduped",
			map[string]string{
				"CLUSTERORBIT_GATEWAY_TOKEN":  "a",
				"CLUSTERORBIT_GATEWAY_TOKENS": "b, a,,b ,c",
			},
			[]string{"a", "b", "c"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := collectTokens(mapEnv(tc.env)); !slices.Equal(got, tc.want) {
				t.Fatalf("collectTokens = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestBuildApprovalPolicy(t *testing.T) {
	two := []string{"a", "b"}
	cases := []struct {
		name      string
		env       map[string]string
		tokens    []string
		wantOps   []string // ops Requires reports; nil == approval off
		wantLabel string
		wantErr   bool
	}{
		{name: "unset is off", tokens: two, wantLabel: "off"},
		{
			name:      "ops are case-insensitive and deduped",
			env:       map[string]string{"CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL": "Drain, SCALE,drain"},
			tokens:    two,
			wantOps:   []string{api.OpDrain, api.OpScale},
			wantLabel: "ops=2 ttl=15m0s",
		},
		{
			name: "custom ttl",
			env: map[string]string{
				"CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL": "cordon",
				"CLUSTERORBIT_GATEWAY_POLICY_APPROVAL_TTL":     "5m",
			},
			tokens:    two,
			wantOps:   []string{api.OpCordon, api.OpDrain}, // cordon gates drain too
			wantLabel: "ops=1 ttl=5m0s",
		},
		{
			name:    "unknown op",
			env:     map[string]string{"CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL": "drian"},
			tokens:  two,
			wantErr: true,
		},
		{
			name:    "one token",
			env:     map[string]string{"CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL": "drain"},
			tokens:  []string{"a"},
			wantErr: true,
		},
		{
			name: "unparsable ttl",
			env: map[string]string{
				"CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL": "drain",
				"CLUSTERORBIT_GATEWAY_POLICY_APPROVAL_TTL":     "15",
			},
			tokens:  two,
			wantErr: true,
		},
		{
			name: "non-positive ttl",
			env: map[string]string{
				"CLUSTERORBIT_GATEWAY_POLICY_REQUIRE_APPROVAL": "drain",
				"CLUSTERORBIT_GATEWAY_POLICY_APPROVAL_TTL":     "-1m",
			},
			tokens:  two,
			wantErr: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store, label, err := buildApprovalPolicy(mapEnv(tc.env), tc.tokens)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got store %+v", store)
				}
				return
			}
			if err != nil {
				t.Fatalf("buildApprovalPolicy: %v", err)
			}
			if label != tc.wantLabel {
				t.Fatalf("label = %q, want %q", label, tc.wantLabel)
			}
			if tc.wantOps == nil {
				if store != nil {
					t.Fatalf("expected no approval store, got %+v", store)
				}
				return
			}
			for _, op := range []string{api.OpScale, api.OpRestart, api.OpCordon, api.OpDrain} {
				if got, want := store.Requires(op), slices.Contains(tc.wantOps, op); got != want {
					t.Fatalf("Requires(%q) = %v, want %v", op, got, want)
				}
			}
		})
	}
}

func TestBuildScalePolicy(t *testing.T) {
	cases := []struct {
		name    string
		env     map[string]string
		want    *api.ScalePolicy
		wantErr bool
	}{
		{name: "unset is off"},
		{
			name: "max and namespaces",
			env: map[string]string{
				"CLUSTERORBIT_GATEWAY_POLICY_MAX_REPLICAS": " 5 ",
				"CLUSTERORBIT_GATEWAY_POLICY_NAMESPACES":   "a, b",
			},
			want: &api.ScalePolicy{MaxReplicas: 5, AllowedNamespaces: []string{"a", "b"}},
		},
		{name: "unparsable max", env: map[string]string{"CLUSTERORBIT_GATEWAY_POLICY_MAX_REPLICAS": "five"}, wantErr: true},
		{name: "negative max", env: map[string]string{"CLUSTERORBIT_GATEWAY_POLICY_MAX_REPLICAS": "-1"}, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, _, err := buildScalePolicy(mapEnv(tc.env))
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if (got == nil) != (tc.want == nil) ||
				got != nil && (got.MaxReplicas != tc.want.MaxReplicas || !slices.Equal(got.AllowedNamespaces, tc.want.AllowedNamespaces)) {
				t.Fatalf("policy = %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestBuildNodePolicy(t *testing.T) {
	cases := []struct {
		name             string
		env              map[string]string
		wantPolicy       bool
		wantDisableDrain bool
		wantErr          bool
	}{
		{name: "unset is off"},
		{name: "explicit false is off", env: map[string]string{"CLUSTERORBIT_GATEWAY_POLICY_DISABLE_DRAIN": "false"}},
		{
			name:             "disable drain",
			env:              map[string]string{"CLUSTERORBIT_GATEWAY_POLICY_DISABLE_DRAIN": "TRUE"},
			wantPolicy:       true,
			wantDisableDrain: true,
		},
		{name: "protected nodes", env: map[string]string{"CLUSTERORBIT_GATEWAY_POLICY_PROTECTED_NODES": "cp-1"}, wantPolicy: true},
		{name: "typo in disable drain", env: map[string]string{"CLUSTERORBIT_GATEWAY_POLICY_DISABLE_DRAIN": "ture"}, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, _, err := buildNodePolicy(mapEnv(tc.env))
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if (got != nil) != tc.wantPolicy || got != nil && got.DisableDrain != tc.wantDisableDrain {
				t.Fatalf("policy = %+v", got)
			}
		})
	}
}

func TestBuildLimiter(t *testing.T) {
	cases := []struct {
		name    string
		env     map[string]string
		wantOn  bool
		wantErr bool
	}{
		{name: "unset is off"},
		{
			name:   "rps and burst",
			env:    map[string]string{"CLUSTERORBIT_GATEWAY_RATE_LIMIT_RPS": "5", "CLUSTERORBIT_GATEWAY_RATE_LIMIT_BURST": "10"},
			wantOn: true,
		},
		{
			name:    "unparsable rps",
			env:     map[string]string{"CLUSTERORBIT_GATEWAY_RATE_LIMIT_RPS": "fast", "CLUSTERORBIT_GATEWAY_RATE_LIMIT_BURST": "10"},
			wantErr: true,
		},
		{
			name:    "NaN burst",
			env:     map[string]string{"CLUSTERORBIT_GATEWAY_RATE_LIMIT_RPS": "5", "CLUSTERORBIT_GATEWAY_RATE_LIMIT_BURST": "NaN"},
			wantErr: true,
		},
		{name: "rps without burst", env: map[string]string{"CLUSTERORBIT_GATEWAY_RATE_LIMIT_RPS": "5"}, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := buildLimiter(mapEnv(tc.env))
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if (got != nil) != tc.wantOn {
				t.Fatalf("limiter on = %v, want %v", got != nil, tc.wantOn)
			}
		})
	}
}
