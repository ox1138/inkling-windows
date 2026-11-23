# ink: local Inkling 2 Mini in one command (Windows, llama.cpp + CUDA).
#
#   ink                 coding agent (Pi) in this folder; asks before risky commands
#   ink chat            chat with web search; cannot touch files or run commands
#   ink ask "question"  one-shot answer with web search
#   ink oc              opencode instead of Pi
#   ink serve           load the model and keep it loaded (until ink stop)
#   ink status | stop | log | bench
#
# The model loads on first use and unloads when the last ink session ends
# (quit, or terminal window closed). INKLING_KEEP=1 keeps it loaded.
# INKLING_THINK=off|minimal|low|medium|high sets thinking effort. INKLING_CONFIRM=0 turns off the prompts.
# Ctrl+T shows or hides the model's thinking. Extra args go to Pi (e.g. `ink -c` to continue).
$ErrorActionPreference = 'Stop'

$Root     = Split-Path -Parent $PSScriptRoot
$Cfg      = Join-Path $Root 'config'
$Exe      = Join-Path $Root 'llama.cpp\llama-server.exe'
$Node     = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
$PiCli    = Join-Path $Root 'tools\pi\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js'
$OcBin    = Join-Path $Root 'tools\opencode\node_modules\.bin\opencode.cmd'

function Env($name, $default) { $v = [Environment]::GetEnvironmentVariable($name); if ($v) { $v } else { $default } }

# Per-machine settings, written by install.ps1 from this PC's VRAM/RAM. Environment variables override them.
$Conf = @{ quant = 'Q4_K_XL'; ctx = 65536; draft = $true; gpu = 'full' }
$ConfFile = Join-Path $Root 'ink.config.json'
if (Test-Path $ConfFile) {
  (Get-Content $ConfFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $Conf[$_.Name] = $_.Value }
}
$Quant    = Env 'INKLING_QUANT' $Conf.quant
$Model    = Env 'INKLING_GGUF'  (Join-Path $Root "models\Inkling-2-Mini-UD-$Quant.gguf")
$Draft    = Join-Path $Root 'models\dspark-Inkling-2-Mini-Q8_0.gguf'
$Mmproj   = Join-Path $Root 'models\mmproj-Inkling-2-Mini-F16.gguf'
$Vision   = (Env 'INKLING_VISION' '0') -eq '1'     # opt-in: image input (~1 GB more VRAM)
if ($Vision -and -not (Test-Path $Mmproj)) { Write-Warning "INKLING_VISION=1 but $Mmproj is missing; running text-only."; $Vision = $false }
# Vision + drafter peaked at 23.6 of 24 GB with a full screenshot (desktop using 3.8 GB). If VRAM gets tight: INKLING_DRAFT=0.
$UseDraft = (Env 'INKLING_DRAFT' $(if ($Conf.draft) { '1' } else { '0' })) -ne '0'
$GpuMode  = Env 'INKLING_GPU'   $Conf.gpu       # full: all on GPU | fit: llama.cpp moves experts to RAM as needed | cpu
$Port     = Env 'INKLING_PORT'  '8080'
$BindHost = Env 'INKLING_HOST'  '127.0.0.1'
$Ctx      = Env 'INKLING_CTX'   ([string]$Conf.ctx)
$Think    = Env 'INKLING_THINK' 'medium'
$PiModel  = 'local-llama/inkling-2-mini'

$State    = Join-Path $env:LOCALAPPDATA 'inkling'
$Sessions = Join-Path $State 'sessions'
$Log      = Join-Path $State 'server.log'
$SrvPid   = Join-Path $State 'server.pid'
$WdPid    = Join-Path $State 'watchdog.pid'
$KeepFile = Join-Path $State 'keep'
$ArgsFile = Join-Path $State 'server.args'
New-Item -ItemType Directory -Force $State, $Sessions | Out-Null

# ---------------------------------------------------------------- helpers

function Get-Alive($pidFile) {
  if (-not (Test-Path $pidFile)) { return $null }
  $id = [int](Get-Content $pidFile -Raw)
  Get-Process -Id $id -ErrorAction SilentlyContinue
}

function Test-Health {
  try {
    $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$Port/health"
    return $r.StatusCode -eq 200
  } catch { return $false }
}

function Test-Running { [bool](Get-Alive $SrvPid) -or (Test-Health) }

