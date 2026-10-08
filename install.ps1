# ClinicNest – install or update on Windows with one command (PowerShell, no administrator rights needed):
#
#   irm https://updates.clinicnest.app/install.ps1 | iex
#   $env:CLINICNEST_EDITION='server'; irm https://updates.clinicnest.app/install.ps1 | iex     ClinicNest Server
#
# The same from Command Prompt (or PowerShell), in one line:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://updates.clinicnest.app/install.ps1 | iex"
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:CLINICNEST_EDITION='server'; irm https://updates.clinicnest.app/install.ps1 | iex"
#
# What it does: downloads the official ClinicNest_setup.exe of the latest release, checks it against SHA256SUMS,
# whose signature is checked with ClinicNest's public key below (the same key the automatic updates are checked
# with), runs the installer silently for the current user (%LOCALAPPDATA%\Programs\ClinicNest, Start menu,
# uninstaller) and starts ClinicNest. Anything changed or incomplete is refused and nothing is installed.
# The clinic's data is not touched (it lives in C:\ProgramData\Clinic).
# CLINICNEST_EDITION=server installs ClinicNest Server (PostgreSQL built in) from ClinicNest-Server_setup.exe: for
# all users in Program Files, as a background service – Windows asks for administrator permission once. It sits
# beside ClinicNest (data in C:\ProgramData\Clinic Server).
#
# Downloaded from downloads.clinicnest.app; when that cannot be reached, from the GitHub Release.
#
# Testing: $env:CLINICNEST_DOWNLOAD = '<base URL> [<second base URL>]'; $env:CLINICNEST_CHECK_ONLY = 1 (download and check, no install)

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads very slowly with a progress bar
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    # where the installers are: our own address first, the GitHub Release second (some networks block the one or
    # the other); wherever it comes from, the same signature check decides
    $sources = if ($env:CLINICNEST_DOWNLOAD) { @($env:CLINICNEST_DOWNLOAD -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('/') }) } `
        else { @('https://downloads.clinicnest.app/latest', 'https://github.com/clinicnest-app/clinic-nest-updates/releases/latest/download') }
    $server = $env:CLINICNEST_EDITION -eq 'server'
    if ($env:CLINICNEST_EDITION -and -not $server) {
        Write-Host "Unknown CLINICNEST_EDITION '$($env:CLINICNEST_EDITION)' - use nothing (ClinicNest) or 'server'." -ForegroundColor Red
        throw 'ClinicNest was not installed.'
    }
    $title = if ($server) { 'ClinicNest Server' } else { 'ClinicNest' }
    $setupName = if ($server) { 'ClinicNest-Server_setup.exe' } else { 'ClinicNest_setup.exe' }

    function Fail([string] $message) {
        Write-Host ''
        Write-Host "Not installed: $message" -ForegroundColor Red
        throw 'ClinicNest was not installed.'
    }

    # ClinicNest's public key (launcher/src/main/resources/update-signing.pub): RSA 3072, exponent 65537
    $modulus = '4iawPd43ggtkWOtePzyYhmxQQS/FI8kJo9odZOBqz0e/ZouURsXXJLwy4vciULx5sVHk0w2dm9NyZ+v00kVSBtvzJzYT38EPvMHDRqiDX7LPEm61ZwDC+gk5gjkorOLJcta36HrKvUtVbFVjf8FqpJaFU0KecQxUxA9SgwgRlCOxTwiM/w5ODd8/vR57ckX7E6UsrM7IttBmNM7dxozQtdNISk1L3OCjjwsLPa4xhWYPXunNB04/dDRQxr/5rTa0CVRzXl0pMSXlc5nUyHcmWRL6kQxT9g4MTXiZ4/sqjLxGBRFGxdx7MZCoPmwRet+51xPt0Cv5GBdb31oA0TDmymlyq9DP+qO64Azo4aZ8aPam7bBLHK2e5ZUZTYX59pye3ZtDcDMohWheLEADfzd6mlZBqtaUb9CgNpXc3yIgPWTnQzL6On+l/YJpvpysKprecsW8ipfoXW6duhafgho4LdDPZ6Qg8FWENrxXp2YxwKTtx3KVowXkggni3oyi37x1'

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('clinicnest-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Write-Host "Downloading $title ..." -ForegroundColor Cyan
        # all three files from the same place, so they belong together
        $from = $null
        foreach ($source in $sources) {
            try {
                foreach ($file in 'SHA256SUMS', 'SHA256SUMS.sig', $setupName) {
                    Invoke-WebRequest -UseBasicParsing -Uri "$source/$file" -OutFile (Join-Path $tmp $file)
                }
                $from = $source
                break
            } catch {
                Write-Host "Not available from $source - trying another address ..."
            }
        }
        if (-not $from) { Fail "could not download $title - check the internet connection (tried: $($sources -join ', '))." }

        Write-Host 'Checking the download ...' -ForegroundColor Cyan
        $sums = [IO.File]::ReadAllBytes((Join-Path $tmp 'SHA256SUMS'))
        $signature = [IO.File]::ReadAllBytes((Join-Path $tmp 'SHA256SUMS.sig'))
        $parameters = New-Object Security.Cryptography.RSAParameters
        $parameters.Modulus = [Convert]::FromBase64String($modulus)
        $parameters.Exponent = [byte[]] (1, 0, 1)
        # RSACng on Windows (.NET Framework 4.6+); RSA.Create() elsewhere (PowerShell 7)
        $rsa = $null
        try { $rsa = New-Object Security.Cryptography.RSACng } catch { $rsa = [Security.Cryptography.RSA]::Create() }
        $rsa.ImportParameters($parameters)
        $signed = $rsa.VerifyData($sums, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        if (-not $signed) { Fail 'the checksum file is not signed by ClinicNest. Please tell support@clinicnest.app.' }

        $expected = $null
        foreach ($line in [Text.Encoding]::ASCII.GetString($sums) -split "`n") {
            if ($line.Trim() -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' -and $Matches[2] -eq $setupName) { $expected = $Matches[1].ToLower() }
        }
        $setup = Join-Path $tmp $setupName
        $actual = (Get-FileHash -Algorithm SHA256 -Path $setup).Hash.ToLower()
        if (-not $expected -or $expected -ne $actual) { Fail 'the download is damaged or was changed on the way. Try again.' }
        Write-Host 'Signature and checksum OK.'
        if ($env:CLINICNEST_CHECK_ONLY) { Write-Host 'Check only: not installing.'; return }
        if (-not [Environment]::Is64BitOperatingSystem) { Fail 'ClinicNest needs 64-bit Windows 10 or 11.' }

        Write-Host 'Installing ...' -ForegroundColor Cyan
        if ($server) {
            # for all users, with the Windows service and the firewall rule: administrator permission (one question)
            Write-Host 'Windows asks for administrator permission: click Yes.'
            try {
                $process = Start-Process -FilePath $setup -ArgumentList '/S' -Verb RunAs -Wait -PassThru
            } catch {
                Fail 'administrator permission was not given.'
            }
            if ($process.ExitCode -ne 0) { Fail "the installer stopped with code $($process.ExitCode)." }
            $app = Join-Path $env:ProgramFiles 'ClinicNest Server\ClinicNest.exe'
            if (-not (Test-Path $app)) { Fail "ClinicNest.exe was not found in $(Split-Path $app)." }
            Write-Host "Installed: $app"
            Start-Process -FilePath $app
            Write-Host ''
            Write-Host 'Done. ClinicNest Server runs as a background service: it starts with Windows, also when nobody is' -ForegroundColor Green
            Write-Host 'signed in. First start: about a minute, then open http://localhost:8081' -ForegroundColor Green
            Write-Host ' - Other computers and phones open http://<this computer>:8081 (the installer opened the firewall for it).'
            Write-Host ' - It updates itself. Data: C:\ProgramData\Clinic Server; backups: Public Documents\ClinicNest Server\backups.'
            Write-Host ' - Stop or start it in Windows: Services > ClinicNest Server. Remove it in Settings > Apps.'
            return
        }
        # the installer closes a running ClinicNest itself; /S = silent, for the current user
        $process = Start-Process -FilePath $setup -ArgumentList '/S' -Wait -PassThru
        if ($process.ExitCode -ne 0) { Fail "the installer stopped with code $($process.ExitCode)." }
        $app = Join-Path $env:LOCALAPPDATA 'Programs\ClinicNest\ClinicNest.exe'
        if (-not (Test-Path $app)) { Fail "ClinicNest.exe was not found in $(Split-Path $app)." }
        Write-Host "Installed: $app"

        Write-Host 'Starting ClinicNest ...' -ForegroundColor Cyan
        Start-Process -FilePath $app
        Write-Host ''
        Write-Host 'Done. ClinicNest opens in the browser in a moment (first start: about 30 seconds).' -ForegroundColor Green
        Write-Host ' - If Windows Firewall asks about ClinicNest / Java: tick "Private networks" and click Allow -'
        Write-Host '   otherwise phones and other computers in the clinic cannot open ClinicNest.'
        Write-Host ' - ClinicNest updates itself; run this command again only to repair an installation.'
        Write-Host ' - Remove it later in Settings > Apps, or with "Uninstall ClinicNest" in the Start menu.'
    } finally {
        Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue
    }
}
