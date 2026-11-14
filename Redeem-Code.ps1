<#
.SYNOPSIS
    Kingshot Gift Code Redeemer Script (PowerShell port) Version 1.0.0
.DESCRIPTION
    Reads player IDs from a CSV file (or a directory of CSVs) or from a single -PlayerId parameter,
    optionally fills in missing kingdom IDs, fetches active Kingshot gift codes from the game website,
    and redeems those codes for each player.
    Supports single-code redemption, bulk redemption of all active codes, and listing currently available
    codes without redeeming. It logs each redemption outcome and tracks redemption history for later review.
    Based on https://github.com/justncodes/ks-giftcode
.PARAMETER Csv
    Path to a CSV file, a directory containing CSV files, or "*.csv" to use
    all CSV files in the Data directory. Defaults to Data/playerIDs.csv.
.PARAMETER Code
    The gift code to redeem.
.PARAMETER PlayerId
    A single player ID to redeem for, instead of loading player IDs from a CSV file.
.PARAMETER Kingdom
    Optional default kingdom ID for player IDs that do not include one.
.EXAMPLE
    .\Redeem-Code.ps1 -Code ABC123
.EXAMPLE
    .\Redeem-Code.ps1 -Csv *.csv -Kingdom 123 -Code ABC123
.EXAMPLE
    .\Redeem-Code.ps1 -PlayerId 123456789 -Kingdom 123 -Code ABC123
.PARAMETER ListCodes
    Fetch and display currently active gift codes from kingshot.net, then exit.
.EXAMPLE
    .\Redeem-Code.ps1 -ListCodes
.PARAMETER RedeemAll
    Fetch all active gift codes from kingshot.net and redeem each one for every player in the CSV or the specified -PlayerId.
.EXAMPLE
    .\Redeem-Code.ps1 -Kingdom 123 -RedeemAll
.EXAMPLE
    .\Redeem-Code.ps1 -PlayerId 123456789 -Kingdom 123 -RedeemAll
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Csv,

    [Parameter(Mandatory = $false)]
    [string]$Code,

    [Parameter(Mandatory = $false)]
    [string]$PlayerId,

    [Parameter(Mandatory = $false)]
    [int]$Kingdom,

    [Parameter(Mandatory = $false)]
    [double]$Delay = 5,

    [Parameter(Mandatory = $false)]
    [switch]$ListCodes,
 
    [Parameter(Mandatory = $false)]
    [switch]$RedeemAll
)

# Configuration
$REDEEM_URL      = 'https://kingshot-giftcode.centurygame.com/api/gift_code'
$GiftCodesUrl    = 'https://kingshot.net/gift-codes'
$WOS_ENCRYPT_KEY = 'mN4!pQs6JrYwV9'  # The secret key
$MAX_KINGDOM_ID  = 999999
$RETRY_DELAY = 5  # Seconds between retries
$MAX_RETRIES = 3  # Max retry attempts per request

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $ScriptDir 'Data'
$LogsDir = Join-Path $ScriptDir 'Logs'
$LogFile = Join-Path $LogsDir "redeemed_codes-$((Get-Date).ToString('yyyyMMdd-HHmm')).log"
$HistoryFile = Join-Path $DataDir 'redemption_history.json'

New-Item -Path $DataDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
if (-not $Csv) {
    $Csv = Join-Path $DataDir 'playerIDs.csv'
}
if (-not (Test-Path -LiteralPath $LogsDir -PathType Container)) {
    New-Item -Path $LogsDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
}

$ResultMessages = @{
    'SUCCESS'             = 'Successfully redeemed'
    'RECEIVED'            = 'Already redeemed'
    'SAME TYPE EXCHANGE'  = 'Successfully redeemed (same type)'
    'TIME ERROR'          = 'Code has expired'
    'TIMEOUT RETRY'       = 'Server requested retry'
    'USED'                = 'Claim limit reached, unable to claim'
}

$Counters = @{
    success          = 0
    already_redeemed = 0
    errors           = 0
}

