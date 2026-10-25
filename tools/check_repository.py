#!/usr/bin/env python3
"""Check the source-only repository and local Markdown links before packaging."""
from pathlib import Path
import re
root=Path(__file__).resolve().parent.parent
issues=[]
for required in ['LICENSE','NOTICE.md','SECURITY.md','README.md','docs/INSTALL.md','docs/CONFIGURATION.md','docs/TROUBLESHOOTING.md']:
    if not (root/required).is_file():issues.append('missing '+required)
for path in root.rglob('*'):
    rel=path.relative_to(root)
    if not path.is_file() or any(x in rel.parts for x in ['.git','build','toolchain','__pycache__']):continue
    if path.suffix.lower() in {'.ipa','.dylib','.p12','.p8','.pem','.mobileprovision','.zip'}:issues.append('unexpected binary/credential artifact '+str(rel))
    if path.suffix!='.md':continue
    for target in re.findall(r'\]\(([^)\s]+)\)',path.read_text()):
        if ':' in target or target.startswith('#'):continue
        target=target.split('#',1)[0]
        if target and not (path.parent/target).is_file():issues.append(f'{rel}: missing link {target}')
if issues:raise SystemExit('\n'.join(issues))
print('PASS: source-only package, required public docs/license and local Markdown links')
