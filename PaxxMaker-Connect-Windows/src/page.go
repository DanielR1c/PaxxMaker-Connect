package main

// The pairing/status page (German or English), served only to a browser on
// this PC. Refreshes its numbers every few seconds.

import "strings"

func pageHTML() string {
	t := map[string]string{
		"title":     L("PaxxMaker-Connect", "PaxxMaker-Connect"),
		"ready":     L("Bereit", "Ready"),
		"code":      L("Kopplungscode", "Pairing code"),
		"scan":      L("QR-Code mit der iPhone-Kamera scannen – PaxxMaker koppelt sich dann von selbst. Oder in PaxxMaker unter Slicer › Manuell verbinden die Adresse und den Code eingeben.", "Scan the QR code with the iPhone camera – PaxxMaker pairs by itself. Or enter the address and the code in PaxxMaker under Slicer › Connect manually."),
		"address":   L("Adresse", "Address"),
		"orcaOK":    L("OrcaSlicer gefunden", "OrcaSlicer found"),
		"orcaMiss":  L("OrcaSlicer fehlt – bitte installieren (Snapmaker Orca allein reicht nicht)", "OrcaSlicer missing – please install it (Snapmaker Orca alone is not enough)"),
		"profiles":  L("Profile aus", "Profiles from"),
		"noProf":    L("Keine Orca-Profile gefunden", "No Orca profiles found"),
		"jobs":      L("Letzte Aufträge", "Recent jobs"),
		"autostart": L("Beim Anmelden automatisch starten", "Start automatically at login"),
		"quit":      L("Dienst beenden", "Quit service"),
		"tray":      L("Diese Seite kann geschlossen werden – PaxxMaker-Connect läuft als Symbol im Infobereich der Taskleiste weiter (rechts unten, ggf. hinter dem Pfeil). Das Symbol oder ein erneuter Start des Programms holt die Seite zurück.", "You can close this page – PaxxMaker-Connect keeps running as an icon in the taskbar's notification area (bottom right, maybe behind the arrow). The icon, or starting the program again, brings the page back."),
		"log":       L("Protokoll", "Log"),
		"quitDone":  L("Dienst beendet. Diese Seite kann geschlossen werden.", "Service stopped. This page can be closed."),
	}
	html := `<!DOCTYPE html>
<html lang="{{lang}}"><head><meta charset="utf-8"><title>{{title}}</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{--bg:#f4f5f7;--card:#fff;--fg:#1c1c1e;--muted:#6e6e73;--accent:#0a84ff;--ok:#34c759;--bad:#ff3b30;--line:#e5e5ea}
@media(prefers-color-scheme:dark){:root{--bg:#1c1c1e;--card:#2c2c2e;--fg:#f2f2f7;--muted:#a1a1a6;--line:#3a3a3c}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:640px;margin:0 auto;padding:24px 16px}
.card{background:var(--card);border-radius:14px;padding:18px 20px;margin-bottom:14px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
h1{font-size:20px;margin:0 0 2px}.sub{color:var(--muted);font-size:13px}
.pair{display:flex;gap:18px;align-items:flex-start;flex-wrap:wrap}
.pair img{width:180px;height:180px;border-radius:8px;background:#fff;padding:6px}
.code{font:700 34px/1 ui-monospace,Menlo,Consolas,monospace;letter-spacing:3px;margin:6px 0 10px;user-select:all}
.muted{color:var(--muted);font-size:13px}.row{display:flex;align-items:center;gap:8px;margin:4px 0}
.dot{width:10px;height:10px;border-radius:50%;flex:none}.ok{background:var(--ok)}.bad{background:var(--bad)}
.jobs div{display:flex;justify-content:space-between;gap:12px;padding:6px 0;border-top:1px solid var(--line);font-size:14px}
.jobs div:first-child{border-top:0}.err{color:var(--bad)}
label{display:flex;align-items:center;gap:10px;cursor:pointer}
button{background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:9px;padding:8px 14px;font:inherit;cursor:pointer}
button.q{color:var(--bad)}
pre{font:12px/1.4 ui-monospace,Menlo,Consolas,monospace;color:var(--muted);white-space:pre-wrap;margin:0;max-height:220px;overflow:auto}
</style></head><body><div class="wrap">
<div class="card"><h1>{{title}} <span class="muted" id="ver"></span></h1><div class="sub" id="status">{{ready}}</div>
<p class="muted" style="margin:10px 0 0">{{tray}}</p></div>
<div class="card"><div class="pair"><img src="/qr.png" alt="QR">
<div><div class="muted">{{code}}</div><div class="code" id="token"></div>
<div class="muted">{{address}}: <span id="addr"></span></div>
<p class="muted" style="margin:10px 0 0">{{scan}}</p></div></div></div>
<div class="card"><div class="row"><span class="dot" id="orcaDot"></span><span id="orca"></span></div>
<div class="row"><span class="dot" id="profDot"></span><span id="prof"></span></div></div>
<div class="card" id="jobsCard" style="display:none"><div class="muted" style="margin-bottom:6px">{{jobs}}</div><div class="jobs" id="jobs"></div></div>
<div class="card"><label><input type="checkbox" id="auto"> {{autostart}}</label>
<div style="margin-top:12px"><button class="q" id="quit">{{quit}}</button></div></div>
<div class="card"><div class="muted" style="margin-bottom:6px">{{log}}</div><pre id="log"></pre></div>
</div>
<script>
const T={orcaOK:{{orcaOK}},orcaMiss:{{orcaMiss}},profiles:{{profiles}},noProf:{{noProf}},quitDone:{{quitDone}}};
let quitting=false;
async function refresh(){
  if(quitting)return;
  try{
    const s=await (await fetch('/ui/state')).json();
    document.getElementById('ver').textContent=s.version;
    document.getElementById('token').textContent=s.token;
    document.getElementById('addr').textContent=s.ip+':'+s.port+' ('+s.host+')';
    document.getElementById('orca').textContent=s.orca?T.orcaOK:T.orcaMiss;
    document.getElementById('orcaDot').className='dot '+(s.orca?'ok':'bad');
    document.getElementById('prof').textContent=s.apps.length?T.profiles+': '+s.apps.join(', '):T.noProf;
    document.getElementById('profDot').className='dot '+(s.apps.length?'ok':'bad');
    document.getElementById('auto').checked=!!s.autostart;
    const jc=document.getElementById('jobsCard'),jl=document.getElementById('jobs');
    if(s.jobs.length){jc.style.display='';jl.innerHTML='';
      for(const j of s.jobs){const d=document.createElement('div');
        let r='';
        if(j.state==='done'&&j.result){r=(j.result.filament_g??0).toFixed(1)+' g · '+Math.round((j.result.time_s??0)/60)+' min';}
        else if(j.state==='failed'){r='<span class="err">'+(j.error||'')+'</span>';}
        else{r=Math.round((j.progress||0)*100)+' %';}
        d.innerHTML='<span>'+(j.process||'Job')+'</span><span>'+r+'</span>';jl.appendChild(d);}
    }else{jc.style.display='none';}
    document.getElementById('log').textContent=(s.log||[]).slice(-40).join('\n');
  }catch(e){document.getElementById('status').textContent='…';}
}
document.getElementById('auto').addEventListener('change',async e=>{
  await fetch('/ui/autostart',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'on='+(e.target.checked?'1':'0')});
});
document.getElementById('quit').addEventListener('click',async()=>{
  quitting=true;await fetch('/ui/quit',{method:'POST'});
  document.body.innerHTML='<div class="wrap"><div class="card">'+T.quitDone+'</div></div>';
});
refresh();setInterval(refresh,4000);
</script></body></html>`
	lang := "en"
	if isGerman {
		lang = "de"
	}
	html = strings.ReplaceAll(html, "{{lang}}", lang)
	for k, v := range t {
		if strings.Contains(html, "{{"+k+"}}") {
			// JS string literals for the few used inside <script>.
			if k == "orcaOK" || k == "orcaMiss" || k == "profiles" || k == "noProf" || k == "quitDone" {
				html = strings.ReplaceAll(html, "{{"+k+"}}", jsString(v))
			} else {
				html = strings.ReplaceAll(html, "{{"+k+"}}", htmlEscape(v))
			}
		}
	}
	return html
}

func htmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;").Replace(s)
}

func jsString(s string) string {
	return "\"" + strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "\n", "\\n", "<", "\\u003c").Replace(s) + "\""
}
