package api

import (
	"math"
	"sync"
	"time"
)

// RateLimiter is a token-bucket limiter keyed by an opaque string. It is
// deliberately simple: no external deps, O(1) per request, a periodic eviction
// prevents unbounded growth. Suitable for a single-process gateway; a
// horizontally-scaled deployment would need a shared store (redis, etc).
type RateLimiter struct {
	mu       sync.Mutex
	buckets  map[string]*bucket
	rate     float64 // tokens per second
	capacity float64 // burst size
	now      func() time.Time
	// evictAfter: prune buckets unused for this long on each Allow call.
	evictAfter time.Duration
	lastEvict  time.Time
	// maxBuckets caps memory. When the map hits this, we force an eviction
	// pass regardless of the time-based schedule; if it's still over we drop
	// the oldest bucket. Prevents unbounded growth from adversarial keys.
	maxBuckets int
}

// defaultMaxBuckets bounds memory for the rate-limiter map. ~10 KiB per
// entry order-of-magnitude, so 10k = ~100 MiB worst case.
const defaultMaxBuckets = 10_000

type bucket struct {
	tokens   float64
	lastSeen time.Time
}

// NewRateLimiter builds a limiter that allows `rps` requests per second with
// the given `burst` capacity. Zero/negative values disable the limiter (Allow
// always returns true).
func NewRateLimiter(rps, burst float64) *RateLimiter {
	if rps <= 0 || burst <= 0 {
		return nil
	}
	return &RateLimiter{
		buckets:    map[string]*bucket{},
		rate:       rps,
		capacity:   burst,
		now:        time.Now,
		evictAfter: 10 * time.Minute,
		maxBuckets: defaultMaxBuckets,
	}
}

// Allow consumes one token for key. Returns true if the request is allowed.
// A nil receiver is valid and always returns true, so callers can pass a
// disabled limiter without a nil check.
func (r *RateLimiter) Allow(key string) bool {
	if r == nil {
		return true
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()

	b, ok := r.buckets[key]
	if !ok {
		if r.maxBuckets > 0 && len(r.buckets) >= r.maxBuckets {
			r.forceEvict(now)
		}
		b = &bucket{tokens: r.capacity, lastSeen: now}
		r.buckets[key] = b
	}
	elapsed := now.Sub(b.lastSeen).Seconds()
	b.tokens = math.Min(r.capacity, b.tokens+elapsed*r.rate)
	b.lastSeen = now

	r.maybeEvict(now)

	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

func (r *RateLimiter) maybeEvict(now time.Time) {
	if now.Sub(r.lastEvict) < r.evictAfter {
		return
	}
	r.lastEvict = now
	cutoff := now.Add(-r.evictAfter)
	for k, b := range r.buckets {
		if b.lastSeen.Before(cutoff) {
			delete(r.buckets, k)
		}
	}
}

// forceEvict runs when the bucket count hits maxBuckets. First pass: drop
// anything past evictAfter. If we're still at cap, drop the single oldest
// entry so the new key can be inserted. O(n) but only runs when the map is
// saturated.
func (r *RateLimiter) forceEvict(now time.Time) {
	r.lastEvict = now
	cutoff := now.Add(-r.evictAfter)
	for k, b := range r.buckets {
		if b.lastSeen.Before(cutoff) {
			delete(r.buckets, k)
		}
	}
	if r.maxBuckets <= 0 || len(r.buckets) < r.maxBuckets {
		return
	}
	var oldestKey string
	var oldestTime time.Time
	first := true
	for k, b := range r.buckets {
		if first || b.lastSeen.Before(oldestTime) {
			oldestKey = k
			oldestTime = b.lastSeen
			first = false
		}
	}
	if !first {
		delete(r.buckets, oldestKey)
	}
}
