package main

import (
	"encoding/json"
	"strconv"
	"strings"
)

func itoa(value int) string {
	return strconv.Itoa(value)
}

func joinStrings(values []string, delimiter string) string {
	return strings.Join(values, delimiter)
}

func dedupeStrings(values []string) []string {
	seen := map[string]bool{}
	result := []string{}
	for _, value := range values {
		if !seen[value] {
			seen[value] = true
			result = append(result, value)
		}
	}
	return result
}

func lastIndexByte(value string, needle byte) int {
	return strings.LastIndexByte(value, needle)
}

func jsonString(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return string(data), nil
}
