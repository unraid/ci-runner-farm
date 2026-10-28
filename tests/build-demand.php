<?php
require __DIR__ . '/../src/usr/local/emhttp/plugins/ci-runner-farm/include/build-demand.php';
function rejects(callable $f): void { try { $f(); } catch (Throwable $e) { return; } throw new RuntimeException('unsafe evidence accepted'); }
function same($a, $b): void { if ($a !== $b) throw new RuntimeException('unexpected demand result'); }
const RECORDS = 'v3|build|general-build|self-hosted,linux,x64,build|10|4|10|10|4|12g|builtin;v3|build-small|build-small|self-hosted,linux,x64|1|0|10|0|2|4g|builtin';
class QueueFixture extends BuildDemand {
    public string $mode = 'complete';
    public array $seen = [];
    public function requests(array $requests): array {
        $result = [];
        foreach ($requests as $url => $token) {
            $this->seen[$url] = $token;
            if (str_contains($url, 'runner-groups?')) {
                $group = ['id'=>1,'name'=>'Default','inherited'=>false,'visibility'=>'all','allows_public_repositories'=>false,'restricted_to_workflows'=>false,'selected_workflows'=>[]];
                if ($this->mode === 'public') $group['allows_public_repositories'] = true;
                if ($this->mode === 'inherited') $group['inherited'] = true;
                if (in_array($this->mode,['selected','inaccessible'],true)) $group['visibility'] = 'selected';
                $items = [$group, array_merge($group,['id'=>2,'inherited'=>true])];
                if ($this->mode === 'ambiguous') $items[1]['inherited'] = false;
                $result[$url] = ['total_count'=>2,'runner_groups'=>$items];
            } elseif (str_contains($url, '/runner-groups/')) {
                $result[$url] = ['total_count'=>1,'repositories'=>[['id'=>11,'full_name'=>$this->mode==='inaccessible'?'unraid/missing':'unraid/core']]];
            } elseif (str_contains($url, '/repos?')) {
                $result[$url] = [['id'=>11,'name'=>'core','full_name'=>'unraid/core','private'=>true],['id'=>12,'name'=>'account','full_name'=>'unraid/account','private'=>true]];
                if ($this->mode === 'repository') $result[$url][1]['full_name'] = 'another/account';
            } elseif (str_contains($url, '/actions/runs?')) {
                preg_match('~/repos/(unraid/[^/]+)/actions/runs\?status=([^&]+)~',$url,$m);
                $run = ['id'=>$m[1]==='unraid/core'?21:22,'run_attempt'=>2,'status'=>$m[2],'repository'=>['full_name'=>$m[1]]];
                $items = $m[2] === 'in_progress' ? [$run] : [];
                if ($this->mode === 'run') $run['repository']['full_name'] = 'other/repo';
                if ($this->mode === 'run' && $items) $items = [$run];
                $result[$url] = ['total_count'=>count($items),'workflow_runs'=>$items];
                if ($this->mode === 'partial') $result[$url]['total_count']++;
            } else {
                preg_match('~/runs/([0-9]+)/attempts/([0-9]+)/jobs~',$url,$m);
                same($m[2],'2');
                $job = ['id'=>(int)$m[1]+100,'run_id'=>(int)$m[1],'status'=>'queued','runner_id'=>0,'labels'=>['self-hosted','linux','x64','general-build']];
                if ($this->mode === 'job') $job['run_id'] = 999;
                if ($this->mode === 'small') $job['labels'] = ['self-hosted','Linux','X64'];
                if ($this->mode === 'status') $job['status'] = 'unrecognized';
                if ($this->mode === 'assigned') $job['runner_id'] = 42;
                if ($this->mode === 'unassigned-null') $job['runner_id'] = null;
                if ($this->mode === 'missing-assignment') unset($job['runner_id']);
                if ($this->mode === 'string-assignment') $job['runner_id'] = '0';
                if ($this->mode === 'boolean-assignment') $job['runner_id'] = false;
                if ($this->mode === 'negative-assignment') $job['runner_id'] = -1;
                if ($this->mode === 'in-progress-null') { $job['runner_id'] = null; $job['status'] = 'in_progress'; }
                if ($this->mode === 'small-unassigned-null') { $job['runner_id'] = null; $job['labels'] = ['self-hosted','Linux','X64']; }
                if ($this->mode === 'foreign-qa') { $job['runner_id'] = null; $job['labels'] = ['Linux','X64','unraid','qa-vm-client','qa-vm-ready']; }
                if ($this->mode === 'foreign-hosted') { $job['runner_id'] = null; $job['labels'] = ['ubuntu-latest']; }
                if ($this->mode === 'foreign-invalid-identity') { $job['runner_id'] = null; $job['labels'] = ['ubuntu-latest']; $job['run_id'] = 999; }
                if ($this->mode === 'foreign-invalid-assignment') { $job['runner_id'] = 'unknown'; $job['labels'] = ['ubuntu-latest']; }
                if ($this->mode === 'labels') $job['labels'][] = 'unsupported';
                $result[$url] = ['total_count'=>1,'jobs'=>[$job]];
                if ($this->mode === 'mixed-foreign') {
                    $result[$url]['total_count']=3;
                    $result[$url]['jobs'][]=array_merge($job,['id'=>$job['id']+1000,'runner_id'=>null,'labels'=>['Linux','X64','unraid','qa-vm-client','qa-vm-ready']]);
                    $result[$url]['jobs'][]=array_merge($job,['id'=>$job['id']+2000,'runner_id'=>null,'labels'=>['ubuntu-latest']]);
                }
                if ($this->mode === 'duplicate') { $result[$url]['total_count']=2; $result[$url]['jobs'][]=$job; }
                if ($this->mode === 'missing') unset($result[$url]['jobs'][0]['labels']);
                if ($this->mode === 'skipped') { $result[$url]['total_count']=2; $result[$url]['jobs'][]=array_merge($job,['id'=>$job['id']+1000,'status'=>'completed','runner_id'=>null,'labels'=>[]]); }
            }
        }
        return $result;
    }
}
class PageFixture extends BuildDemand {
    public array $responses = [];
    public function requests(array $requests): array {
        $result=[];
        foreach ($requests as $path=>$token) { parse_str(parse_url($path,PHP_URL_QUERY),$query); $result[$path]=$this->responses[$query['page']]; }
        return $result;
    }
}
$cache = sys_get_temp_dir() . '/farm-demand-' . bin2hex(random_bytes(8));
try {
    same(BuildDemand::warmTargets(RECORDS), ['schema'=>1,'targets'=>['build-small'=>0,'build'=>10]]);
    same(BuildDemand::warmTargets(str_replace('|1|0|10|0|2|4g|', '|1|0|10|1|2|4g|', RECORDS))['targets'], ['build-small'=>1,'build'=>10]);
    $paged = new PageFixture($cache,'g','q');
    $paged->responses=[1=>['total_count'=>101,'jobs'=>array_fill(0,100,['id'=>1])],2=>['total_count'=>101,'jobs'=>[['id'=>101]]]];
    $visited=0;
    $paged->pages(['/jobs'=>'read-only'],'jobs',function()use(&$visited){$visited++;},10);
    same($visited,101);
    $paged->responses[2]['total_count']=102;
    rejects(fn()=>$paged->pages(['/jobs'=>'read-only'],'jobs',fn()=>null,10));
    $paged->responses[1]['jobs']=array_fill(0,99,['id'=>1]);
    rejects(fn()=>$paged->pages(['/jobs'=>'read-only'],'jobs',fn()=>null,10));
    $paged->responses[1]=['total_count'=>101,'jobs'=>array_fill(0,100,['id'=>1])];
    rejects(fn()=>$paged->pages(['/jobs'=>'read-only'],'jobs',fn()=>null,1));
    $scope = ['GH_OWNER'=>'unraid','RUNNER_GROUP'=>'Default','token'=>'group-only','queue-token'=>'actions-only'];
    $pools = BuildDemand::pools(RECORDS);
    $reader = new QueueFixture($cache,'group-only','actions-only');
    $scan = $reader->queue($scope,$pools);
    same($scan['counts'],['build-small'=>0,'build'=>2]);
    foreach ($reader->seen as $path=>$token) same($token,str_contains($path,'runner-groups')?'group-only':'actions-only');
    foreach (['public','inherited','ambiguous','repository','run','partial','job','duplicate','missing','inaccessible','status','missing-assignment','string-assignment','boolean-assignment','negative-assignment','foreign-invalid-identity','foreign-invalid-assignment'] as $mode) {
        $reader->mode=$mode; rejects(fn()=>$reader->queue($scope,$pools));
    }
    $reader->mode='selected'; same($reader->queue($scope,$pools)['counts'],['build-small'=>0,'build'=>1]);
    $reader->mode='unassigned-null'; same($reader->queue($scope,$pools)['counts'],['build-small'=>0,'build'=>2]);
    $reader->mode='small-unassigned-null'; same($reader->queue($scope,$pools)['counts'],['build-small'=>2,'build'=>0]);
    $reader->mode='small'; same($reader->queue($scope,$pools)['counts'],['build-small'=>2,'build'=>0]);
    $reader->mode='skipped'; same($reader->queue($scope,$pools)['counts'],['build-small'=>0,'build'=>2]);
    $reader->mode='mixed-foreign'; same($reader->queue($scope,$pools)['counts'],['build-small'=>0,'build'=>2]);
    foreach (['assigned','in-progress-null','labels','foreign-qa','foreign-hosted'] as $mode) { $reader->mode=$mode; same($reader->queue($scope,$pools)['counts'],['build-small'=>0,'build'=>0]); }
    $observation=['schema'=>1,'observedAt'=>time(),'policyDigest'=>str_repeat('a',64),'poolsDigest'=>hash('sha256',"unraid\0".RECORDS),'retained'=>['build'=>5,'build-small'=>0]];
    same(BuildDemand::targets(RECORDS,$scan,$observation)['targets'],['build-small'=>0,'build'=>10]);
    foreach (['stale','policy','pool','missing','negative','extra'] as $mode) {
        $bad=$observation; $queue=$scan;
        if ($mode==='stale') $queue['queueStartedAt']=time()-181;
        if ($mode==='policy') $bad['policyDigest']='';
        if ($mode==='pool') $bad['poolsDigest']=str_repeat('b',64);
        if ($mode==='missing') unset($queue['counts']['build-small']);
        if ($mode==='negative') $queue['counts']['build']=-1;
        if ($mode==='extra') $bad['retained']['other']=0;
        rejects(fn()=>BuildDemand::targets(RECORDS,$queue,$bad));
    }
    $reader = new BuildDemand($cache,'g','q');
    rejects(fn()=>$reader->response('key',304,[],'',null));
    rejects(fn()=>$reader->response('key',302,[],'',null));
    rejects(fn()=>$reader->response('key',200,[],str_repeat('x',1048577),null));
    same($reader->response('key',304,[],'',['body'=>'{"fresh":true}']),['fresh'=>true]);
    for ($i=0;$i<520;$i++) $reader->response('key'.$i,200,['etag'=>'"e"'],'{"ok":true}',null);
    $reader->save();
    $stored=json_decode(file_get_contents($cache),true);
    same(count($stored['items']),512); same(fileperms($cache)&0777,0600);
    rejects(fn()=>$reader->response('rate',429,['retry-after'=>'120'],'',null));
    $reader->save(); same(json_decode(file_get_contents($cache),true)['cooldown'] >= time()+299,true);
    chmod($cache,0644); rejects(fn()=>new BuildDemand($cache,'g','q')); unlink($cache);
    // A rotating App token keeps one cache scope; distinct PATs do not share one.
    $scope = new ReflectionProperty(BuildDemand::class, 'scope');
    same($scope->getValue(new BuildDemand($cache,'ghs_one','ghs_one','github-app:7:42')), $scope->getValue(new BuildDemand($cache,'ghs_two','ghs_two','github-app:7:42')));
    same($scope->getValue(new BuildDemand($cache,'pat-a','q')) === $scope->getValue(new BuildDemand($cache,'pat-b','q')), false);
    symlink('/dev/null',$cache); rejects(fn()=>new BuildDemand($cache,'g','q')); unlink($cache);
    if (posix_geteuid() === 0) {
        $credentialDir = $cache . '-credentials';
        mkdir($credentialDir, 0700);
        file_put_contents($credentialDir . '/ci-runner-farm.cfg', "CI_PROVIDER=github\nGH_SCOPE=org\nGH_OWNER=example\nRUNNER_GROUP=Default\n");
        chmod($credentialDir . '/ci-runner-farm.cfg', 0600);
        file_put_contents($credentialDir . '/token', 'native-token');
        chmod($credentialDir . '/token', 0600);
        try {
            same(BuildDemand::credentials($credentialDir, false)['token'], 'native-token');
            same(BuildDemand::credentials($credentialDir, false)['queue-token'], '');
            rejects(fn()=>BuildDemand::credentials($credentialDir));
            // GitHub App mode: the engine-exported minted token serves both the
            // runner-group and the queue reads, and names a stable identity.
            $minted = $credentialDir . '/minted-token';
            file_put_contents($minted, 'ghs_minted'); chmod($minted, 0600);
            putenv('CRF_GITHUB_TOKEN_FILE=' . $minted);
            rejects(fn()=>BuildDemand::credentials($credentialDir));
            file_put_contents($credentialDir . '/ci-runner-farm.cfg', "CI_PROVIDER=github\nGH_SCOPE=org\nGH_OWNER=example\nRUNNER_GROUP=Default\nGH_APP_ID=\"7\"\nGH_APP_INSTALLATION_ID=\"42\"\n");
            $app = BuildDemand::credentials($credentialDir);
            same([$app['token'], $app['queue-token'], $app['identity']], ['ghs_minted', 'ghs_minted', 'github-app:7:42']);
            putenv('CRF_GITHUB_TOKEN_FILE=relative/token'); rejects(fn()=>BuildDemand::credentials($credentialDir));
            putenv('CRF_GITHUB_TOKEN_FILE');
            unlink($minted);
            same(BuildDemand::credentials($credentialDir, false)['identity'], '');
            file_put_contents($credentialDir . '/ci-runner-farm.cfg', "CI_PROVIDER=github\nGH_SCOPE=org\nGH_OWNER=example\nRUNNER_GROUP=Default\n");
            mkdir($credentialDir . '/runtime', 0700);
            $command = implode(' ', array_map('escapeshellarg', [PHP_BINARY,
                __DIR__ . '/../src/usr/local/emhttp/plugins/ci-runner-farm/include/build-demand.php',
                'begin-recovery', $credentialDir, $credentialDir . '/runtime', RECORDS]));
            exec($command . ' 2>/dev/null', $output, $status);
            same($status, 0);
            same(json_decode(implode("\n", $output), true), ['recoveryReady'=>true]);
            exec($command . ' 2>/dev/null', $ignored, $status);
            same($status, 1); // A fresh process still observes the recovery cadence.
        } finally {
            if (is_dir($credentialDir . '/runtime')) {
                @unlink($credentialDir . '/runtime/build-demand-http.json');
                rmdir($credentialDir . '/runtime');
            }
            unlink($credentialDir . '/token');
            unlink($credentialDir . '/ci-runner-farm.cfg');
            rmdir($credentialDir);
        }
        $reader = new BuildDemand($cache,'g','q');
        $reader->begin();
        // A fresh process cannot turn a failed/restarted pass into another scan.
        rejects(fn()=>(new BuildDemand($cache,'g','q'))->begin());
        $stored=json_decode(file_get_contents($cache),true);
        $stored['plan']['attemptedAt']=time()-280;
        file_put_contents($cache,json_encode($stored));
        rejects(fn()=>(new BuildDemand($cache,'g','q'))->begin());
        // A tick that lands slightly early on a 300s interval still polls.
        $stored['plan']['attemptedAt']=time()-290;
        file_put_contents($cache,json_encode($stored));
        (new BuildDemand($cache,'g','q'))->begin();
        unlink($cache);
        $reader = new BuildDemand($cache,'g','q');
        $reset=time()+900;
        same($reader->response('reserve',200,['x-ratelimit-remaining'=>'500','x-ratelimit-reset'=>(string)$reset],'{"ok":true}',null),['ok'=>true]);
        $reader->save();
        rejects(fn()=>(new BuildDemand($cache,'g','q'))->begin());
        same(json_decode(file_get_contents($cache),true)['cooldown'] >= $reset,true);
        // Queue quota blocks queue reads, while one scheduled native recovery
        // remains available and persists across fresh processes.
        (new BuildDemand($cache,'g','q'))->beginRecovery();
        rejects(fn()=>(new BuildDemand($cache,'g','q'))->beginRecovery());
        rejects(fn()=>(new BuildDemand($cache,'g','rotated-queue'))->beginRecovery());
        rejects(fn()=>(new BuildDemand($cache,'g','q'))->begin());
        $stored=json_decode(file_get_contents($cache),true);
        same($stored['cooldown'] >= $reset,true);
        $stored['recoveryPlan']['attemptedAt']=time()-300;
        file_put_contents($cache,json_encode($stored));
        (new BuildDemand($cache,'g','q'))->beginRecovery();
        (new BuildDemand($cache,'rotated-native','q'))->beginRecovery();
        $stored=json_decode(file_get_contents($cache),true);
        $stored['recoveryPlan']['attemptedAt']=time()+300;
        file_put_contents($cache,json_encode($stored));
        rejects(fn()=>(new BuildDemand($cache,'rotated-native','q'))->beginRecovery());
        unset($stored['recoveryPlan']);
        file_put_contents($cache,json_encode($stored));
        // A credential replacement must not inherit another credential's denial.
        (new BuildDemand($cache,'other','credential'))->begin();
        unlink($cache);
        $reader = new BuildDemand($cache,'g','q');
        $reader->response('above',200,['x-ratelimit-remaining'=>'501','x-ratelimit-reset'=>(string)$reset],'{"ok":true}',null);
        $reader->save();
        (new BuildDemand($cache,'g','q'))->begin();
        unlink($cache);
    }
    echo "build-demand: private group/credential split, complete current-attempt queues, target identity and authenticated cache protections passed\n";
} finally { if (file_exists($cache)||is_link($cache)) unlink($cache); }
