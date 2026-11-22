#!/bin/bash
set -euo pipefail
APP="${1:-app}"
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib,sys
root=Path(sys.argv[1]); project=root/'project.yml'
s=project.read_text()
if 'GoogleCast:' not in s:s=s.replace('packages:\\n','packages:\\n  GoogleCast:\\n    url: https://github.com/googlecast/google-cast-ios-sdk\\n    exactVersion: "4.8.6"\\n',1)
key='  StremioXiOSNative:\\n'; start=s.index(key); end=s.find('\\n  StremioX',start+len(key)); end=len(s) if end<0 else end
chunk=s[start:end]
if 'GoogleCastDynamic' not in chunk:chunk=chunk.replace('    dependencies:\\n','    dependencies:\\n      - package: GoogleCast\\n        product: GoogleCastDynamic\\n',1)
if 'Cast/CastManager.swift' not in chunk:chunk=chunk.replace('      - SourcesiOS\\n','      - SourcesiOS\\n      - Cast/CastManager.swift\\n      - Cast/CastButton.swift\\n',1)
s=s[:start]+chunk+s[end:];project.write_text(s)
info=root/'Resources/Info-iOS.plist'; p=plistlib.loads(info.read_bytes())
p['NSLocalNetworkUsageDescription']='Stremio uses the local network to discover Chromecast devices.'
p['NSBonjourServices']=sorted(set(p.get('NSBonjourServices',[]))|{'_googlecast._tcp','_CC1AD845._googlecast._tcp'})
info.write_bytes(plistlib.dumps(p,fmt=plistlib.FMT_XML))
app=root/'SourcesiOS/StremioXiOSApp.swift';s=app.read_text()
if 'CastManager.shared.setup()' not in s:s=s.replace('    init() {\\n','    init() {\\n        CastManager.shared.setup()\\n',1)
app.write_text(s)
player=root/'Sources/PlayerScreen.swift'; s=player.read_text()
anchor='            iconButton("gearshape", label: "Player settings") { openPanel(.playerSettings) }'
if 'CastButton(url: curURL ?? url, title: title)' not in s:
 if anchor not in s:raise SystemExit('Player toolbar insertion anchor not found')
 s=s.replace(anchor,anchor+'\\n            #if os(iOS)\\n            CastButton(url: curURL ?? url, title: title).frame(width: 38, height: 38)\\n            #endif',1)
player.write_text(s)
PY
