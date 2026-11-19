<#
.SYNOPSIS
  Sync skills, MCP servers and RTK between Claude Code and OpenCode (Windows).

.PARAMETER Direction
  ToOpenCode : Claude  -> OpenCode
  ToClaude   : OpenCode -> Claude
  Both       : ToOpenCode then ToClaude (union, nothing deleted)

.PARAMETER DryRun   Show what would change, change nothing.
.PARAMETER Force    Overwrite existing MCP entries / skills that already exist on the target.

Never deletes anything. Backs up opencode.jsonc before editing.
Existing entries on the target are kept unless -Force.
#>
param(
  [ValidateSet('ToOpenCode','ToClaude','Both')][string]$Direction = 'Both',
  [switch]$DryRun,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$U = $env:USERPROFILE
$ClaudeDir  = Join-Path $U '.claude'
$ClaudeJson = Join-Path $U '.claude.json'
$OcDir      = Join-Path $U '.config\opencode'
$OcSkills   = Join-Path $OcDir 'skills'
$OcCfg      = @('opencode.jsonc','opencode.json') | % { Join-Path $OcDir $_ } | ? { Test-Path $_ } | Select -First 1
if (-not $OcCfg) { $OcCfg = Join-Path $OcDir 'opencode.jsonc' }

function Say($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Act($m){ if($DryRun){ Say "  [dry-run] $m" Yellow } else { Say "  $m" Green } }

# ---------- JSONC reader (strips comments + trailing commas, string-aware) ----------
function Read-Jsonc([string]$path){
  if (-not (Test-Path $path)) { return $null }
  $t = Get-Content $path -Raw
  $sb = New-Object Text.StringBuilder; $i=0; $inStr=$false
  while($i -lt $t.Length){
    $ch=$t[$i]
    if($inStr){ [void]$sb.Append($ch); if($ch -eq '\'){ $i++; if($i -lt $t.Length){[void]$sb.Append($t[$i])} } elseif($ch -eq '"'){ $inStr=$false } }
    elseif($ch -eq '"'){ $inStr=$true; [void]$sb.Append($ch) }
    elseif($ch -eq '/' -and $i+1 -lt $t.Length -and $t[$i+1] -eq '/'){ while($i -lt $t.Length -and $t[$i] -ne "`n"){$i++}; continue }
    elseif($ch -eq '/' -and $i+1 -lt $t.Length -and $t[$i+1] -eq '*'){ $i+=2; while($i+1 -lt $t.Length -and -not($t[$i] -eq '*' -and $t[$i+1] -eq '/')){$i++}; $i+=2; continue }
    else { [void]$sb.Append($ch) }
    $i++
  }
  $s = [regex]::Replace($sb.ToString(), ',(\s*[}\]])', '$1')
  return $s | ConvertFrom-Json
}
function To-Hash($o){  # PSCustomObject -> ordered hashtable (one level)
  $h=[ordered]@{}; if($o){ foreach($p in $o.PSObject.Properties){ $h[$p.Name]=$p.Value } }; return $h
}

# ---------- Collect Claude-side assets ----------
function Get-ClaudeSkillDirs {   # name -> path
  $m=@{}
  $roots=@()
  $roots += (Join-Path $ClaudeDir 'skills')
  $ip = Join-Path $ClaudeDir 'plugins\installed_plugins.json'
  if(Test-Path $ip){
    $j = Get-Content $ip -Raw | ConvertFrom-Json
    foreach($p in $j.plugins.PSObject.Properties){ foreach($e in $p.Value){ if($e.installPath){ $roots += (Join-Path $e.installPath 'skills') } } }
  }
  $roots += (Get-ChildItem "$env:APPDATA\Claude\rpm\*\*\plugin_*\skills" -Directory -ErrorAction SilentlyContinue | % FullName)
  foreach($r in $roots){
    if(-not (Test-Path $r)){continue}
    foreach($d in Get-ChildItem $r -Directory){ if((Test-Path "$($d.FullName)\SKILL.md") -and -not $m.ContainsKey($d.Name)){ $m[$d.Name]=$d.FullName } }
  }
  return $m
}
function Get-ClaudeMcp {   # name -> normalized {kind,command,args,env,url,headers}
  $m=@{}
  function Add($n,$s){
    if($m.ContainsKey($n)){return}
    $type = if($s.type){$s.type}elseif($s.url){'http'}else{'stdio'}
    $m[$n]=@{ kind=$(if($type -eq 'stdio'){'local'}else{'remote'}); command=$s.command; args=@($s.args); env=(To-Hash $s.env); url=$s.url; headers=(To-Hash $s.headers) }
  }
  if(Test-Path $ClaudeJson){
    $j = Get-Content $ClaudeJson -Raw | ConvertFrom-Json
    foreach($p in (To-Hash $j.mcpServers).GetEnumerator()){ Add $p.Key $p.Value }
    foreach($proj in $j.projects.PSObject.Properties){ foreach($p in (To-Hash $proj.Value.mcpServers).GetEnumerator()){ Add $p.Key $p.Value } }
  }
  $ip = Join-Path $ClaudeDir 'plugins\installed_plugins.json'
  if(Test-Path $ip){
    $j = Get-Content $ip -Raw | ConvertFrom-Json
    foreach($p in $j.plugins.PSObject.Properties){ foreach($e in $p.Value){
      $f = Join-Path $e.installPath '.mcp.json'
      if(Test-Path $f){ $x = Get-Content $f -Raw | ConvertFrom-Json; $srv = if($x.mcpServers){$x.mcpServers}else{$x}; foreach($q in (To-Hash $srv).GetEnumerator()){ Add $q.Key $q.Value } }
    } }
  }
  return $m
}

# ---------- Claude -> OpenCode ----------
function Sync-ToOpenCode {
  Say "`n== Claude -> OpenCode ==" Cyan
  # Skills: user skills in ~/.claude/skills are already read by OpenCode natively; copy plugin/account skills only.
  $userSkills = Join-Path $ClaudeDir 'skills'
  $n=0
  foreach($kv in (Get-ClaudeSkillDirs).GetEnumerator()){
    if($kv.Value.StartsWith($userSkills,'OrdinalIgnoreCase')){ continue }
    $dst = Join-Path $OcSkills $kv.Key
    if((Test-Path $dst) -and -not $Force){ continue }
    Act "skill $($kv.Key)"; $n++
    if(-not $DryRun){ New-Item -ItemType Directory -Force $OcSkills | Out-Null; if(Test-Path $dst){Remove-Item $dst -Recurse -Force}; Copy-Item $kv.Value $dst -Recurse -Force }
  }
  Say "  skills copied: $n"
  # MCP
  $cfg = Read-Jsonc $OcCfg; if(-not $cfg){ $cfg = [pscustomobject]@{ '$schema'='https://opencode.ai/config.json' } }
  $mcp = To-Hash $cfg.mcp; $added=0
  foreach($kv in (Get-ClaudeMcp).GetEnumerator()){
    if($mcp.Contains($kv.Key) -and -not $Force){ continue }
    $s=$kv.Value
    if($s.kind -eq 'local'){
      $e=[ordered]@{ type='local'; command=@(@($s.command)+@($s.args) | ? { $_ }); enabled=$true }
      if($s.env.Count){ $e.environment=$s.env }
    } else {
      $e=[ordered]@{ type='remote'; url=$s.url; enabled=$true }
      if($s.headers.Count){ $e.headers=$s.headers }
    }
    Act "mcp $($kv.Key) ($($s.kind))"; $mcp[$kv.Key]=[pscustomobject]$e; $added++
  }
  if($added -and -not $DryRun){
    if(Test-Path $OcCfg){ Copy-Item $OcCfg "$OcCfg.bak" -Force }
    if($cfg.PSObject.Properties['mcp']){ $cfg.mcp=[pscustomobject]$mcp } else { $cfg | Add-Member mcp ([pscustomobject]$mcp) }
    ($cfg | ConvertTo-Json -Depth 20) | Set-Content $OcCfg -Encoding UTF8
    Say "  (backup: $OcCfg.bak; comments in the file, if any, are not preserved)" DarkGray
  }
  Say "  mcp added: $added"
  # RTK
  if(Get-Command rtk -ErrorAction SilentlyContinue){
    $plug = Join-Path $OcDir 'plugins\rtk.ts'
    if((Test-Path $plug) -and -not $Force){ Say "  rtk: OpenCode plugin already installed ($(rtk --version))" }
    else { Act "rtk init -g --opencode --auto-patch"; if(-not $DryRun){ rtk init -g --opencode --auto-patch | Out-Null } }
  } else { Say "  rtk: not on PATH, skipped (install from https://github.com/rtk-ai/rtk/releases)" Yellow }
}

# ---------- OpenCode -> Claude ----------
function Sync-ToClaude {
  Say "`n== OpenCode -> Claude ==" Cyan
  $claudeSkills = Get-ClaudeSkillDirs; $n=0
  if(Test-Path $OcSkills){
    foreach($d in Get-ChildItem $OcSkills -Directory){
      if(-not (Test-Path "$($d.FullName)\SKILL.md")){ continue }
      if($claudeSkills.ContainsKey($d.Name) -and -not $Force){ continue }
      $dst = Join-Path $ClaudeDir "skills\$($d.Name)"
      Act "skill $($d.Name)"; $n++
      if(-not $DryRun){ if(Test-Path $dst){Remove-Item $dst -Recurse -Force}; Copy-Item $d.FullName $dst -Recurse -Force }
    }
  }
  Say "  skills copied: $n"
  $cfg = Read-Jsonc $OcCfg; $have = Get-ClaudeMcp; $added=0
  if($cfg -and $cfg.mcp){
    $claudeOk = [bool](Get-Command claude -ErrorAction SilentlyContinue)
    foreach($kv in (To-Hash $cfg.mcp).GetEnumerator()){
      if($have.ContainsKey($kv.Key) -and -not $Force){ continue }
      $s=$kv.Value
      if($s.enabled -eq $false){ continue }
      if($s.type -eq 'remote'){ $o=[ordered]@{ type='http'; url=$s.url }; if($s.headers){ $o.headers=$s.headers } }
      else { $cmd=@($s.command); $o=[ordered]@{ type='stdio'; command=$cmd[0]; args=@($cmd | Select -Skip 1) }; if($s.environment){ $o.env=$s.environment } }
      $json = $o | ConvertTo-Json -Depth 10 -Compress
      Act "mcp $($kv.Key) ($($s.type))"; $added++
      if(-not $DryRun){
        if(-not $claudeOk){ Say "    claude CLI not found; run manually: claude mcp add-json -s user $($kv.Key) '$json'" Yellow; continue }
        if($Force){ claude mcp remove $($kv.Key) -s user 2>$null | Out-Null }
        claude mcp add-json -s user $kv.Key ($json.Replace('"','\"')) | Out-Null
      }
    }
  }
  Say "  mcp added: $added"
}

# ---------- Run ----------
if(-not (Test-Path $OcDir)){ Say "OpenCode config dir not found: $OcDir" Red; exit 1 }
if($DryRun){ Say "DRY RUN - no changes will be made" Yellow }
if($Direction -in 'ToOpenCode','Both'){ Sync-ToOpenCode }
if($Direction -in 'ToClaude','Both'){ Sync-ToClaude }
Say "`nDone. Restart Claude Code / OpenCode to pick up changes." Cyan
