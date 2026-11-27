"""Release identity must match its actual dylib; policy and backup run production code."""
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from build_865_migration_package import stamp_client_release

ROOT = Path(__file__).resolve().parents[1]

class ClientReleaseTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform=='darwin','Requires Objective-C/Foundation')
    def test_actual_presenter_resolves_865_tabs_without_covering_editor_or_share(self):
        code=(ROOT/'AMProjExport/AMClientRelease.m').read_text(encoding='utf-8')
        start=code.index('static UIViewController *AMReleaseTopController(void) {')
        resolver=code[start:code.index('// 只收集原生',start)]
        fixture=(ROOT/'tests/client_release_presenter_smoke.m').read_text(encoding='utf-8').replace('// AMPROJ_PRODUCTION_TOP_CONTROLLER',resolver)
        with tempfile.TemporaryDirectory() as temporary:
            source=Path(temporary)/'presenter.m'; binary=Path(temporary)/'presenter'
            source.write_text(fixture,encoding='utf-8')
            built=subprocess.run(['clang','-fobjc-arc','-framework','Foundation','-framework','CoreGraphics','-I',str(ROOT/'AMProjExport'),str(source),'-o',str(binary)],capture_output=True,text=True,timeout=30)
            self.assertEqual(built.returncode,0,built.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('CLIENT_RELEASE_PRESENTER_PASS',result.stdout)

    def test_packager_uses_compiled_identity_and_clears_stale_metadata(self):
        info = plistlib.dumps({'AMProjReleaseCode':999,'AMProjReleaseChannel':'beta','AMProjReleaseDate':'20200101','AMAppUpdate':{'token':'stale-device-grant'},'name':'keep'})
        for channel in ('stable','beta'):
            marker = ('AMCLIENT_RELEASE:174:'+channel+':123456789abc\0').encode()
            value = plistlib.loads(stamp_client_release(info,marker))
            self.assertEqual((value['AMProjReleaseCode'],value['AMProjReleaseChannel'],value['AMProjReleaseBuild']), (174,channel,'123456789abc'))
        self.assertEqual(plistlib.loads(stamp_client_release(info,b'legacy')),{'name':'keep'})
        for marker in (b'AMCLIENT_RELEASE:0:beta:123456789abc\0',b'AMCLIENT_RELEASE:174:beta:unknown\0',b'AMCLIENT_RELEASE:174:beta:123456789abc\0AMCLIENT_RELEASE:175:beta:123456789abc\0'):
            with self.assertRaises(RuntimeError):stamp_client_release(info,marker)
        marker = b'AMCLIENT_RELEASE:176:stable:123456789abc\0'
        value = plistlib.loads(stamp_client_release(info, marker + b'AMCLIENT_RELEASE_DATE:20261126\0'))
        self.assertEqual(value['AMProjReleaseDate'], '20261126')
        self.assertNotIn('AMAppUpdate', value)
        for date in (b'unknown', b'20260230', b'20261126\0AMCLIENT_RELEASE_DATE:20261127'):
            with self.assertRaises(RuntimeError): stamp_client_release(info, marker + b'AMCLIENT_RELEASE_DATE:' + date + b'\0')

    @unittest.skipUnless(sys.platform=='darwin','Requires Objective-C/Foundation')
    def test_actual_policy_and_backup_collector(self):
        code=(ROOT/'AMProjExport/AMClientRelease.m').read_text(encoding='utf-8')
        start=code.index('static BOOL AMReleaseCollectBackup(')
        collector=code[start:code.index('@class AMReleaseManager;',start)]
        fixture=(ROOT/'tests/client_release_policy_smoke.m').read_text(encoding='utf-8').replace('// AMPROJ_PRODUCTION_BACKUP_COLLECTOR',collector)
        with tempfile.TemporaryDirectory() as temporary:
            source=Path(temporary)/'release.m'; binary=Path(temporary)/'release'
            source.write_text(fixture,encoding='utf-8')
            built=subprocess.run(['clang','-fobjc-arc','-framework','Foundation','-lz','-I',str(ROOT/'AMProjExport'),str(source),str(ROOT/'AMProjExport/AMProjImportArchive.m'),str(ROOT/'AMProjExport/AMProjZIPWriter.m'),'-o',str(binary)],capture_output=True,text=True,timeout=60)
            self.assertEqual(built.returncode,0,built.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('CLIENT_RELEASE_POLICY_AND_BACKUP_PASS',result.stdout)

    def test_known_update_denial_does_not_revoke_plugin_authorization(self):
        source=(ROOT/'AMProjExport/AMCloudSync.m').read_text(encoding='utf-8')
        start=source.index('static void AMCloudQuietReauthAttempt(void) {')
        block=source[start:source.index('void AMCloudSyncInstallPluginHooksEarly',start)]
        self.assertLess(block.index('error.code == 426'),block.index('AMCloudLapsePluginAuthorization();'))
        self.assertIn('AMClientReleaseHandleResponse(rawResponse, data)',source)

    def test_actual_web_request_script_preserves_auth_and_external_requests(self):
        header=(ROOT/'AMProjExport/AMClientPackageIdentity.h').read_text(encoding='utf-8')
        script_function=header.split('static inline NSString *AMClientPackageRequestScript(void)',1)[1]
        body=script_function.split('return [NSString stringWithFormat:',1)[1].split(',value];',1)[0]
        script=''.join(json.loads('"'+s+'"') for s in re.findall(r'@?"((?:\\.|[^"\\])*)"',body))
        script=script.replace('%@',json.dumps({'release':174,'channel':'beta','build':'123456789abc'}))
        fixture=(ROOT/'tests/client_release_web_smoke.cjs').read_text(encoding='utf-8')
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'web.cjs'; path.write_text(fixture.replace('// AMPROJ_WEB_SCRIPT',script),encoding='utf-8')
            result=subprocess.run(['node',str(path)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('CLIENT_RELEASE_WEB_PASS',result.stdout)
