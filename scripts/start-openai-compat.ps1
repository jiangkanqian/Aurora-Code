param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$CliArgs
)

$ErrorActionPreference = "Stop"
# In PowerShell 7+, prevent stderr from native commands being promoted to
# terminating errors when ErrorActionPreference=Stop.
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

# Force UTF-8 for native process pipe decoding/encoding to avoid mojibake on
# Chinese output when capturing Node stdout/stderr in PowerShell.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$EnvFile = Join-Path $RepoRoot ".env"
$CliDistJs = Join-Path $RepoRoot "dist\cli.js"
$CliDistCjs = Join-Path $RepoRoot "dist\cli.cjs"
$CliDist = if (Test-Path $CliDistJs) { $CliDistJs } else { $CliDistCjs }

if (-not (Test-Path $EnvFile)) {
  Write-Host "Missing .env file at $EnvFile" -ForegroundColor Yellow
  Write-Host "Create it from .env.example first." -ForegroundColor Yellow
  exit 1
}

Get-Content $EnvFile | ForEach-Object {
  $line = $_.Trim()
  if (-not $line -or $line.StartsWith("#")) { return }
  $idx = $line.IndexOf("=")
  if ($idx -lt 1) { return }
  $name = $line.Substring(0, $idx).Trim()
  $value = $line.Substring($idx + 1).Trim()
  if (
    ($value.StartsWith('"') -and $value.EndsWith('"')) -or
    ($value.StartsWith("'") -and $value.EndsWith("'"))
  ) {
    $value = $value.Substring(1, $value.Length - 2)
  }
  [Environment]::SetEnvironmentVariable($name, $value, "Process")
}

# Force OpenAI-compatible runtime mode for this launcher.
[Environment]::SetEnvironmentVariable("CLAUDE_CODE_USE_OPENAI_COMPAT", "1", "Process")
if (-not [Environment]::GetEnvironmentVariable("CLAUDE_CODE_FORCE_NON_STREAMING", "Process")) {
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_FORCE_NON_STREAMING", "1", "Process")
}
if (-not [Environment]::GetEnvironmentVariable("CLAUDE_CODE_MAX_RETRIES", "Process")) {
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_MAX_RETRIES", "1", "Process")
}
if (-not [Environment]::GetEnvironmentVariable("OPENAI_COMPAT_REQUEST_TIMEOUT_MS", "Process")) {
  [Environment]::SetEnvironmentVariable("OPENAI_COMPAT_REQUEST_TIMEOUT_MS", "45000", "Process")
}
if (-not [Environment]::GetEnvironmentVariable("API_TIMEOUT_MS", "Process")) {
  [Environment]::SetEnvironmentVariable("API_TIMEOUT_MS", "45000", "Process")
}
if (-not [Environment]::GetEnvironmentVariable("CLAUDE_CODE_ENABLE_TELEMETRY", "Process")) {
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_ENABLE_TELEMETRY", "0", "Process")
}
if (-not [Environment]::GetEnvironmentVariable("USE_BUILTIN_RIPGREP", "Process")) {
  [Environment]::SetEnvironmentVariable("USE_BUILTIN_RIPGREP", "0", "Process")
}
$openaiBase = [Environment]::GetEnvironmentVariable("OPENAI_BASE_URL", "Process")
if ($openaiBase) {
  [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $openaiBase, "Process")
}
$openaiKey = [Environment]::GetEnvironmentVariable("OPENAI_API_KEY", "Process")
$anthropicKey = [Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "Process")
if (-not $openaiKey -and $anthropicKey) {
  [Environment]::SetEnvironmentVariable("OPENAI_API_KEY", $anthropicKey, "Process")
}
if (-not $anthropicKey -and $openaiKey) {
  [Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", $openaiKey, "Process")
}

# Interactive mode is streaming-first. Some OpenAI-compatible gateways keep
# streams open without Anthropic-formatted events, which appears as "Enter后无响应".
# Enable stream watchdog so runtime can auto-fallback to non-streaming.
if (-not [Environment]::GetEnvironmentVariable("CLAUDE_ENABLE_STREAM_WATCHDOG", "Process")) {
  [Environment]::SetEnvironmentVariable("CLAUDE_ENABLE_STREAM_WATCHDOG", "1", "Process")
}
if (-not [Environment]::GetEnvironmentVariable("CLAUDE_STREAM_IDLE_TIMEOUT_MS", "Process")) {
  [Environment]::SetEnvironmentVariable("CLAUDE_STREAM_IDLE_TIMEOUT_MS", "20000", "Process")
}

if (-not (Test-Path $CliDist)) {
  Write-Host "Missing dist\\cli.js (or dist\\cli.cjs). Build first: npm.cmd run build" -ForegroundColor Yellow
  exit 1
}

# Optional proxy clearing. Disabled by default so enterprise/proxied networks keep working.
$clearProxyRaw = [Environment]::GetEnvironmentVariable("OPENAI_COMPAT_CLEAR_PROXY", "Process")
$clearProxy = $clearProxyRaw -and @("1", "true", "yes", "on") -contains $clearProxyRaw.ToLowerInvariant()
if ($clearProxy) {
  [Environment]::SetEnvironmentVariable("HTTP_PROXY", "", "Process")
  [Environment]::SetEnvironmentVariable("HTTPS_PROXY", "", "Process")
  [Environment]::SetEnvironmentVariable("ALL_PROXY", "", "Process")
  Write-Host "Proxy vars cleared for this run (OPENAI_COMPAT_CLEAR_PROXY enabled)." -ForegroundColor Yellow
}
[Environment]::SetEnvironmentVariable("npm_config_offline", "false", "Process")

Write-Host "Starting Claude Code with OpenAI-compatible backend..." -ForegroundColor Cyan

function Get-OpenAIBaseUrl() {
  $v = [Environment]::GetEnvironmentVariable("OPENAI_BASE_URL", "Process")
  if (-not $v) { $v = [Environment]::GetEnvironmentVariable("OPENAI_COMPAT_BASE_URL", "Process") }
  if (-not $v) { $v = [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "Process") }
  if (-not $v) { $v = "https://api.openai.com/v1" }
  return $v.TrimEnd("/")
}

function Test-TcpPort([string]$TargetHost, [int]$TargetPort, [int]$TimeoutMs = 3000) {
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $async = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
      $client.Close()
      return $false
    }
    $client.EndConnect($async) | Out-Null
    $client.Close()
    return $true
  } catch {
    return $false
  }
}

