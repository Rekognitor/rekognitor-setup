# Run by the "Rekognitor" scheduled task at logon (hidden window), installed by
# install.ps1 into %ProgramData%\Rekognitor.
#
# WSL stops a distribution once nothing runs in it, which would stop k0s. This
# keeps one process alive inside "Rekognitor" and, if WSL is in NAT mode (the
# default), forwards the Rekognitor ports from Windows to the distribution's
# current IP, which changes on every WSL start. In mirrored mode WSL already
# shares the Windows ports. If WSL is shut down, the loop starts it again.
$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'
$Distro = 'Rekognitor'
$Ports = @(31881, 31882, 31883)   # NodePorts: UI, MQTT/WebSocket, MQTT
$state = Get-Content (Join-Path $env:ProgramData 'Rekognitor\state.json') -Raw | ConvertFrom-Json
$listen = if ($state.AllowLan) { '0.0.0.0' } else { '127.0.0.1' }

while ($true) {
    & wsl.exe -d $Distro -u root -- true   # boots the distribution (systemd -> k0s)
    if ($state.NetworkingMode -ne 'mirrored') {
        $ip = ((& wsl.exe -d $Distro -u root -- hostname -I) -join ' ').Trim().Split(' ')[0]
        if ($ip) {
            foreach ($p in $Ports) {
                & netsh.exe interface portproxy delete v4tov4 listenport=$p listenaddress=$listen | Out-Null
                & netsh.exe interface portproxy add v4tov4 listenport=$p listenaddress=$listen connectport=$p connectaddress=$ip | Out-Null
            }
        }
    }
    # blocks for as long as the distribution runs
    & wsl.exe -d $Distro -u root --exec sleep infinity
    Start-Sleep -Seconds 10
}
