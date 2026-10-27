"""Consume only the mounted release archive; no repository/build tree is needed."""
import argparse, ctypes as C, hashlib, json, os, platform, shutil, subprocess, tarfile, tempfile, time
from pathlib import Path

def digest(path):
    checksum=hashlib.sha256()
    with open(path,'rb') as file:
        for block in iter(lambda:file.read(1024*1024),b''): checksum.update(block)
    return checksum.hexdigest()

def environment(cuda=False):
    tools={name:shutil.which(name) for name in ['cmake','cc','gcc','g++','c++','clang','clang++','make','ninja','nvcc']}
    assert not any(tools.values()), tools
    with tempfile.NamedTemporaryFile() as fixture:
        fixture.write(b'libllama-consumer');fixture.flush();assert digest(fixture.name)==hashlib.sha256(b'libllama-consumer').hexdigest()
    result={'platform':platform.platform(),'machine':platform.machine(),'os_release':Path('/etc/os-release').read_text(),'python':platform.python_version(),'cpu_count':os.cpu_count(),'cpu_affinity':sorted(os.sched_getaffinity(0)) if hasattr(os,'sched_getaffinity') else None,'build_tools':tools}
    if cuda:
        driver=C.CDLL('libcuda.so.1'); driver.cuInit.argtypes=[C.c_uint]; driver.cuDeviceGetCount.argtypes=[C.POINTER(C.c_int)]; driver.cuDriverGetVersion.argtypes=[C.POINTER(C.c_int)]
        assert driver.cuInit(0)==0
        count=C.c_int(); version=C.c_int(); assert driver.cuDeviceGetCount(C.byref(count))==0 and count.value>0
        assert driver.cuDriverGetVersion(C.byref(version))==0
        runtime=C.CDLL('libcudart.so.12'); runtime.cudaRuntimeGetVersion.argtypes=[C.POINTER(C.c_int)]; runtime_version=C.c_int(); assert runtime.cudaRuntimeGetVersion(C.byref(runtime_version))==0
        result['cuda']={'device_count':count.value,'driver_api_version':version.value,'runtime_version':runtime_version.value,'nvidia_smi':subprocess.check_output(['nvidia-smi','--query-gpu=name,driver_version,memory.total','--format=csv,noheader'],text=True).strip()}
    return result

