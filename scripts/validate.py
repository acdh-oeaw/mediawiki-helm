#!/usr/bin/env python3
from pathlib import Path
import subprocess, yaml, json, base64
chart='chart/mediawiki'
base=['helm','template','demo',chart,'-f','examples/ci.values.yaml']
def run(args):
    p=subprocess.run(args,text=True,capture_output=True)
    if p.returncode: raise RuntimeError(p.stderr+p.stdout)
    return p.stdout
def docs(flags): return [d for d in yaml.safe_load_all(run(base+flags)) if d]
run(['helm','lint',chart,'--strict','-f','examples/ci.values.yaml'])
variants=[[],['-f','examples/new-instance.values.yaml'],['-f','examples/bitnami-import.values.yaml'],
 ['--set','replicaCount=0,migration.enabled=true'],
 ['--set','ingress.enabled=true,ingress.tls.enabled=true,networkPolicy.enabled=true'],
 ['--set','persistence.enabled=false'],['--set','persistence.existingClaim=data,persistence.subPath=images'],
 ['--set','externalDatabase.existingSecret=db,security.existingSecret=keys'],
 ['--set','replicaCount=0,bootstrap.enabled=true,bootstrap.existingSecret=admin']]
for flags in variants:
    ds=docs(flags); dep=next(d for d in ds if d['kind']=='Deployment');pod=dep['spec']['template']['spec']
    assert dep['spec']['strategy']['type']=='Recreate'
    assert pod['securityContext']['runAsUser']==33
    assert not pod['automountServiceAccountToken']
    for d in ds:
        assert 'helm.sh/hook' not in d.get('metadata',{}).get('annotations',{})
        if d['kind']=='Job': assert d['spec']['backoffLimit']==0
    service=next(d for d in ds if d['kind']=='Service')
    assert service['spec']['selector']['app.kubernetes.io/component']=='web'
    if not flags:
        assert not any(d['kind']=='Job' for d in ds)
        cm=next(d for d in ds if d['kind']=='ConfigMap')
        secret=next(d for d in ds if d['kind']=='Secret' and d['metadata']['name'].endswith('-settings'))
        Path('.rendered').mkdir(exist_ok=True)
        for k,v in cm['data'].items():Path('.rendered',k).write_text(v)
        for k,v in secret['data'].items():Path('.rendered',k).write_bytes(base64.b64decode(v))
    for d in ds:
        if d['kind']=='Job':
            ctr=d['spec']['template']['spec']['containers'][0]
            if ctr['name']=='install':
                assert not any(v['mountPath']=='/var/www/html/LocalSettings.php' for v in ctr['volumeMounts'])
                assert 'SHOW TABLES' in ctr['args'][0]
                assert '--conf=/etc/mediawiki-runtime/LocalSettings.php' in ctr['args'][0]
                Path('.rendered/install.sh').write_text(ctr['args'][0])
            elif ctr['name']=='copy-uploads':
                assert ctr['volumeMounts'][0]['readOnly']
                assert 'Destination is not empty' in ctr['args'][0]
                Path('.rendered/import.sh').write_text(ctr['args'][0])
            elif ctr['name']=='update': assert ctr['command'][-2:]==['update','--quick']
reject=[['--set','migration.enabled=true'],['--set','bootstrap.enabled=true,bootstrap.adminPassword=test'],
 ['--set','replicaCount=2'],['--set','externalDatabase.port=0'],
 ['--set','replicaCount=0,migration.enabled=true,bootstrap.enabled=true,bootstrap.adminPassword=test'],
 ['--set','replicaCount=0,bitnamiImport.enabled=true'],
 ['--set','replicaCount=0,bitnamiImport.enabled=true,bitnamiImport.existingClaim=source,persistence.enabled=false']]
for flags in reject:
    p=subprocess.run(base+flags,capture_output=True,text=True)
    assert p.returncode!=0,flags