function Show-FetchFailedDiagnostics() {
  Write-Host ""
  Write-Host "=== Connectivity Diagnostics ===" -ForegroundColor Yellow
  $base = Get-OpenAIBaseUrl
  Write-Host "OPENAI_BASE_URL effective: $base" -ForegroundColor Yellow

  try {
    $uri = [Uri]$base
  } catch {
    Write-Host "Base URL parse failed. Please check OPENAI_BASE_URL format." -ForegroundColor Red
    return
  }

  $targetHost = $uri.Host
  $targetPort = if ($uri.Port -gt 0) { $uri.Port } elseif ($uri.Scheme -eq "https") { 443 } else { 80 }

  $httpProxy = [Environment]::GetEnvironmentVariable("HTTP_PROXY", "Process")
  $httpsProxy = [Environment]::GetEnvironmentVariable("HTTPS_PROXY", "Process")
  $allProxy = [Environment]::GetEnvironmentVariable("ALL_PROXY", "Process")
  Write-Host ("HTTP_PROXY set:  " + [bool]$httpProxy)
  Write-Host ("HTTPS_PROXY set: " + [bool]$httpsProxy)
  Write-Host ("ALL_PROXY set:   " + [bool]$allProxy)

  try {
    $ips = [System.Net.Dns]::GetHostAddresses($targetHost) | ForEach-Object { $_.ToString() }
    if ($ips.Count -gt 0) {
      Write-Host ("DNS OK: " + ($ips -join ", ")) -ForegroundColor Green
    } else {
      Write-Host "DNS failed: no address returned." -ForegroundColor Red
    }
  } catch {
    Write-Host ("DNS failed: " + $_.Exception.Message) -ForegroundColor Red
  }

  $tcpOk = Test-TcpPort -Host $targetHost -Port $targetPort -TimeoutMs 4000
  if ($tcpOk) {
    Write-Host "TCP connect OK: $targetHost`:$targetPort" -ForegroundColor Green
  } else {
    Write-Host "TCP connect failed: $targetHost`:$targetPort" -ForegroundColor Red
  }

  try {
    $probeUrl = "$base/models"
    $resp = Invoke-WebRequest -Uri $probeUrl -Method Get -TimeoutSec 12 -ErrorAction Stop
    Write-Host ("HTTP probe OK: " + [int]$resp.StatusCode + " " + $probeUrl) -ForegroundColor Green
  } catch {
    $msg = $_.Exception.Message
    if ($msg) {
      Write-Host ("HTTP probe failed: " + $msg) -ForegroundColor Yellow
    } else {
      Write-Host "HTTP probe failed." -ForegroundColor Yellow
    }
  }
  Write-Host "================================" -ForegroundColor Yellow
  Write-Host ""
}

