# Install ink on Windows: llama.cpp (Unsloth build), an Inkling 2 Mini GGUF sized for this PC, Pi, extensions.
# Everything goes under this folder except two small `ink` shims in %USERPROFILE%\.local\bin.
# Safe to re-run: finished steps are skipped.
#
#   powershell -ExecutionPolicy Bypass -File install.ps1                 # detect GPU/RAM and pick settings
#   ... install.ps1 -Quant Q3_K_XL -Gpu fit -Ctx 32768 -WithOpencode     # or choose yourself
#
#   -Quant    Q4_K_XL | Q4_K_M | IQ4_XS | Q3_K_XL | IQ3_XXS | Q2_K_XL | IQ2_XXS ...  (see README)
#   -Gpu      full (all on GPU) | fit (experts that don't fit go to RAM) | cpu
#   -Backend  cuda13 | cuda12 | vulkan | cpu   (default: from the NVIDIA driver)
param([string]$Quant, [ValidateSet('full', 'fit', 'cpu')][string]$Gpu, [int]$Ctx,
      [ValidateSet('cuda13', 'cuda12', 'vulkan', 'cpu')][string]$Backend, [switch]$NoDraft, [switch]$WithOpencode)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = $PSScriptRoot

$LlamaTag = 'b12631-mix-acc0843'
$Release  = "https://github.com/unslothai/llama.cpp/releases/download/$LlamaTag"
# Unsloth's "portable" CUDA zips leave out the CUDA runtime DLLs; upstream llama.cpp ships NVIDIA's redistributables.
$Cudart   = @{
  cuda13 = @('https://github.com/ggml-org/llama.cpp/releases/download/b12651/cudart-llama-bin-win-cuda-13.5-x64.zip',
             @('cublas64_13.dll', 'cublasLt64_13.dll'))
  cuda12 = @('https://github.com/ggml-org/llama.cpp/releases/download/b12651/cudart-llama-bin-win-cuda-12.4-x64.zip',
             @('cudart64_12.dll', 'cublas64_12.dll', 'cublasLt64_12.dll'))
}
$HF     = 'https://huggingface.co/unsloth/Inkling-2-Mini-GGUF/resolve/main'
$Quants = @{   # size in bytes, sha256 (from the Hugging Face repo)
  'Q8_K_XL' = @(22867451616, 'dfb04bf37bee457f98800989dedf93ec442ede8636dbea9433992f1e527e9a41')
  'Q4_K_XL' = @(17629759456, 'e62d463c135ffe283df8d94b279a96ca145ac128b52ce854478613045bf4de15')
  'Q4_K_M'  = @(16610543328, 'f90c5a4df44d335ac9f9eea2a15c31d6c5a377b1b3cd9ff7fc2cf123f3cdf7e1')
  'IQ4_XS'  = @(15733755232, 'a861d21e7c6d7bc69d8cdcdfb9eb195fd37ef1cd2ab31499db61cd7d30d9b3a1')
  'Q3_K_XL' = @(13631778016, 'f72f396d1b479b14d76346df80baa449c8b1f399653bff38fa4764b359a40048')
  'IQ3_XXS' = @(11663309504, 'bd7ef0865adf119b5183e45e741c629bafa649769b33b5ebf689bb4bcc4690d6')
  'Q2_K_XL' = @(9138715328,  '20292e8142b69535ca88a5d04439d0fdeb4dc698d44c002dca706dcf92901441')
  'IQ2_XXS' = @(8486236352,  '4fe958f73a667d8082f911a4347e52bc34696a7816cf3d5b9f7c8a81d5c5ceaa')
}
$Draft  = @('dspark-Inkling-2-Mini-Q8_0.gguf', 402278560, '2ec78510da837e8fc3be54a14757a0c5fbd2d8d9e85a0d92853fafdf674f3773')
$PiPkg  = '@earendil-works/pi-coding-agent@1.6.0'
$OcPkg  = 'opencode-ai@1.19.6'

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
foreach ($c in 'node', 'npm', 'curl.exe') {
  if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "Missing $c. Install Node.js 22.19 or newer first (https://nodejs.org)." }
}
$nodeMajor = [int]((node --version) -replace '^v(\d+).*', '$1')
if ($nodeMajor -lt 22) { throw "Pi needs Node.js 22.19 or newer; this PC has $(node --version)." }
if (-not (Test-Path "$env:ProgramFiles\Git\bin\bash.exe")) { Write-Warning 'Git for Windows not found. Pi runs commands through Git Bash: install it from https://git-scm.com.' }

