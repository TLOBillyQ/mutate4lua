package analysis

import "testing"

func TestTokenizeParsesHexBinaryAndExponentNumbers(t *testing.T) {
	tokens := Tokenize("local a=0xFF local b=0b1010 local c=1.5e-3\n")
	numbers := []string{}
	for _, token := range tokens {
		if token.Type == "number" {
			numbers = append(numbers, token.Value)
		}
	}
	if len(numbers) != 3 || numbers[0] != "0xFF" || numbers[1] != "0b1010" || numbers[2] != "1.5e-3" {
		t.Fatalf("unexpected numbers: %#v", numbers)
	}
}

func TestAnalyzeDiscoversOperatorsAndSkipsComments(t *testing.T) {
	source := "local value = 0 -- true == false\nreturn true and call()\n"
	analysis := AnalyzeSource("/tmp/sample.lua", "sample.lua", source)
	descriptions := map[string]bool{}
	for _, site := range analysis.Sites {
		descriptions[site.Description] = true
	}
	for _, expected := range []string{"replace 0 with 1", "replace true with false", "replace and with or", "replace call() with nil"} {
		if !descriptions[expected] {
			t.Fatalf("missing mutation %q in %#v", expected, descriptions)
		}
	}
	if descriptions["replace == with ~="] {
		t.Fatalf("comment token should not be mutated: %#v", descriptions)
	}
}