function Get-WinHttpProxyUrl() {
  try {
    $raw = & netsh winhttp show proxy 2>$null | Out-String
    if (-not $raw) { return $null }
    if ($raw -match "Direct access \(no proxy server\)") { return $null }

    # Prefer explicit https= endpoint when present.
    $mHttps = [regex]::Match($raw, "https=([^\s;]+)")
    if ($mHttps.Success) {
      $v = $mHttps.Groups[1].Value.Trim()
      if ($v -and -not ($v -match "^[a-zA-Z]+://")) { $v = "http://$v" }
      return $v
    }

    # Fallback: first host:port in output.
    $mHostPort = [regex]::Match($raw, "([A-Za-z0-9\.\-]+:\d+)")
    if ($mHostPort.Success) {
      return "http://$($mHostPort.Groups[1].Value)"
    }
  } catch {
    return $null
  }
  return $null
}

function Try-EnableProxyFromWinHttp() {
  $httpProxy = [Environment]::GetEnvironmentVariable("HTTP_PROXY", "Process")
  $httpsProxy = [Environment]::GetEnvironmentVariable("HTTPS_PROXY", "Process")
  $allProxy = [Environment]::GetEnvironmentVariable("ALL_PROXY", "Process")
  if ($httpProxy -or $httpsProxy -or $allProxy) { return $false }

  $proxyUrl = Get-WinHttpProxyUrl
  if (-not $proxyUrl) { return $false }

  [Environment]::SetEnvironmentVariable("HTTP_PROXY", $proxyUrl, "Process")
  [Environment]::SetEnvironmentVariable("HTTPS_PROXY", $proxyUrl, "Process")
  Write-Host "Enabled proxy from WinHTTP for this run: $proxyUrl" -ForegroundColor Yellow
  return $true
}

function Get-UserInternetProxyUrl() {
  try {
    $reg = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop
    if (-not $reg.ProxyEnable) { return $null }
    $proxyServer = [string]$reg.ProxyServer
    if (-not $proxyServer) { return $null }

    $mHttps = [regex]::Match($proxyServer, "https=([^;]+)")
    if ($mHttps.Success) {
      $v = $mHttps.Groups[1].Value.Trim()
      if ($v -and -not ($v -match "^[a-zA-Z]+://")) { $v = "http://$v" }
      return $v
    }

    $mHttp = [regex]::Match($proxyServer, "http=([^;]+)")
    if ($mHttp.Success) {
      $v = $mHttp.Groups[1].Value.Trim()
      if ($v -and -not ($v -match "^[a-zA-Z]+://")) { $v = "http://$v" }
      return $v
    }

    $v2 = $proxyServer.Trim()
    if ($v2 -and -not ($v2 -match "^[a-zA-Z]+://")) { $v2 = "http://$v2" }
    return $v2
  } catch {
    return $null
  }
}

