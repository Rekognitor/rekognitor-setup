# Rekognitor installer for Windows 10 (2004+) / 11.
#
# Run it through install-windows.cmd (double click). It:
#   1. installs WSL2 if missing (asks for a reboot and resumes on next logon);
#   2. imports a dedicated Ubuntu 24.04 WSL distribution named "Rekognitor";
#   3. runs install.sh inside it (k0s + the rekognitor charts), the same k0s
#      the Linux installer uses;
#   4. creates the "Rekognitor" logon task that keeps the distribution running
#      (and, in WSL NAT mode, forwards the ports to it);
#   5. optionally opens the ports to the LAN, creates a desktop shortcut and opens
#      the web UI.
# Everything it creates is recorded in %ProgramData%\Rekognitor\state.json and is
# removed by uninstall-windows.cmd. Your other WSL distributions and .wslconfig
# are not modified.
[CmdletBinding()]
param(
    # -Profile (not $Profile: that is PowerShell's automatic variable)
    [Alias('Profile')][ValidateSet('auto', 'light', 'full')][string]$Sizing = 'auto',
    [switch]$AllowLan,
    [switch]$Check,
    [switch]$Yes,
    [int]$Timeout = 1200,
    [switch]$Elevated   # internal: set on the self-elevated relaunch
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:WSL_UTF8 = '1'   # wsl.exe prints UTF-16 otherwise
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Distro    = 'Rekognitor'
$TaskName  = 'Rekognitor'
$Home_     = Join-Path $env:ProgramData 'Rekognitor'
$StateFile = Join-Path $Home_ 'state.json'
$Root      = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$UiPort    = 31881
$Ports     = @(31881, 31882, 31883)   # NodePorts: UI, MQTT/WebSocket, MQTT
$RootfsBase = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current'

function Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "       $m" }
function Pause-Window { if ($Elevated -or -not $Yes) { Write-Host ""; Read-Host "Pressione Enter para fechar" | Out-Null } }
function Fail($m) {
    Write-Host ""; Write-Host "ERRO: $m" -ForegroundColor Red
    Pause-Window
    exit 1
}
function Confirm-Action($q) {
    if ($Yes) { return $true }
    $a = Read-Host "$q [s/N]"
    return ($a -match '^[sSyY]')
}

