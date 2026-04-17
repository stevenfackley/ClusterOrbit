package api

import (
	"testing"
	"time"
)

func TestRateLimiterAllowsWithinBurst(t *testing.T) {
	rl := NewRateLimiter(1, 3)
	for i := 0; i < 3; i++ {
		if !rl.Allow("k") {
			t.Fatalf("request %d denied, want allow", i)
		}
	}
	if rl.Allow("k") {
		t.Fatalf("4th request allowed, want deny")
	}
}

func TestRateLimiterRefills(t *testing.T) {
	rl := NewRateLimiter(10, 1) // 10 rps, burst 1
	base := time.Unix(0, 0)
	rl.now = func() time.Time { return base }

	if !rl.Allow("k") {
		t.Fatalf("first allow denied")
	}
	if rl.Allow("k") {
		t.Fatalf("second allow passed, want deny")
	}
	// 200 ms later → 2 tokens refilled (capacity caps at 1).
	rl.now = func() time.Time { return base.Add(200 * time.Millisecond) }
	if !rl.Allow("k") {
		t.Fatalf("post-refill allow denied")
	}
}

func TestRateLimiterKeysAreIndependent(t *testing.T) {
	rl := NewRateLimiter(1, 1)
	if !rl.Allow("a") || !rl.Allow("b") {
		t.Fatalf("independent keys should each have their own bucket")
	}
	if rl.Allow("a") {
		t.Fatalf("key a second call should be denied")
	}
}

func TestRateLimiterNilIsPermissive(t *testing.T) {
	var rl *RateLimiter
	if !rl.Allow("k") {
		t.Fatalf("nil limiter should allow")
	}
}

func TestNewRateLimiterZeroReturnsNil(t *testing.T) {
	if NewRateLimiter(0, 5) != nil {
		t.Fatalf("rps=0 should disable limiter (nil)")
	}
	if NewRateLimiter(5, 0) != nil {
		t.Fatalf("burst=0 should disable limiter (nil)")
	}
}