function Try-EnableProxyFromUserInternetSettings() {
  $httpProxy = [Environment]::GetEnvironmentVariable("HTTP_PROXY", "Process")
  $httpsProxy = [Environment]::GetEnvironmentVariable("HTTPS_PROXY", "Process")
  $allProxy = [Environment]::GetEnvironmentVariable("ALL_PROXY", "Process")
  if ($httpProxy -or $httpsProxy -or $allProxy) { return $false }

  $proxyUrl = Get-UserInternetProxyUrl
  if (-not $proxyUrl) { return $false }

  try {
    $pu = [Uri]$proxyUrl
    $ok = Test-TcpPort -TargetHost $pu.Host -TargetPort $pu.Port -TimeoutMs 1200
    if (-not $ok) {
      Write-Host "Detected user proxy but local endpoint is unreachable: $proxyUrl" -ForegroundColor Yellow
      return $false
    }
  } catch {
    Write-Host "Detected user proxy but parse/connect check failed: $proxyUrl" -ForegroundColor Yellow
    return $false
  }

  [Environment]::SetEnvironmentVariable("HTTP_PROXY", $proxyUrl, "Process")
  [Environment]::SetEnvironmentVariable("HTTPS_PROXY", $proxyUrl, "Process")
  Write-Host "Enabled proxy from Windows Internet Settings for this run: $proxyUrl" -ForegroundColor Yellow
  return $true
}

function Get-LatestAssistantTranscriptText() {
  try {
    $projectSlug = $RepoRoot -replace '[:\\]', '-'
    $projectDir = Join-Path $env:USERPROFILE (".aurora\\projects\\" + $projectSlug)
    if (-not (Test-Path $projectDir)) { return $null }
    $latest = Get-ChildItem -Path $projectDir -File -Filter *.jsonl -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if (-not $latest) { return $null }
    $lines = Get-Content -Path $latest.FullName -Tail 80
    [array]::Reverse($lines)
    foreach ($line in $lines) {
      if (-not $line) { continue }
      try {
        $obj = $line | ConvertFrom-Json -ErrorAction Stop
      } catch {
        continue
      }
      if ($obj.type -eq 'assistant' -and $obj.message -and $obj.message.content) {
        foreach ($block in $obj.message.content) {
          if ($block.type -eq 'text' -and $block.text) {
            return [string]$block.text
          }
        }
      }
    }
  } catch {
    return $null
  }
  return $null
}

function Ensure-PrivateStubs() {
  $pkgDir = Join-Path $RepoRoot "node_modules\\@ant\\claude-for-chrome-mcp"
  New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
  @'
{
  "name": "@ant/claude-for-chrome-mcp",
  "version": "0.0.0-local-stub",
  "type": "module",
  "main": "./index.js"
}
'@ | Set-Content -Path (Join-Path $pkgDir "package.json") -Encoding UTF8
  @'
export const BROWSER_TOOLS = []
export function createClaudeForChromeMcpServer() {
  return {
    connect() {},
    close() {}
  }
}
export default {
  BROWSER_TOOLS,
  createClaudeForChromeMcpServer
}
'@ | Set-Content -Path (Join-Path $pkgDir "index.js") -Encoding UTF8
}

function Patch-JsoncParserEsmImports() {
  $esmRoot = Join-Path $RepoRoot "node_modules\\jsonc-parser\\lib\\esm"
  if (-not (Test-Path $esmRoot)) { return $false }

  $changed = $false
  $files = Get-ChildItem -Path $esmRoot -Recurse -File -Filter *.js
  foreach ($file in $files) {
    $raw = Get-Content -Raw $file.FullName
    # Add .js extension to extensionless relative imports:
    #   from './x'  -> from './x.js'
    #   from '../x' -> from '../x.js'
    $patched = [regex]::Replace(
      $raw,
      "(from\s+['""](?:\./|\.\./)[^'"".]+)(['""]\s*;?)",
      '$1.js$2'
    )
    if ($patched -ne $raw) {
      Set-Content -Path $file.FullName -Value $patched -Encoding UTF8
      $changed = $true
    }
  }
  return $changed
}

function Patch-DistCjsNamedImport([string]$PackageName) {
  if (-not $PackageName) { return $false }
  if (-not (Test-Path $CliDist)) { return $false }

  $raw = Get-Content -Raw $CliDist
  $escapedPkg = [regex]::Escape($PackageName)
  # Keep match strictly inside one import statement. Support both quotes.
  $pattern = "import\s*\{\s*([^}]*)\s*\}\s*from\s*['`"]$escapedPkg['`"];"
  $m = [regex]::Match($raw, $pattern)
  if (-not $m.Success) {
    return $false
  }

  $importsRaw = $m.Groups[1].Value
  $items = $importsRaw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
  if ($items.Count -eq 0) {
    return $false
  }

  $destructItems = @()
  foreach ($item in $items) {
    if ($item -match '^\s*([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)\s*$') {
      $destructItems += "$($Matches[1]): $($Matches[2])"
    } elseif ($item -match '^[A-Za-z_$][\w$]*$') {
      $destructItems += $item
    }
  }

  if ($destructItems.Count -eq 0) {
    return $false
  }

  $safeVar = "__cjs_" + (($PackageName -replace '[^A-Za-z0-9_]', '_'))
  $replacement = "import $safeVar from `"$PackageName`";`nconst { $($destructItems -join ', ') } = $safeVar;"
  $patched = $raw.Substring(0, $m.Index) + $replacement + $raw.Substring($m.Index + $m.Length)
  Set-Content -Path $CliDist -Value $patched -Encoding UTF8
  return $true
}

