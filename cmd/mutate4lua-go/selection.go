package main

func scopeHashMap(scopes []scopeInfo) map[string]string {
	result := map[string]string{}
	for _, scope := range scopes {
		result[scope.ID] = scope.SemanticHash
	}
	return result
}

func mutationCount(sites []mutationSite, scopeIDs map[string]bool) int {
	if scopeIDs == nil {
		return len(sites)
	}
	count := 0
	for _, site := range sites {
		if scopeIDs[site.ScopeID] {
			count++
		}
	}
	return count
}

func computeChangedScopes(previous *manifestData, analysis analysisResult) changedScopes {
	if previous == nil {
		return changedScopes{All: map[string]bool{}, Unregistered: map[string]bool{}, Violations: map[string]bool{}}
	}
	if previous.ProjectHash == analysis.ProjectHash {
		return changedScopes{ManifestExists: true, All: map[string]bool{}, Unregistered: map[string]bool{}, Violations: map[string]bool{}}
	}
	previousHashes := scopeHashMap(previous.Scopes)
	all := map[string]bool{}
	unregistered := map[string]bool{}
	violations := map[string]bool{}
	for _, scope := range analysis.Scopes {
		oldHash, ok := previousHashes[scope.ID]
		if !ok {
			unregistered[scope.ID] = true
			all[scope.ID] = true
		} else if oldHash != scope.SemanticHash {
			violations[scope.ID] = true
			all[scope.ID] = true
		}
	}
	return changedScopes{
		ManifestExists:     true,
		ProjectHashChanged: true,
		All:                all,
		Unregistered:       unregistered,
		Violations:         violations,
	}
}

func filterSelection(args selectionArgs, analysis analysisResult, previous *manifestData, coverageLines map[string]bool) selectionResult {
	changed := computeChangedScopes(previous, analysis)
	selected := []mutationSite{}
	covered := []mutationSite{}
	uncovered := []mutationSite{}
	lineSelected := func(site mutationSite) bool {
		if len(args.Lines) == 0 {
			return true
		}
		return args.LinesLookup[site.Line]
	}
	scopeSelected := func(site mutationSite) bool {
		if args.MutateAll {
			return true
		}
		if len(args.Lines) > 0 {
			return true
		}
		if args.SinceLastRun {
			return changed.All[site.ScopeID]
		}
		if previous == nil {
			return true
		}
		if !changed.ProjectHashChanged {
			return false
		}
		return changed.All[site.ScopeID]
	}
	for _, site := range analysis.Sites {
		if !lineSelected(site) || !scopeSelected(site) {
			continue
		}
		selected = append(selected, site)
		if len(coverageLines) > 0 {
			key := normalizeRelativePath(site.RelativeFile) + ":" + itoa(site.Line)
			if coverageLines[key] {
				covered = append(covered, site)
			} else {
				uncovered = append(uncovered, site)
			}
		} else {
			covered = append(covered, site)
		}
	}
	return selectionResult{
		TotalMutationSites:           len(analysis.Sites),
		Selected:                     selected,
		Covered:                      covered,
		Uncovered:                    uncovered,
		ChangedMutationSites:         mutationCount(analysis.Sites, changed.All),
		ManifestExists:               changed.ManifestExists,
		ProjectHashChanged:           changed.ProjectHashChanged,
		DifferentialSurfaceArea:      mutationCount(analysis.Sites, changed.Unregistered),
		ManifestViolatingSurfaceArea: mutationCount(analysis.Sites, changed.Violations),
		ChangedScopeIDs:              changed.All,
	}
}
