$Machine="M1"; $Runner="Ollama"; $EnvProfile="NORMAL_ALWAYS_ON_STT"
$Reps=3; $Cap=1024; $Ctx=4096
$Root="C:\AI\Bench"; $Session=(Get-Date -Format "yyyyMMdd-HHmmss")+"-"+$Machine+"-RD"
$Dir=Join-Path $Root $Session; New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$Csv=Join-Path $Dir "realdoc_runs.csv"
$ArticleFile="C:\AI\Bench\realdoc_article.md"
if(-not(Test-Path $ArticleFile)){ Write-Host "MISSING $ArticleFile" -ForegroundColor Red; exit }
$Hash=(Get-FileHash $ArticleFile -Algorithm SHA256).Hash
$Prompt=(Get-Content $ArticleFile -Raw) + "`n`nBased on the text above, extract the 5 most important financial metrics and explain their significance."
if($Runner -eq "Ollama"){ $Plan=@(@{Model='qwen3.5:4b';Think='off'},@{Model='nemotron-3-nano:4b';Think='off'}) }
else{ $Plan=@(@{Model='lfm2.5-24b-a2b';Think='off'},@{Model='openai_gpt-oss-20b';Think='low'}) }
function Get-Field($o,$names){foreach($n in $names){if($o -and ($o.PSObject.Properties.Name -contains $n) -and $o.$n -ne $null){return $o.$n}}return $null}
foreach($p in $Plan){
  if($Runner -eq "LMStudio"){ Read-Host "Load $($p.Model) in LM Studio | ctx=4096 | offload max | reasoning=$($p.Think). Press Enter" }
  $safe=($p.Model -replace '[^a-zA-Z0-9]','_')
  for($i=0;$i -le $Reps;$i++){
    $nonce= if($i -eq 0){"warm"}else{"rd"+$i+"-"+[guid]::NewGuid().ToString('N').Substring(0,6)}
    try{
      if($Runner -eq "Ollama"){
        $body=@{model=$p.Model;prompt="[$nonce] "+$Prompt;stream=$false;keep_alive="10m";options=@{temperature=0;seed=42;num_ctx=$Ctx;num_predict=$Cap}}
        if($p.Think -eq 'off'){$body.think=$false}
        $r=Invoke-RestMethod -Uri http://localhost:11434/api/generate -Method Post -Body ($body|ConvertTo-Json -Depth 6) -ContentType "application/json" -TimeoutSec 3600
        $answer=$r.response; $think=$r.thinking
        $pt=[int]$r.prompt_eval_count; $ot=[int]$r.eval_count; $rt=0
        $ttft=($r.load_duration+$r.prompt_eval_duration)/1e6
        $prefill= if($r.prompt_eval_duration -gt 0){[math]::Round($pt/($r.prompt_eval_duration/1e9),1)}else{$null}
        $decode= if($r.eval_duration -gt 0){[math]::Round($ot/($r.eval_duration/1e9),2)}else{$null}
        $e2e=[math]::Round($r.total_duration/1e9,1); $prov="ttft=D;prefill=D-exact;decode=D-exact;e2e=M"
      }else{
        $body=@{model=$p.Model;input="[$nonce] "+$Prompt;temperature=0;max_output_tokens=$Cap;stream=$false}
        $r=Invoke-RestMethod -Uri http://localhost:1234/api/v1/chat -Method Post -Body ($body|ConvertTo-Json -Depth 6) -ContentType "application/json" -TimeoutSec 3600
        $s=$r.stats
        $answer=(($r.output | Where-Object {$_.type -eq 'message'} | ForEach-Object {$_.content}) -join "")
        $think=(($r.output | Where-Object {$_.type -eq 'reasoning'} | ForEach-Object {$_.content}) -join "")
        $pt=[int](Get-Field $s @('input_tokens')); $ot=[int](Get-Field $s @('total_output_tokens')); $rt=[int](Get-Field $s @('reasoning_output_tokens'))
        $ttft=[double](Get-Field $s @('time_to_first_token_seconds'))*1000; $tps=[double](Get-Field $s @('tokens_per_second'))
        $prefill= if($ttft -gt 0){[math]::Round($pt/($ttft/1000),1)}else{$null}
        $decode=[math]::Round($tps,2); $e2e=[math]::Round(($ttft/1000)+($ot/$tps),1); $prov="ttft=M;prefill=D-lowerbound;decode=M;e2e=D"
      }
      if($i -eq 0){ continue }
      $ansFile=Join-Path $Dir ($safe+"_rep"+$i+".txt"); Set-Content -Path $ansFile -Value $answer
      if($think){ Set-Content -Path (Join-Path $Dir ($safe+"_rep"+$i+"_thinking.txt")) -Value $think }
      [pscustomobject]@{session_id=$Session;run_date=(Get-Date -Format 'yyyy-MM-dd HH:mm');machine=$Machine;env_profile=$EnvProfile;runner=$Runner;model=$p.Model;tier='REALDOC';rep=$i;ctx=$Ctx;cap=$Cap;think=$p.Think;article_hash=$Hash;prompt_tokens=$pt;ttft_ms=[math]::Round($ttft,1);prefill_tps=$prefill;decode_tps=$decode;e2e_s=$e2e;output_tokens=$ot;reasoning_tokens=$rt;answer_tokens=($ot-$rt);answer_file=$ansFile;score='';provenance=$prov} | Export-Csv $Csv -Append -NoTypeInformation
      Write-Host "$($p.Model) rep$i done (answer $($ot-$rt) tok)"
    }catch{ $msg="ERROR $($p.Model) rep$i : $($_.Exception.Message)"; Write-Host $msg -ForegroundColor Red; Add-Content (Join-Path $Dir "errors.txt") $msg }
  }
}
Write-Host "DONE. $Csv | answers in $Dir" -ForegroundColor Green