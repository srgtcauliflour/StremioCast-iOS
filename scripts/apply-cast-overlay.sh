#!/bin/bash
set -euo pipefail
APP="$1"
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib,sys

root=Path(sys.argv[1])
project=root/'project.yml'
s=project.read_text()

if 'GoogleCast:' not in s:
    s=s.replace('packages:\n','packages:\n  GoogleCast:\n    url: https://github.com/googlecast/google-cast-ios-sdk\n    exactVersion: "4.8.6"\n',1)

key='  StremioXiOSNative:\n'
if key not in s: raise SystemExit('Native iOS target not found')
start=s.index(key)
end=s.find('\n  StremioX',start+len(key))
end=len(s) if end<0 else end
chunk=s[start:end]

if 'GoogleCastDynamic' not in chunk:
    chunk=chunk.replace('    dependencies:\n','    dependencies:\n      - package: GoogleCast\n        product: GoogleCastDynamic\n',1)
if '    sources:\n' not in chunk:
    raise SystemExit('Native iOS target has no sources section')
if '      - Cast\n' not in chunk:
    chunk=chunk.replace('    sources:\n','    sources:\n      - Cast\n',1)
s=s[:start]+chunk+s[end:]
project.write_text(s)

info=root/'Resources/Info-iOS.plist'
pl=plistlib.loads(info.read_bytes())
pl['NSLocalNetworkUsageDescription']='Stremio uses the local network to discover Chromecast devices.'
pl['NSBonjourServices']=sorted(set(pl.get('NSBonjourServices',[]))|{'_googlecast._tcp','_CC1AD845._googlecast._tcp'})
info.write_bytes(plistlib.dumps(pl,fmt=plistlib.FMT_XML))

app=root/'SourcesiOS/StremioXiOSApp.swift'
a=app.read_text()
if 'CastManager.shared.setup()' not in a:
    a=a.replace('    init() {\n','    init() {\n        CastManager.shared.setup()\n',1)
app.write_text(a)

player=root/'Sources/PlayerScreen.swift'
p=player.read_text()
if 'CastButton(url: curURL ?? url, title: title, headers: curHeaders ?? headers ?? [:])' not in p:
    anchor='            iconButton("gearshape", label: "Player settings")'
    i=p.find(anchor)
    if i<0: raise SystemExit('Player toolbar insertion anchor not found')
    end=p.find('\n',i)
    p=p[:end+1]+'            #if os(iOS)\n            CastButton(url: curURL ?? url, title: title, headers: curHeaders ?? headers ?? [:]).frame(width: 38, height: 38)\n            #endif\n'+p[end+1:]

if '@ObservedObject private var castManager = CastManager.shared' not in p:
    anchor='    @EnvironmentObject private var theme: ThemeManager'
    if anchor not in p: raise SystemExit('Player environment anchor not found')
    p=p.replace(anchor,anchor+'\n    @ObservedObject private var castManager = CastManager.shared',1)

alert='''        .alert("Chromecast", isPresented: Binding(
            get: { castManager.lastError != nil },
            set: { if !$0 { castManager.clearError() } }
        )) {
            Button("OK", role: .cancel) { castManager.clearError() }
        } message: {
            Text(castManager.lastError ?? "Unknown Chromecast error")
        }'''
if '.alert("Chromecast"' not in p:
    anchor='        .sheet(isPresented: $showShare) { ShareSheet(items: [curURL ?? url]) }'
    if anchor not in p: raise SystemExit('Player sheet anchor not found')
    p=p.replace(anchor,anchor+'\n'+alert,1)

if 'StremioCastPlaybackStarted' not in p:
    anchor='        .onDisappear {'
    if anchor not in p: raise SystemExit('Player onDisappear anchor not found')
    p=p.replace(anchor,'        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StremioCastPlaybackStarted"))) { _ in\n            if !isPaused {\n                coordinator.player?.togglePause()\n                isPaused = true\n            }\n        }\n'+anchor,1)

player.write_text(p)
PY