assert subprocess.run(['helm','template','demo',chart],capture_output=True).returncode!=0
# Verify nested typed values and PHP payload strings remain data.
probe={'localSettings':{'variables':{'wgTest':{'enabled':True,'count':3,'items':['a',"quote' \" $value"]}}}}
Path('.rendered/probe.yaml').write_text(yaml.safe_dump(probe))
ds=docs(['-f','.rendered/probe.yaml']);sec=next(d for d in ds if d['kind']=='Secret' and d['metadata']['name'].endswith('-settings'))
actual=json.loads(base64.b64decode(sec['data']['settings.json']))
assert actual['wgTest']==probe['localSettings']['variables']['wgTest']
for script in ['install.sh','import.sh']:run(['sh','-n','.rendered/'+script])
for p in list(Path('.github/workflows').glob('*.yml'))+[Path(chart)/'questions.yaml']:yaml.safe_load(p.read_text())
# Dedicated DB and external routing checks.
for flags in [
 ['-f','examples/dedicated-mariadb.values.yaml'],
 ['--set','mariadb.enabled=true,mariadb.auth.existingSecret=db-auth,security.existingSecret=keys'],
 ['--set','mariadb.enabled=true,mariadb.auth.existingSecret=db-auth,mariadb.persistence.existingClaim=db-data,networkPolicy.enabled=true']]:
    ds=docs(flags)
    sts=next(d for d in ds if d['kind']=='StatefulSet')
    assert sts['spec']['replicas']==1
    dbpod=sts['spec']['template']['spec']
    assert dbpod['securityContext']['runAsUser']==999
    assert dbpod['containers'][0]['securityContext']['readOnlyRootFilesystem']
    dep=next(d for d in ds if d['kind']=='Deployment')
    env=dep['spec']['template']['spec']['containers'][0]['env']
    assert next(e['value'] for e in env if e['name']=='MW_DB_HOST')=='demo-mediawiki-mariadb'
    assert next(e['value'] for e in env if e['name']=='MW_DB_PORT')=='3306'
    appPass=next(e['valueFrom']['secretKeyRef'] for e in env if e['name']=='MW_DB_PASSWORD')
    assert appPass['key']=='database-password'
    assert not any('root-password' in str(e) for e in env)
    assert not any(d['kind']=='Secret' and d['metadata']['name']=='demo-mediawiki-db' for d in ds)
    if 'networkPolicy.enabled=true' in ','.join(flags):
        policy=next(d for d in ds if d['kind']=='NetworkPolicy' and d['metadata']['name'].endswith('-mariadb'))
        assert policy['spec']['ingress'][0]['ports'][0]['port']==3306
    if any('existingClaim=db-data' in f for f in flags):
        assert not any(d['kind']=='PersistentVolumeClaim' and 'mariadb-data' in d['metadata']['name'] for d in ds)
        assert dbpod['volumes'][0]['persistentVolumeClaim']['claimName']=='db-data'
for flags in [[],['-f','examples/external-database.values.yaml']]:
    ds=docs(flags)
    assert not any(d['kind']=='StatefulSet' for d in ds)
    assert not any(d['kind']=='PersistentVolumeClaim' and d['metadata']['name'].endswith('-mariadb-data') for d in ds)
for flags in [['--set','mariadb.enabled=true'],['--set','mariadb.enabled=true,mariadb.auth.username=root,mariadb.auth.password=app,mariadb.auth.rootPassword=root']]:
    assert subprocess.run(base+flags,capture_output=True).returncode!=0
for d in docs(['--set','replicaCount=0,migration.enabled=true']):
    if d['kind']=='Job':
        wait=d['spec']['template']['spec']['initContainers'][0]
        assert wait['name']=='wait-database'
        assert '600 seconds' in wait['args'][0]
print('PASS: strict lint, 14 render cases, 10 rejection checks, typed globals, routing/storage isolation and wait-init checks')