# Log messages to file and console
function Write-Log {
    param([string]$Message)

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $entry     = "$timestamp - $Message"

    Write-Host $entry

    try {
        # utf-8 with BOM to mirror the Python "utf-8-sig" behavior
        Add-Content -Path $LogFile -Value $entry -Encoding UTF8
    }
    catch {
        Write-Host "$timestamp - LOGGING ERROR: Could not write to $LogFile. Error: $_"
        Write-Host "$timestamp - ORIGINAL MESSAGE: $entry"
    }
}

# Save the local redemption history database.
function Save-RedemptionHistory {
    param([System.Collections.IDictionary]$History)

    $temporaryFile = "$HistoryFile.tmp"
    try {
        $json = if ($History.Count -eq 0) { '{}' } else { $History | ConvertTo-Json -Depth 3 }
        $json | Set-Content -LiteralPath $temporaryFile -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temporaryFile -Destination $HistoryFile -Force -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
        throw "Could not save redemption history to '$HistoryFile': $($_.Exception.Message)"
    }
}

# Load the history, migrating the original flat array format when necessary.
function Get-RedemptionHistory {
    if (-not (Test-Path -LiteralPath $HistoryFile)) {
        return @{}
    }

    try {
        $content = Get-Content -LiteralPath $HistoryFile -Raw -ErrorAction Stop
        if ($null -eq $content -or -not $content.Trim()) { return @{} }
        $history = $content | ConvertFrom-Json -ErrorAction Stop

        if ($history -is [System.Array]) {
            $groupedHistory = @{}
            foreach ($record in $history) {
                $code = "$($record.code)"
                if (-not $code) { continue }
                if (-not $groupedHistory.ContainsKey($code)) {
                    $groupedHistory[$code] = [ordered]@{ users = @() }
                }
                $groupedHistory[$code]['users'] = @($groupedHistory[$code]['users']) + [pscustomobject]@{
                    fid             = "$($record.fid)"
                    kid             = "$($record.kid)"
                    name            = $record.name
                    status          = "$($record.status)"
                    redeemed_at_utc = "$($record.redeemed_at_utc)"
                }
            }
            Save-RedemptionHistory -History $groupedHistory
            return $groupedHistory
        }

        $groupedHistory = @{}
        foreach ($codeProperty in $history.PSObject.Properties) {
            $groupedHistory[$codeProperty.Name] = [ordered]@{
                users = @($codeProperty.Value.users)
            }
        }
        return $groupedHistory
    }
    catch {
        throw "Could not read redemption history from '$HistoryFile': $($_.Exception.Message)"
    }
}

