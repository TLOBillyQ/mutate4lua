package main

import (
	"os"
	"path/filepath"
	"sort"
	"sync"
)

type mutationJob struct {
	SiteIndex     int
	Site          mutationSite
	MutatedSource string
}

func runMutationBatch(projectRoot, targetFile string, commandArgs []string, commandShell bool, timeoutSeconds int, jobs []mutationJob, workerCount int) ([]jobResult, error) {
	if workerCount < 1 {
		workerCount = 1
	}
	if workerCount > len(jobs) && len(jobs) > 0 {
		workerCount = len(jobs)
	}
	workerRoot := filepath.Join(projectRoot, ".mutate4lua", "cache", "workers")
	_ = os.MkdirAll(workerRoot, 0o755)
	batches := partitionJobs(jobs, workerCount)
	results := make([]jobResult, 0, len(jobs))
	var mu sync.Mutex
	var firstErr error
	var wg sync.WaitGroup
	for _, batch := range batches {
		batch := batch
		wg.Add(1)
		go func() {
			defer wg.Done()
			sandbox, err := os.MkdirTemp(workerRoot, "mutatecore-")
			if err != nil {
				mu.Lock()
				if firstErr == nil {
					firstErr = err
				}
				mu.Unlock()
				return
			}
			defer os.RemoveAll(sandbox)
			if err := copyProject(projectRoot, sandbox); err != nil {
				mu.Lock()
				if firstErr == nil {
					firstErr = err
				}
				mu.Unlock()
				return
			}
			localResults := []jobResult{}
			for _, job := range batch {
				_ = resetWorkspace(sandbox)
				if err := writeFile(filepath.Join(sandbox, targetFile), job.MutatedSource); err != nil {
					mu.Lock()
					if firstErr == nil {
						firstErr = err
					}
					mu.Unlock()
					return
				}
				started := nowMillis()
				result := runCommand(sandbox, commandArgs, timeoutSeconds, commandShell)
				localResults = append(localResults, jobResult{
					SiteIndex:   job.SiteIndex,
					Line:        job.Site.Line,
					Description: job.Site.Description,
					Killed:      result.TimedOut || result.ExitCode != 0,
					TimedOut:    result.TimedOut,
					DurationMS:  result.DurationMS,
					JobWallMS:   nowMillis() - started,
					ExitCode:    result.ExitCode,
				})
			}
			mu.Lock()
			results = append(results, localResults...)
			mu.Unlock()
		}()
	}
	wg.Wait()
	sort.Slice(results, func(i, j int) bool { return results[i].SiteIndex < results[j].SiteIndex })
	return results, firstErr
}

func partitionJobs(jobs []mutationJob, workerCount int) [][]mutationJob {
	if workerCount < 1 {
		workerCount = 1
	}
	buckets := make([][]mutationJob, workerCount)
	for index, job := range jobs {
		bucket := index % workerCount
		buckets[bucket] = append(buckets[bucket], job)
	}
	result := [][]mutationJob{}
	for _, bucket := range buckets {
		if len(bucket) > 0 {
			result = append(result, bucket)
		}
	}
	return result
}
