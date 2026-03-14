package manifest

import (
	"path/filepath"
	"strconv"
	"strings"

	"github.com/billyq/mutate4lua/internal/analysis"
	mutruntime "github.com/billyq/mutate4lua/internal/runtime"
)

const embeddedManifestStart = "--[[ mutate4lua-manifest\n"
const embeddedManifestEnd = "]]"

type Data struct {
	Version     int                  `json:"version"`
	ProjectHash string               `json:"project_hash"`
	Scopes      []analysis.ScopeInfo `json:"scopes"`
}

func embeddedManifestStartIndex(source string) int {
	source = mutruntime.NormalizeNewlines(source)
	marker := strings.Index(source, embeddedManifestStart)
	if marker < 0 {
		return -1
	}
	tail := mutruntime.Trim(source[marker:])
	if !strings.HasSuffix(tail, embeddedManifestEnd) {
		return -1
	}
	return marker
}

func StripEmbedded(source string) string {
	source = mutruntime.NormalizeNewlines(source)
	index := embeddedManifestStartIndex(source)
	if index < 0 {
		return source
	}
	stripped := mutruntime.Trim(source[:index])
	if stripped == "" {
		return ""
	}
	return stripped + "\n"
}

func ReadEmbedded(source string) (*Data, error) {
	source = mutruntime.NormalizeNewlines(source)
	start := embeddedManifestStartIndex(source)
	if start < 0 {
		return nil, nil
	}
	stop := strings.Index(source[start:], embeddedManifestEnd)
	if stop < 0 {
		return nil, nil
	}
	body := mutruntime.Trim(source[start+len(embeddedManifestStart) : start+stop])
	data := Data{Version: 1, Scopes: []analysis.ScopeInfo{}}
	scopeMap := map[int]map[string]string{}
	for _, line := range strings.Split(body, "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key, value := parts[0], parts[1]
		if strings.HasPrefix(key, "scope.") {
			fields := strings.SplitN(key, ".", 3)
			if len(fields) != 3 {
				continue
			}
			idx, err := strconv.Atoi(fields[1])
			if err != nil {
				continue
			}
			if _, ok := scopeMap[idx]; !ok {
				scopeMap[idx] = map[string]string{}
			}
			scopeMap[idx][fields[2]] = value
			continue
		}
		switch key {
		case "version":
			if parsed, err := strconv.Atoi(value); err == nil {
				data.Version = parsed
			}
		case "projectHash":
			data.ProjectHash = value
		}
	}
	if len(scopeMap) == 0 && data.ProjectHash == "" {
		return nil, nil
	}
	for index := 0; ; index++ {
		scope, ok := scopeMap[index]
		if !ok {
			break
		}
		startLine, _ := strconv.Atoi(scope["startLine"])
		endLine, _ := strconv.Atoi(scope["endLine"])
		data.Scopes = append(data.Scopes, analysis.ScopeInfo{
			ID:           scope["id"],
			Kind:         scope["kind"],
			StartLine:    startLine,
			EndLine:      endLine,
			SemanticHash: scope["semanticHash"],
		})
	}
	return &data, nil
}

func SidecarPath(projectRoot, relativeFile string) string {
	normalized := mutruntime.NormalizeRelativePath(relativeFile)
	return filepath.Join(projectRoot, ".mutate4lua", "manifests", normalized+".json")
}

func Load(projectRoot, targetPath, relativeFile, rawSource string) (*Data, error) {
	sidecar := SidecarPath(projectRoot, relativeFile)
	if mutruntime.FileExists(sidecar) {
		var data Data
		if err := mutruntime.ReadJSONFile(sidecar, &data); err != nil {
			return nil, err
		}
		return &data, nil
	}
	embedded, err := ReadEmbedded(rawSource)
	if err != nil || embedded == nil {
		return embedded, err
	}
	if err := mutruntime.WriteJSONFile(sidecar, embedded); err != nil {
		return nil, err
	}
	return embedded, nil
}

func Write(projectRoot, relativeFile string, result analysis.Result) error {
	path := SidecarPath(projectRoot, relativeFile)
	data := Data{Version: 1, ProjectHash: result.ProjectHash, Scopes: result.Scopes}
	for i := range data.Scopes {
		data.Scopes[i].StartPos = 0
		data.Scopes[i].EndPos = 0
		data.Scopes[i].File = ""
		data.Scopes[i].RelativeFile = ""
	}
	return mutruntime.WriteJSONFile(path, data)
}
