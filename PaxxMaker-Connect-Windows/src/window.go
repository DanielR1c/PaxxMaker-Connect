package main

// Where the pairing page shows up. Deliberately the browser: a native window
// (WebView2) was built and worked, but it does not solve the real obstacle —
// Windows Smart App Control blocks the unsigned exe either way — and it added
// a runtime dependency for no gain. Everything that wants the page calls this:
// the first start, the tray menu, and a second start of the exe via /ui/show.
func showPairing() { openBrowser(pairingURL()) }