# ------------------------------------------------------------------ detect hardware
Say 'This PC'
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$vramGB = 0; $cudaMajor = 0; $gpuName = 'none'
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
  $q = (nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits | Select-Object -First 1) -split ',\s*'
  $gpuName = $q[0]; $vramGB = [math]::Round([int]$q[1] / 1024)
  $m = [regex]::Match((nvidia-smi | Out-String), 'CUDA (?:UMD )?Version:\s*(\d+)\.')
  if ($m.Success) { $cudaMajor = [int]$m.Groups[1].Value }
}
Write-Host "GPU: $gpuName ($vramGB GB), CUDA driver level $cudaMajor, RAM: $ramGB GB"

if (-not $Backend) {
  if ($cudaMajor -ge 13) { $Backend = 'cuda13' }
  elseif ($cudaMajor -eq 12) { $Backend = 'cuda12' }
  elseif ($gpuName -ne 'none') { throw 'Your NVIDIA driver is too old for CUDA 12. Update it from nvidia.com, then re-run.' }
  else { $Backend = 'vulkan'; Write-Warning 'No NVIDIA GPU found: using the Vulkan build (AMD/Intel GPUs). This path is untested; -Backend cpu runs without a GPU.' }
}

# Pick settings from VRAM and RAM (measured numbers in README.md). The model needs to fit in VRAM + RAM
# with room for Windows: weights that don't fit on the GPU live in RAM.
function Pick {
  if ($Backend -eq 'cpu') { return @('Q4_K_XL', 'cpu') }
  if ($Backend -eq 'vulkan') { return @('Q4_K_XL', 'fit') }
  if ($vramGB -ge 22) { return @('Q4_K_XL', 'full') }
  $budget = $vramGB + $ramGB - 8          # leave ~8 GB of RAM for Windows and your apps
  if ($budget -ge 20) { return @('Q4_K_XL', 'fit') }
  if ($budget -ge 15) { return @('Q3_K_XL', 'fit') }
  if ($budget -ge 11) { return @('Q2_K_XL', 'fit') }
  throw "This PC has $vramGB GB VRAM + $ramGB GB RAM; Inkling 2 Mini needs about 12 GB combined plus room for Windows."
}
$pick = Pick
if (-not $Quant) { $Quant = $pick[0] }
if (-not $Gpu)   { $Gpu = $pick[1] }
if (-not $Ctx)   { $Ctx = if ($Gpu -eq 'full' -and $vramGB -ge 22) { 65536 } else { 32768 } }
if (-not $Quants.ContainsKey($Quant)) { throw "Unknown quant $Quant. Choose one of: $($Quants.Keys -join ', ')" }
$useDraft = (-not $NoDraft) -and $Gpu -eq 'full'
Write-Host "Settings: UD-$Quant, GPU mode $Gpu, $Ctx context, DSpark drafter $(if ($useDraft) { 'on' } else { 'off' })"

