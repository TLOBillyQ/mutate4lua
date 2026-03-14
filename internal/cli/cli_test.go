package cli

import (
	"bytes"
	"strings"
	"testing"
)

func TestOldUpdateCommandIsRejected(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := Execute([]string{"migrate-manifest"}, ".", &stdout, &stderr)
	if code != 1 {
		t.Fatalf("expected exit code 1, got %d", code)
	}
	if !strings.Contains(stderr.String(), "mutate4lua-engine update-manifest") {
		t.Fatalf("expected usage text, got %q", stderr.String())
	}
}
