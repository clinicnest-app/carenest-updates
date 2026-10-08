# ClinicNest server edition – install or update on Windows with Docker Desktop (PowerShell):
#
#   irm https://updates.clinicnest.app/install-server.ps1 | iex
#
# Sets up ClinicNest + PostgreSQL + Caddy (web server: https or plain http) in %USERPROFILE%\ClinicNest-Server,
# creates the passwords and a one-time setup code, starts everything and prints the address. Run it again to
# update: the passwords and settings in .env are kept, the newest ClinicNest is started.
# Docker Desktop is needed (free for organisations under 250 staff and USD 10 million revenue); when it is
# missing, the script offers to install it with winget (asks for administrator permission once).
#
# Settings (environment, all optional): CLINICNEST_SITE (internet name for https, "none" = clinic network only),
# CLINICNEST_DIR (install folder), CLINICNEST_YES=1 (no questions), CLINICNEST_VERSION (image tag, default latest),
# CLINICNEST_HTTP_PORT / CLINICNEST_HTTPS_PORT (80 / 443), CLINICNEST_BASE (where the compose files come from).

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    $base = if ($env:CLINICNEST_BASE) { $env:CLINICNEST_BASE.TrimEnd('/') } else { 'https://updates.clinicnest.app' }
    $dir = if ($env:CLINICNEST_DIR) { $env:CLINICNEST_DIR } else { Join-Path $env:USERPROFILE 'ClinicNest-Server' }
    $yes = [bool] $env:CLINICNEST_YES

    function Say([string] $text) { Write-Host ''; Write-Host $text -ForegroundColor Cyan }
    function Fail([string] $message) {
        Write-Host ''
        Write-Host "Not installed: $message" -ForegroundColor Red
        throw 'ClinicNest server was not installed.'
    }
    function Ask([string] $question, [string] $default) {
        if ($yes) { return $default }
        $answer = Read-Host $question
        if ([string]::IsNullOrWhiteSpace($answer)) { return $default } else { return $answer.Trim() }
    }
    function Random([int] $length) {
        $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
        $bytes = New-Object byte[] $length
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
    }
    function DockerRunning { & docker info *> $null; return $LASTEXITCODE -eq 0 }
    # HTTP status of a local address; 0 = no answer
    function Status([string] $url) {
        try {
            $request = [Net.HttpWebRequest]::Create($url)
            $request.AllowAutoRedirect = $false
            $request.Timeout = 5000
            $response = $request.GetResponse()
            $code = [int] $response.StatusCode
            $response.Close()
            return $code
        } catch [Net.WebException] {
            if ($_.Exception.Response) { return [int] $_.Exception.Response.StatusCode }
            return 0
        }
    }

    # ------------------------------------------------------------------------------------------ Docker Desktop
    $dockerBin = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'
    if (-not (Get-Command docker -ErrorAction SilentlyContinue) -and (Test-Path $dockerBin)) { $env:Path += ";$dockerBin" }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Say 'Docker Desktop is not installed.'
        Write-Host 'ClinicNest server runs in Docker Desktop (free for clinics under 250 staff and USD 10 million revenue).'
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Fail 'install Docker Desktop from https://www.docker.com/products/docker-desktop/ , open it once, then run this again.'
        }
        $answer = Ask 'Install Docker Desktop now? Windows asks for administrator permission. [Y/n]' 'y'
        if ($answer -match '^[nN]') { Fail 'Docker Desktop is needed.' }
        & winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { Fail 'Docker Desktop could not be installed.' }
        Write-Host ''
        Write-Host 'Docker Desktop is installed. Restart Windows if it asks, open Docker Desktop once and accept its terms,' -ForegroundColor Yellow
        Write-Host 'then run the same command again.' -ForegroundColor Yellow
        return
    }
    if (-not (DockerRunning)) {
        Say 'Starting Docker Desktop ...'
        $app = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
        if (Test-Path $app) { Start-Process $app }
        for ($i = 0; $i -lt 90 -and -not (DockerRunning); $i++) { Start-Sleep -Seconds 2 }
        if (-not (DockerRunning)) {
            Fail 'Docker Desktop is not running. Open it (accept its terms the first time; it may ask to install WSL), then run this again.'
        }
    }
    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) { Fail 'Docker Compose is missing - update Docker Desktop.' }

    # ------------------------------------------------------------------------------------------ files
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Push-Location $dir
    try {
        Say "ClinicNest folder: $dir"
        foreach ($f in 'docker-compose.yml', 'Caddyfile') {
            try {
                $text = (Invoke-WebRequest -UseBasicParsing -Uri "$base/docker/$f").Content
            } catch {
                Fail "could not download $base/docker/$f - check the internet connection."
            }
            if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
            if ([string]::IsNullOrWhiteSpace($text)) { Fail "$f is empty - try again later." }
            # as downloaded: Unix line ends, no byte-order mark (Docker reads them in Linux)
            [IO.File]::WriteAllText((Join-Path $dir $f), $text.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
        }

        # -------------------------------------------------------------------------------------- settings (.env)
        $envFile = Join-Path $dir '.env'
        $new = -not (Test-Path $envFile)
        if ($new) {
            $site = $env:CLINICNEST_SITE
            if (-not $site) {
                Say 'How will ClinicNest be opened?'
                Write-Host '  - Only in the clinic (same network as this computer): just press Enter.'
                Write-Host '  - From the internet too: enter the name, e.g. clinic.example.com. It must already point to this'
                Write-Host '    computer and ports 80 and 443 must be open; a free https certificate is then set up.'
                $site = Ask 'Internet name (or Enter for clinic network only)' 'none'
            }
            $site = ($site -replace '\s', '' -replace '^https?://', '' -replace '/.*$', '')
            if (-not $site -or $site -eq 'none') { $site = ':80'; $secure = 'false' } else { $secure = 'true' }

            $httpPort = if ($env:CLINICNEST_HTTP_PORT) { $env:CLINICNEST_HTTP_PORT } else { '80' }
            if ($site -eq ':80' -and $httpPort -eq '80' -and
                (Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue)) {
                $httpPort = '8080'
                Write-Host "Port 80 is used by another program on this computer: ClinicNest uses port $httpPort."
            }
            $httpsPort = if ($env:CLINICNEST_HTTPS_PORT) { $env:CLINICNEST_HTTPS_PORT } else { '443' }

            # Windows time zone -> the name Linux uses
            $tzGuess = 'Asia/Kolkata'
            $iana = $null
            try { if ([TimeZoneInfo]::TryConvertWindowsIdToIanaId([TimeZoneInfo]::Local.Id, [ref] $iana)) { $tzGuess = $iana } } catch { }
            $tz = Ask "Time zone of the clinic [$tzGuess]" $tzGuess

            $version = if ($env:CLINICNEST_VERSION) { $env:CLINICNEST_VERSION } else { 'latest' }
            $code = '{0}-{1}-{2}-{3}' -f (Random 4), (Random 4), (Random 4), (Random 4)
            $lines = @(
                "# ClinicNest server settings - created by install-server.ps1 on $(Get-Date -Format yyyy-MM-dd). Keep this file private.",
                '# After a change: docker compose up -d (in this folder)',
                "CLINICNEST_DB_PASSWORD=$(Random 32)",
                '# needed once, for the first-run setup in the browser',
                "CLINICNEST_SETUP_CODE=$code",
                '# ":80" = clinic network, plain http; a name = https from the internet',
                "CLINICNEST_SITE=$site",
                "CLINICNEST_SECURE_COOKIE=$secure",
                "CLINICNEST_HTTP_PORT=$httpPort",
                "CLINICNEST_HTTPS_PORT=$httpsPort",
                "TZ=$tz",
                "CLINICNEST_VERSION=$version",
                '# where the backups are, as shown on the screens',
                "CLINICNEST_BACKUP_FOLDER=$(Join-Path $dir 'backups')"
            )
            [IO.File]::WriteAllText($envFile, ($lines -join "`n") + "`n", (New-Object Text.UTF8Encoding $false))
        } else {
            Say "Updating (settings in $envFile are kept)."
            if ($env:CLINICNEST_VERSION) {
                $text = [IO.File]::ReadAllText($envFile) -replace '(?m)^CLINICNEST_VERSION=.*$', "CLINICNEST_VERSION=$($env:CLINICNEST_VERSION)"
                [IO.File]::WriteAllText($envFile, $text, (New-Object Text.UTF8Encoding $false))
            }
        }
        $settings = @{}
        foreach ($line in [IO.File]::ReadAllLines($envFile)) {
            if ($line -match '^([A-Z_]+)=(.*)$') { $settings[$Matches[1]] = $Matches[2] }
        }
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'data'), (Join-Path $dir 'backups') | Out-Null

        # -------------------------------------------------------------------------------------- start
        Say 'Downloading ClinicNest ...'
        & docker compose pull --quiet --ignore-pull-failures
        if ($LASTEXITCODE -ne 0) { Write-Host 'Could not download the newest version - starting the version already here (if there is one).' }
        Say 'Starting ...'
        & docker compose up -d --remove-orphans
        if ($LASTEXITCODE -ne 0) { Fail 'could not start (docker compose logs app shows why).' }

        $port = $settings['CLINICNEST_HTTP_PORT']
        if (-not $port) { $port = '80' }
        $code = 0
        for ($i = 0; $i -lt 90; $i++) {
            $code = Status "http://127.0.0.1:$port/"
            if ($code -ne 0 -and $code -ne 502 -and $code -ne 503) { break }
            Start-Sleep -Seconds 2
        }
        if ($code -eq 0 -or $code -eq 502 -or $code -eq 503) { Fail "ClinicNest did not answer. See: cd `"$dir`"; docker compose logs app" }

        # -------------------------------------------------------------------------------------- done
        Say 'ClinicNest is running.'
        $site = $settings['CLINICNEST_SITE']
        if ($site -and $site -ne ':80') {
            Write-Host "Open:  https://$site"
        } else {
            $suffix = if ($port -eq '80') { '' } else { ":$port" }
            $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
                    $_.InterfaceAlias -notmatch 'Loopback|vEthernet|WSL|Docker|VirtualBox|VMware' -and
                    $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } | ForEach-Object { $_.IPAddress })
            foreach ($ip in $ips) { Write-Host "Open on a computer in the clinic:  http://$ip$suffix" }
            if (-not $ips) { Write-Host "Open on a computer in the clinic:  http://<this computer's address>$suffix" }
        }
        if ($new) {
            Write-Host ''
            Write-Host "Setup code (asked once, at the first-run setup):  $($settings['CLINICNEST_SETUP_CODE'])" -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host "Backups: ClinicNest makes them itself, into $(Join-Path $dir 'backups') - copy that folder to another"
        Write-Host 'place regularly (set a backup password in Settings -> Backup so the copies are encrypted).'
        Write-Host 'Update later: run this command again.'
        Write-Host ''
        Write-Host 'Windows: ClinicNest runs while Docker Desktop runs. In Docker Desktop -> Settings -> General, keep'
        Write-Host '"Start Docker Desktop when you sign in" on; this computer must stay on and signed in, without sleep.'
        Write-Host 'If other computers cannot open it: Windows Security -> Firewall -> Allow an app through firewall ->'
        Write-Host 'tick "Private" for Docker Desktop Backend.'
    } finally {
        Pop-Location
    }
}
