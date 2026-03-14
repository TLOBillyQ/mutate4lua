package main

import (
	"fmt"
	"sort"
	"strings"
)

var binaryReplacements = map[string]struct{ Replacement, Description string }{
	"==":  {"~=", "replace == with ~="},
	"~=":  {"==", "replace ~= with =="},
	"<":   {"<=", "replace < with <="},
	"<=":  {"<", "replace <= with <"},
	">":   {">=", "replace > with >="},
	">=":  {">", "replace >= with >"},
	"+":   {"-", "replace + with -"},
	"-":   {"+", "replace - with +"},
	"*":   {"/", "replace * with /"},
	"/":   {"*", "replace / with *"},
	"and": {"or", "replace and with or"},
	"or":  {"and", "replace or with and"},
}

var expressionBreakers = map[string]bool{
	"(": true, "{": true, "[": true, ",": true, "=": true, "==": true, "~=": true,
	"<": true, "<=": true, ">": true, ">=": true, "+": true, "-": true, "*": true,
	"/": true, "..": true, "and": true, "or": true, "not": true, "return": true,
	"then": true, "do": true, "elseif": true, "local": true, "until": true, ";": true,
}

var blockStarters = map[string]bool{"if": true, "for": true, "while": true}

func previousToken(tokens []token, index int) *token {
	if index-1 < 0 || index-1 >= len(tokens) {
		return nil
	}
	return &tokens[index-1]
}

func nextToken(tokens []token, index int) *token {
	if index+1 < 0 || index+1 >= len(tokens) {
		return nil
	}
	return &tokens[index+1]
}

func functionName(tokens []token, index int) string {
	tok := nextToken(tokens, index)
	parts := []string{}
	if tok != nil && tok.Value == "(" {
		return fmt.Sprintf("anonymous@%d", tokens[index].Line)
	}
	for tok != nil {
		if tok.Value == "(" {
			break
		}
		if tok.Type == "identifier" || tok.Value == "." || tok.Value == ":" {
			parts = append(parts, tok.Value)
		} else {
			break
		}
		if index+len(parts) >= len(tokens) {
			tok = nil
		} else {
			tok = nextToken(tokens, index+len(parts))
		}
	}
	if len(parts) == 0 {
		return fmt.Sprintf("anonymous@%d", tokens[index].Line)
	}
	return strings.Join(parts, "")
}

func shouldPushDo(tokens []token, index int) bool {
	prev := previousToken(tokens, index)
	if prev == nil {
		return true
	}
	return !blockStarters[prev.Value]
}

func buildScopes(sourceFile, relativeFile, source string, tokens []token) []scopeInfo {
	scopes := []scopeInfo{{
		ID:        "chunk:" + relativeFile,
		Kind:      "chunk",
		StartLine: 1,
		EndLine:   len(splitLines(source)),
		StartPos:  1,
		EndPos:    len(source),
	}}
	type stackEntry struct {
		Kind      string
		Name      string
		StartLine int
		StartPos  int
	}
	stack := []stackEntry{}
	for index, tok := range tokens {
		if tok.Type != "keyword" {
			continue
		}
		switch tok.Value {
		case "function":
			stack = append(stack, stackEntry{Kind: "function", Name: functionName(tokens, index), StartLine: tok.Line, StartPos: tok.StartPos})
		case "if", "for", "while":
			stack = append(stack, stackEntry{Kind: tok.Value})
		case "do":
			if shouldPushDo(tokens, index) {
				stack = append(stack, stackEntry{Kind: "do"})
			}
		case "repeat":
			stack = append(stack, stackEntry{Kind: "repeat"})
		case "until":
			for position := len(stack) - 1; position >= 0; position-- {
				if stack[position].Kind == "repeat" {
					stack = append(stack[:position], stack[position+1:]...)
					break
				}
			}
		case "end":
			if len(stack) == 0 {
				continue
			}
			block := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			if block.Kind == "function" {
				scopes = append(scopes, scopeInfo{
					ID:        fmt.Sprintf("function:%s:%d", block.Name, block.StartLine),
					Kind:      "function",
					StartLine: block.StartLine,
					EndLine:   tok.Line,
					StartPos:  block.StartPos,
					EndPos:    tok.EndPos,
				})
			}
		}
	}
	for i := range scopes {
		parts := []string{}
		for _, tok := range tokens {
			if tok.StartPos >= scopes[i].StartPos && tok.EndPos <= scopes[i].EndPos {
				parts = append(parts, tok.Value)
			}
		}
		scopes[i].SemanticHash = fnv1a64Hex(strings.Join(parts, " "))
		scopes[i].File = sourceFile
		scopes[i].RelativeFile = relativeFile
	}
	return scopes
}

func assignScope(scopes []scopeInfo, position int) scopeInfo {
	winner := scopes[0]
	bestSpan := winner.EndPos - winner.StartPos
	for _, scope := range scopes {
		if position >= scope.StartPos && position <= scope.EndPos {
			span := scope.EndPos - scope.StartPos
			if span <= bestSpan {
				bestSpan = span
				winner = scope
			}
		}
	}
	return winner
}

