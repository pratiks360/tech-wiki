<#
.SYNOPSIS
  Keep Claude Code and OpenCode in sync, on every machine, through a master stored in a git repo.

.DESCRIPTION
  Master (in the repo, folder .agent-master):
    skills/<name>/...   user-owned skills (full copy)
    mcp.json            MCP servers, neutral format, secrets redacted
    plugins.json        Claude Code plugins (+ marketplace sources) to install
  Per machine, "local" = Claude Code + OpenCode together (union).

  Sync   : pull master, apply what is missing locally, add what is new locally to master, commit + push.
  Pull   : master -> this machine only.
  Push   : this machine -> master only.
  Status : show differences, change nothing.

  Nothing is ever deleted. A skill / MCP entry that exists on both sides with different content is a
  CONFLICT: reported, and resolved only with -Prefer Local|Repo.

.PARAMETER Action   Sync (default) | Pull | Push | Status
.PARAMETER Prefer   None (default) | Local | Repo   - how to resolve conflicts
.PARAMETER DryRun   Change nothing (also for git)
.PARAMETER DuplicateToOpenCode  Also copy master skills into OpenCode's own skills dir
                    (normally not needed: OpenCode reads ~/.claude/skills).
.PARAMETER RepoDir  Local clone to use. Default: the clone this script lives in, else %USERPROFILE%\.agent-sync\tech-wiki
#>
param(
  [ValidateSet('Sync','Pull','Push','Status')][string]$Action = 'Sync',
  [ValidateSet('None','Local','Repo')][string]$Prefer = 'None',
  [switch]$DryRun,
  [switch]$DuplicateToOpenCode,
  [string]$RepoUrl = 'https://github.com/pratiks360/tech-wiki.git',
  [string]$RepoDir
)
$ErrorActionPreference = 'Stop'
$U          = $env:USERPROFILE
$ClaudeDir  = Join-Path $U '.claude'
$ClaudeSk   = Join-Path $ClaudeDir 'skills'
$ClaudeJson = Join-Path $U '.claude.json'
$OcDir      = Join-Path $U '.config\opencode'
$OcSkills   = Join-Path $OcDir 'skills'
$OcCfg      = @('opencode.jsonc','opencode.json') | % { Join-Path $OcDir $_ } | ? { Test-Path $_ } | Select -First 1
if (-not $OcCfg) { $OcCfg = Join-Path $OcDir 'opencode.jsonc' }
$Conflicts = New-Object System.Collections.ArrayList
$Warnings  = New-Object System.Collections.ArrayList
$Changed   = $false   # repo changed

function Say($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Act($m){ if($DryRun -or $Action -eq 'Status'){ Say "  [would] $m" Yellow } else { Say "  $m" Green } }
function Warn($m){ [void]$Warnings.Add($m); Say "  ! $m" Yellow }
$Write = (-not $DryRun) -and ($Action -ne 'Status')
$DoPull = $Action -in 'Sync','Pull','Status'
$DoPush = $Action -in 'Sync','Push','Status'

# ---------------- helpers ----------------
function Write-Utf8([string]$path,[string]$text){ $text=$text.Replace('\u003c','<').Replace('\u003e','>').Replace('\u0026','&').Replace('\u0027',"'"); [IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false))) }
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
function To-Hash($o){ $h=[ordered]@{}; if($o -is [System.Collections.IDictionary]){ foreach($k in $o.Keys){ $h[$k]=$o[$k] } } elseif($o){ foreach($p in $o.PSObject.Properties){ $h[$p.Name]=$p.Value } }; return $h }
function Read-JsonFile($path,$default){ if(Test-Path $path){ $r = Get-Content $path -Raw | ConvertFrom-Json; if($r){return $r} }; return $default }

