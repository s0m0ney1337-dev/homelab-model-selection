# ===== LM STUDIO BENCH SESSION v2.0 =====
$Machine="M2"; $EnvProfile="NORMAL_DESKTOP"; $Reps=5
$Tiers=@("SHORT","MEDIUM","LONG")
$Root="C:\AI\Bench"; $Session=(Get-Date -Format "yyyyMMdd-HHmmss")+"-"+$Machine+"-LMS"
$Dir=Join-Path $Root $Session; New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$Csv=Join-Path $Dir "runs.csv"; $Baseline=Join-Path $Dir "baseline.txt"

# ---- EDIT to exact IDs from /api/v1/models ----
$Plan=@(
  @{Model='lfm2.5-24b-a2b';   Arch='MoE'; Quant='Q4_K_XL'; Think='off'},
  @{Model='gemma-4-7.5b-e4b'; Arch='MoE'; Quant='Q4_K_M';  Think='none'},
  @{Model='gpt-oss-20b';      Arch='MoE'; Quant='MXFP4';   Think='low'},
  @{Model='qwen3.6-35b-a3b';  Arch='MoE'; Quant='Q4_K_M';  Think='off'}
)
# Think is set in the LM Studio UI per model (reasoning off / low). Script records it, does not send it.

$Para="Benchmarking local inference requires separating model load, prompt processing, and token generation. Prefill is compute bound and scales with prompt length, while decode is usually limited by memory bandwidth and active parameter count. Recorded context length, quantization, offload split, and thinking mode are required for comparability. "
$Short="Write a detailed technical explanation of how dense and mixture-of-experts language models differ in memory use, prompt processing, and token generation. Keep writing until you are cut off; do not conclude."
$Medium=($Para*8)+"Using the passage above, write a detailed 400-word analysis of why tokens per second alone is misleading. Keep writing until cut off; do not conclude."
$LongTask="Based on the passage above, write a detailed 400-word analysis of the measurement conventions it describes. Keep writing until cut off; do not conclude."
$LongFile="C:\AI\Bench\bench_long.txt"
if(-not(Test-Path $LongFile)){Set-Content -Path $LongFile -Value (($Para*70)+$LongTask) -NoNewline}
$LongHash=(Get-FileHash $LongFile -Algorithm SHA256).Hash; $Long=Get-Content $LongFile -Raw

function Get-Field($o,$names){foreach($n in $names){if($o -and ($o.PSObject.Properties.Name -contains $n) -and $o.$n -ne $null){return $o.$n}}return $null}
function Get-CommitGB{try{return [math]::Round((Get-Counter '\Memory\Committed Bytes').CounterSamples[0].CookedValue/1GB,2)}catch{return $null}}

"SESSION $Session | $Machine | $EnvProfile | $(Get-Date -Format o)"|Set-Content $Baseline
"LONG SHA256: $LongHash"|Add-Content $Baseline
Get-CimInstance Win32_OperatingSystem|Select-Object @{n='FreeRAM_GB';e={[math]::Round($_.FreePhysicalMemory/1MB,2)}},@{n='TotalRAM_GB';e={[math]::Round($_.TotalVisibleMemorySize/1MB,2)}}|Format-List|Out-String|Add-Content $Baseline
$procs=Get-Process|Sort-Object WorkingSet64 -Descending|Select-Object -First 15 Name,@{n='RAM_MB';e={[math]::Round($_.WorkingSet64/1MB)}}
$procs|Format-Table -AutoSize|Out-String|Add-Content $Baseline
"FLAG >500MB:"|Add-Content $Baseline
$procs|Where-Object{$_.RAM_MB -gt 500}|Format-Table -AutoSize|Out-String|Add-Content $Baseline
"Committed GB idle: $(Get-CommitGB)"|Add-Content $Baseline

