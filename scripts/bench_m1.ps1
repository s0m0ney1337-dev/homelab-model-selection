# ===== OLLAMA BENCH SESSION v2.0 =====
$Machine    = "M1"                      # M2 when you do the calibration lane
$EnvProfile = "NORMAL_ALWAYS_ON_STT"    # M2: "NORMAL_DESKTOP"
$Reps       = 5                         # smoke test: set 3
$Tiers = @("SHORT","MEDIUM","LONG")  # smoke test: @("SHORT")
$Root       = "C:\AI\Bench"
$Session    = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + $Machine
$Dir        = Join-Path $Root $Session
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$Csv        = Join-Path $Dir "runs.csv"
$Baseline   = Join-Path $Dir "baseline.txt"

# ---- EDIT THESE to exact `ollama list` tags ----
$Plan = @(
  @{Model='qwen3.5:4b';        Arch='Dense'; Quant='Q4_K_M'; Think='off'},
  @{Model='granite4.2:8b';     Arch='Dense'; Quant='Q4_K_M'; Think='off'},
  @{Model='qwen3.5:9b';        Arch='Dense'; Quant='Q4_K_M'; Think='off'},
  @{Model='nemotron-3-nano:4b';Arch='MoE';   Quant='Q4_K_M'; Think='off'}
)
# Think: 'off'=send think:false | 'low'/'medium'/'high'=string | 'none'=omit (non-thinking models)

# ---- Canonical prompts (identical on every machine) ----
$Para = "Benchmarking local inference requires separating model load, prompt processing, and token generation. Prefill is compute bound and scales with prompt length, while decode is usually limited by memory bandwidth and active parameter count. Recorded context length, quantization, offload split, and thinking mode are required for comparability. "
$Short  = "Write a detailed technical explanation of how dense and mixture-of-experts language models differ in memory use, prompt processing, and token generation. Keep writing until you are cut off; do not conclude."
$Medium = ($Para * 8) + "Using the passage above, write a detailed 400-word analysis of why tokens per second alone is misleading. Keep writing until cut off; do not conclude."
$LongTask = "Based on the passage above, write a detailed 400-word analysis of the measurement conventions it describes. Keep writing until cut off; do not conclude."
$LongFile = "C:\AI\Bench\bench_long.txt"
if (-not (Test-Path $LongFile)) { Set-Content -Path $LongFile -Value (($Para * 70) + $LongTask) -NoNewline }
$LongHash = (Get-FileHash $LongFile -Algorithm SHA256).Hash
$Long = Get-Content $LongFile -Raw

# ---- Helpers ----
function Get-Field($o,$names){ foreach($n in $names){ if($o -and ($o.PSObject.Properties.Name -contains $n) -and $o.$n -ne $null){ return $o.$n } } return $null }
function Get-GpuMB { if(Get-Command nvidia-smi -ErrorAction SilentlyContinue){ try{ return [int]((nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | Select-Object -First 1).Trim()) }catch{ return $null } } return $null }
function Get-CommitGB { try{ return [math]::Round((Get-Counter '\Memory\Committed Bytes').CounterSamples[0].CookedValue/1GB,2) }catch{ return $null } }
function Get-Split($m){ try{ $l=(ollama ps) -split "`n" | Where-Object { $_ -match [regex]::Escape($m) } | Select-Object -First 1; return (($l -replace '\s+',' ').Trim()) }catch{ return "" } }

# ---- Environment baseline (apps LEFT RUNNING; record + flag) ----
"SESSION $Session | $Machine | $EnvProfile | $(Get-Date -Format o)" | Set-Content $Baseline
"LONG prompt SHA256: $LongHash" | Add-Content $Baseline
Get-CimInstance Win32_OperatingSystem | Select-Object @{n='FreeRAM_GB';e={[math]::Round($_.FreePhysicalMemory/1MB,2)}},@{n='TotalRAM_GB';e={[math]::Round($_.TotalVisibleMemorySize/1MB,2)}} | Format-List | Out-String | Add-Content $Baseline
$procs = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 Name,@{n='RAM_MB';e={[math]::Round($_.WorkingSet64/1MB)}}
$procs | Format-Table -AutoSize | Out-String | Add-Content $Baseline
"FLAG >500MB:" | Add-Content $Baseline
$procs | Where-Object { $_.RAM_MB -gt 500 } | Format-Table -AutoSize | Out-String | Add-Content $Baseline
"GPU idle MB: $(Get-GpuMB) | Committed GB idle: $(Get-CommitGB)" | Add-Content $Baseline
"NOTE: normal apps + Parakeet STT API left running by design." | Add-Content $Baseline