function Normalize-ColorDiffImport() {
  if (-not (Test-Path $CliDist)) { return $false }
  $raw = Get-Content -Raw -Path $CliDist
  if (-not $raw) { return $false }

  $target = @'
import __cjs_color_diff_napi from "color-diff-napi";
const { ColorDiff, ColorFile, getSyntaxTheme: nativeGetSyntaxTheme } = __cjs_color_diff_napi;
'@
  $changed = $false
  $patched = $raw

  # 1) Normalize named import form to default-import + destructuring.
  $namedImportPattern = "import\s*\{\s*ColorDiff[\s\S]*?ColorFile[\s\S]*?nativeGetSyntaxTheme[\s\S]*?\}\s*from\s*['`"]color-diff-napi['`"];"
  $step1 = [regex]::Replace($patched, $namedImportPattern, $target)
  if ($step1 -ne $patched) {
    $patched = $step1
    $changed = $true
  }

  # 2) Collapse repeated const declarations into exactly one line.
  $duplicatePattern = "import\s+__cjs_color_diff_napi\s+from\s+['`"]color-diff-napi['`"];\s*(?:const\s*\{\s*ColorDiff,\s*ColorFile,\s*getSyntaxTheme:\s*nativeGetSyntaxTheme\s*\}\s*=\s*__cjs_color_diff_napi;\s*)+"
  $step2 = [regex]::Replace($patched, $duplicatePattern, ($target + "`n"))
  if ($step2 -ne $patched) {
    $patched = $step2
    $changed = $true
  }

  if ($changed) {
    Set-Content -Path $CliDist -Value $patched -Encoding UTF8
  }
  return $changed
}

function Repair-CorruptedColorDiffImport() {
  if (-not (Test-Path $CliDist)) { return $false }
  $raw = Get-Content -Raw $CliDist
  $pattern = 'import __cjs_color_diff_napi from "color-diff-napi";\s*const \{[\s\S]*?\} = __cjs_color_diff_napi;'
  $replacement = @'
import __cjs_color_diff_napi from "color-diff-napi";
const { ColorDiff, ColorFile, getSyntaxTheme: nativeGetSyntaxTheme } = __cjs_color_diff_napi;
'@
  $patched = [regex]::Replace($raw, $pattern, $replacement)
  if ($patched -ne $raw) {
    Set-Content -Path $CliDist -Value $patched -Encoding UTF8
    return $true
  }
  return $false
}

function Repair-BrokenAnsiToPngShadeBlock() {
  if (-not (Test-Path $CliDist)) { return $false }
  $raw = Get-Content -Raw $CliDist
  $pattern = 'SHADE_ALPHA = \{[\s\S]*?PNG_SIG ='
  $replacement = @'
SHADE_ALPHA = {
      9617: 0.25,
      9618: 0.5,
      9619: 0.75,
      9608: 1
    };
    PNG_SIG =
'@
  $patched = [regex]::Replace($raw, $pattern, $replacement)
  if ($patched -ne $raw) {
    Set-Content -Path $CliDist -Value $patched -Encoding UTF8
    return $true
  }
  return $false
}

function Rebuild-Dist() {
  Write-Host "Rebuilding dist/cli.js to recover from previous patch side effects..." -ForegroundColor Yellow
  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & npm.cmd run build 2>&1 | Out-Null
  $code = $LASTEXITCODE
  $ErrorActionPreference = $oldEap
  return ($code -eq 0)
}

