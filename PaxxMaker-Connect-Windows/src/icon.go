package main

// One icon for all three places it shows up: the tray, the window and the
// favicon of the local page.

import _ "embed"

//go:embed assets/icon.ico
var appIcon []byte
