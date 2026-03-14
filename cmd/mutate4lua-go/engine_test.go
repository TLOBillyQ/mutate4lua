package main

import "testing"

func TestTokenizeParsesHexBinaryAndExponentNumbers(t *testing.T) {
	tokens := tokenize("local a=0xFF local b=0b1010 local c=1.5e-3\n")
	numbers := []string{}
	for _, tok := range tokens {
		if tok.Type == "number" {
			numbers = append(numbers, tok.Value)
		}
	}
	if len(numbers) != 3 || numbers[0] != "0xFF" || numbers[1] != "0b1010" || numbers[2] != "1.5e-3" {
		t.Fatalf("unexpected numbers: %#v", numbers)
	}
}

func TestAnalyzeDiscoversOperatorsAndSkipsComments(t *testing.T) {
	source := "local value = 0 -- true == false\nreturn true and call()\n"
	analysis := analyzeSource("/tmp/sample.lua", "sample.lua", source)
	descriptions := map[string]bool{}
	for _, site := range analysis.Sites {
		descriptions[site.Description] = true
	}
	for _, expected := range []string{"replace 0 with 1", "replace true with false", "replace and with or", "replace call() with nil"} {
		if !descriptions[expected] {
			t.Fatalf("missing mutation %q", expected)
		}
	}
	if descriptions["replace == with ~="] {
		t.Fatalf("unexpected mutation inside comment")
	}
}

func TestEmbeddedManifestStripAndRead(t *testing.T) {
	source := "return true\n\n--[[ mutate4lua-manifest\nversion=1\nprojectHash=abc\nscope.0.id=chunk:file\nscope.0.kind=chunk\nscope.0.startLine=1\nscope.0.endLine=1\nscope.0.semanticHash=xyz\n]]\n"
	stripped := stripEmbeddedManifest(source)
	if stripped != "return true\n" {
		t.Fatalf("unexpected stripped source: %q", stripped)
	}
	manifest, err := readEmbeddedManifest(source)
	if err != nil {
		t.Fatalf("readEmbeddedManifest error: %v", err)
	}
	if manifest == nil || manifest.ProjectHash != "abc" || len(manifest.Scopes) != 1 || manifest.Scopes[0].ID != "chunk:file" {
		t.Fatalf("unexpected manifest: %#v", manifest)
	}
}

func TestSelectionCoverageUsesNormalizedPath(t *testing.T) {
	analysis := analysisResult{
		RelativeFile: "src/demo.lua",
		ProjectHash:  "new",
		Scopes:       []scopeInfo{{ID: "chunk:src/demo.lua", SemanticHash: "x"}},
		Sites: []mutationSite{{
			RelativeFile: "src/demo.lua",
			Line:         3,
			ScopeID:      "chunk:src/demo.lua",
		}},
	}
	previous := &manifestData{ProjectHash: "old", Scopes: []scopeInfo{{ID: "chunk:src/demo.lua", SemanticHash: "y"}}}
	selection := filterSelection(selectionArgs{}, analysis, previous, map[string]bool{"./src/demo.lua:3": true, "src/demo.lua:3": true})
	if len(selection.Covered) != 1 {
		t.Fatalf("expected covered mutation, got %#v", selection)
	}
}