# Live sessions are files named by PID holding that process's start time (guards against PID reuse).
function Get-LiveSessions {
  $n = 0
  foreach ($f in Get-ChildItem $Sessions -File -ErrorAction SilentlyContinue) {
    $p = Get-Process -Id ([int]$f.Name) -ErrorAction SilentlyContinue
    $ok = $false
    if ($p) { try { $ok = ($p.StartTime.Ticks -eq [long](Get-Content $f.FullName -Raw)) } catch { $ok = $false } }
    if ($ok) { $n++ } else { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
  }
  $n
}

function With-Lock([scriptblock]$body) {
  $m = New-Object System.Threading.Mutex($false, 'Local\inkling-ink')
  try { [void]$m.WaitOne() } catch [System.Threading.AbandonedMutexException] { }
  try { & $body } finally { $m.ReleaseMutex(); $m.Dispose() }
}

# Windows PowerShell 5.1 does not escape embedded quotes when calling native programs.
function Quote-Args([string[]]$a) { foreach ($x in $a) { $x -replace '(\\*)"', '$1$1\"' } }

function Server-Args {
  $a = @('-m', $Model, '--jinja', '-fa', 'on', '-lm', 'none',
         '-c', $Ctx, '-ctk', 'q8_0', '-ctv', 'q8_0', '-np', '1',
         '--temp', '1.0', '--top-p', '1.0', '--top-k', '0', '--min-p', '0.0',
         '--alias', 'inkling-2-mini', '--host', $BindHost, '--port', $Port)
  switch ($GpuMode) {
    'fit'   { $a += @('--fit', 'on') }                       # fills the free VRAM, rest of the experts in RAM
    'cpu'   { $a += @('-ngl', '0', '--fit', 'off') }
    default { $a += @('-ngl', '99', '--fit', 'off') }
  }
  if ($UseDraft -and $GpuMode -eq 'full' -and (Test-Path $Draft)) {
    $a += @('-md', $Draft, '--spec-type', 'draft-dspark', '--spec-draft-n-max', '2', '-ngld', '99')
  }
  if ($Vision) { $a += @('--mmproj', $Mmproj) }
  $keyFile = Join-Path $State 'api-key.txt'
  if ($BindHost -ne '127.0.0.1' -and (Test-Path $keyFile)) { $a += @('--api-key-file', $keyFile) }
  $a
}

# ---------------------------------------------------------------- server lifecycle

function Test-ServerVision { (Test-Path $ArgsFile) -and ((Get-Content $ArgsFile -Raw) -match '--mmproj') }

function Start-Server {
  if ((Test-Running) -and $Vision -and -not (Test-ServerVision)) {
    if ((Get-LiveSessions) -le 1 -and -not (Test-Path $KeepFile)) {
      Write-Host 'Reloading with vision...'; Stop-Server -Quiet; Start-Sleep -Seconds 2
      if ((Env 'INKLING_KEEP' '0') -eq '1') { New-Item -ItemType File -Force $KeepFile | Out-Null }
    } else {
      Write-Warning 'The model is already loaded without vision and another session (or ink serve) is using it. Images are off for this session; close the others or run ink stop first.'
    }
  }
  if (Test-Running) { return }
  if (-not (Test-Path $Exe))   { throw "llama-server not found at $Exe. Run install.ps1." }
  if (-not (Test-Path $Model)) { throw "Model not found at $Model. See README.md." }
  Write-Host -NoNewline 'Starting Inkling 2 Mini... '
  # The watchdog runs detached (via WMI) so closing this terminal doesn't kill the server.
  (Server-Args | ForEach-Object { '"' + $_ + '"' }) -join ' ' | Set-Content $ArgsFile -Encoding ASCII
  Set-Content $Log '' -Encoding ASCII
  $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
  $cmd = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" __watchdog"
  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
         CommandLine = $cmd; CurrentDirectory = $Root; ProcessStartupInformation = $si }
  if ($r.ReturnValue -ne 0) { throw "Could not start the watchdog (WMI error $($r.ReturnValue))." }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt 300) {
    if (Test-Health) { Write-Host ("ready ({0:N0}s)." -f $sw.Elapsed.TotalSeconds); return }
    Start-Sleep -Milliseconds 500
    if ($sw.Elapsed.TotalSeconds -gt 5 -and -not (Get-Alive $SrvPid) -and -not (Get-Alive $WdPid)) {
      Write-Host "failed. Last lines of ${Log}:"
      Get-Content $Log -Tail 15 -ErrorAction SilentlyContinue
      Write-Host '(Out of VRAM? Close GPU-heavy apps, or try: $env:INKLING_GPU="fit"  or  $env:INKLING_CTX=32768)'
      exit 1
    }
  }
  Write-Host "timed out; see $Log"; exit 1
}