function Install-MissingPackage([string]$PackageName) {
  if (-not $PackageName) { return $false }
  Write-Host "Detected missing package: $PackageName" -ForegroundColor Yellow
  Write-Host "Installing in project scope..." -ForegroundColor Cyan

  $installEnv = @{
    "HTTP_PROXY" = ""
    "HTTPS_PROXY" = ""
    "ALL_PROXY" = ""
    "npm_config_proxy" = ""
    "npm_config_https_proxy" = ""
    "npm_config_offline" = "false"
    "npm_config_cache" = (Join-Path $RepoRoot ".npm-cache")
  }

  $saved = @{}
  foreach ($k in $installEnv.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k, "Process")
    [Environment]::SetEnvironmentVariable($k, $installEnv[$k], "Process")
  }

  try {
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $npmOut = & npm.cmd install $PackageName --save --prefer-online --offline=false 2>&1
    if ($LASTEXITCODE -eq 0) {
      return $true
    }

    # Fallback for private/internal packages unavailable on public npm.
    if ($PackageName -eq "@ant/claude-for-chrome-mcp") {
      Write-Host "Package $PackageName is not publicly available. Creating local stub package..." -ForegroundColor Yellow
      Ensure-PrivateStubs
      return $true
    }

    $npmOut
    return $false
  } finally {
    $ErrorActionPreference = $oldEap
    foreach ($k in $saved.Keys) {
      [Environment]::SetEnvironmentVariable($k, $saved[$k], "Process")
    }
  }
}

function Ensure-UndiciForProxy() {
  $httpProxy = [Environment]::GetEnvironmentVariable("HTTP_PROXY", "Process")
  $httpsProxy = [Environment]::GetEnvironmentVariable("HTTPS_PROXY", "Process")
  $allProxy = [Environment]::GetEnvironmentVariable("ALL_PROXY", "Process")
  if (-not ($httpProxy -or $httpsProxy -or $allProxy)) { return $false }

  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & node -e "require('undici');process.exit(0)" 2>&1 | Out-Null
  $ok = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = $oldEap
  if ($ok) { return $false }

  Write-Host "Proxy is enabled and package 'undici' is missing. Installing..." -ForegroundColor Yellow
  if (Install-MissingPackage "undici") {
    Write-Host "Installed undici for proxy-enabled fetch." -ForegroundColor Green
    return $true
  }
  return $false
}

function Ensure-NodePackagePresent([string]$PackageName) {
  if (-not $PackageName) { return $false }
  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & node -e "require.resolve('$PackageName');process.exit(0)" 2>&1 | Out-Null
  $ok = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = $oldEap
  if ($ok) { return $true }
  return (Install-MissingPackage $PackageName)
}

# Interactive mode (no args): run with attached TTY so Claude does not switch
# to non-interactive/print path due to piped stdio capture.
if (-not $CliArgs -or $CliArgs.Count -eq 0) {
  # Interactive TUI expects streaming semantics. Keep one-shot mode on
  # non-streaming for stability, but re-enable streaming in interactive mode.
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_FORCE_NON_STREAMING", "0", "Process")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_OPENAI_COMPAT_ALLOW_STREAMING", "1", "Process")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_FORCE_INTERACTIVE", "1", "Process")
  Ensure-NodePackagePresent "proper-lockfile" | Out-Null
  Ensure-PrivateStubs
  Patch-JsoncParserEsmImports | Out-Null
  Repair-BrokenAnsiToPngShadeBlock | Out-Null
  Patch-DistCjsNamedImport "color-diff-napi" | Out-Null
  Normalize-ColorDiffImport | Out-Null

  # Best-effort proxy auto-detection for environments that require local proxy.
  if (-not (Try-EnableProxyFromWinHttp)) {
    Try-EnableProxyFromUserInternetSettings | Out-Null
  }
  Ensure-UndiciForProxy | Out-Null

  $interactiveArgs = @()
  $interactiveDebugRaw = [Environment]::GetEnvironmentVariable("OPENAI_COMPAT_INTERACTIVE_DEBUG", "Process")
  if ($interactiveDebugRaw -and @("1", "true", "yes", "on") -contains $interactiveDebugRaw.ToLowerInvariant()) {
    $interactiveArgs += "--debug"
    $interactiveArgs += "--debug-to-stderr"
  }
  $forceBare = [Environment]::GetEnvironmentVariable("OPENAI_COMPAT_FORCE_BARE", "Process")
  if ($forceBare -and @("1", "true", "yes", "on") -contains $forceBare.ToLowerInvariant()) {
    $interactiveArgs += "--bare"
    Write-Host "Launching interactive mode (bare)..." -ForegroundColor Cyan
  } else {
    Write-Host "Launching interactive mode..." -ForegroundColor Cyan
  }
  & node $CliDist @interactiveArgs
  exit $LASTEXITCODE
}