function Get-State {
    if (Test-Path $StateFile) { return Get-Content $StateFile -Raw | ConvertFrom-Json }
    return [pscustomobject]@{}
}
function Set-State($key, $value) {
    $s = Get-State
    $s | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force
    New-Item -ItemType Directory -Force -Path $Home_ | Out-Null
    $s | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

# wsl.exe with UTF-8 output; returns the output lines, $LASTEXITCODE is kept.
function Wsl { & wsl.exe @args }
function In-Distro([string]$cmd) { & wsl.exe -d $Distro -u root -- bash -c $cmd }
function Distro-Exists { return ((Wsl -l -q 2>$null) -replace "`0", '' | ForEach-Object { $_.Trim() }) -contains $Distro }

function Get-WslNetworkingMode {
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    if ((Test-Path $cfg) -and ((Get-Content $cfg -Raw) -match '(?im)^\s*networkingMode\s*=\s*mirrored')) { return 'mirrored' }
    return 'nat'
}

# --------------------------------------------------------------- elevation ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# -Check only reads system information: no elevation needed
if (-not $isAdmin -and -not $Check) {
    Write-Host "Pedindo permissão de administrador..."
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Profile', $Sizing, '-Timeout', $Timeout, '-Elevated')
    if ($AllowLan) { $argList += '-AllowLan' }
    if ($Check)    { $argList += '-Check' }
    if ($Yes)      { $argList += '-Yes' }
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $p.ExitCode
}

Write-Host "Rekognitor - instalador para Windows" -ForegroundColor White
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'RekognitorInstall' -ErrorAction SilentlyContinue

# --------------------------------------------------------------- preflight ---
Step "Verificando pré-requisitos"
$fail = $false
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
if ($build -lt 19041) { Warn "Windows build ${build}: é preciso Windows 10 versão 2004 (build 19041) ou mais novo"; $fail = $true }
else { Ok "$($os.Caption) (build $build)" }

$cpu = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$memGb = [math]::Round($os.TotalVisibleMemorySize / 1MB)
if ($cpu -lt 2) { Warn "CPUs: $cpu (mínimo 2)"; $fail = $true } elseif ($cpu -lt 4) { Warn "CPUs: $cpu (recomendado 4 ou mais)" } else { Ok "CPUs: $cpu" }
if ($memGb -lt 6) { Warn "memória: $memGb GB (mínimo 6 GB no Windows)"; $fail = $true } elseif ($memGb -lt 8) { Warn "memória: $memGb GB (recomendado 8 GB)" } else { Ok "memória: $memGb GB" }
$freeGb = [math]::Floor((Get-PSDrive -Name ($env:ProgramData.Substring(0, 1))).Free / 1GB)
if ($freeGb -lt 20) { Warn "disco livre: $freeGb GB (mínimo 20 GB)"; $fail = $true } else { Ok "disco livre: $freeGb GB" }

$cs = Get-CimInstance Win32_ComputerSystem
$proc = Get-CimInstance Win32_Processor | Select-Object -First 1
if ($cs.HypervisorPresent -or $proc.VirtualizationFirmwareEnabled) { Ok "virtualização habilitada" }
else { Warn "virtualização desabilitada na BIOS/UEFI (Intel VT-x / AMD-V): habilite-a para usar o WSL2"; $fail = $true }

try {
    Invoke-WebRequest -Uri 'https://registry-1.docker.io/v2/' -UseBasicParsing -TimeoutSec 15 | Out-Null
    Ok "internet: Docker Hub acessível"
} catch {
    if ($_.Exception.Response) { Ok "internet: Docker Hub acessível" }
    else { Warn "sem acesso a https://registry-1.docker.io (as imagens vêm do Docker Hub)"; $fail = $true }
}

$mode = Get-WslNetworkingMode
$state = Get-State
if (-not $state.Distro) {
    # In mirrored mode the WSL distro shares the Windows ports; in NAT mode the
    # installer forwards them with netsh portproxy. Both need them free.
    $portsToCheck = $Ports + $(if ($mode -eq 'mirrored') { @(6443, 10250) } else { @() })
    $busy = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $portsToCheck -contains $_.LocalPort } | Select-Object -ExpandProperty LocalPort -Unique
    # NodePorts of a Kubernetes in WSL mirrored mode answer without a Windows listening socket
    foreach ($p in $portsToCheck) {
        $c = New-Object Net.Sockets.TcpClient
        try { if ($c.ConnectAsync('127.0.0.1', $p).Wait(1000) -and $c.Connected) { $busy = @($busy) + $p } } catch {} finally { $c.Close() }
    }
    $busy = @($busy | Where-Object { $_ } | Sort-Object -Unique)
    if ($busy) { Warn "portas já em uso: $($busy -join ', ') (outro Kubernetes, Docker Desktop ou o Rekognitor já rodando?)"; $fail = $true }
    else { Ok "portas livres: $($Ports -join ', ')" }
}

$wslOk = $false
& wsl.exe --status *> $null
if ($LASTEXITCODE -eq 0) { $wslOk = $true; Ok "WSL instalado (rede: $mode)" } else { Warn "WSL não instalado: será instalado agora (exige reiniciar o Windows)" }

if ($fail) { Fail "corrija os itens marcados com [!] e rode de novo" }
if ($Check) { Write-Host ""; Write-Host "Tudo certo: esta máquina pode instalar o Rekognitor." -ForegroundColor Green; Pause-Window; exit 0 }

if (-not $state.Distro) {
    Write-Host ""
    Info "Será criada a distribuição WSL '$Distro' (Ubuntu 24.04) com o Kubernetes (k0s)"
    Info "e os serviços do Rekognitor. Suas outras distribuições WSL não são alteradas."
    if (-not (Confirm-Action "Continuar?")) { Fail "cancelado" }
}

