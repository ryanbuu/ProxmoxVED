#!/usr/bin/env python3
"""Local tests; never invoke PVE, systemd, apt, or live DHCP."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALL = (ROOT / 'install/kea-install.sh').read_text()
CT = (ROOT / 'ct/kea.sh').read_text()


def installer_configs():
    return dict(re.findall(r"cat <<'CONF' >/etc/kea/([^\n]+)\n(.*?)\nCONF", INSTALL, re.S))


class KeaTests(unittest.TestCase):
    def test_staged_install(self):
        configs = installer_configs()
        self.assertEqual(len(configs), 3)
        dhcp = json.loads(configs['kea-dhcp4.conf'])['Dhcp4']
        self.assertEqual(dhcp['subnet4'], [])
        self.assertFalse(dhcp['dhcp-ddns']['enable-updates'])
        self.assertEqual(dhcp['interfaces-config']['dhcp-socket-type'], 'udp')
        agent = json.loads(configs['kea-ctrl-agent.conf'])['Control-agent']
        self.assertEqual(agent['http-host'], '127.0.0.1')
        self.assertEqual(agent['control-sockets']['dhcp4'], dhcp['control-socket'])
        self.assertLess(INSTALL.index('systemctl mask'), INSTALL.index('$STD apt install'))
        self.assertNotRegex(re.sub(r"cat <<'GUIDE'.*?\nGUIDE", '', INSTALL, flags=re.S), r'systemctl (?:enable|start|unmask) ')

    def test_update_entrypoint(self):
        block = re.search(r'cat <<EOF_UPDATE >/usr/bin/update\n(.*?)\nEOF_UPDATE', INSTALL, re.S)[1]
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            # Generate the heredoc exactly as the installer would.
            result = subprocess.run(['bash', '-c', 'cat <<EOF_UPDATE\n'+block+'\nEOF_UPDATE'],
                                    env={**os.environ, 'COMMUNITY_SCRIPTS_URL': 'https://example.test/fork'},
                                    capture_output=True, text=True, check=True)
            stub = p/'curl'
            stub.write_text('#!/bin/bash\n[[ "$1" == -fsSL && "$2" == https://example.test/fork/ct/kea.sh ]] || exit 7\necho "echo fork-update-ok"\n')
            stub.chmod(0o755)
            run = subprocess.run(['bash', '-c', result.stdout],
                                 env={**os.environ, 'PATH': str(p)+':'+os.environ['PATH']},
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout.strip(), 'fork-update-ok')

    def run_update(self, fail_apt=False, invalid_config=False):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            (p/'etc/kea').mkdir(parents=True)
            (p/'opt').mkdir()
            for name, content in installer_configs().items():
                (p/'etc/kea'/name).write_text(content)
            state = {'kea-dhcp4-server': ['active','enabled'],
                     'kea-dhcp-ddns-server': ['inactive','disabled'],
                     'kea-ctrl-agent': ['inactive','masked']}
            (p/'state.json').write_text(json.dumps(state))
            (p/'calls').touch()
            bindir = p/'bin'
            bindir.mkdir()
            stub = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['TEST_ROOT']); args=sys.argv[1:]; name=Path(sys.argv[0]).name
with (p/'calls').open('a') as f: f.write(name+' '+' '.join(args)+'\\n')
if name.startswith('kea-'):
    sys.exit(1 if os.environ.get('INVALID_CONFIG')=='1' else 0)
if name=='apt': sys.exit(1 if os.environ.get('FAIL_APT')=='1' else 0)
s=json.loads((p/'state.json').read_text()); service=args[-1]
if args[0]=='is-active': sys.exit(0 if s[service][0]=='active' else 3)
if args[0]=='is-enabled':
    print(s[service][1]); sys.exit(0 if s[service][1]=='enabled' else 1)
if args[0]=='mask':
    s[service].append(s[service][1]); s[service][1]='masked-runtime'
elif args[0]=='unmask': s[service][1]=s[service].pop()
elif args[0]=='restart': s[service][0]='active'
else: sys.exit(8)
(p/'state.json').write_text(json.dumps(s))
'''
            for name in ['systemctl','apt','kea-dhcp4','kea-dhcp-ddns','kea-ctrl-agent']:
                exe=bindir/name
                exe.write_text(stub)
                exe.chmod(0o755)
            body=re.search(r'function update_script\(\) \{(.*?)\n\}\n\nstart', CT, re.S)[1]
            body=body.replace('/etc/kea', str(p/'etc/kea')).replace('/opt/kea-', str(p/'opt/kea-'))
            prelude='set -e\nSTD=""\nfor f in header_info check_container_storage check_container_resources msg_info msg_ok msg_error; do eval "$f() { :; }"; done\n'
            run=subprocess.run(['bash','-c',prelude+'update_script() {\n'+body+'\n}\nupdate_script'],capture_output=True,text=True,
                env={**os.environ,'PATH':str(bindir)+':'+os.environ['PATH'], 'TEST_ROOT':tmp,
                     'FAIL_APT':str(int(fail_apt)), 'INVALID_CONFIG':str(int(invalid_config))})
            return run, json.loads((p/'state.json').read_text()), (p/'calls').read_text()

    def test_update_preserves_service_state(self):
        run,state,calls=self.run_update()
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertEqual(state['kea-dhcp-ddns-server'],['inactive','disabled'])
        self.assertEqual(state['kea-ctrl-agent'],['inactive','masked'])
        self.assertIn('systemctl restart kea-dhcp4-server',calls)
        self.assertNotIn('systemctl restart kea-dhcp-ddns-server',calls)

    def test_failed_update_cleans_runtime_masks(self):
        run,state,calls=self.run_update(fail_apt=True)
        self.assertNotEqual(run.returncode,0)
        self.assertEqual(state['kea-dhcp4-server'],['active','enabled'])
        self.assertEqual(state['kea-dhcp-ddns-server'],['inactive','disabled'])
        self.assertEqual(state['kea-ctrl-agent'],['inactive','masked'])
        self.assertNotIn('systemctl restart',calls)

    def test_invalid_config_blocks_update(self):
        run,state,calls=self.run_update(invalid_config=True)
        self.assertNotEqual(run.returncode,0)
        self.assertNotIn('apt ',calls)
        self.assertNotIn('systemctl mask',calls)


if __name__ == '__main__':
    unittest.main()