# Persist one completed redemption and its UTC timestamp.
function Add-RedemptionHistory {
    param(
        [System.Collections.IDictionary]$History,
        [string]$Fid,
        [string]$Kid,
        [string]$Name,
        [string]$Code,
        [string]$Status
    )

    if (-not $History.ContainsKey($Code)) {
        $History[$Code] = [ordered]@{ users = @() }
    }
    $History[$Code]['users'] = @($History[$Code]['users']) + [pscustomobject]@{
        fid             = $Fid
        kid             = $Kid
        name            = $Name
        status          = $Status
        redeemed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Save-RedemptionHistory -History $History

    return $History
}

function Test-RedemptionRecorded {
    param(
        [System.Collections.IDictionary]$History,
        [string]$Fid,
        [string]$Code
    )

    if (-not $History.ContainsKey($Code)) { return $false }
    return $null -ne ($History[$Code].users | Where-Object { "$($_.fid)" -eq "$Fid" } | Select-Object -First 1)
}

# Generate the sign, an MD5 hash sent with the POST payload
function ConvertTo-SignedPayload {
    param([hashtable]$Data)

    $sortedKeys = $Data.Keys | Sort-Object

    $parts = foreach ($key in $sortedKeys) {
        $value = $Data[$key]
        if ($value -is [hashtable] -or $value -is [System.Collections.IDictionary]) {
            $value = $value | ConvertTo-Json -Compress
        }
        "$key=$value"
    }
    $encoded = [string]::Join('&', $parts)

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$encoded$WOS_ENCRYPT_KEY")
        $hash  = $md5.ComputeHash($bytes)
        $sign  = -join ($hash | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $md5.Dispose()
    }

    $payload = @{ sign = $sign }
    foreach ($key in $Data.Keys) {
        $payload[$key] = $Data[$key]
    }
    return $payload
}

# Send POST and handle retries if failed
function Invoke-ApiRequest {
    param(
        [string]$Url,
        [hashtable]$Payload
    )

    $fidLabel = if ($Payload.ContainsKey('fid')) { $Payload['fid'] } else { 'N/A' }

    for ($attempt = 1; $attempt -le $MAX_RETRIES; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Post -Body $Payload `
                -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -ErrorAction Stop

            if ($response.StatusCode -eq 200) {
                try {
                    $data = $response.Content | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    Write-Log "Attempt $attempt failed for FID ${fidLabel}: JSON parse error: $_. Response text: $($response.Content.Substring(0, [Math]::Min(200, $response.Content.Length)))"
                    if ($attempt -lt $MAX_RETRIES) { Start-Sleep -Seconds $RETRY_DELAY }
                    continue
                }

                $msgContent = $data.msg
                if ($msgContent -is [string] -and ($msgContent.Trim('.') -eq 'TIMEOUT RETRY')) {
                    if ($attempt -lt $MAX_RETRIES) {
                        Write-Log "Attempt ${attempt}: Server requested retry for payload: $fidLabel"
                        Start-Sleep -Seconds $RETRY_DELAY
                        continue
                    }
                    else {
                        Write-Log "Attempt ${attempt}: Max retries reached after server requested retry for payload: $fidLabel"
                        return $data
                    }
                }

                return $data
            }

            $snippet = $response.Content
            if ($snippet.Length -gt 200) { $snippet = $snippet.Substring(0, 200) }
            Write-Log "Attempt $attempt failed for FID ${fidLabel}: HTTP $($response.StatusCode), Response: $snippet"
        }
        catch {
            Write-Log "Attempt $attempt failed for FID ${fidLabel}: RequestException: $($_.Exception.Message)"
        }

        if ($attempt -lt $MAX_RETRIES) {
            Start-Sleep -Seconds $RETRY_DELAY
        }
    }

    Write-Log "All $MAX_RETRIES attempts failed for request to $Url with FID $fidLabel."
    return $null
}

# Redeem a gift code for a player and return the response object
function Invoke-RedeemGiftCode {
    param(
        [string]$Fid,
        [string]$Cdk,
        [string]$Kid
    )

    $trimmed = "$Fid".Trim()
    if ($trimmed -notmatch '^\d+$') {
        Write-Log "Skipping invalid FID: '$Fid'"
        return @{ msg = 'Invalid FID format' }
    }
    $Fid = $trimmed

    if ($Kid -and $Kid.Trim() -match '^\d+$') {
        $Kid = $Kid.Trim()
    }
    else {
        $Kid = $null
    }

    try {
        $nowSec = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $redeemPayload = @{
            fid  = $Fid
            cdk  = $Cdk
            time = $nowSec
        }
        if ($Kid) {
            $redeemPayload.kid = $Kid
        }
        $redeemPayload = ConvertTo-SignedPayload -Data $redeemPayload
        $redeemData     = Invoke-ApiRequest -Url $REDEEM_URL -Payload $redeemPayload

        if (-not $redeemData) {
            return @{ msg = 'Redemption request failed after retries' }
        }

        return $redeemData
    }
    catch {
        Write-Log "Unexpected error during redemption for ${Fid}: $($_.Exception.Message)"
        return @{ msg = "Unexpected Error: $($_.Exception.Message)" }
    }
}

# Read player IDs, optional kingdoms, and optional player names from a CSV file.
# Supports rows like "fid", "fid,kid", or "fid,kid,name" and comma-separated player IDs on a single line.
function Read-PlayerIdsFromCsv {
    param([string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw [System.IO.FileNotFoundException]::new("File not found: $FilePath", $FilePath)
    }

    $entries = New-Object System.Collections.Generic.List[hashtable]

    try {
        $lines = Get-Content -LiteralPath $FilePath -Encoding UTF8
        $sample = ($lines | Select-Object -First 5) -join "`n"
        $format = if ($sample -match ',') { 'comma-separated' } else { 'newline' }

        Write-Log "Reading $FilePath (detected format: $format)"

        $rowNum = 0
        foreach ($line in $lines) {
            $rowNum++
            $trimmedLine = $line.Trim()
            if ([string]::IsNullOrEmpty($trimmedLine) -or $trimmedLine.StartsWith('#')) {
                continue
            }

            $fields = $trimmedLine -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if ($fields.Count -eq 0) {
                continue
            }

            if ($fields.Count -ge 2 -and $fields[0] -match '^\d+$' -and $fields[1] -match '^\d+$' -and [int]$fields[1] -le $MAX_KINGDOM_ID) {
                $playerName = $null
                if ($fields.Count -ge 3) {
                    $playerName = ($fields[2..($fields.Count - 1)] -join ',').Trim()
                    if ([string]::IsNullOrWhiteSpace($playerName)) { $playerName = $null }
                }
                $entries.Add(@{ fid = $fields[0]; kid = $fields[1]; name = $playerName })
                continue
            }

            foreach ($field in $fields) {
                if ($field -match '^\d+$') {
                    $entries.Add(@{ fid = $field; kid = $null; name = $null })
                }
                else {
                    Write-Log "Warning: Ignoring invalid entry '$field' in $FilePath on row $rowNum"
                }
            }
        }
    }
    catch [System.IO.FileNotFoundException] {
        throw
    }
    catch {
        Write-Log "Error reading or processing CSV file ${FilePath}: $($_.Exception.Message)"
        return @()
    }

    return $entries.ToArray()
}

# Scrape currently active gift codes from kingshot.net/gift-codes
function Get-ActiveGiftCodes {
    try {
        $response = Invoke-WebRequest -Uri $GiftCodesUrl `
            -UseBasicParsing `
            -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36' `
            -ErrorAction Stop
    }
    catch {
        Write-Log "Error fetching gift codes page: $($_.Exception.Message)"
        return @()
    }

    $html = $response.Content

    # The current page places active codes in a section labelled by this heading;
    # expired codes are in a separate, collapsed <details> element.
    $sectionMatch = [regex]::Match(
        $html,
        '(?is)<section\b(?=[^>]*\baria-labelledby="gift-codes-active")[^>]*>(.*?)</section>'
    )
    if (-not $sectionMatch.Success) {
        Write-Log "Could not locate 'Active Gift Codes' section on kingshot.net."
        return @()
    }
    $activeSection = $sectionMatch.Groups[1].Value

    # Active codes are rendered in <code> elements inside the active-code section.
    $codes = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($activeSection, '(?is)<code\b[^>]*>\s*([A-Za-z0-9]{3,30})\s*</code>')) {
        $code = $m.Groups[1].Value.Trim()
        if (-not $codes.Contains($code)) {
            $codes.Add($code)
        }
    }

    if ($codes.Count -eq 0) {
        Write-Log "No active gift codes found in the active-code section on kingshot.net."
    }

    return $codes.ToArray()
}