$JunkRx = '\\(__pycache__|node_modules|\.git|\.DS_Store)(\\|$)|\.pyc$'
function Get-SkillFiles($dir){ Get-ChildItem $dir -Recurse -File -Force | ? { $_.FullName -notmatch $JunkRx } }
function Get-DirHash($dir){   # line-ending-insensitive for text files
  $sha=[Security.Cryptography.SHA256]::Create(); $sb=New-Object Text.StringBuilder
  foreach($f in (Get-SkillFiles $dir | Sort-Object FullName)){
    $rel=$f.FullName.Substring($dir.Length).TrimStart('\').Replace('\','/')
    $b=[IO.File]::ReadAllBytes($f.FullName)
    if($b -notcontains 0){ $b = [byte[]]($b | ? { $_ -ne 13 }) }
    [void]$sb.Append($rel).Append(':').Append([BitConverter]::ToString($sha.ComputeHash($b))).Append(';')
  }
  return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sb.ToString())))
}
function Copy-SkillDir($src,$dst){
  if(Test-Path $dst){ Remove-Item $dst -Recurse -Force }
  New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
  Copy-Item $src $dst -Recurse -Force
  Get-ChildItem $dst -Recurse -Force | ? { $_.FullName -match $JunkRx } | Sort-Object FullName -Descending | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
$SecretRx = '(sk-(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]{24,}|ghp_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.)'
function Find-Secret($dir){
  foreach($f in (Get-SkillFiles $dir)){
    if($f.Length -gt 2MB){ continue }
    $b=[IO.File]::ReadAllBytes($f.FullName); if($b -contains 0){ continue }
    $m=[regex]::Match([Text.Encoding]::UTF8.GetString($b), $SecretRx)
    if($m.Success){ return "$($f.Name): $($m.Value.Substring(0,[Math]::Min(8,$m.Value.Length)))..." }
  }
  return $null
}

# ---------------- repo ----------------
function Resolve-Repo {
  if($RepoDir){ return $RepoDir }
  $top = $null
  try { $top = (git -C $PSScriptRoot rev-parse --show-toplevel 2>$null) } catch {}
  if($top -and (Test-Path (Join-Path $top 'ai-tooling\agent-sync'))){ return ($top -replace '/','\') }
  return (Join-Path $U '.agent-sync\tech-wiki')
}
function RGit { & git -C $script:Repo @args; if($LASTEXITCODE -ne 0){ throw "git $($args -join ' ') failed ($LASTEXITCODE)" } }
function Ensure-Repo {
  $script:Repo = Resolve-Repo
  Say "Repo: $script:Repo" DarkGray
  if(-not (Test-Path (Join-Path $script:Repo '.git'))){
    Act "clone $RepoUrl"
    if(-not $DryRun){ New-Item -ItemType Directory -Force (Split-Path $script:Repo) | Out-Null; git clone -q $RepoUrl $script:Repo; if($LASTEXITCODE){ throw 'clone failed' } }
    elseif(-not (Test-Path $script:Repo)){ throw "Repo not cloned yet; run without -DryRun/Status once, or: git clone $RepoUrl `"$script:Repo`"" }
  } else {
    if(-not $DryRun){ RGit pull -q --rebase --autostash }
  }
  $script:Master = Join-Path $script:Repo '.agent-master'
  $script:MSkills = Join-Path $script:Master 'skills'
  if($Write){ New-Item -ItemType Directory -Force $script:MSkills | Out-Null
    $ga = Join-Path $script:Master '.gitattributes'; if(-not (Test-Path $ga)){ Write-Utf8 $ga "* -text`n" } }
}

# ---------------- local inventory ----------------
function Get-ClaudePluginSkillDirs {   # skills that come from plugins / account plugins (not user-owned)
  $m=@{}; $roots=@()
  $ip = Join-Path $ClaudeDir 'plugins\installed_plugins.json'
  if(Test-Path $ip){ $j=Get-Content $ip -Raw | ConvertFrom-Json
    foreach($p in $j.plugins.PSObject.Properties){ foreach($e in $p.Value){ if($e.installPath){ $roots += (Join-Path $e.installPath 'skills') } } } }
  $roots += (Get-ChildItem "$env:APPDATA\Claude\rpm\*\*\plugin_*\skills" -Directory -ErrorAction SilentlyContinue | % FullName)
  foreach($r in $roots){ if(-not (Test-Path $r)){continue}
    foreach($d in Get-ChildItem $r -Directory){ if((Test-Path "$($d.FullName)\SKILL.md") -and -not $m.ContainsKey($d.Name)){ $m[$d.Name]=$d.FullName } } }
  return $m
}
function Get-LocalUserSkills($pluginNames){   # name -> path (user-owned)
  $m=@{}
  foreach($root in @($ClaudeSk,$OcSkills)){
    if(-not (Test-Path $root)){continue}
    foreach($d in Get-ChildItem $root -Directory){
      if(-not (Test-Path "$($d.FullName)\SKILL.md")){ continue }
      if($m.ContainsKey($d.Name)){ continue }
      if($pluginNames.ContainsKey($d.Name) -and $root -eq $OcSkills){ continue }  # OpenCode-dir copy of a plugin skill
      $m[$d.Name]=$d.FullName
    }
  }
  return $m
}
function Norm-Mcp($name,$s,$fromOc){   # -> neutral {type, command[], env, url, headers}
  if($fromOc){
    if($s.type -eq 'remote'){ return [ordered]@{ type='remote'; url=$s.url; headers=(To-Hash $s.headers) } }
    return [ordered]@{ type='local'; command=@($s.command); env=(To-Hash $s.environment) }
  }
  $t = if($s.type){$s.type}elseif($s.url){'http'}else{'stdio'}
  if($t -eq 'stdio'){ return [ordered]@{ type='local'; command=@(@($s.command)+@($s.args) | ? { $_ }); env=(To-Hash $s.env) } }
  return [ordered]@{ type='remote'; url=$s.url; headers=(To-Hash $s.headers) }
}
function Get-LocalMcp {   # name -> @{ def=neutral(raw secrets); inClaude; inOc }
  $m=@{}
  function Put($n,$d,$where){ if(-not $m.ContainsKey($n)){ $m[$n]=@{def=$d;inClaude=$false;inOc=$false} }; $m[$n][$where]=$true }
  if(Test-Path $ClaudeJson){ $j=Get-Content $ClaudeJson -Raw | ConvertFrom-Json
    foreach($p in (To-Hash $j.mcpServers).GetEnumerator()){ Put $p.Key (Norm-Mcp $p.Key $p.Value $false) 'inClaude' }
    foreach($proj in $j.projects.PSObject.Properties){ foreach($p in (To-Hash $proj.Value.mcpServers).GetEnumerator()){ Put $p.Key (Norm-Mcp $p.Key $p.Value $false) 'inClaude' } } }
  $ip = Join-Path $ClaudeDir 'plugins\installed_plugins.json'
  if(Test-Path $ip){ $j=Get-Content $ip -Raw | ConvertFrom-Json
    foreach($p in $j.plugins.PSObject.Properties){ foreach($e in $p.Value){ $f=Join-Path $e.installPath '.mcp.json'
      if(Test-Path $f){ $x=Get-Content $f -Raw | ConvertFrom-Json; $srv=if($x.mcpServers){$x.mcpServers}else{$x}
        foreach($q in (To-Hash $srv).GetEnumerator()){ if(-not $m.ContainsKey($q.Key)){ Put $q.Key (Norm-Mcp $q.Key $q.Value $false) 'inClaude' } } } } } }
  $cfg = Read-Jsonc $OcCfg
  if($cfg -and $cfg.mcp){ foreach($p in (To-Hash $cfg.mcp).GetEnumerator()){ if($p.Value.enabled -eq $false){continue}; Put $p.Key (Norm-Mcp $p.Key $p.Value $true) 'inOc' } }
  return $m
}
function Redact($d){   # copy with secret values replaced; returns $null if args look secret
  $o=[ordered]@{}; foreach($k in $d.Keys){ $o[$k]=$d[$k] }
  foreach($f in 'env','headers'){ if($o.Contains($f)){ $h=[ordered]@{}; foreach($kv in (To-Hash $o[$f]).GetEnumerator()){ $h[$kv.Key]='<REDACTED>' }; $o[$f]=$h } }
  if($o.Contains('command') -and (($o.command -join ' ') -match $SecretRx)){ return $null }
  if($o.Contains('url') -and ($o.url -match $SecretRx -or $o.url -match '[?&](key|token|api_key|apikey)=')){ return $null }
  return $o
}
function Mcp-Sig($d){   # canonical signature ignoring secret values and JSON round-trip quirks
  $h = To-Hash $d
  $cmd = (@($h['command']) | ? { $_ }) -join ' '
  if($cmd -match $SecretRx -or "$($h['url'])" -match $SecretRx){ return 'SECRET' }
  $env = (@((To-Hash $h['env']).Keys) | Sort-Object) -join ','
  $hdr = (@((To-Hash $h['headers']).Keys) | Sort-Object) -join ','
  return "$($h['type'])|$cmd|$($h['url'])|env:$env|hdr:$hdr"
}
function Resolve-Secrets($d,$name){   # master def -> installable def, or $null if secrets missing
  $o=[ordered]@{}; foreach($k in $d.PSObject.Properties){ $o[$k.Name]=$k.Value }
  foreach($f in 'env','headers'){ if($o.Contains($f)){ $h=[ordered]@{}
      foreach($kv in (To-Hash $o[$f]).GetEnumerator()){
        if($kv.Value -eq '<REDACTED>'){ $ev=[Environment]::GetEnvironmentVariable($kv.Key); if(-not $ev){ Warn "mcp '$name' needs secret '$($kv.Key)': set it as an environment variable, then re-run"; return $null }; $h[$kv.Key]=$ev }
        else { $h[$kv.Key]=$kv.Value } }
      $o[$f]=$h } }
  return $o
}

function Add-ClaudeMcp($name,$o){
  if(-not (Get-Command claude -ErrorAction SilentlyContinue)){ Warn "claude CLI not found; skipped mcp '$name'"; return }
  if($o.type -eq 'remote'){ $j=[ordered]@{ type='http'; url=$o.url }; if($o.headers.Count){ $j.headers=$o.headers } }
  else { $c=@($o.command); $j=[ordered]@{ type='stdio'; command=$c[0]; args=@($c | Select -Skip 1) }; if($o.env.Count){ $j.env=$o.env } }
  $json = $j | ConvertTo-Json -Depth 10 -Compress
  $eap=$ErrorActionPreference; $ErrorActionPreference='Continue'
  try { claude mcp remove $name -s user 2>$null | Out-Null; claude mcp add-json -s user $name ($json.Replace('"','\"')) | Out-Null } finally { $ErrorActionPreference=$eap }
}
function Add-OcMcp($name,$o,[ref]$cfgRef){
  $cfg=$cfgRef.Value; $mcp=To-Hash $cfg.mcp
  if($o.type -eq 'remote'){ $e=[ordered]@{ type='remote'; url=$o.url; enabled=$true }; if($o.headers.Count){ $e.headers=$o.headers } }
  else { $e=[ordered]@{ type='local'; command=@($o.command); enabled=$true }; if($o.env.Count){ $e.environment=$o.env } }
  $mcp[$name]=[pscustomobject]$e
  if($cfg.PSObject.Properties['mcp']){ $cfg.mcp=[pscustomobject]$mcp } else { $cfg | Add-Member mcp ([pscustomobject]$mcp) }
}

# =============== SKILLS ===============
function Sync-Skills {
  Say "`n== Skills ==" Cyan
  $plugin = Get-ClaudePluginSkillDirs
  $local  = Get-LocalUserSkills $plugin
  $master = @{}; if(Test-Path $MSkills){ foreach($d in Get-ChildItem $MSkills -Directory){ if(Test-Path "$($d.FullName)\SKILL.md"){ $master[$d.Name]=$d.FullName } } }
  $names = @($local.Keys) + @($master.Keys) | Sort-Object -Unique
  $nPush=0;$nPull=0;$nSame=0
  foreach($n in $names){
    $inL=$local.ContainsKey($n); $inM=$master.ContainsKey($n)
    $push=$false; $pull=$false
    if($inL -and -not $inM){ $push=$DoPush }
    elseif($inM -and -not $inL){ $pull=$DoPull }
    else {
      if((Get-DirHash $local[$n]) -eq (Get-DirHash $master[$n])){ $nSame++; continue }
      if($Prefer -eq 'Local'){ $push=$DoPush } elseif($Prefer -eq 'Repo'){ $pull=$DoPull }
      else { [void]$Conflicts.Add("skill '$n' differs between this machine and master (use -Prefer Local|Repo)"); continue }
    }
    if($push){
      $sec = Find-Secret $local[$n]
      if($sec){ Warn "skill '$n' NOT pushed: looks like it contains a secret ($sec)"; continue }
      Act "push skill $n"; $nPush++
      if($Write){ Copy-SkillDir $local[$n] (Join-Path $MSkills $n); $script:Changed=$true }
    }
    if($pull){
      Act "pull skill $n"; $nPull++
      if($Write){ Copy-SkillDir $master[$n] (Join-Path $ClaudeSk $n)
        if($DuplicateToOpenCode){ Copy-SkillDir $master[$n] (Join-Path $OcSkills $n) }
        elseif((Test-Path (Join-Path $OcSkills $n)) -and -not $plugin.ContainsKey($n)){ Copy-SkillDir $master[$n] (Join-Path $OcSkills $n) } }
    }
  }
  Say "  pushed: $nPush  pulled: $nPull  identical: $nSame"
}

# =============== MCP ===============
function Sync-Mcp {
  Say "`n== MCP servers ==" Cyan
  $mf = Join-Path $script:Master 'mcp.json'
  $master = To-Hash (Read-JsonFile $mf $null)
  $local  = Get-LocalMcp
  $cfg    = Read-Jsonc $OcCfg; if(-not $cfg){ $cfg=[pscustomobject]@{ '$schema'='https://opencode.ai/config.json' } }
  $ocDirty=$false; $mDirty=$false; $nPush=0;$nInst=0
  $names = @($local.Keys)+@($master.Keys) | Sort-Object -Unique
  foreach($n in $names){
    $inL=$local.ContainsKey($n); $inM=$master.Contains($n)
    $final=$null   # neutral def to install on the machine
    if($inL -and -not $inM){
      if($DoPush){ $r=Redact $local[$n].def
        if(-not $r){ Warn "mcp '$n' NOT pushed: command/url looks like it contains a secret"; continue }
        Act "push mcp $n"; $nPush++; $master[$n]=[pscustomobject]$r; $mDirty=$true }
    }
    elseif($inM -and -not $inL){ $final=$master[$n] }
    else {
      if((Mcp-Sig $local[$n].def) -ne (Mcp-Sig $master[$n])){
        if($Prefer -eq 'Local' -and $DoPush){ $r=Redact $local[$n].def; if($r){ Act "push (overwrite) mcp $n"; $master[$n]=[pscustomobject]$r; $mDirty=$true; $nPush++ } }
        elseif($Prefer -eq 'Repo' -and $DoPull){ $final=$master[$n]; $forceInstall=$true }
        else { [void]$Conflicts.Add("mcp '$n' differs between this machine and master (use -Prefer Local|Repo)"); continue }
      }
    }
    # make sure the server exists in BOTH tools on this machine
    if($DoPull){
      $def = if($final){ $final } elseif($master.Contains($n)){ $master[$n] } elseif($inL){ $local[$n].def } else { $null }
      if($def -and ($final -or -not $local[$n].inClaude -or -not $local[$n].inOc)){
        $needC = $final -or -not $local[$n].inClaude; $needO = $final -or -not $local[$n].inOc
        if($final -and -not $forceInstall){ $needC=$true; $needO=$true }
        $inst = if($inL -and -not $final){ $local[$n].def } else { Resolve-Secrets $def $n }
        if($inst){
          if($needC){ Act "install mcp $n -> Claude Code"; $nInst++; if($Write){ Add-ClaudeMcp $n $inst } }
          if($needO){ Act "install mcp $n -> OpenCode";   $nInst++; if($Write){ Add-OcMcp $n $inst ([ref]$cfg); $ocDirty=$true } }
        }
      }
    }
    $forceInstall=$false
  }
  if($Write){
    if($mDirty){ $o=[ordered]@{}; foreach($k in ($master.Keys | Sort-Object)){ $o[$k]=$master[$k] }
      Write-Utf8 $mf (($o | ConvertTo-Json -Depth 10) + "`n"); $script:Changed=$true }
    if($ocDirty){ if(Test-Path $OcCfg){ Copy-Item $OcCfg "$OcCfg.bak" -Force }
      Write-Utf8 $OcCfg (($cfg | ConvertTo-Json -Depth 20) + "`n") }
  }
  Say "  pushed: $nPush  installed: $nInst"
}

# =============== PLUGINS ===============
function Sync-Plugins {
  Say "`n== Claude Code plugins ==" Cyan
  $pf = Join-Path $script:Master 'plugins.json'
  $master = Read-JsonFile $pf ([pscustomobject]@{ plugins=@(); marketplaces=[pscustomobject]@{} })
  $mPlug = @($master.plugins); $mMk = To-Hash $master.marketplaces
  $ip = Join-Path $ClaudeDir 'plugins\installed_plugins.json'
  $lPlug=@(); if(Test-Path $ip){ $lPlug=@((Get-Content $ip -Raw | ConvertFrom-Json).plugins.PSObject.Properties.Name) }
  $km = Join-Path $ClaudeDir 'plugins\known_marketplaces.json'; $lMk=@{}
  if(Test-Path $km){ foreach($p in (Get-Content $km -Raw | ConvertFrom-Json).PSObject.Properties){ $s=$p.Value.source; if($s.source -eq 'github'){ $lMk[$p.Name]=$s.repo } } }
  $dirty=$false
  if($DoPush){
    foreach($p in $lPlug){ if($mPlug -notcontains $p){ Act "push plugin $p"; $mPlug+=$p; $dirty=$true
        $mkName=($p -split '@')[1]; if($mkName -and $lMk.ContainsKey($mkName) -and -not $mMk.Contains($mkName)){ $mMk[$mkName]=$lMk[$mkName] } } }
    foreach($k in $lMk.Keys){ if(-not $mMk.Contains($k)){ $mMk[$k]=$lMk[$k]; $dirty=$true } }
  }
  if($DoPull){
    foreach($p in $mPlug){ if($lPlug -contains $p){ continue }
      Act "install plugin $p"
      if($Write){
        if(-not (Get-Command claude -ErrorAction SilentlyContinue)){ Warn "claude CLI not found; skipped plugin $p"; continue }
        $mkName=($p -split '@')[1]
        if($mkName -and $mMk.Contains($mkName) -and -not $lMk.ContainsKey($mkName) -and $mkName -ne 'claude-plugins-official'){ $eap=$ErrorActionPreference; $ErrorActionPreference='Continue'; try { claude plugin marketplace add $mMk[$mkName] 2>&1 | Out-Null } finally { $ErrorActionPreference=$eap } }
        $eap=$ErrorActionPreference; $ErrorActionPreference='Continue'; try { claude plugin install $p 2>&1 | Out-Null } finally { $ErrorActionPreference=$eap }
        if($LASTEXITCODE){ if($mkName -and $mMk.Contains($mkName)){ $eap=$ErrorActionPreference; $ErrorActionPreference='Continue'; try { claude plugin marketplace add $mMk[$mkName] 2>&1 | Out-Null; claude plugin install $p 2>&1 | Out-Null } finally { $ErrorActionPreference=$eap } }; if($LASTEXITCODE){ Warn "plugin install failed: $p (try manually: claude plugin install $p)" } }
      } }
  }
  if($Write -and $dirty){ $o=[ordered]@{ plugins=@($mPlug | Sort-Object -Unique); marketplaces=$mMk }
    Write-Utf8 $pf (($o | ConvertTo-Json -Depth 10) + "`n"); $script:Changed=$true }
}

# =============== Claude plugin skills -> OpenCode, RTK ===============
function Sync-LocalBridge {
  Say "`n== Claude plugin skills + RTK -> OpenCode ==" Cyan
  $n=0
  foreach($kv in (Get-ClaudePluginSkillDirs).GetEnumerator()){
    $dst=Join-Path $OcSkills $kv.Key
    if((Test-Path $dst) -or (Test-Path (Join-Path $ClaudeSk $kv.Key))){ continue }
    Act "opencode skill $($kv.Key) (from Claude plugin)"; $n++
    if($Write){ Copy-SkillDir $kv.Value $dst }
  }
  Say "  copied: $n"
  if(Get-Command rtk -ErrorAction SilentlyContinue){
    if(Test-Path (Join-Path $OcDir 'plugins\rtk.ts')){ Say "  rtk: OpenCode plugin installed ($(rtk --version))" }
    else { Act "rtk init -g --opencode --auto-patch"; if($Write){ $eap=$ErrorActionPreference; $ErrorActionPreference='Continue'; try { rtk init -g --opencode --auto-patch 2>&1 | Out-Null } finally { $ErrorActionPreference=$eap } } }
  } else { Warn "rtk not on PATH (https://github.com/rtk-ai/rtk/releases) - RTK not enabled in OpenCode" }
}

# =============== run ===============
if(-not (Test-Path $OcDir)){ Warn "OpenCode config dir not found ($OcDir) - OpenCode parts skipped"; New-Item -ItemType Directory -Force $OcDir -ErrorAction SilentlyContinue | Out-Null }
if(-not (Test-Path $ClaudeDir)){ throw "Claude dir not found: $ClaudeDir" }
if($Action -eq 'Status' -or $DryRun){ Say "NO CHANGES WILL BE MADE ($Action$(if($DryRun){' -DryRun'}))" Yellow }
Say "Machine: $env:COMPUTERNAME   Action: $Action   Prefer: $Prefer" DarkGray
Ensure-Repo
Sync-Skills
Sync-Mcp
Sync-Plugins
if($DoPull){ Sync-LocalBridge }

if($Write -and $DoPush -and $Changed){
  Say "`n== Commit + push master ==" Cyan
  RGit add -A .agent-master
  & git -C $Repo diff --cached --quiet; $dirtyIdx = ($LASTEXITCODE -ne 0)
  if($dirtyIdx){
    RGit commit -q -m "sync(agent-master): update from $env:COMPUTERNAME"
    & git -C $Repo push -q
    if($LASTEXITCODE){ RGit pull -q --rebase --autostash; RGit push -q }
    Say "  pushed master from $env:COMPUTERNAME" Green
  }
}
if($Conflicts.Count){ Say "`nCONFLICTS (nothing overwritten):" Red; $Conflicts | % { Say "  - $_" Red } }
if($Warnings.Count){ Say "`nWarnings: $($Warnings.Count) (see ! lines above)" Yellow }
Say "`nDone. Restart Claude Code / OpenCode to pick up changes." Cyan