# ------------------------------------------------------------------ llama.cpp
$dl = Join-Path $Root 'dl'; $llama = Join-Path $Root 'llama.cpp'
New-Item -ItemType Directory -Force $dl, "$Root\models", $llama | Out-Null
$stamp = Join-Path $llama 'ink-backend.txt'
$have = if (Test-Path $stamp) { (Get-Content $stamp -Raw).Trim() } else { '' }
Say "llama.cpp $LlamaTag ($Backend)"
if ($have -ne "$LlamaTag $Backend") {
  $flavor = switch ($Backend) { 'cuda13' { 'cuda13-portable' } 'cuda12' { 'cuda12-portable' } 'vulkan' { 'vulkan' } 'cpu' { 'cpu' } }
  curl.exe -fL -o "$dl\llama.zip" "$Release/app-$LlamaTag-windows-x64-$flavor.zip"
  if ($LASTEXITCODE -ne 0) { throw 'llama.cpp download failed.' }
  Remove-Item "$llama\*" -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive "$dl\llama.zip" $llama -Force
  if ($Cudart.ContainsKey($Backend)) {
    curl.exe -fL -o "$dl\cudart.zip" $Cudart[$Backend][0]
    if ($LASTEXITCODE -ne 0) { throw 'CUDA runtime download failed.' }
    Expand-Archive "$dl\cudart.zip" "$dl\cudart" -Force
    foreach ($f in $Cudart[$Backend][1]) { Copy-Item "$dl\cudart\$f" $llama }
  }
  "$LlamaTag $Backend" | Set-Content $stamp -Encoding ASCII
  Remove-Item $dl -Recurse -Force
}
$dev = & "$llama\llama-server.exe" --list-devices 2>&1 | Out-String
if ($Backend -ne 'cpu' -and $dev -notmatch '(CUDA|Vulkan)0') { throw "llama-server does not see a GPU:`n$dev" }

# ------------------------------------------------------------------ model
function Get-Model($file, $size, $sha) {
  $p = "$Root\models\$file"
  if ((Test-Path $p) -and (Get-Item $p).Length -eq $size) { return }
  Write-Host ("Downloading $file ({0:N1} GB)" -f ($size / 1e9))
  curl.exe -fL -C - -o $p "$HF/$file"   # resumes a partial download
  if ($LASTEXITCODE -ne 0) { throw "Download of $file failed; re-run to resume." }
  if ((Get-FileHash $p -Algorithm SHA256).Hash -ne $sha) { throw "Checksum mismatch for $file; delete it and re-run." }
}
Say 'Model'
Get-Model "Inkling-2-Mini-UD-$Quant.gguf" $Quants[$Quant][0] $Quants[$Quant][1]
if ($useDraft) { Get-Model $Draft[0] $Draft[1] $Draft[2] }

@{ quant = $Quant; gpu = $Gpu; ctx = $Ctx; draft = $useDraft } | ConvertTo-Json | Set-Content "$Root\ink.config.json" -Encoding ASCII

# ------------------------------------------------------------------ agents
Say 'Pi coding agent (local to this folder)'
Push-Location; New-Item -ItemType Directory -Force "$Root\tools\pi" | Out-Null; Set-Location "$Root\tools\pi"
if (-not (Test-Path package.json)) { npm init -y | Out-Null }
npm install --no-audit --no-fund $PiPkg; Pop-Location

if ($WithOpencode) {
  Say 'opencode (optional, local)'
  Push-Location; New-Item -ItemType Directory -Force "$Root\tools\opencode" | Out-Null; Set-Location "$Root\tools\opencode"
  if (-not (Test-Path package.json)) { npm init -y | Out-Null }
  npm install --no-audit --no-fund $OcPkg; Pop-Location
}

Say 'Extensions'
Push-Location "$Root\config\ext"; npm ci --no-audit --no-fund; Pop-Location

Say 'ink command'
$bin = Join-Path $env:USERPROFILE '.local\bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$ps1 = Join-Path $Root 'bin\ink.ps1'
"@powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" %*`r`n" | Set-Content "$bin\ink.cmd" -Encoding ASCII -NoNewline
"#!/usr/bin/env bash`nexec powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File '$ps1' `"`$@`"`n" | Set-Content "$bin\ink" -Encoding ASCII -NoNewline
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($userPath -split ';') -contains $bin)) {
  [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ";$bin"), 'User')
  Write-Host "Added $bin to your user PATH. Open a new terminal for it to take effect."
}

Write-Host "`nDone. In any folder: ink      (ink status shows the settings; re-run install.ps1 with -Quant/-Gpu to change them)"
