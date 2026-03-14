package main

import (
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
)

const embeddedManifestStart = "--[[ mutate4lua-manifest\n"
const embeddedManifestEnd = "]]"

func embeddedManifestStartIndex(source string) int {
	source = normalizeNewlines(source)
	marker := strings.Index(source, embeddedManifestStart)
	if marker < 0 {
		return -1
	}
	tail := trim(source[marker:])
	if !strings.HasSuffix(tail, embeddedManifestEnd) {
		return -1
	}
	return marker
}

func stripEmbeddedManifest(source string) string {
	source = normalizeNewlines(source)
	index := embeddedManifestStartIndex(source)
	if index < 0 {
		return source
	}
	stripped := trim(source[:index])
	if stripped == "" {
		return ""
	}
	return stripped + "\n"
}

func readEmbeddedManifest(source string) (*manifestData, error) {
	source = normalizeNewlines(source)
	start := embeddedManifestStartIndex(source)
	if start < 0 {
		return nil, nil
	}
	stop := strings.Index(source[start:], embeddedManifestEnd)
	if stop < 0 {
		return nil, nil
	}
	body := trim(source[start+len(embeddedManifestStart) : start+stop])
	data := manifestData{Version: 1, Scopes: []scopeInfo{}}
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
		data.Scopes = append(data.Scopes, scopeInfo{
			ID:           scope["id"],
			Kind:         scope["kind"],
			StartLine:    startLine,
			EndLine:      endLine,
			SemanticHash: scope["semanticHash"],
		})
	}
	return &data, nil
}

func manifestSidecarPath(projectRoot, relativeFile string) string {
	normalized := normalizeRelativePath(relativeFile)
	return filepath.Join(projectRoot, ".mutate4lua", "manifests", normalized+".json")
}

func loadManifest(projectRoot, targetPath, relativeFile, rawSource string) (*manifestData, error) {
	sidecar := manifestSidecarPath(projectRoot, relativeFile)
	if fileExists(sidecar) {
		var data manifestData
		if err := readJSONFile(sidecar, &data); err != nil {
			return nil, err
		}
		return &data, nil
	}
	embedded, err := readEmbeddedManifest(rawSource)
	if err != nil || embedded == nil {
		return embedded, err
	}
	if err := writeJSONFile(sidecar, embedded); err != nil {
		return nil, err
	}
	return embedded, nil
}

func writeManifest(projectRoot, relativeFile string, analysis analysisResult) error {
	path := manifestSidecarPath(projectRoot, relativeFile)
	data := manifestData{Version: 1, ProjectHash: analysis.ProjectHash, Scopes: analysis.Scopes}
	for i := range data.Scopes {
		data.Scopes[i].StartPos = 0
		data.Scopes[i].EndPos = 0
		data.Scopes[i].File = ""
		data.Scopes[i].RelativeFile = ""
	}
	return writeJSONFile(path, data)
}

func migrateManifest(projectRoot, targetPath string) (string, error) {
	absoluteTarget, err := filepath.Abs(targetPath)
	if err != nil {
		return "", err
	}
	relativeFile, err := filepath.Rel(projectRoot, absoluteTarget)
	if err != nil {
		return "", err
	}
	relativeFile = normalizeRelativePath(relativeFile)
	rawSource, err := readFile(absoluteTarget)
	if err != nil {
		return "", err
	}
	manifest, err := loadManifest(projectRoot, absoluteTarget, relativeFile, rawSource)
	if err != nil {
		return "", err
	}
	if manifest == nil {
		return fmt.Sprintf("No manifest found for %s\n", relativeFile), nil
	}
	return fmt.Sprintf("Updated manifest for %s\n", relativeFile), nil
}