function Invoke-LMS($Model,$PromptText,$Nonce){
  $body=@{model=$Model;input="[$Nonce] "+$PromptText;temperature=0;max_output_tokens=256;stream=$false}|ConvertTo-Json -Depth 6
  Invoke-RestMethod -Uri http://localhost:1234/api/v1/chat -Method Post -Body $body -ContentType "application/json" -TimeoutSec 3600
}
function Write-Row($p,$tier,$phase,$rep,$ctx,$r,$note){
  $s=Get-Field $r @('stats')
  $pt=[int](Get-Field $s @('promptTokensCount','input_tokens'))
  $ot=[int](Get-Field $s @('predictedTokensCount','total_output_tokens'))
  $rt=Get-Field $s @('reasoningTokensCount','reasoning_output_tokens')
  $tps=[double](Get-Field $s @('tokensPerSecond','tokens_per_second'))
  $ttft=[double](Get-Field $s @('timeToFirstTokenSec','time_to_first_token_seconds'))
  $tot=Get-Field $s @('totalTimeSec','total_time_sec')
  $load=Get-Field $s @('modelLoadTimeSec','model_load_time_seconds')
  $stop=Get-Field $r @('stopReason','stop_reason')
  $prefill = if($ttft -gt 0 -and $phase -eq 'WARM'){[math]::Round($pt/$ttft,1)}else{$null}
  [pscustomobject]@{
    protocol_version='v2.0';session_id=$Session;run_date=(Get-Date -Format 'yyyy-MM-dd HH:mm')
    machine=$Machine;env_profile=$EnvProfile;runner='LMStudio';model=$p.Model;arch=$p.Arch;quant=$p.Quant
    tier=$tier;phase=$phase;rep=$rep;ctx=$ctx;think_set=$p.Think;think_used='UI';seed='not_exposed';num_predict=256
    prompt_tokens=$pt;cached_tokens='U';output_tokens=$ot;reasoning_tokens=$rt;stop_reason=$stop
    load_ms=$(if($load){[math]::Round($load*1000,1)}else{$null});ttft_ms=$(if($ttft){[math]::Round($ttft*1000,1)}else{$null})
    prefill_tps=$prefill;decode_tps=$(if($tps){[math]::Round($tps,2)}else{$null});e2e_s=$(if($tot){[math]::Round($tot,1)}else{$null})
    gpu_used_mb='U(unified)';committed_gb=(Get-CommitGB);split='UI GPU-offload setting'
    provenance='ttft=M;decode=M;e2e=M;prefill=D-lowerbound;cached=U;reason_tok=M-if-present;load=U-if-absent'
    notes=$note
  }|Export-Csv $Csv -Append -NoTypeInformation
}

foreach($p in $Plan){
  foreach($tier in $Tiers){
    $ctx=if($tier -eq 'LONG'){8192}else{4096}
    $prompt=switch($tier){'SHORT'{$Short}'MEDIUM'{$Medium}'LONG'{$Long}}
    Read-Host "LM Studio: load $($p.Model) | ctx=$ctx | GPU offload max | reasoning=$($p.Think). Press Enter"
    try{
      $cold=Invoke-LMS $p.Model $prompt ("cold-"+[guid]::NewGuid().ToString('N').Substring(0,8))
      Write-Row $p $tier 'COLD_FIRST_GEN' 0 $ctx $cold "first gen after load; load excluded; NOT for floors; long_hash=$LongHash"
      Invoke-LMS $p.Model $prompt ("warm-"+[guid]::NewGuid().ToString('N').Substring(0,8))|Out-Null
      for($i=1;$i -le $Reps;$i++){
        $r=Invoke-LMS $p.Model $prompt ("r"+$i+"-"+[guid]::NewGuid().ToString('N').Substring(0,8))
        $note="warm; nonce; long_hash=$LongHash"
        $ot=[int](Get-Field (Get-Field $r @('stats')) @('predictedTokensCount','total_output_tokens')); if($ot -lt 200){$note+="; short_output=$ot"}
        Write-Row $p $tier 'WARM' $i $ctx $r $note
        Write-Host "$($p.Model) $tier rep$i done"
      }
    }catch{
[pscustomobject]@{protocol_version='v2.0';session_id=$Session;run_date=(Get-Date -Format 'yyyy-MM-dd HH:mm');machine=$Machine;env_profile=$EnvProfile;runner='LMStudio';model=$p.Model;arch=$p.Arch;quant=$p.Quant;tier='ERR';phase='ERROR';rep=0;notes=$_.Exception.Message}|Export-Csv $Csv -Append -NoTypeInformation
Write-Host "ERROR ..." -ForegroundColor Red
}
  }
}
Write-Host "DONE. Raw runs: $Csv | Baseline: $Baseline" -ForegroundColor Green