param([ValidateSet('Check','Apply','Restore')][string]$Action='Check',[string]$GameRoot='')
$ErrorActionPreference='Stop'
function Need([bool]$ok,[string]$msg){if(-not $ok){throw $msg}}
function Sha([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function Regular([string]$p){
  Need (Test-Path -LiteralPath $p -PathType Leaf) "Missing file: $p"
  Need (-not ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) "Reparse point refused: $p"
}
function NoLinkPath([string]$p){
  $cur=$p
  while($cur){
    if(Test-Path -LiteralPath $cur){
      Need (-not ((Get-Item -LiteralPath $cur -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) "Reparse point refused: $cur"
    }
    $parent=Split-Path -Parent $cur
    if($parent -eq $cur){break}
    $cur=$parent
  }
}
function AtomicCopy([string]$src,[string]$dst,[string]$expected){
  $tmp=$dst+'.twdeblur-'+[Guid]::NewGuid().ToString('N')+'.tmp'
  $swapBackup=$tmp+'.previous'
  try {
    [IO.File]::Copy($src,$tmp,$false)
    Need ((Sha $tmp) -eq $expected) "Temporary copy hash mismatch: $dst"
    [IO.File]::Replace($tmp,$dst,$swapBackup)
    Need ((Sha $dst) -eq $expected) "Final hash mismatch: $dst"
  } finally {
    if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}
    if(Test-Path -LiteralPath $swapBackup){Remove-Item -LiteralPath $swapBackup -Force}
  }
}
try{
  $plan=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'plan.json') -Raw | ConvertFrom-Json
  # Always ask for a game root unless one was explicitly supplied.
  while($true){
    if([string]::IsNullOrWhiteSpace($GameRoot)){
      Write-Host '請輸入遊戲根目錄（包含 AzurPromilia_Data 的資料夾）。'
      Write-Host '可直接貼上完整路徑；按 Enter 不輸入即可取消。'
      $GameRoot=Read-Host '遊戲路徑'
      if([string]::IsNullOrWhiteSpace($GameRoot)){Write-Host 'Cancelled.';exit 0}
    }
    $candidate=$GameRoot.Trim().Trim('"').Trim()
    if(-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Container)){
      $resolved=(Resolve-Path -LiteralPath $candidate).Path
      $candidateData=Join-Path $resolved 'AzurPromilia_Data'
      if(Test-Path -LiteralPath $candidateData -PathType Container){
        $GameRoot=$resolved
        $data=$candidateData
        break
      }
    }
    Write-Host '路徑無效，請選擇包含 AzurPromilia_Data 的遊戲根目錄。' -ForegroundColor Yellow
    $GameRoot=''
  }
  NoLinkPath $data
  $backup=Join-Path $data '.tw-deblur-3221746-backup'
  $statePath=Join-Path $backup 'state.json'
  Write-Host "Action: $Action"
  Write-Host "Game root: $GameRoot"
  if($Action -ne 'Check'){
    $running=@(Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.ProcessName -like 'AzurPromilia*'})
    Need ($running.Count -eq 0) 'Close game and launcher before continuing.'
  }
  # Both known manifests must remain identical, including during restoration.
  foreach($e in $plan.readonly_files){
    $dst=Join-Path $data $e.relative_path
    NoLinkPath $dst; Regular $dst
    Need ((Sha $dst) -eq $e.sha256) "Manifest mismatch: $($e.relative_path)"
    Write-Host "Verified manifest: $($e.relative_path)"
  }
  $mdir=Join-Path $data '.res/default_package/ManifestFiles'
  $newer=@(Get-ChildItem -LiteralPath $mdir -File -Force | Where-Object {$_.Name -match '^0release_default_package_(\d+)\.bytes$' -and [long]$Matches[1] -gt [long]$plan.version})
  Need ($newer.Count -eq 0) 'Newer manifest detected. Refusing to modify this installation.'
  $items=@()
  foreach($e in $plan.files){
    $name=Split-Path -Leaf $e.relative_path
    $dst=Join-Path $data $e.relative_path
    $src=Join-Path (Join-Path $PSScriptRoot 'payload') $name
    NoLinkPath $dst; Regular $dst
    Need ((Get-Item -LiteralPath $dst).Length -eq [long]$e.size) "File size mismatch: $name"
    if($Action -ne 'Restore'){
      Regular $src
      Need ((Get-Item -LiteralPath $src).Length -eq [long]$e.size) "Payload size mismatch: $name"
      Need ((Sha $src) -eq $e.target_sha256) "Payload hash mismatch: $name"
    }
    $current=Sha $dst
    $status=if($current -eq $e.source_sha256){'Original'}elseif($current -eq $e.target_sha256){'Modified'}else{'Unknown'}
    Write-Host "$status : $($e.relative_path)"
    Need ($status -ne 'Unknown') "Unknown file; refusing changes: $dst"
    $items += [pscustomobject]@{name=$name;relative=$e.relative_path;dst=$dst;src=$src;source_sha=$e.source_sha256;target_sha=$e.target_sha256;status=$status}
  }
  if($Action -eq 'Check'){Write-Host 'Static compatibility checks passed. Runtime not verified.';exit 0}
  NoLinkPath $backup
  if($Action -eq 'Restore'){
    Regular $statePath
    $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Need ($state.game_root -eq $GameRoot) 'Backup belongs to a different game root.'
    Need ($state.version -eq $plan.version) 'Backup version mismatch.'
    foreach($x in $items){
      $orig=Join-Path $backup $x.name; Regular $orig
      Need ((Sha $orig) -eq $x.source_sha) "Invalid backup: $($x.name)"
    }
    if((Read-Host 'Type RESTORE to restore the original files') -cne 'RESTORE'){Write-Host 'Cancelled.';exit 0}
    foreach($x in $items){
      $now=Sha $x.dst
      Need (($now -eq $x.source_sha) -or ($now -eq $x.target_sha)) "File changed during restore: $($x.dst)"
      if($now -ne $x.source_sha){AtomicCopy (Join-Path $backup $x.name) $x.dst $x.source_sha}
      Write-Host "Restored/verified: $($x.relative)"
    }
    Write-Host "Restore finished. Backup retained: $backup";exit 0
  }
  Need (@($items | Where-Object {$_.status -ne 'Original'}).Count -eq 0) 'All four files must be original before applying.'
  if((Read-Host 'Runtime not verified. Type APPLY to install the candidate') -cne 'APPLY'){Write-Host 'Cancelled.';exit 0}
  if(Test-Path -LiteralPath $backup){
    Regular $statePath
    $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Need (($state.game_root -eq $GameRoot) -and ($state.version -eq $plan.version)) 'Existing backup does not match.'
    foreach($x in $items){
      $orig=Join-Path $backup $x.name; Regular $orig
      Need ((Sha $orig) -eq $x.source_sha) "Invalid existing backup: $($x.name)"
    }
  }else{
    [void](New-Item -ItemType Directory -Path $backup)
    foreach($x in $items){
      $orig=Join-Path $backup $x.name
      [IO.File]::Copy($x.dst,$orig,$false)
      Need ((Sha $orig) -eq $x.source_sha) "Backup hash mismatch: $($x.name)"
    }
    [pscustomobject]@{game_root=$GameRoot;version=$plan.version} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
  }
  $attempted=@()
  try{
    foreach($x in $items){
      Need ((Sha $x.dst) -eq $x.source_sha) "Source changed since validation: $($x.dst)"
      $attempted+=$x
      AtomicCopy $x.src $x.dst $x.target_sha
      Write-Host "Applied: $($x.relative)"
    }
  }catch{
    $failure=$_
    foreach($x in $attempted){
      try{
        $now=Sha $x.dst
        if($now -eq $x.target_sha){AtomicCopy (Join-Path $backup $x.name) $x.dst $x.source_sha}
        elseif($now -ne $x.source_sha){Write-Warning "Unknown file state: $($x.dst)"}
      }catch{Write-Warning "Rollback failed: $($x.dst)"}
    }
    throw $failure
  }
  Write-Host "Candidate installed. Backup retained: $backup";exit 0
}catch{Write-Host $_.Exception.Message -ForegroundColor Red;exit 1}
