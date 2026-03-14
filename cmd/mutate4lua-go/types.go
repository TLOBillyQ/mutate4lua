package main

type token struct {
	Type     string `json:"type"`
	Value    string `json:"value"`
	StartPos int    `json:"start_pos"`
	EndPos   int    `json:"end_pos"`
	Line     int    `json:"line"`
}

type scopeInfo struct {
	ID           string `json:"id"`
	Kind         string `json:"kind"`
	StartLine    int    `json:"start_line"`
	EndLine      int    `json:"end_line"`
	StartPos     int    `json:"start_pos,omitempty"`
	EndPos       int    `json:"end_pos,omitempty"`
	SemanticHash string `json:"semantic_hash"`
	File         string `json:"file,omitempty"`
	RelativeFile string `json:"relative_file,omitempty"`
}

type mutationSite struct {
	File            string `json:"file"`
	RelativeFile    string `json:"relative_file"`
	Line            int    `json:"line"`
	StartPos        int    `json:"start_pos"`
	EndPos          int    `json:"end_pos"`
	OriginalText    string `json:"original_text"`
	ReplacementText string `json:"replacement_text"`
	Description     string `json:"description"`
	ScopeID         string `json:"scope_id"`
}

type analysisResult struct {
	File         string         `json:"file"`
	RelativeFile string         `json:"relative_file"`
	FileHash     string         `json:"file_hash"`
	ProjectHash  string         `json:"project_hash"`
	Scopes       []scopeInfo    `json:"scopes"`
	Sites        []mutationSite `json:"sites"`
}

type manifestData struct {
	Version     int         `json:"version"`
	ProjectHash string      `json:"project_hash"`
	Scopes      []scopeInfo `json:"scopes"`
}

type changedScopes struct {
	ManifestExists     bool            `json:"manifest_exists"`
	ProjectHashChanged bool            `json:"project_hash_changed"`
	All                map[string]bool `json:"all"`
	Unregistered       map[string]bool `json:"unregistered"`
	Violations         map[string]bool `json:"violations"`
}

type selectionArgs struct {
	Lines        []int        `json:"lines"`
	LinesLookup  map[int]bool `json:"-"`
	SinceLastRun bool         `json:"since_last_run"`
	MutateAll    bool         `json:"mutate_all"`
}

type selectionResult struct {
	TotalMutationSites           int             `json:"total_mutation_sites"`
	Selected                     []mutationSite  `json:"selected"`
	Covered                      []mutationSite  `json:"covered"`
	Uncovered                    []mutationSite  `json:"uncovered"`
	ChangedMutationSites         int             `json:"changed_mutation_sites"`
	ManifestExists               bool            `json:"manifest_exists"`
	ProjectHashChanged           bool            `json:"project_hash_changed"`
	DifferentialSurfaceArea      int             `json:"differential_surface_area"`
	ManifestViolatingSurfaceArea int             `json:"manifest_violating_surface_area"`
	ChangedScopeIDs              map[string]bool `json:"changed_scope_ids"`
}

type runResult struct {
	ExitCode   int    `json:"exit_code"`
	TimedOut   bool   `json:"timed_out"`
	DurationMS int64  `json:"duration_ms"`
	Output     string `json:"output"`
}

type jobResult struct {
	SiteIndex   int    `json:"site_index"`
	Line        int    `json:"line"`
	Description string `json:"description"`
	Killed      bool   `json:"killed"`
	TimedOut    bool   `json:"timed_out"`
	DurationMS  int64  `json:"duration_ms"`
	JobWallMS   int64  `json:"job_wall_ms"`
	ExitCode    int    `json:"exit_code"`
}

type baselineCache struct {
	DurationMS       int64    `json:"duration_ms"`
	SuiteFingerprint string   `json:"suite_fingerprint"`
	Suites           []string `json:"suites,omitempty"`
}

type suiteIndex struct {
	Lane        string              `json:"lane"`
	Mode        string              `json:"mode"`
	ProjectHash string              `json:"project_hash"`
	Suites      map[string][]string `json:"suites"`
}
