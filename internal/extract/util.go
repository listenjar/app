package extract

// ListenJar port: str, num, listAt and pathValue are copied verbatim from
// downbit's internal/extract/util.go. readAll, jsonAfter, unixDate, firstText
// and firstNonBlank are not ported (the YouTube extractor does not use them).

import (
	"encoding/json"
	"strconv"
)

// str returns the string (or number, formatted) at path in decoded JSON.
// Path elements are object keys (string) and array indexes (int).
func str(v any, path ...any) string {
	switch x := pathValue(v, path...).(type) {
	case string:
		return x
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	}
	return ""
}

func num(v any, path ...any) float64 {
	switch x := pathValue(v, path...).(type) {
	case float64:
		return x
	case string:
		var f float64
		_ = json.Unmarshal([]byte(x), &f)
		return f
	}
	return 0
}

func listAt(v any, path ...any) []any { // RECOVERY: always inlined; name unknown.
	a, _ := pathValue(v, path...).([]any)
	return a
}

// pathValue walks decoded JSON; nil when a step is missing or mistyped.
func pathValue(v any, path ...any) any {
	for _, key := range path {
		switch k := key.(type) {
		case string:
			m, ok := v.(map[string]any)
			if !ok {
				return nil
			}
			v = m[k]
		case int:
			a, ok := v.([]any)
			if !ok || k < 0 || k >= len(a) {
				return nil
			}
			v = a[k]
		}
	}
	return v
}

