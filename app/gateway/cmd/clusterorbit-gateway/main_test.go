package main

import "testing"

func TestMessage(t *testing.T) {
	if got, want := message(), scaffoldMessage; got != want {
		t.Fatalf("message() = %q, want %q", got, want)
	}
}