function Stop-Server([switch]$Quiet) {
  $stopped = $false
  foreach ($f in @($WdPid, $SrvPid)) {
    $p = Get-Alive $f
    if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $stopped = $true }
    Remove-Item $f -Force -ErrorAction SilentlyContinue
  }
  Remove-Item $KeepFile -Force -ErrorAction SilentlyContinue
  if (-not $stopped) {
    # A server started some other way on our port.
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { Stop-Process -Id $c.OwningProcess -Force; $stopped = $true }
  }
  if (-not $Quiet) { if ($stopped) { 'Stopped. VRAM freed.' } else { 'Not running.' } }
}

# Runs hidden and detached: owns llama-server, unloads it when no ink sessions are left.
function Watchdog {
  Set-Content $WdPid $PID -Encoding ASCII
  $p = Start-Process -FilePath $Exe -ArgumentList (Get-Content $ArgsFile -Raw).Trim() -NoNewWindow -PassThru `
         -RedirectStandardError $Log -RedirectStandardOutput (Join-Path $State 'server.out.log')
  Set-Content $SrvPid $p.Id -Encoding ASCII
  $idle = 0
  while (-not $p.HasExited) {
    Start-Sleep -Seconds 2
    if ((Test-Path $KeepFile) -or (Get-LiveSessions) -gt 0) { $idle = 0 } else { $idle++ }
    if ($idle -ge 2) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; break }
  }
  Remove-Item $SrvPid, $WdPid -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- sessions

function Invoke-Session([scriptblock]$body) {
  $me = Join-Path $Sessions $PID
  With-Lock {
    Set-Content $me (Get-Process -Id $PID).StartTime.Ticks -Encoding ASCII
    if ((Env 'INKLING_KEEP' '0') -eq '1') { New-Item -ItemType File -Force $KeepFile | Out-Null }
    Start-Server
  }
  if ($SyncPi) { Sync-PiConfig }   # after the server is up, so Pi knows whether images work
  try { & $body }
  finally {
    Remove-Item $me -Force -ErrorAction SilentlyContinue
    With-Lock {
      if (-not (Test-Path $KeepFile) -and (Get-LiveSessions) -eq 0 -and (Get-Alive $SrvPid)) {
        Stop-Server -Quiet; 'Inkling unloaded (no sessions left).'
      }
    }
  }
}

function Sync-PiConfig {
  $env:PI_CODING_AGENT_DIR = Env 'INKLING_PI_DIR' (Join-Path $State 'pi')
  New-Item -ItemType Directory -Force $env:PI_CODING_AGENT_DIR | Out-Null
  # Pi's context window must match the server's, or long sessions overflow it.
  $m = Get-Content (Join-Path $Cfg 'pi\models.json') -Raw | ConvertFrom-Json
  # Images only when the running server has the vision projector loaded.
  $img = (Test-Running) -and (Test-ServerVision)
  foreach ($x in $m.providers.'local-llama'.models) {
    $x.contextWindow = [int]$Ctx; $x.name = "Inkling 2 Mini (UD-$Quant, llama.cpp, local)"
    $x.input = [string[]]$(if ($img) { 'text', 'image' } else { 'text' })   # cast: a 1-item list would become a plain string
  }
  [IO.File]::WriteAllText((Join-Path $env:PI_CODING_AGENT_DIR 'models.json'), ($m | ConvertTo-Json -Depth 20))  # no BOM
  $s = Join-Path $env:PI_CODING_AGENT_DIR 'settings.json'
  if (-not (Test-Path $s)) { Copy-Item (Join-Path $Cfg 'pi\settings.json') $s }
}

# Prompts go to Pi as files: avoids Windows quoting problems with multi-line arguments.
function Prompt-File($name) {
  $out = Join-Path $State "$name"
  $today = 'Today is ' + (Get-Date).ToString('dddd, MMMM d, yyyy', [Globalization.CultureInfo]::InvariantCulture) + '.'
  (Get-Content (Join-Path $Cfg $name) -Raw) + "`n$today`n" | Set-Content $out -Encoding UTF8
  $out
}

function Run-Pi([string[]]$piArgs, [switch]$NoStdin) {
  if (-not $Node) { throw 'Node.js not found on PATH.' }
  if ($NoStdin) { $null | & $Node $PiCli @(Quote-Args $piArgs) }   # -p mode would otherwise wait on piped stdin
  else { & $Node $PiCli @(Quote-Args $piArgs) }
}

function Chat([string[]]$extra, [switch]$NoStdin) {
  $env:INKLING_MODE = 'chat'
  $t = Env 'INKLING_THINK' 'low'
  Run-Pi (@('--model', "${PiModel}:$t", '-ne', '-e', (Join-Path $Cfg 'ext\web.ts'),
            '--no-builtin-tools', '--no-context-files', '--no-skills', '--no-mcp',
            '--system-prompt', (Prompt-File 'chat-prompt.md')) + $extra) -NoStdin:$NoStdin
}

function Code([string[]]$extra) {
  $ext = @('-e', (Join-Path $Cfg 'ext\web.ts'))
  if ((Env 'INKLING_CONFIRM' '1') -eq '1') { $ext += @('-e', (Join-Path $Cfg 'ext\confirm.ts')) }
  Run-Pi (@('--model', "${PiModel}:$Think") + $ext + @('--append-system-prompt', (Prompt-File 'code-prompt.md')) + $extra)
}

# ---------------------------------------------------------------- commands

$All  = [string[]]$args
$cmd  = if ($args.Count) { [string]$args[0] } else { '' }
$rest = if ($args.Count -gt 1) { [string[]]$args[1..($args.Count - 1)] } else { [string[]]@() }

switch ($cmd) {
  '__watchdog' { Watchdog }
  'stop'   { Stop-Server }
  'status' {
    $what = "UD-$Quant, GPU mode $GpuMode, ${Ctx} context" + $(if ($UseDraft -and $GpuMode -eq 'full') { ', DSpark' } else { '' }) + $(if ($Vision) { ', vision' } else { '' })
    if ((Test-Running) -and (Test-Path $ArgsFile)) {   # describe what is actually loaded, not this shell's settings
      $sa = Get-Content $ArgsFile -Raw
      $what = "UD-$Quant, ${Ctx} context" + $(if ($sa -match 'dspark') { ', DSpark' } else { '' }) + $(if ($sa -match '--mmproj') { ', vision' } else { '' })
    }
    if (Test-Running) { "Running on http://${BindHost}:$Port/v1 ($what), $(Get-LiveSessions) session(s)" + $(if (Test-Path $KeepFile) { ', kept loaded' } else { '' }) }
    else { "Not running. Configured: $what." }
  }
  'log'    { Get-Content $Log -Wait -Tail 30 }
  'serve'  { New-Item -ItemType File -Force $KeepFile | Out-Null; With-Lock { Start-Server }; "Serving on http://${BindHost}:$Port/v1 until 'ink stop'." }
  'chat'   { $SyncPi = $true; Invoke-Session { Chat $rest } }
  'ask'    {   # @file arguments (text or images) stay separate; the other words form the question
    $SyncPi = $true; $files = @($rest | Where-Object { $_ -like '@*' }); $q = ($rest | Where-Object { $_ -notlike '@*' }) -join ' '
    Invoke-Session { Chat (@('--no-session', '-p') + $files + @($q)) -NoStdin }
  }
  'oc'     {
    $env:XDG_DATA_HOME = Join-Path $State 'xdg-data'
    $env:OPENCODE_CONFIG = Join-Path $Cfg 'opencode.json'
    Invoke-Session { & $OcBin @(Quote-Args $rest) }
  }
  'bench'  { & python -I (Join-Path $Root 'scripts\bench.py') @rest }
  { $_ -in @('-h', '--help', 'help') } {
    Get-Content $PSCommandPath | Select-Object -Skip 1 -First 12 | ForEach-Object { $_ -replace '^# ?', '' }
  }
  default  { $SyncPi = $true; Invoke-Session { Code $All } }
}