# Print summary of actions
function Write-Summary {
    Write-Log "`n=== Redemption Complete ==="
    Write-Log "Successfully redeemed: $($Counters.success)"
    Write-Log "Already redeemed: $($Counters.already_redeemed)"
    Write-Log "Errors/Failures: $($Counters.errors)"
}

# ========== Main ==========

if ($ListCodes) {
    Write-Log 'Fetching active gift codes from kingshot.net...'
    $activeCodes = Get-ActiveGiftCodes
    if ($activeCodes.Count -eq 0) {
        Write-Log 'No active codes found (or the page structure has changed).'
    }
    else {
        Write-Log "Active gift codes ($($activeCodes.Count) found):"
        foreach ($c in $activeCodes) { Write-Log "  $c" }
    }
    exit 0
}

if (-not $Code -and -not $RedeemAll) {
    Write-Log 'Error: -Code is required. Use -ListCodes to list active codes, or -RedeemAll to redeem all of them.'
    exit 1
}
$startTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
Write-Log "`n=== Starting redemption at $startTime ==="

$allPlayers = [System.Collections.Generic.List[hashtable]]::new()
if ($PSBoundParameters.ContainsKey('PlayerId')) {
    $fid = $PlayerId.Trim()
    if ($fid -notmatch '^\d+$') {
        Write-Log 'Error: -PlayerId must contain only digits.'
        exit 1
    }
    $kid = if ($PSBoundParameters.ContainsKey('Kingdom')) { $Kingdom.ToString() } else { $null }
    $allPlayers.Add(@{ fid = $fid; kid = $kid; name = $null })
    Write-Log "Using single player ID $fid"
}
else {
    # Resolve CSV input
    if ($Csv -eq '*.csv') {
        $csvFiles = Get-ChildItem -Path (Join-Path $DataDir '*.csv') -File -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName
    }
    elseif (Test-Path -LiteralPath $Csv -PathType Container) {
        $csvFiles = Get-ChildItem -Path (Join-Path $Csv '*.csv') -File -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName
    }
    else {
        $csvFiles = @($Csv)
    }

    if (-not $csvFiles -or $csvFiles.Count -eq 0) {
        Write-Log 'Error: No CSV files found.'
        exit 1
    }

    # Load and kingdom-resolve all players from every CSV file once
    foreach ($csvFile in $csvFiles) {
        try {
            $playerIds = Read-PlayerIdsFromCsv -FilePath $csvFile
            Write-Log "Loaded $($playerIds.Count) player IDs from $csvFile"
            foreach ($entry in $playerIds) {
                $fid = $entry.fid
                $kid = $entry.kid
                $name = if ($entry.ContainsKey('name')) { $entry.name } else { $null }
                if (-not $kid) {
                    if (-not $PSBoundParameters.ContainsKey('Kingdom')) {
                        if ($name) {
                            Write-Log "Warning: Skipping $name (FID $fid) - no kingdom in CSV and -Kingdom not provided."
                        }
                        else {
                            Write-Log "Warning: Skipping FID $fid - no kingdom in CSV and -Kingdom not provided."
                        }
                        continue
                    }
                    $kid = $Kingdom.ToString()
                }
                $allPlayers.Add(@{ fid = $fid; kid = $kid; name = $name })
            }
        }
        catch [System.IO.FileNotFoundException] {
            Write-Log "Error: CSV file '$csvFile' does not exist. Create and populate it with player IDs before running the script."
        }
        catch {
            Write-Log "Error processing ${csvFile}: $($_.Exception.Message)"
        }
    }
}