# ---- Request ----
function Invoke-Ollama($Model,$PromptText,$Ctx,$Think,$Nonce,$Keep){
  $body = @{ model=$Model; prompt="[$Nonce] "+$PromptText; stream=$false; keep_alive=$Keep
             options=@{ temperature=0; seed=42; num_ctx=$Ctx; num_predict=256 } }
  $used=$Think
  if($Think -eq 'off'){ $body.think=$false } elseif($Think -ne 'none'){ $body.think=$Think }
  $json = $body | ConvertTo-Json -Depth 6
  try { $resp = Invoke-RestMethod -Uri http://localhost:11434/api/generate -Method Post -Body $json -ContentType "application/json" -TimeoutSec 3600 }
  catch {
    if($Think -ne 'none'){ $body.Remove('think'); $used='none(retry)'; $json=$body|ConvertTo-Json -Depth 6
      $resp = Invoke-RestMethod -Uri http://localhost:11434/api/generate -Method Post -Body $json -ContentType "application/json" -TimeoutSec 3600 }
    else { throw }
  }
  [pscustomobject]@{Resp=$resp;ThinkUsed=$used}
}

# ---- Row writer ----
function Write-Row($p,$tier,$phase,$rep,$ctx,$res,$note){
  $r=$res.Resp
  $pt=[int](Get-Field $r @('prompt_eval_count'))
  $cached=[int](Get-Field $r @('prompt_eval_cached_count')); if(-not $cached){$cached=0}
  $pd=[double](Get-Field $r @('prompt_eval_duration')); $ld=[double](Get-Field $r @('load_duration'))
  $ec=[int](Get-Field $r @('eval_count')); $ed=[double](Get-Field $r @('eval_duration')); $td=[double](Get-Field $r @('total_duration'))
  $unc=$pt-$cached
  $prefill = if($pd -gt 0){ [math]::Round($unc/($pd/1e9),1) } else { $null }
  $decode  = if($ed -gt 0){ [math]::Round($ec/($ed/1e9),2) } else { $null }
  [pscustomobject]@{
    protocol_version='v2.0'; session_id=$Session; run_date=(Get-Date -Format 'yyyy-MM-dd HH:mm')
    machine=$Machine; env_profile=$EnvProfile; runner='Ollama'; model=$p.Model; arch=$p.Arch; quant=$p.Quant
    tier=$tier; phase=$phase; rep=$rep; ctx=$ctx; think_set=$p.Think; think_used=$res.ThinkUsed; seed=42; num_predict=256
    prompt_tokens=$pt; cached_tokens=$cached; output_tokens=$ec; stop_reason=(Get-Field $r @('done_reason'))
    load_ms=[math]::Round($ld/1e6,1); ttft_ms=[math]::Round(($ld+$pd)/1e6,1)
    prefill_tps=$prefill; decode_tps=$decode; e2e_s=[math]::Round($td/1e9,1)
    gpu_used_mb=(Get-GpuMB); committed_gb=(Get-CommitGB); split=(Get-Split $p.Model)
    provenance='ttft=D(load+prefill);prefill=D-exact;decode=D-exact;e2e=M;reason_tok=U;peak=footprint-snapshot'
    notes=$note
  } | Export-Csv $Csv -Append -NoTypeInformation
}

# ---- Run plan ----
$tags = (Invoke-RestMethod http://localhost:11434/api/tags).models
foreach($p in $Plan){
  try{
    $tag = $tags | Where-Object { $_.name -eq $p.Model -or $_.model -eq $p.Model } | Select-Object -First 1
    $sizeGB = if($tag){ [math]::Round($tag.size/1GB,2) } else { $null }
    if($Machine -eq 'M1' -and $sizeGB -gt 10){
      [pscustomobject]@{protocol_version='v2.0';session_id=$Session;run_date=(Get-Date -Format 'yyyy-MM-dd HH:mm');machine=$Machine;env_profile=$EnvProfile;runner='Ollama';model=$p.Model;arch=$p.Arch;quant=$p.Quant;tier='ALL';phase='SKIPPED_FIT';rep=0;notes="model $sizeGB GB > M1 safe threshold; move to M2"} | Export-Csv $Csv -Append -NoTypeInformation
      Write-Host "SKIP $($p.Model) ($sizeGB GB) - fit gate" -ForegroundColor Yellow; continue
    }
    # unload for true COLD
    Invoke-RestMethod -Uri http://localhost:11434/api/generate -Method Post -Body (@{model=$p.Model;keep_alive=0}|ConvertTo-Json) -ContentType "application/json" | Out-Null
    Start-Sleep 2
    $cold = Invoke-Ollama $p.Model $Short 4096 $p.Think ("cold-"+[guid]::NewGuid().ToString('N').Substring(0,8)) "10m"
    Write-Row $p 'SHORT' 'COLD' 0 4096 $cold "cold after unload; load included; NOT for floors"
    foreach($tier in $Tiers){
      $ctx = if($tier -eq 'LONG'){8192}else{4096}
      $prompt = switch($tier){ 'SHORT'{$Short} 'MEDIUM'{$Medium} 'LONG'{$Long} }
      Invoke-Ollama $p.Model $prompt $ctx $p.Think ("warm-"+[guid]::NewGuid().ToString('N').Substring(0,8)) "10m" | Out-Null   # discarded warm-up, SAME tier prompt
      for($i=1;$i -le $Reps;$i++){
        $res = Invoke-Ollama $p.Model $prompt $ctx $p.Think ("r"+$i+"-"+[guid]::NewGuid().ToString('N').Substring(0,8)) "10m"
        $note = "warm; nonce; long_hash=$LongHash"
        $cached=[int](Get-Field $res.Resp @('prompt_eval_cached_count')); if($cached -gt 0){ $note="DISCARD cache hit $cached" }
        $oc=[int](Get-Field $res.Resp @('eval_count')); if($oc -lt 200){ $note += "; short_output=$oc" }
        Write-Row $p $tier 'WARM' $i $ctx $res $note
        Write-Host "$($p.Model) $tier rep$i complete"
      }
    }
    Invoke-RestMethod -Uri http://localhost:11434/api/generate -Method Post -Body (@{model=$p.Model;keep_alive=0}|ConvertTo-Json) -ContentType "application/json" | Out-Null
 }catch{
[pscustomobject]@{protocol_version='v2.0';session_id=$Session;run_date=(Get-Date -Format 'yyyy-MM-dd HH:mm');machine=$Machine;env_profile=$EnvProfile;runner='LMStudio';model=$p.Model;arch=$p.Arch;quant=$p.Quant;tier='ERR';phase='ERROR';rep=0;notes=$_.Exception.Message}|Export-Csv $Csv -Append -NoTypeInformation
Write-Host "ERROR ..." -ForegroundColor Red
}
}
Write-Host "DONE. Raw runs: $Csv | Baseline: $Baseline" -ForegroundColor Green