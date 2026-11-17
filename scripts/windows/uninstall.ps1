# Rekognitor uninstaller for Windows. Run it through uninstall-windows.cmd.
#
# Removes what install.ps1 created (recorded in %ProgramData%\Rekognitor\state.json):
# the "Rekognitor" logon task, port forwards, firewall rules, desktop shortcut and
# the "Rekognitor" WSL distribution, which holds k0s, the services and the enrolled
# faces. WSL itself and your other distributions are left installed.
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$Elevated   # internal: set on the self-elevated relaunch
)
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Distro    = 'Rekognitor'
$TaskName  = 'Rekognitor'
$Home_     = Join-Path $env:ProgramData 'Rekognitor'
$StateFile = Join-Path $Home_ 'state.json'
$Ports     = @(31881, 31882, 31883)   # NodePorts: UI, MQTT/WebSocket, MQTT

function Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "       $m" }
function Pause-Window { if ($Elevated -or -not $Yes) { Write-Host ""; Read-Host "Pressione Enter para fechar" | Out-Null } }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Pedindo permissão de administrador..."
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Elevated')
    if ($Yes) { $argList += '-Yes' }
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $p.ExitCode
}

Write-Host "Rekognitor - desinstalador para Windows" -ForegroundColor White
$state = if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$distroExists = ((& wsl.exe -l -q 2>$null) -replace "`0", '' | ForEach-Object { $_.Trim() }) -contains $Distro
if (-not (Test-Path $StateFile) -and -not $distroExists) {
    Write-Host "O Rekognitor não está instalado neste computador." -ForegroundColor Yellow
    Pause-Window
    exit 0
}

Write-Host ""
Write-Host "Será removido:"
Info "- a distribuição WSL '$Distro' (Kubernetes, serviços, rostos cadastrados e configurações)"
Info "- a tarefa de inicialização '$TaskName', regras de firewall e redirecionamentos de porta"
Info "- o atalho 'Rekognitor' da Área de Trabalho"
Info "O WSL e suas outras distribuições continuam instalados."
if (-not $Yes) {
    $a = Read-Host "Confirmar a desinstalação? [s/N]"
    if ($a -notmatch '^[sSyY]') { Write-Host "cancelado"; Pause-Window; exit 1 }
}

Step "Parando o Rekognitor"
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Ok "tarefa '$TaskName' removida"
}
# the task's script loops and restarts WSL: make sure it is gone
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'rekognitor-start\.ps1' } |
    ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }
if ($distroExists) { & wsl.exe --terminate $Distro | Out-Null }

Step "Rede e firewall"
foreach ($listen in @('127.0.0.1', '0.0.0.0')) {
    foreach ($p in $Ports) { & netsh.exe interface portproxy delete v4tov4 listenport=$p listenaddress=$listen 2>&1 | Out-Null }
}
Ok "redirecionamentos de porta removidos"
Get-NetFirewallRule -Group 'Rekognitor' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if (Get-Command Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
    foreach ($p in $Ports) { Remove-NetFirewallHyperVRule -Name "Rekognitor-HyperV-$p" -ErrorAction SilentlyContinue }
}
Ok "regras de firewall removidas"

Step "Removendo a distribuição '$Distro'"
if ($distroExists) {
    & wsl.exe --unregister $Distro | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "distribuição '$Distro' removida" } else { Warn "wsl --unregister $Distro falhou (código $LASTEXITCODE)" }
} else { Info "distribuição já não existia" }

$lnk = if ($state.Shortcut) { $state.Shortcut } else { Join-Path ([Environment]::GetFolderPath('Desktop')) 'Rekognitor.url' }
if (Test-Path $lnk) { Remove-Item $lnk -Force; Ok "atalho removido" }
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'RekognitorInstall' -ErrorAction SilentlyContinue
if (Test-Path $Home_) { Remove-Item $Home_ -Recurse -Force; Ok "$Home_ removida" }

Write-Host ""
Write-Host "Rekognitor desinstalado." -ForegroundColor Green
Pause-Window