if ($allPlayers.Count -eq 0) {
    Write-Log 'Error: No valid player IDs loaded from any CSV file.'
    exit 1
}

try {
    $redemptionHistory = Get-RedemptionHistory
    Write-Log "Loaded $($redemptionHistory.Count) redemption history record(s) from $HistoryFile"
}
catch {
    Write-Log "Error: $($_.Exception.Message)"
    exit 1
}

# Compute display widths so result output columns align across all players.
$nameLengths = $allPlayers | ForEach-Object {
    if ($_.name) { $_.name.Length } else { 1 }
}
$fidLengths = $allPlayers | ForEach-Object { "$($_.fid)".Length }

$nameColumnWidth = [Math]::Max(4, [int](($nameLengths | Measure-Object -Maximum).Maximum))
$fidColumnWidth = [Math]::Max(3, [int](($fidLengths | Measure-Object -Maximum).Maximum))
$resultFormat = "Result: {0,-$nameColumnWidth} | FID {1,-$fidColumnWidth} | {2}"

# Determine which codes to redeem
if ($RedeemAll) {
    Write-Log 'Fetching active gift codes from kingshot.net...'
    $codesToRedeem = Get-ActiveGiftCodes
    if ($codesToRedeem.Count -eq 0) {
        Write-Log 'No active codes found. Exiting.'
        exit 0
    }
    Write-Log "Found $($codesToRedeem.Count) active code(s): $($codesToRedeem -join ', ')"
}
else {
    $codesToRedeem = @($Code)
}

