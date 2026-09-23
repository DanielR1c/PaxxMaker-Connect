//go:build windows

package main

import "golang.org/x/sys/windows/registry"

// The user's Windows display language, e.g. "de-DE".
func systemLocale() string {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Control Panel\International`, registry.QUERY_VALUE)
	if err != nil {
		return ""
	}
	defer k.Close()
	v, _, err := k.GetStringValue("LocaleName")
	if err != nil {
		return ""
	}
	return v
}