# --------------------------------------------------------------------- WSL ---
if (-not $wslOk) {
    Step "Instalando o WSL2"
    & wsl.exe --install --no-distribution
    if ($LASTEXITCODE -ne 0) {
        # older in-box wsl.exe (Windows 10) has no --no-distribution: enable the features directly
        Info "usando o DISM para habilitar o WSL e a Plataforma de Máquina Virtual..."
        & dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
        & dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { Fail "falha ao habilitar o WSL (código $LASTEXITCODE)" }
    }
    # resume after the reboot, at the next logon of this user (it asks for admin again)
    $resume = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Profile $Sizing" + $(if ($AllowLan) { ' -AllowLan' } else { '' })
    New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'RekognitorInstall' -Value $resume
    Write-Host ""
    Write-Host "O WSL foi instalado. É preciso REINICIAR o Windows." -ForegroundColor Yellow
    Write-Host "A instalação do Rekognitor continua sozinha depois do login."
    if (Confirm-Action "Reiniciar agora?") { Restart-Computer -Force }
    Pause-Window
    exit 0
}
& wsl.exe --update *> $null

if (-not (Distro-Exists)) {
    Step "Criando a distribuição WSL '$Distro' (Ubuntu 24.04)"
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $file = "ubuntu-noble-wsl-$arch-wsl.rootfs.tar.gz"
    $tar = Join-Path $Home_ $file
    New-Item -ItemType Directory -Force -Path $Home_ | Out-Null
    Info "baixando $file (~350 MB)..."
    & curl.exe -fL --retry 3 -o $tar "$RootfsBase/$file"
    if ($LASTEXITCODE -ne 0) { Fail "falha ao baixar $RootfsBase/$file" }
    $sums = (Invoke-WebRequest -Uri "$RootfsBase/SHA256SUMS" -UseBasicParsing).Content
    $expected = ($sums -split "`n" | Where-Object { $_ -match [regex]::Escape($file) + '$' } | Select-Object -First 1) -replace '\s.*$', ''
    $actual = (Get-FileHash -Algorithm SHA256 $tar).Hash.ToLower()
    if (-not $expected -or $actual -ne $expected.ToLower()) { Remove-Item $tar -Force; Fail "checksum inválido para $file" }
    Ok "download verificado (SHA256)"
    & wsl.exe --import $Distro (Join-Path $Home_ 'wsl') $tar --version 2
    if ($LASTEXITCODE -ne 0) { Fail "wsl --import falhou (código $LASTEXITCODE)" }
    Remove-Item $tar -Force
    Set-State 'Distro' $Distro
    # systemd runs k0s as a service; no Windows PATH (spaces) inside the distro
    In-Distro "printf '[boot]\nsystemd=true\n\n[user]\ndefault=root\n\n[interop]\nappendWindowsPath=false\n' > /etc/wsl.conf"
    & wsl.exe --terminate $Distro | Out-Null
    Ok "distribuição '$Distro' criada"
} else {
    Ok "distribuição '$Distro' já existe"
    if (-not $state.Distro) { Set-State 'Distro' $Distro }
}
Set-State 'NetworkingMode' $mode
Set-State 'AllowLan' ([bool]$AllowLan)

# ----------------------------------------------------- keep-alive logon task ---
Step "Tarefa de inicialização '$TaskName'"
$startScript = Join-Path $Home_ 'rekognitor-start.ps1'
Copy-Item (Join-Path $PSScriptRoot 'rekognitor-start.ps1') $startScript -Force
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
# re-run: restart the task so it picks up the new state (e.g. -AllowLan)
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'rekognitor-start\.ps1' } |
    ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Set-State 'Task' $TaskName
Ok "a distribuição '$Distro' inicia junto com o login do Windows"

# ---------------------------------------------------------- run install.sh ---
if ($Root -notmatch '^[A-Za-z]:\\') { Fail "extraia o Rekognitor numa pasta local (ex.: C:\Rekognitor), não em $Root" }
Step "Copiando o instalador para a distribuição"
$wslRoot = '/mnt/' + $Root.Substring(0, 1).ToLower() + ($Root.Substring(2) -replace '\\', '/')
In-Distro "set -e; rm -rf /opt/rekognitor; mkdir -p /opt/rekognitor; tar -C '$wslRoot' --exclude=.git -cf - . | tar -C /opt/rekognitor -xf -; find /opt/rekognitor -name '*.sh' -exec sed -i 's/\r`$//' {} +; chmod +x /opt/rekognitor/*.sh"
if ($LASTEXITCODE -ne 0) { Fail "falha ao copiar $Root para a distribuição" }
Ok "instalador em /opt/rekognitor"