# Redeem each code for every player
$codeIndex = 0
foreach ($cdk in $codesToRedeem) {
    if ($RedeemAll -and $codeIndex -gt 0) {
        Write-Log "Pausing 60s before next code to avoid rate limiting..."
        Start-Sleep -Seconds 60
    }
    $codeIndex++
    Write-Log "`n--- Code: $cdk | Players: $($allPlayers.Count) ---"
    foreach ($entry in $allPlayers) {
        $fid = $entry.fid
        $kid = $entry.kid
        $name = $entry.name

        if (Test-RedemptionRecorded -History $redemptionHistory -Fid $fid -Code $cdk) {
            $nameDisplay = if ($name) { $name } else { '-' }
            Write-Log ($resultFormat -f $nameDisplay, $fid, 'Already recorded; skipping request')
            continue
        }

        $result = Invoke-RedeemGiftCode -Fid $fid -Cdk $cdk -Kid $kid

        $rawMsg = $null
        if ($result -is [hashtable]) {
            if ($result.ContainsKey('msg')) { $rawMsg = $result['msg'] }
        }
        elseif ($result -and $result.PSObject.Properties['msg']) {
            $rawMsg = $result.msg
        }
        if (-not $rawMsg) { $rawMsg = 'Unknown error' }
        $rawMsg = "$rawMsg".Trim('.')
        $statusKey = $rawMsg.ToUpperInvariant()
        if ($statusKey -eq 'TIME EXPIRED') { $statusKey = 'TIME ERROR' }

        if ($statusKey -eq 'SUCCESS' -or $statusKey -eq 'SAME TYPE EXCHANGE' -or $statusKey -eq 'RECEIVED') {
            try {
                $redemptionHistory = Add-RedemptionHistory -History $redemptionHistory -Fid $fid -Kid $kid -Name $name -Code $cdk -Status $statusKey
            }
            catch {
                Write-Log "Error: $($_.Exception.Message)"
                Write-Summary
                exit 1
            }
        }

        $friendlyMsg = if ($ResultMessages.ContainsKey($statusKey)) { $ResultMessages[$statusKey] } else { $rawMsg }

        if ($statusKey -eq 'TIME ERROR') {
            if ($RedeemAll) { Write-Log "Code $cdk has expired. Skipping to next code."; break }
            Write-Log 'Code has expired! Script will now exit.'
            Write-Summary; exit 1
        }
        elseif ($statusKey -eq 'USED') {
            if ($RedeemAll) { Write-Log "Code $cdk claim limit reached. Skipping to next code."; break }
            Write-Log 'Claim limit reached! Script will now exit.'
            Write-Summary; exit 1
        }

        switch ($rawMsg) {
            'SUCCESS'             { $Counters.success++ }
            'SAME TYPE EXCHANGE'  { $Counters.success++ }
            'RECEIVED'            { $Counters.already_redeemed++ }
            'TIMEOUT RETRY'       { }
            default               { $Counters.errors++ }
        }

        $nameDisplay = if ($name) { $name } else { '-' }
        Write-Log ($resultFormat -f $nameDisplay, $fid, $friendlyMsg)
        if (-not $Delay) { $Delay = 1 }
        Start-Sleep -Seconds $Delay
    }
}

Write-Summary
