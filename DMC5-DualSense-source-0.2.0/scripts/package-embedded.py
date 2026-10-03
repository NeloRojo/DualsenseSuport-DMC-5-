"""Rebuild a minimal in-process release from the unchanged development sources."""
import argparse,json,shutil,sys,zipfile,hashlib,os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
DEPS=Path(os.environ.get('DMC5_DEPS',str(ROOT/'.venv/Lib/site-packages')))
def write_zip(path,files):
 with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
  for name,data in sorted(files.items()):z.writestr(name,data)
def cut(code,start,end):
 a=code.index(start);b=code.index(end,a);return code[:a]+code[b:]
def build(destination):
 out=destination.resolve()
 if out.exists():raise ValueError('Use a new destination; never overwrite a development copy')
 mod=out/'DMC5 DualSense Preview';bridge=mod/'reframework/data/dmc5_dualsense'
 runtime=bridge/'runtime';runtime.mkdir(parents=True)
 profiles=runtime/'profiles';profiles.mkdir()
 libs=ROOT/'dist/DMC5DualSense/_internal'
 # Minimal CPython extensions. No NumPy, BLAS, zstandard, finder or capture DLL.
 names=['python310.dll','python3.dll','VCRUNTIME140.dll','VCRUNTIME140_1.dll',
        '_ctypes.pyd','libffi-7.dll','_hashlib.pyd','libcrypto-1_1.dll','_socket.pyd',
        'select.pyd','_bz2.pyd','_lzma.pyd','unicodedata.pyd',
        'hid.cp310-win_amd64.pyd','_cffi_backend.cp310-win_amd64.pyd']
 for name in names:shutil.copy2(libs/name,runtime/name)
 stdlib={}
 excluded={'test','tests','tkinter','turtledemo','idlelib','ensurepip','site-packages','__pycache__','venv','distutils','lib2to3'}
 for p in (Path(sys.base_prefix)/'Lib').rglob('*.py'):
  rel=p.relative_to(Path(sys.base_prefix)/'Lib')
  if not excluded.intersection(rel.parts):stdlib[rel.as_posix()]=p.read_bytes()
 write_zip(runtime/'python310.zip',stdlib)
 app={}
 for name in ['effects','dualsense','audio_haptics','lifecycle','native_input']:
  code=(ROOT/'helper'/f'{name}.py').read_text()
  if name=='lifecycle':
   code=code.replace('    def running(self):\n',"    def running(self):\n        if globals().get('EMBEDDED_STOP_EVENT') and self.kernel and self.kernel.WaitForSingleObject(EMBEDDED_STOP_EVENT,0)==0:return False\n")
  app[name+'.py']=code.encode()
 main=(ROOT/'helper/main.py').read_text()
 for line in ['from action_capture import ActionCapture','from pc_preview import PCPreview','from audio_finder import AudioFinder']:
  main=main.replace(line,'')
 main=main.replace('    action_capture=ActionCapture(args.bridge,args.parent_pid) if args.bridge and args.speaker else None','    action_capture=None')
 main=main.replace('    pc_preview=PCPreview() if action_capture else None','    pc_preview=None')
 main=main.replace('    finder=AudioFinder(args.bridge) if action_capture else None','    finder=None')
 # Remove unreachable development command dispatch and status payloads.
 main=cut(main,"                    if finder and str(request.get('event','')).startswith('finder_'):","                    try:\n                        e=p['effects'][request['event']]")
 main=main.replace(',capture=action_capture.status() if action_capture else {},finder=finder.status() if finder else {},pc_preview=pc_preview.status() if pc_preview else {}','')
 app['main.py']=main.encode()
 app['embedded_entry.py']=b'''import ctypes,logging,os,sys,traceback
from pathlib import Path
from logging.handlers import RotatingFileHandler
def run():
 import main,lifecycle
 bridge=Path(sys.argv[sys.argv.index('--bridge')+1]);root=bridge/'runtime'
 log=RotatingFileHandler(root/'runtime.log',maxBytes=262144,backupCount=1,encoding='utf-8')
 logging.basicConfig(level=logging.WARNING,format='%(asctime)s %(levelname)s %(message)s',handlers=[log])
 sys.stdout=sys.stderr=open(root/'runtime-errors.log','a',encoding='utf-8',buffering=1)
 kernel=ctypes.WinDLL('kernel32',use_last_error=True)
 kernel.OpenEventW.argtypes=[ctypes.c_ulong,ctypes.c_int,ctypes.c_wchar_p];kernel.OpenEventW.restype=ctypes.c_void_p
 kernel.CloseHandle.argtypes=[ctypes.c_void_p]
 handle=kernel.OpenEventW(0x100000,False,'Local\\\\DMC5DualSenseStop_'+str(os.getpid()))
 lifecycle.EMBEDDED_STOP_EVENT=handle
 try:main.main()
 except BaseException:traceback.print_exc()
 finally:
  if handle:kernel.CloseHandle(handle)
'''
 for name in ['sounddevice.py','_sounddevice.py']:app[name]=(DEPS/name).read_bytes()
 for package in ['cffi','pycparser']:
  for p in (DEPS/package).rglob('*.py'):app[p.relative_to(DEPS).as_posix()]=p.read_bytes()
 write_zip(runtime/'app.zip',app)
 portaudio=runtime/'_sounddevice_data/portaudio-binaries';portaudio.mkdir(parents=True)
 shutil.copy2(DEPS/'_sounddevice_data/portaudio-binaries/libportaudio64bit.dll',portaudio/'libportaudio64bit.dll')
 members=set()
 for name in ['nero','dante','vergil','common']:
  data=json.loads((ROOT/'profiles'/f'{name}.json').read_text())
  for event in list(data['effects']):
   if event.startswith('preview_') or event.endswith('_test') or event in ('trigger_test','damage_test'):del data['effects'][event]
  for effect in data['effects'].values():
   for key in ('speaker_audio','haptic_audio'):
    if 'file' in effect.get(key,{}):members.add(effect[key]['file'])
  (profiles/f'{name}.json').write_text(json.dumps(data,indent=2)+'\n')
 with zipfile.ZipFile(ROOT/'profiles/audio.dmcpack') as src:
  write_zip(profiles/'audio.dmcpack',{n:src.read(n) for n in sorted(members)})
 (bridge/'native_input.ini').write_text('[input]\nenabled=0\n')
 config=json.loads((ROOT/'reframework/data/dmc5_dualsense/config.json').read_text())
 config.update(enabled=True,hp_path=[],hp_method='get_hp',speaker_volume=100)
 (bridge/'config.json').write_text(json.dumps(config,indent=2)+'\n')
 plugins=mod/'reframework/plugins';plugins.mkdir(parents=True)
 shutil.copy2(ROOT/'build/embedded/DMC5DualSensePlugin.dll',plugins/'DMC5DualSensePlugin.dll')
 scripts=mod/'reframework/autorun';scripts.mkdir(parents=True)
 code=(ROOT/'reframework/autorun/dmc5_dualsense.lua').read_text()
 code=cut(code,'local function export_player(','local function emit(')
 code=cut(code,'        if player and diagnostic_player~=id then','        if id~=previous_player then')
 code=cut(code,'        if os.clock()-last_telemetry>=0.25 then','    end)\n    error_text')
 code='\n'.join(line for line in code.splitlines() if 'table.insert(sword_contacts' not in line and 'if #sword_contacts>30' not in line)
 code=code.replace("; log.info('[DualSense] '..event)",'').replace('Volumen del altavoz (%)','Controller speaker volume (%)')
 labels={
 'enabled':'Enable mod','rumble':'Rumble','haptics':'Audio haptics','speaker':'Controller speaker','lightbar':'Lightbar','triggers':'Adaptive triggers','parry':'Parry','enemy_step':'Enemy Step',
 'exceed':'Exceed','exceed_hits':'EX attacks','normal_sword_hits':'Sword impacts','adaptive_exceed':'Exceed L2 resistance','exceed_fire':'Exceed fire lightbar','bringer':'Devil Bringer feedback','adaptive_bringer':'Devil Bringer R2 resistance','devil_trigger':'Devil Trigger','nero_specials':'Showdown / Maximum Bet','max_act':'MAX-Act',
 'dante_weapons':'Next weapon trigger feedback','dante_normal_hits':'Melee impacts / Balrog Ignition','dante_gunfire':'Gunfire / Dr. Faust','dante_devil_trigger':'Devil Trigger','dante_sdt_charge':'SDT gauge lightbar','dante_sdt_transform':'SDT transformation','dante_sdt_attacks':'SDT attacks','dante_sdt_triggers':'Demolition / The Luce triggers','dante_normal_block':'Normal block','dante_royal_block':'Royal Block','dante_royal_release':'Royal Release','dante_normal_release':'Normal Release','dante_devil_counter':'Royal Revenge / Devil Counter',
 'vergil_weapons':'Weapon trigger feedback','vergil_doppel':'Doppelganger lightbar','vergil_sdt_charge':'SDT gauge lightbar','vergil_sdt_transform':'SDT transformation','vergil_specials':'Special techniques','vergil_normal_hits':'Melee impacts / SDT finishers','vergil_beowulf_charge':'Beowulf charge / impacts'}
 groups={
 'General':['enabled','rumble','haptics','speaker','lightbar','triggers','parry','enemy_step'],
 'Nero':['exceed','exceed_hits','normal_sword_hits','adaptive_exceed','exceed_fire','bringer','adaptive_bringer','devil_trigger','nero_specials','max_act'],
 'Dante':[k for k in labels if k.startswith('dante_')],
 'Vergil':[k for k in labels if k.startswith('vergil_')]}
 ui="""re.on_draw_ui(function()
    if not imgui.tree_node('DMC5 DualSense - Preview') then return end
    draw_speaker_volume()
    local fresh=status.heartbeat and os.time()-status.heartbeat<3
    imgui.text('Controller: '..(fresh and status.connected and 'USB connected' or 'offline'))
    imgui.text('Audio haptics: '..(fresh and status.audio_haptics_connected and 'connected' or 'unavailable'))
    if status.audio_haptics_error and status.audio_haptics_error~='' then imgui.text(status.audio_haptics_error) end
"""
 for group,keys in groups.items():
  ui+=f"    if imgui.tree_node('{group}') then\n"
  for key in keys:
   ui+=f"        do local changed,value=imgui.checkbox('{labels[key]}',cfg.{key});if changed then cfg.{key}=value;json.dump_file(dir..'config.json',cfg) end end\n"
  ui+='        imgui.tree_pop()\n    end\n'
 ui+='    imgui.tree_pop()\nend)\n'
 code=code[:code.index('re.on_draw_ui(function()')]+ui
 (scripts/'dmc5_dualsense.lua').write_text(code,encoding='utf-8')
 for name in ['dmc5_dante_combat.lua','dmc5_dante_sdt.lua','dmc5_vergil.lua','dmc5_dante_weapons.lua']:
  code=(ROOT/'reframework/autorun'/name).read_text()
  if name=='dmc5_dante_sdt.lua':code=code[:code.index('function D.draw()')]
  if name=='dmc5_vergil.lua':code=code[:code.index('function V.draw()')]
  if name=='dmc5_dante_weapons.lua':
   code=cut(code,'local fields={}','local last_key')
   code=cut(code,'        if D.active and','    else')
   code=code[:code.index('re.on_frame(function()')]
  (scripts/name).write_text(code,encoding='utf-8')
 (mod/'modinfo.ini').write_text('name=DMC5 DualSense Preview (in-process)\nversion=0.2.0-preview\nauthor=Nelo\ndescription=Experimental USB DualSense effects. Requires REFramework. No helper executable.\n')
 (mod/'README.txt').write_text('''DMC5 DualSense - 0.2.0 preview
Requires Windows x64, DMC5, REFramework and a DualSense connected by USB.
This preview hosts a private reduced Python runtime inside a REFramework DLL;
it is not a full C++ rewrite. No executable is launched, no Python installation is required.
Haptics/speaker require the DualSense USB audio endpoint to remain enabled.
For gameplay controls use Steam Input (effects communicate directly with the USB device).

Install through Fluffy Mod Manager with the game CLOSED. Remove previous
DMC5 DualSense versions first: the helper launcher and this DLL must not coexist.
Do not replace dinput8.dll or original game files. REFramework must be installed separately.
Open Script Generated UI > DMC5 DualSense - Preview. Speaker volume is the first
setting; 0 mutes it. Character and general feature toggles are underneath.
Nero, Dante and Vergil effects are experimental/incomplete. V is not fully supported.
This package contains no audio search, recording, event catalog, SDK dump or development bridge.
The game may create small settings/state/error-log files during use.

Uninstall through Fluffy with the game CLOSED, or remove this mod's five autorun
scripts, DMC5DualSensePlugin.dll and reframework/data/dmc5_dualsense.
Do not delete files belonging to other REFramework mods.
In-process errors can affect the game. Another loaded Python 3.10 interpreter disables
this plugin to avoid sharing its state. Game restart required after plugin replacement.
Rollback: uninstall this package and restore the separately preserved development build.

Credits: Nelo provided design, instructions, audio selection and gameplay testing.
Most code and compilation work was assisted by Codex Astra.
REFramework by praydog; HIDAPI/hidapi Python bindings; CPython; sounddevice/PortAudio;
CFFI/pycparser; MinHook. See licenses and THIRD-PARTY.txt.
Audio effects derived from Devil May Cry 5 are owned by their original rights holders;
open-source software licenses do not grant redistribution rights to game audio.
''',encoding='utf-8')
 licenses=mod/'licenses';licenses.mkdir()
 for notice in (ROOT/'docs/release-licenses').glob('*'):
  if notice.is_file():shutil.copy2(notice,licenses/notice.name)
 shutil.copy2(Path(sys.base_prefix)/'LICENSE.txt',licenses/'Python-LICENSE.txt')
 shutil.copy2(ROOT/'native/third_party/minhook/LICENSE.txt',licenses/'MinHook-LICENSE.txt')
 for prefix in ['cffi-','pycparser-','sounddevice-','hidapi-']:
  for metadata in DEPS.glob(prefix+'*.dist-info'):
   for file in metadata.rglob('*'):
    if file.is_file() and ('license' in file.name.lower() or 'copying' in file.name.lower()):
     dst=licenses/metadata.name/file.relative_to(metadata);dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(file,dst)
 (mod/'THIRD-PARTY.txt').write_text('''Third-party software used by this preview (not REFramework itself):
CPython 3.10.11: Python Software Foundation license. Copyright Python contributors.
hidapi Python binding 0.14.0.post4 / HIDAPI: licenses bundled in licenses/hidapi*.
sounddevice 0.5.3 / PortAudio: MIT licenses, bundled separately.
CFFI 2.1.1 / pycparser 3.0: MIT / BSD licenses, bundled separately.
MinHook: BSD 2-clause, Tsuda Kageyu and contributors.
libffi and OpenSSL 1.1: copyright and license texts bundled separately.
Microsoft Visual C++ runtime files: redistributable dependencies of the Python runtime.
REFramework by praydog is required but is not redistributed in this archive.
No NumPy, OpenBLAS, ASIO runtime, audio extractor, recorder or search index is bundled.
Game sounds remain the property of CAPCOM/their original rights holders.
''',encoding='utf-8')
 manifest={p.relative_to(mod).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in mod.rglob('*') if p.is_file()}
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2))
 with zipfile.ZipFile(out/'DMC5-DualSense-0.2.0-preview-Fluffy.zip','w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
  for p in mod.rglob('*'):
   if p.is_file():z.write(p,p.relative_to(mod).as_posix())
 print(json.dumps({'folder':str(mod),'bytes':sum(p.stat().st_size for p in mod.rglob('*') if p.is_file()),'audio_members':len(members)}))
 return mod
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('destination',type=Path);build(parser.parse_args().destination)