def consume(args,evidence):
    archive=Path(args.archive); checksum=Path(args.checksum_file)
    entries=[line.split() for line in checksum.read_text().splitlines() if line.strip()]
    expected=[row[0] for row in entries if len(row)==2 and row[1].lstrip('*')==archive.name]
    assert len(expected)==1, ('checksum entry missing/ambiguous',archive.name)
    evidence.update(version=args.version,archive_name=archive.name,archive_sha256=digest(archive),member=args.member,legacy_v074=args.legacy_v074)
    assert evidence['archive_sha256']==expected[0], 'release archive checksum mismatch'
    if args.legacy_v074:
        assert args.version=='0.7.4' and args.backend=='cpu'
        evidence['scope']='OLD v0.7.4 PROCEDURE CONTROL; NOT v0.7.5 release validation'
    else:
        evidence['scope']='Consumer of the supplied checksummed release archive'
    evidence['model_sha256']=digest(args.model)
    with tempfile.TemporaryDirectory(prefix='libllama-release-consumer-') as directory:
        with tarfile.open(archive,'r:gz') as package:
            matches=[m for m in package.getmembers() if m.name.removeprefix('./')==args.member]
            assert len(matches)==1 and matches[0].isfile(), ('missing/nonregular release library',args.member)
            library=Path(directory)/Path(args.member).name
            with package.extractfile(matches[0]) as src,library.open('wb') as dst: shutil.copyfileobj(src,dst)
        evidence['library_sha256']=digest(library)
        dependencies=subprocess.run(['ldd',str(library)],capture_output=True,text=True)
        evidence['ldd']=dependencies.stdout+dependencies.stderr
        assert dependencies.returncode==0 and 'not found' not in evidence['ldd'], evidence['ldd']
        lib=C.CDLL(str(library)); evidence['exports']={name:hasattr(lib,name) for name in ['llcs_engine_create','llcs_engine_prepare','llcs_engine_caps','llcs_engine_submit','llcs_engine_poll','llcs_engine_destroy','llcs_engine_stats','llcs_string_free']}
        assert all(value for name,value in evidence['exports'].items() if name!='llcs_engine_prepare'), evidence['exports']
        if not args.legacy_v074: assert evidence['exports']['llcs_engine_prepare'], 'current release missing preparation API'
        signatures={'llcs_engine_create':([C.c_char_p,C.POINTER(C.c_void_p)],C.c_void_p),'llcs_engine_caps':([C.c_void_p],C.c_void_p),'llcs_engine_submit':([C.c_void_p,C.c_char_p,C.POINTER(C.c_void_p)],C.c_int64),'llcs_engine_poll':([C.c_void_p,C.c_int64,C.c_int32],C.c_void_p),'llcs_engine_stats':([C.c_void_p],C.c_void_p),'llcs_engine_destroy':([C.c_void_p],None),'llcs_string_free':([C.c_void_p],None)}
        if evidence['exports']['llcs_engine_prepare']: signatures['llcs_engine_prepare']=([C.c_void_p,C.c_char_p,C.POINTER(C.c_void_p)],C.c_void_p)
        for name,(types,result) in signatures.items(): getattr(lib,name).argtypes=types; getattr(lib,name).restype=result
        def read(ptr):
            if not ptr:return None
            try:
                value=C.string_at(ptr).decode(); return json.loads(value) if value else ''
            finally:lib.llcs_string_free(ptr)
        config={'model_path':str(Path(args.model).resolve()),'n_ctx':512,'n_batch':64,'n_ubatch':64,'n_threads':2,'n_threads_batch':2,'n_gpu_layers':args.gpu_layers,'backend':args.backend,'require_backend':True,'n_parallel':1}
        evidence['requested']=config; error=C.c_void_p(); engine=lib.llcs_engine_create(json.dumps(config).encode(),C.byref(error)); native_error=read(error)
        assert engine, native_error
        try:
            caps=read(lib.llcs_engine_caps(engine)); evidence['caps']=caps
            if not args.legacy_v074:
                assert caps['selected_backend']==args.backend and caps['require_backend'] and not caps['degradation'],caps
            body={'messages':[{'role':'user','content':'Reply with the word ready.'}],'stream':True,'max_tokens':16,'temperature':0,'chat_template_kwargs':{'enable_thinking':False},'stream_options':{'include_usage':True}}
            if evidence['exports']['llcs_engine_prepare']:
                error=C.c_void_p(); evidence['budget']=read(lib.llcs_engine_prepare(engine,json.dumps(body).encode(),C.byref(error))); assert evidence['budget'] and evidence['budget']['fits'],read(error)
            error=C.c_void_p(); task=lib.llcs_engine_submit(engine,json.dumps(body).encode(),C.byref(error)); assert task>=0,read(error)
            started=time.monotonic(); deadline=started+120; text=''; reasoning=''; finished=False; drained=False; events=0; usage=None; finish_reasons=[]
            while time.monotonic()<deadline:
                event=read(lib.llcs_engine_poll(engine,task,100))
                if event is None:drained=True;break
                if event=='':continue
                assert 'error' not in event,event;events+=1
                if 'usage' in event: usage=event['usage']
                for choice in event.get('choices',[]):
                    delta=choice.get('delta',{});text+=delta.get('content') or '';reasoning+=delta.get('reasoning_content') or ''
                    if choice.get('finish_reason') is not None: finished=True;finish_reasons.append(choice['finish_reason'])
            evidence['inference']={'text':text,'finished':finished,'drained':drained,'events':events,'reasoning':reasoning,'finish_reasons':finish_reasons,'usage':usage,'seconds':time.monotonic()-started}
            assert drained and finished and text.strip(),evidence['inference']
            assert usage and usage['prompt_tokens']>0 and usage['completion_tokens']>0,usage
            assert usage['total_tokens']==usage['prompt_tokens']+usage['completion_tokens'],usage
            evidence['final_native_stats']=read(lib.llcs_engine_stats(engine))
            assert all(evidence['final_native_stats'][key]==0 for key in ['active_tasks','retained_tasks','pending_cancellations','buffered_bytes','buffered_events','failed']),evidence['final_native_stats']
        finally:
            lib.llcs_engine_destroy(engine)
            evidence['teardown']={'engine_destroy_returned':True}

parser=argparse.ArgumentParser(); sub=parser.add_subparsers(dest='command',required=True)
env=sub.add_parser('environment');env.add_argument('--cuda-probe',action='store_true');env.add_argument('--output',required=True)
run=sub.add_parser('consume')
for name in ['archive','checksum-file','member','model','version','output']:run.add_argument('--'+name,required=True)
run.add_argument('--backend',choices=['cpu','cuda','vulkan'],required=True);run.add_argument('--gpu-layers',type=int,required=True);run.add_argument('--legacy-v074',action='store_true')
args=parser.parse_args();evidence={}
try:
    evidence['environment']=environment(getattr(args,'cuda_probe',False))
    if args.command=='consume':consume(args,evidence)
    evidence['status']='passed'
except BaseException as error:
    evidence.update(status='failed',error=repr(error));raise
finally:
    Path(args.output).write_text(json.dumps(evidence,indent=2));print(json.dumps(evidence),flush=True)