func addSite(sites *[]mutationSite, scopes []scopeInfo, source string, tok token, replacement, description string) {
	scope := assignScope(scopes, tok.StartPos)
	*sites = append(*sites, mutationSite{
		File:            scope.File,
		RelativeFile:    scope.RelativeFile,
		Line:            tok.Line,
		StartPos:        tok.StartPos,
		EndPos:          tok.EndPos,
		OriginalText:    sourceSlice(source, tok.StartPos, tok.EndPos),
		ReplacementText: replacement,
		Description:     description,
		ScopeID:         scope.ID,
	})
}

func isUnaryMinus(tokens []token, index int) bool {
	prev := previousToken(tokens, index)
	if prev == nil {
		return true
	}
	return expressionBreakers[prev.Value]
}

func matchCall(tokens []token, index int) (int, int, bool) {
	tok := tokens[index]
	if tok.Type != "identifier" {
		return 0, 0, false
	}
	startIndex := index
	for startIndex-2 >= 0 && (tokens[startIndex-1].Value == "." || tokens[startIndex-1].Value == ":") && tokens[startIndex-2].Type == "identifier" {
		startIndex -= 2
	}
	if startIndex != index {
		return 0, 0, false
	}
	if startIndex-1 >= 0 && tokens[startIndex-1].Value == "function" {
		return 0, 0, false
	}
	cursor := index + 1
	for cursor < len(tokens) && (tokens[cursor].Value == "." || tokens[cursor].Value == ":") {
		if cursor+1 >= len(tokens) || tokens[cursor+1].Type != "identifier" {
			return 0, 0, false
		}
		cursor += 2
	}
	if cursor >= len(tokens) || tokens[cursor].Value != "(" {
		return 0, 0, false
	}
	depth := 0
	finish := cursor
	for finish < len(tokens) {
		if tokens[finish].Value == "(" {
			depth++
		} else if tokens[finish].Value == ")" {
			depth--
			if depth == 0 {
				break
			}
		}
		finish++
	}
	if finish >= len(tokens) || tokens[finish].Value != ")" {
		return 0, 0, false
	}
	return startIndex, finish, true
}

func addCallSite(sites *[]mutationSite, scopes []scopeInfo, source string, tokens []token, startIndex, endIndex int) {
	startToken := tokens[startIndex]
	endToken := tokens[endIndex]
	scope := assignScope(scopes, startToken.StartPos)
	originalText := sourceSlice(source, startToken.StartPos, endToken.EndPos)
	*sites = append(*sites, mutationSite{
		File:            scope.File,
		RelativeFile:    scope.RelativeFile,
		Line:            startToken.Line,
		StartPos:        startToken.StartPos,
		EndPos:          endToken.EndPos,
		OriginalText:    originalText,
		ReplacementText: "nil",
		Description:     "replace " + originalText + " with nil",
		ScopeID:         scope.ID,
	})
}

func analyzeSource(sourceFile, relativeFile, source string) analysisResult {
	source = normalizeNewlines(source)
	tokens := tokenize(source)
	scopes := buildScopes(sourceFile, relativeFile, source, tokens)
	sites := []mutationSite{}
	for index := 0; index < len(tokens); index++ {
		tok := tokens[index]
		switch tok.Type {
		case "keyword":
			switch tok.Value {
			case "true":
				addSite(&sites, scopes, source, tok, "false", "replace true with false")
			case "false":
				addSite(&sites, scopes, source, tok, "true", "replace false with true")
			case "and", "or":
				mutation := binaryReplacements[tok.Value]
				addSite(&sites, scopes, source, tok, mutation.Replacement, mutation.Description)
			case "not":
				addSite(&sites, scopes, source, tok, "", "replace not with removed not")
			}
		case "symbol":
			mutation, ok := binaryReplacements[tok.Value]
			if ok {
				if tok.Value == "-" && isUnaryMinus(tokens, index) {
					addSite(&sites, scopes, source, tok, "", "replace - with removed -")
				} else {
					addSite(&sites, scopes, source, tok, mutation.Replacement, mutation.Description)
				}
			}
		case "number":
			if tok.Value == "0" {
				addSite(&sites, scopes, source, tok, "1", "replace 0 with 1")
			} else if tok.Value == "1" {
				addSite(&sites, scopes, source, tok, "0", "replace 1 with 0")
			}
		case "string":
			addSite(&sites, scopes, source, tok, "nil", "replace "+tok.Value+" with nil")
		case "identifier":
			startIndex, endIndex, ok := matchCall(tokens, index)
			if ok && startIndex == index {
				addCallSite(&sites, scopes, source, tokens, startIndex, endIndex)
				index = endIndex
			}
		}
	}
	sort.Slice(sites, func(i, j int) bool {
		if sites[i].StartPos == sites[j].StartPos {
			return sites[i].EndPos < sites[j].EndPos
		}
		return sites[i].StartPos < sites[j].StartPos
	})
	return analysisResult{
		File:         sourceFile,
		RelativeFile: relativeFile,
		FileHash:     fnv1a64Hex(source),
		Scopes:       scopes,
		Sites:        sites,
	}
}

func applyMutation(source string, site mutationSite) string {
	return sourceSlice(source, 1, site.StartPos-1) + site.ReplacementText + sourceSlice(source, site.EndPos+1, len(source))
}
