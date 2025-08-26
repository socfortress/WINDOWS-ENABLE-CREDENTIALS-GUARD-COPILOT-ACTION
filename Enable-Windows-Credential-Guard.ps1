[CmdletBinding()]
param(
  [switch]$RebootAfter,
  [string]$LogPath = "$env:TEMP\EnableCredentialGuard-script.log",
  [string]$ARLog = 'C:\Program Files (x86)\ossec-agent\active-response\active-responses.log'
)

$ErrorActionPreference = 'Stop'
$HostName = $env:COMPUTERNAME
$LogMaxKB = 100
$LogKeep = 5
$runStart = Get-Date
function Write-Log {
  param([string]$Message,[ValidateSet('INFO','WARN','ERROR','DEBUG')]$Level='INFO')
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
  $line = "[$ts][$Level] $Message"
  switch ($Level) {
    'ERROR' { Write-Host $line -ForegroundColor Red }
    'WARN'  { Write-Host $line -ForegroundColor Yellow }
    'DEBUG' { if ($PSCmdlet.MyInvocation.BoundParameters.ContainsKey('Verbose')) { Write-Verbose $line } }
    default { Write-Host $line }
  }
  Add-Content -Path $LogPath -Value $line -Encoding utf8
}
function Rotate-Log {
  if (Test-Path $LogPath -PathType Leaf) {
    if ((Get-Item $LogPath).Length/1KB -gt $LogMaxKB) {
      for ($i = $LogKeep - 1; $i -ge 0; $i--) {
        $old = "$LogPath.$i"
        $new = "$LogPath." + ($i + 1)
        if (Test-Path $old) { Rename-Item $old $new -Force }
      }
      Rename-Item $LogPath "$LogPath.1" -Force
    }
  }
}
function Now-Timestamp {
  return (Get-Date).ToString('yyyy-MM-dd HH:mm:sszzz')
}

function Write-NDJSONLines {
  param([string[]]$JsonLines,[string]$Path=$ARLog)
  $tmp = Join-Path $env:TEMP ("arlog_{0}.tmp" -f ([guid]::NewGuid().ToString("N")))
  Set-Content -Path $tmp -Value ($JsonLines -join [Environment]::NewLine) -Encoding ascii -Force
  try { Move-Item -Path $tmp -Destination $Path -Force } 
  catch { Move-Item -Path $tmp -Destination ($Path + '.new') -Force }
}

Rotate-Log
Write-Log "=== SCRIPT START : Enable Windows Credential Guard ==="

$ts = Now-Timestamp
$lines = @()
$status = 'success'
$errorMsg = $null

try {
  Write-Log "Enabling Credential Guard policies..." 'INFO'

  $RegPaths = @(
    "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard",
    "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
  )

  if (-not (Test-Path $RegPaths[0])) { New-Item -Path $RegPaths[0] -Force | Out-Null }
  Set-ItemProperty -Path $RegPaths[0] -Name "EnableVirtualizationBasedSecurity" -Value 1 -Type DWord -Force
  Set-ItemProperty -Path $RegPaths[0] -Name "RequirePlatformSecurityFeatures" -Value 1 -Type DWord -Force

  if (-not (Test-Path $RegPaths[1])) { New-Item -Path $RegPaths[1] -Force | Out-Null }
  Set-ItemProperty -Path $RegPaths[1] -Name "RunAsPPL" -Value 1 -Type DWord -Force

  Write-Log "Credential Guard enabled. A reboot is required for changes to take effect." 'INFO'

  if ($RebootAfter) {
    Write-Log "Rebooting system as requested..." 'INFO'
    Restart-Computer -Force
  }

  foreach ($path in $RegPaths) {
    $values = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    $lines += ([pscustomobject]@{
      timestamp      = $ts
      host           = $HostName
      action         = 'enable_credential_guard'
      copilot_action = $true
      type           = 'verify_registry'
      registry_path  = $path
      values         = $values | Select-Object * | ConvertTo-Json -Compress
    } | ConvertTo-Json -Compress -Depth 5)
  }

} catch {
  $status = 'error'
  $errorMsg = $_.Exception.Message
  Write-Log "Failed to enable Credential Guard: $errorMsg" 'ERROR'
  $lines += ([pscustomobject]@{
    timestamp      = $ts
    host           = $HostName
    action         = 'enable_credential_guard'
    copilot_action = $true
    type           = 'error'
    error          = $errorMsg
  } | ConvertTo-Json -Compress -Depth 4)
}

$summary = [pscustomobject]@{
  timestamp      = $ts
  host           = $HostName
  action         = 'enable_credential_guard'
  copilot_action = $true
  type           = 'summary'
  reboot_after   = [bool]$RebootAfter
  status         = $status
  error          = $errorMsg
  duration_s     = [math]::Round(((Get-Date)-$runStart).TotalSeconds,1)
}

$lines = @(( $summary | ConvertTo-Json -Compress -Depth 5 )) + $lines

Write-NDJSONLines -JsonLines $lines -Path $ARLog
Write-Log ("NDJSON written to {0} ({1} lines)" -f $ARLog,$lines.Count) 'INFO'

$dur = [int]((Get-Date) - $runStart).TotalSeconds
Write-Log "=== SCRIPT END : duration ${dur}s ==="
