package analysis

import (
	"fmt"
	"sort"
	"strings"

	mutruntime "github.com/billyq/mutate4lua/internal/runtime"
)

type Token struct {
	Type     string `json:"type"`
	Value    string `json:"value"`
	StartPos int    `json:"start_pos"`
	EndPos   int    `json:"end_pos"`
	Line     int    `json:"line"`
}

type ScopeInfo struct {
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

type MutationSite struct {
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

type Result struct {
	File         string         `json:"file"`
	RelativeFile string         `json:"relative_file"`
	FileHash     string         `json:"file_hash"`
	ProjectHash  string         `json:"project_hash"`
	Scopes       []ScopeInfo    `json:"scopes"`
	Sites        []MutationSite `json:"sites"`
}

var keywords = map[string]bool{
	"and": true, "break": true, "do": true, "else": true, "elseif": true,
	"end": true, "false": true, "for": true, "function": true, "goto": true,
	"if": true, "in": true, "local": true, "nil": true, "not": true,
	"or": true, "repeat": true, "return": true, "then": true, "true": true,
	"until": true, "while": true,
}

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

func countNewlines(text string) int {
	return strings.Count(text, "\n")
}

func sourceByte(source string, index int) byte {
	if index < 1 || index > len(source) {
		return 0
	}
	return source[index-1]
}

func sourceSlice(source string, start, end int) string {
	if start < 1 {
		start = 1
	}
	if end > len(source) {
		end = len(source)
	}
	if start > end || start > len(source) {
		return ""
	}
	return source[start-1 : end]
}

func longBracketEquals(source string, index int) (int, bool) {
	if sourceByte(source, index) != '[' {
		return 0, false
	}
	cursor := index + 1
	for sourceByte(source, cursor) == '=' {
		cursor++
	}
	if sourceByte(source, cursor) != '[' {
		return 0, false
	}
	return cursor - index - 1, true
}

func closeLongBracket(source string, index, equalsCount int) (int, bool) {
	closer := "]" + strings.Repeat("=", equalsCount) + "]"
	offset := strings.Index(source[index-1:], closer)
	if offset < 0 {
		return 0, false
	}
	return index + offset, true
}

func isDigit(ch byte) bool { return ch >= '0' && ch <= '9' }
func isHex(ch byte) bool {
	return isDigit(ch) || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')
}
func isBin(ch byte) bool { return ch == '0' || ch == '1' }
func isAlpha(ch byte) bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}
func isIdentChar(ch byte) bool {
	return isAlpha(ch) || isDigit(ch) || ch == '_'
}
func isSpaceNoNewline(ch byte) bool {
	switch ch {
	case ' ', '\t', '\v', '\f', '\r':
		return true
	default:
		return false
	}
}

func scanNumber(source string, index int) int {
	length := len(source)
	cursor := index
	prefix := sourceSlice(source, index, index+1)
	if prefix == "0x" || prefix == "0X" {
		cursor = index + 2
		for cursor <= length {
			ch := sourceByte(source, cursor)
			if ch == '_' || isHex(ch) {
				cursor++
			} else {
				break
			}
		}
		if sourceByte(source, cursor) == '.' {
			cursor++
			for cursor <= length {
				ch := sourceByte(source, cursor)
				if ch == '_' || isHex(ch) {
					cursor++
				} else {
					break
				}
			}
		}
		exp := sourceByte(source, cursor)
		if exp == 'p' || exp == 'P' {
			cursor++
			sign := sourceByte(source, cursor)
			if sign == '+' || sign == '-' {
				cursor++
			}
			for cursor <= length {
				ch := sourceByte(source, cursor)
				if ch == '_' || isDigit(ch) {
					cursor++
				} else {
					break
				}
			}
		}
		return cursor - 1
	}
	if prefix == "0b" || prefix == "0B" {
		cursor = index + 2
		for cursor <= length {
			ch := sourceByte(source, cursor)
			if ch == '_' || isBin(ch) {
				cursor++
			} else {
				break
			}
		}
		return cursor - 1
	}
	for cursor <= length {
		ch := sourceByte(source, cursor)
		if isDigit(ch) || ch == '_' {
			cursor++
			continue
		}
		break
	}
	if sourceByte(source, cursor) == '.' && sourceByte(source, cursor+1) != '.' {
		cursor++
		for cursor <= length {
			ch := sourceByte(source, cursor)
			if isDigit(ch) || ch == '_' {
				cursor++
				continue
			}
			break
		}
	}
	exp := sourceByte(source, cursor)
	if exp == 'e' || exp == 'E' {
		cursor++
		sign := sourceByte(source, cursor)
		if sign == '+' || sign == '-' {
			cursor++
		}
		for cursor <= length {
			ch := sourceByte(source, cursor)
			if isDigit(ch) || ch == '_' {
				cursor++
				continue
			}
			break
		}
	}
	return cursor - 1
}

func Tokenize(source string) []Token {
	source = mutruntime.NormalizeNewlines(source)
	tokens := []Token{}
	index := 1
	line := 1
	length := len(source)
	for index <= length {
		current := sourceByte(source, index)
		next := sourceByte(source, index+1)
		switch {
		case current == '\n':
			line++
			index++
		case isSpaceNoNewline(current):
			index++
		case current == '-' && next == '-':
			if equalsCount, ok := longBracketEquals(source, index+2); ok {
				closeIndex, found := closeLongBracket(source, index+2, equalsCount)
				if !found {
					chunk := source[index-1:]
					line += countNewlines(chunk)
					index = length + 1
					break
				}
				chunkEnd := closeIndex + equalsCount + 2
				chunk := sourceSlice(source, index, chunkEnd)
				line += countNewlines(chunk)
				index = chunkEnd + 1
			} else {
				offset := strings.IndexByte(source[index-1:], '\n')
				if offset < 0 {
					index = length + 1
					break
				}
				line++
				index = index + offset + 1
			}
		case current == '\'' || current == '"':
			delimiter := current
			cursor := index + 1
			for cursor <= length {
				ch := sourceByte(source, cursor)
				if ch == '\\' {
					cursor += 2
				} else if ch == delimiter {
					break
				} else {
					cursor++
				}
			}
			if cursor > length {
				cursor = length
			}
			text := sourceSlice(source, index, cursor)
			tokens = append(tokens, Token{Type: "string", Value: text, StartPos: index, EndPos: cursor, Line: line})
			line += countNewlines(text)
			index = cursor + 1
		case current == '[':
			if equalsCount, ok := longBracketEquals(source, index); ok {
				closeIndex, found := closeLongBracket(source, index+1, equalsCount)
				cursor := length
				if found {
					cursor = closeIndex + equalsCount + 2
				}
				text := sourceSlice(source, index, cursor)
				tokens = append(tokens, Token{Type: "string", Value: text, StartPos: index, EndPos: cursor, Line: line})
				line += countNewlines(text)
				index = cursor + 1
			} else {
				tokens = append(tokens, Token{Type: "symbol", Value: string(current), StartPos: index, EndPos: index, Line: line})
				index++
			}
		case isAlpha(current) || current == '_':
			cursor := index
			for isIdentChar(sourceByte(source, cursor)) {
				cursor++
			}
			cursor--
			text := sourceSlice(source, index, cursor)
			tokenType := "identifier"
			if keywords[text] {
				tokenType = "keyword"
			}
			tokens = append(tokens, Token{Type: tokenType, Value: text, StartPos: index, EndPos: cursor, Line: line})
			index = cursor + 1
		case isDigit(current):
			cursor := scanNumber(source, index)
			tokens = append(tokens, Token{Type: "number", Value: sourceSlice(source, index, cursor), StartPos: index, EndPos: cursor, Line: line})
			index = cursor + 1
		default:
			three := sourceSlice(source, index, index+2)
			two := sourceSlice(source, index, index+1)
			value := string(current)
			if three == "..." {
				value = three
			} else if two == "==" || two == "~=" || two == "<=" || two == ">=" || two == ".." {
				value = two
			}
			tokens = append(tokens, Token{Type: "symbol", Value: value, StartPos: index, EndPos: index + len(value) - 1, Line: line})
			index += len(value)
		}
	}
	return tokens
}

func previousToken(tokens []Token, index int) *Token {
	if index-1 < 0 || index-1 >= len(tokens) {
		return nil
	}
	return &tokens[index-1]
}

func nextToken(tokens []Token, index int) *Token {
	if index+1 < 0 || index+1 >= len(tokens) {
		return nil
	}
	return &tokens[index+1]
}

func functionName(tokens []Token, index int) string {
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

func shouldPushDo(tokens []Token, index int) bool {
	prev := previousToken(tokens, index)
	if prev == nil {
		return true
	}
	return !blockStarters[prev.Value]
}

func buildScopes(sourceFile, relativeFile, source string, tokens []Token) []ScopeInfo {
	scopes := []ScopeInfo{{
		ID:        "chunk:" + relativeFile,
		Kind:      "chunk",
		StartLine: 1,
		EndLine:   len(mutruntime.SplitLines(source)),
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
				scopes = append(scopes, ScopeInfo{
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
		scopes[i].SemanticHash = mutruntime.FNV1a64Hex(strings.Join(parts, " "))
		scopes[i].File = sourceFile
		scopes[i].RelativeFile = relativeFile
	}
	return scopes
}

func assignScope(scopes []ScopeInfo, position int) ScopeInfo {
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

func addSite(sites *[]MutationSite, scopes []ScopeInfo, source string, tok Token, replacement, description string) {
	scope := assignScope(scopes, tok.StartPos)
	*sites = append(*sites, MutationSite{
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

func isUnaryMinus(tokens []Token, index int) bool {
	prev := previousToken(tokens, index)
	if prev == nil {
		return true
	}
	return expressionBreakers[prev.Value]
}

func matchCall(tokens []Token, index int) (int, int, bool) {
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

func addCallSite(sites *[]MutationSite, scopes []ScopeInfo, source string, tokens []Token, startIndex, endIndex int) {
	startToken := tokens[startIndex]
	endToken := tokens[endIndex]
	scope := assignScope(scopes, startToken.StartPos)
	originalText := sourceSlice(source, startToken.StartPos, endToken.EndPos)
	*sites = append(*sites, MutationSite{
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

func AnalyzeSource(sourceFile, relativeFile, source string) Result {
	source = mutruntime.NormalizeNewlines(source)
	tokens := Tokenize(source)
	scopes := buildScopes(sourceFile, relativeFile, source, tokens)
	sites := []MutationSite{}
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
	return Result{
		File:         sourceFile,
		RelativeFile: relativeFile,
		FileHash:     mutruntime.FNV1a64Hex(source),
		Scopes:       scopes,
		Sites:        sites,
	}
}

func ApplyMutation(source string, site MutationSite) string {
	return sourceSlice(source, 1, site.StartPos-1) + site.ReplacementText + sourceSlice(source, site.EndPos+1, len(source))
}
