package manifest

import "testing"

func TestEmbeddedManifestStripAndRead(t *testing.T) {
	source := "return true\n\n--[[ mutate4lua-manifest\nversion=1\nprojectHash=abc\nscope.0.id=chunk:file\nscope.0.kind=chunk\nscope.0.startLine=1\nscope.0.endLine=1\nscope.0.semanticHash=xyz\n]]\n"
	stripped := StripEmbedded(source)
	if stripped != "return true\n" {
		t.Fatalf("unexpected stripped source: %q", stripped)
	}
	data, err := ReadEmbedded(source)
	if err != nil {
		t.Fatal(err)
	}
	if data == nil || data.ProjectHash != "abc" || len(data.Scopes) != 1 || data.Scopes[0].ID != "chunk:file" {
		t.Fatalf("unexpected manifest: %#v", data)
	}
}
