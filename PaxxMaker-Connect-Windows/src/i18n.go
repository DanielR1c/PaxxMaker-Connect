package main

import (
	"os"
	"strings"
)

// German on a German Windows, English everywhere else — same rule as the
// Mac version.
var isGerman = detectGerman()

func L(de, en string) string {
	if isGerman {
		return de
	}
	return en
}

func detectGerman() bool {
	if v := os.Getenv("PAXX_LANG"); v != "" {
		return strings.HasPrefix(strings.ToLower(v), "de")
	}
	if loc := systemLocale(); loc != "" {
		return strings.HasPrefix(strings.ToLower(loc), "de")
	}
	for _, k := range []string{"LC_ALL", "LC_MESSAGES", "LANG"} {
		if v := os.Getenv(k); v != "" {
			return strings.HasPrefix(strings.ToLower(v), "de")
		}
	}
	return false
}