# install.sh asks for the CLIENT_ID / SECRET issued by Rekognitor itself, without
# echo, in this same console: they never pass through PowerShell, a command line
# or a file. For unattended installs, REKOGNITOR_CLIENT_ID / REKOGNITOR_SECRET set
# in this session's environment are handed to WSL through WSLENV (not argv).
if ($env:REKOGNITOR_CLIENT_ID -and $env:REKOGNITOR_SECRET) {
    $env:WSLENV = (@($env:WSLENV, 'REKOGNITOR_CLIENT_ID', 'REKOGNITOR_SECRET') | Where-Object { $_ }) -join ':'
}
& wsl.exe -d $Distro -u root -- bash /opt/rekognitor/install.sh --yes --cluster k0s --profile $Sizing --timeout $Timeout
if ($LASTEXITCODE -ne 0) { Fail "a instalação dentro do WSL falhou (veja as mensagens acima)" }

# ------------------------------------------------------- Windows-side access ---
Step "Acesso pelo Windows"
# the logon task applies the NAT port forwarding; give it a moment
Start-Sleep -Seconds 5
if ($AllowLan) {
    foreach ($p in $Ports) {
        $n = "Rekognitor-$p"
        Remove-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $n -Group 'Rekognitor' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $p | Out-Null
    }
    Ok "firewall do Windows: portas $($Ports -join ', ') liberadas para a rede"
    if ($mode -eq 'mirrored' -and (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) {
        # mirrored-mode inbound traffic is filtered by the Hyper-V firewall too
        $wslVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
        foreach ($p in $Ports) {
            $n = "Rekognitor-HyperV-$p"
            Remove-NetFirewallHyperVRule -Name $n -ErrorAction SilentlyContinue
            New-NetFirewallHyperVRule -Name $n -DisplayName $n -Direction Inbound -Action Allow -Protocol TCP -LocalPorts $p -VMCreatorId $wslVmCreatorId | Out-Null
        }
        Ok "firewall Hyper-V (WSL espelhado): portas liberadas"
    }
    Set-State 'Firewall' $true
}

$url = "http://localhost:$UiPort"
$up = $false
for ($i = 0; $i -lt 40; $i++) {
    try { Invoke-WebRequest -Uri "$url/healthz" -UseBasicParsing -TimeoutSec 5 | Out-Null; $up = $true; break } catch { Start-Sleep -Seconds 3 }
}
if ($up) { Ok "interface web respondendo em $url" } else { Warn "o Windows ainda não alcança $url (aguarde um minuto ou reinicie o Windows)" }

$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop 'Rekognitor.url'
Set-Content -Path $lnk -Value "[InternetShortcut]`r`nURL=$url/`r`n" -Encoding ASCII
Set-State 'Shortcut' $lnk
Ok "atalho 'Rekognitor' criado na Área de Trabalho"

$ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notlike '169.*' -and $_.InterfaceAlias -notlike 'vEthernet*' -and $_.InterfaceAlias -notlike '*Loopback*' } |
    Select-Object -First 1).IPAddress
Set-State 'InstalledAt' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "          Rekognitor instalado com sucesso!" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Interface web    $url   (atalho na Área de Trabalho)"
if ($AllowLan) { Write-Host "                   na rede: http://${ip}:$UiPort" }
Write-Host "  MQTT (câmeras)   ${ip}:31883   (WebSocket: ${ip}:31882)"
Write-Host "  Login            CLIENT_ID e SECRET fornecidos pela Rekognitor"
Write-Host "                   (guardados no Secret rekognitor-credentials do k0s)"
Write-Host "  Comandos         wsl -d $Distro k0s kubectl -n rekognitor get pods"
Write-Host "  Desinstalar      uninstall-windows.cmd"
Write-Host ""
if ($up) { Start-Process $url }
Pause-Window
