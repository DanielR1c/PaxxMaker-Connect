package main

// Bonjour: the same _paxxconnect._tcp the phone browses for under
// "Manuell verbinden". Windows has no Bonjour by itself, so the
// responder is built in (pure Go). Failing here is harmless — the QR code
// and the typed address still work.

import (
	"github.com/grandcat/zeroconf"
)

var mdnsServer *zeroconf.Server // kept for the process lifetime

func advertise(port int) {
	name := appName + " (" + hostName() + ")"
	txt := []string{"v=" + version, "host=" + hostName()}
	srv, err := zeroconf.Register(name, "_paxxconnect._tcp", "local.", port, txt, nil)
	if err != nil {
		state.Log.Add("Bonjour: " + err.Error())
		return
	}
	mdnsServer = srv
}
