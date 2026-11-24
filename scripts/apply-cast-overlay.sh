#!/bin/bash
set -euo pipefail
APP="$1"
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib,sys
root=Path(sys.argv[1]); project=root/'project.yml'
s=project.read_text()
if 'GoogleCast:' not in s:
    s=s.replace('packages:\n','packages:\n  GoogleCast:\n    url: https://github.com/googlecast/google-cast-ios-sdk\n    exactVersion: "4.8.6"\n',1)
key='  StremioXiOSNative:\n'
if key not in s: raise SystemExit('Native iOS target not found')
start=s.index(key); end=s.find('\n  StremioX',start+len(key)); end=len(s) if end<0 else end
chunk=s[start:end]
if 'GoogleCastDynamic' not in chunk:
    chunk=chunk.replace('    dependencies:\n','    dependencies:\n      - package: GoogleCast\n        product: GoogleCastDynamic\n',1)
# Register the entire Cast directory under the native target's sources.
# This avoids relying on an exact match for the commented SourcesiOS entry.
if '    sources:\\n' not in chunk:
    raise SystemExit('Native iOS target has no sources section')
if '      - Cast\\n' not in chunk:
    chunk=chunk.replace('    sources:\\n','    sources:\\n      - Cast\\n',1)
s=s[:start]+chunk+s[end:]; project.write_text(s)
info=root/'Resources/Info-iOS.plist'
pl=plistlib.loads(info.read_bytes())
pl['NSLocalNetworkUsageDescription']='Stremio uses the local network to discover Chromecast devices.'
pl['NSBonjourServices']=sorted(set(pl.get('NSBonjourServices',[]))|{'_googlecast._tcp','_CC1AD845._googlecast._tcp'})
info.write_bytes(plistlib.dumps(pl,fmt=plistlib.FMT_XML))
app=root/'SourcesiOS/StremioXiOSApp.swift'; a=app.read_text()
if 'CastManager.shared.setup()' not in a:
    a=a.replace('    init() {\n','    init() {\n        CastManager.shared.setup()\n',1)
app.write_text(a)
player=root/'Sources/PlayerScreen.swift'; p=player.read_text()
anchor='            iconButton("gearshape", label: "Player settings") { openPanel(.playerSettings) }'
if 'CastButton(url: curURL ?? url, title: title)' not in p:
    if anchor not in p: raise SystemExit('Player toolbar insertion anchor not found')
    p=p.replace(anchor,anchor+'\n            #if os(iOS)\n            CastButton(url: curURL ?? url, title: title).frame(width: 38, height: 38)\n            #endif',1)
player.write_text(p)
PY
