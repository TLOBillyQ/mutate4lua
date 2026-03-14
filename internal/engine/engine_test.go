package engine

import (
	"testing"

	"github.com/billyq/mutate4lua/internal/analysis"
)

func TestSelectionCoverageUsesNormalizedPath(t *testing.T) {
	result := analysis.Result{
		Sites: []analysis.MutationSite{{RelativeFile: "./src/demo.lua", Line: 3, ScopeID: "chunk:src/demo.lua"}},
	}
	selection := FilterSelection(SelectionArgs{}, result, nil, map[string]bool{"src/demo.lua:3": true})
	if len(selection.Covered) != 1 || len(selection.Uncovered) != 0 {
		t.Fatalf("unexpected selection: %#v", selection)
	}
}
