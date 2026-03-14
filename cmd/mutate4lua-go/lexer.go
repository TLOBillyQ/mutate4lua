package main

import "strings"

var keywords = map[string]bool{
	"and": true, "break": true, "do": true, "else": true, "elseif": true,
	"end": true, "false": true, "for": true, "function": true, "goto": true,
	"if": true, "in": true, "local": true, "nil": true, "not": true,
	"or": true, "repeat": true, "return": true, "then": true, "true": true,
	"until": true, "while": true,
}

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

func tokenize(source string) []token {
	source = normalizeNewlines(source)
	tokens := []token{}
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
			tokens = append(tokens, token{Type: "string", Value: text, StartPos: index, EndPos: cursor, Line: line})
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
				tokens = append(tokens, token{Type: "string", Value: text, StartPos: index, EndPos: cursor, Line: line})
				line += countNewlines(text)
				index = cursor + 1
			} else {
				tokens = append(tokens, token{Type: "symbol", Value: string(current), StartPos: index, EndPos: index, Line: line})
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
			tokens = append(tokens, token{Type: tokenType, Value: text, StartPos: index, EndPos: cursor, Line: line})
			index = cursor + 1
		case isDigit(current):
			cursor := scanNumber(source, index)
			tokens = append(tokens, token{Type: "number", Value: sourceSlice(source, index, cursor), StartPos: index, EndPos: cursor, Line: line})
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
			tokens = append(tokens, token{Type: "symbol", Value: value, StartPos: index, EndPos: index + len(value) - 1, Line: line})
			index += len(value)
		}
	}
	return tokens
}