[Environment]::SetEnvironmentVariable("CLAUDE_CODE_FORCE_INTERACTIVE", "", "Process")
$maxAttempts = 60
$proxyFallbackTried = $false
$userProxyFallbackTried = $false
$undiciFallbackTried = $false
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
  Write-Host "Startup attempt $attempt/$maxAttempts..." -ForegroundColor DarkCyan
  Ensure-PrivateStubs
  Patch-JsoncParserEsmImports | Out-Null
  Repair-BrokenAnsiToPngShadeBlock | Out-Null
  Normalize-ColorDiffImport | Out-Null
  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & node $CliDist @CliArgs 2>&1
  $ErrorActionPreference = $oldEap
  $code = $LASTEXITCODE
  $text = ($output | Out-String)
  if ($code -eq 0 -and [string]::IsNullOrWhiteSpace($text)) {
    $transcriptText = Get-LatestAssistantTranscriptText
    if ($transcriptText) {
      $output = @($transcriptText)
      $text = $transcriptText
      if ($transcriptText -like 'API Error:*') {
        $code = 1
      }
    }
  }
  if ($code -eq 0) {
    $output
    exit 0
  }

  if ($text -match "Identifier '[^']+' has already been declared") {
    if (Repair-CorruptedColorDiffImport) {
      Write-Host "Repaired corrupted color-diff-napi import patch, retrying startup..." -ForegroundColor Green
      continue
    }
    if (Rebuild-Dist) {
      Write-Host "Rebuild completed, retrying startup..." -ForegroundColor Green
      continue
    }
  }
  $cjsMatch = [regex]::Match($text, "module '([^']+)' is a CommonJS module")
  if ($cjsMatch.Success) {
    $cjsPkg = $cjsMatch.Groups[1].Value
    if (Patch-DistCjsNamedImport $cjsPkg) {
      Write-Host "Patched dist import for CommonJS package $cjsPkg, retrying startup..." -ForegroundColor Green
      continue
    }
  }
  if ($text -match "jsonc-parser\\lib\\esm\\") {
    if (Patch-JsoncParserEsmImports) {
      Write-Host "Patched jsonc-parser ESM imports for Node 24 compatibility, retrying startup..." -ForegroundColor Green
      continue
    }
  }
  if ($text -match "API Error:\s*fetch failed") {
    if (-not $proxyFallbackTried -and (Try-EnableProxyFromWinHttp)) {
      $proxyFallbackTried = $true
      Write-Host "Retrying startup with detected WinHTTP proxy..." -ForegroundColor Green
      continue
    }
    if (-not $userProxyFallbackTried -and (Try-EnableProxyFromUserInternetSettings)) {
      $userProxyFallbackTried = $true
      Write-Host "Retrying startup with detected user proxy settings..." -ForegroundColor Green
      continue
    }
    if (-not $undiciFallbackTried -and (Ensure-UndiciForProxy)) {
      $undiciFallbackTried = $true
      Write-Host "Retrying startup after installing undici..." -ForegroundColor Green
      continue
    }
    Show-FetchFailedDiagnostics
    $output
    exit $code
  }
  $match = [regex]::Match($text, "Cannot find package '([^']+)' imported from")
  if (-not $match.Success) {
    $output
    exit $code
  }

  $pkg = $match.Groups[1].Value
  if (-not (Install-MissingPackage $pkg)) {
    Write-Host "Auto-install failed for package: $pkg" -ForegroundColor Red
    $output
    exit 1
  }

  Write-Host "Installed $pkg, retrying startup..." -ForegroundColor Green
}

Write-Host "Reached maximum auto-install attempts ($maxAttempts)." -ForegroundColor Red
$output
exit 1
