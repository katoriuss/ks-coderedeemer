# Kingshot Gift Code Redeemer

`Redeem-Code.ps1` is a PowerShell script for redeeming Kingshot gift codes for one player or a list of players. You can provide a code yourself or have the script fetch active codes from [kingshot.net](https://kingshot.net/gift-codes). Redemption results are written to the console and a log file, while completed redemptions are recorded locally to avoid unnecessary repeat requests.

## Requirements

- Windows PowerShell or PowerShell 7
- An internet connection to access kingshot.net and the Kingshot gift-code service
- A valid Kingshot player ID (FID); provide a kingdom ID (KID) when needed

Run the examples below from the directory containing `Redeem-Code.ps1`, or specify the script's full path.

## Quick start

Fetch all active codes and redeem them for every player listed in `playerIDs.csv`:

```powershell
.\Redeem-Code.ps1 -Csv .\playerIDs.csv -RedeemAll
```

List codes currently shown as active on kingshot.net:

```powershell
.\Redeem-Code.ps1 -ListCodes
```

Redeem one code for the players in the default `Data\playerIDs.csv` file:

```powershell
.\Redeem-Code.ps1 -Code ABC123
```

Redeem one code for a single player without using a CSV:

```powershell
.\Redeem-Code.ps1 -PlayerId 123456789 -Kingdom 123 -Code ABC123
```

Fetch active codes and redeem them for every player in the default CSV:

```powershell
.\Redeem-Code.ps1 -Kingdom 123 -RedeemAll
```

Fetch active codes and redeem them for just one player:

```powershell
.\Redeem-Code.ps1 -PlayerId 123456789 -Kingdom 123 -RedeemAll
```

## Parameters

| Parameter | Description |
| --- | --- |
| `-Csv` | A CSV file path or a directory containing CSV files. The special value `*.csv` loads all CSV files from the script's `Data` directory. Defaults to `Data\playerIDs.csv`. Ignored when `-PlayerId` is supplied. |
| `-Code` | Redeem this gift code. Required unless `-RedeemAll` or `-ListCodes` is used. |
| `-PlayerId` | Redeem for this single player ID instead of loading players from CSV. The value must contain digits only. |
| `-Kingdom` | Default kingdom ID for CSV entries that do not specify one. For a single `-PlayerId`, the kingdom is included in the redemption request when supplied. |
| `-Delay` | Delay, in seconds, between redemption requests. Defaults to `5`. |
| `-ListCodes` | Fetch and display active codes from kingshot.net, then exit without redeeming. |
| `-RedeemAll` | Fetch active codes from kingshot.net and redeem each code for the selected player or players. |

`-PlayerId` and `-Csv` are alternative ways to select players. If `-PlayerId` is provided, the CSV is not read. `-ListCodes` takes precedence and exits after listing codes.

## Player CSV format

By default, the script reads `Data\playerIDs.csv`, relative to the script file. The file can contain one player per line:

```text
123456789,123
234567890,123,Player Two
```

The columns are:

1. **FID** — numeric player ID
2. **KID** — optional numeric kingdom ID
3. **Name** — optional display name; any remaining comma-separated fields are included in the name

An FID-only line is also accepted:

```text
123456789
```

When an entry has no KID, provide `-Kingdom` for the run; otherwise that entry is skipped. Lines beginning with `#` and blank lines are ignored. Do not include a header row. Although the reader accepts comma-separated fields, use one player per line to avoid ambiguity between a list of IDs and an FID/KID pair.

### Selecting CSV files

Use the default file:

```powershell
.\Redeem-Code.ps1 -Code ABC123
```

Specify a file:

```powershell
.\Redeem-Code.ps1 -Csv '.\Data\friends.csv' -Kingdom 123 -Code ABC123
```

Load every CSV file in a directory:

```powershell
.\Redeem-Code.ps1 -Csv '.\Data' -Kingdom 123 -Code ABC123
```

Load every CSV file in the script's `Data` directory:

```powershell
.\Redeem-Code.ps1 -Csv '*.csv' -Kingdom 123 -Code ABC123
```

## Redemption examples

Use a custom delay between player requests:

```powershell
.\Redeem-Code.ps1 -Csv '.\Data\playerIDs.csv' -Kingdom 123 -Code ABC123 -Delay 2
```

Redeem one code for several CSV files:

```powershell
.\Redeem-Code.ps1 -Csv '.\Data' -Kingdom 123 -Code ABC123
```

Redeem a manually specified code for one player. `-Kingdom` is optional for a direct player ID, but should be supplied if the redemption service requires it:

```powershell
.\Redeem-Code.ps1 -PlayerId 123456789 -Code ABC123
```

## Redemption behavior and records

- Active codes are fetched from the active-code section of kingshot.net. If the site is unavailable or its page layout changes, the script may not find any codes.
- Bulk redemption (`-RedeemAll`) pauses for 60 seconds between codes. The `-Delay` value controls the pause between player requests.
- Failed requests and server retry responses are retried up to three times, with a five-second pause between attempts.
- Redemption history is stored in `Data\redemption_history.json`. Successful, already-redeemed, and same-type-exchange responses are recorded. Later runs skip a player/code pair already present in this history.
- Text logs are written to `Logs\redeemed_codes-yyyyMMdd-HHmm.log` and also displayed in the console.
- A code reported as expired or at its claim limit stops processing that code. During `-RedeemAll`, the script moves on to the next code.

Common redemption results:

| Result | Meaning |
| --- | --- |
| `SUCCESS` | The code was redeemed successfully. |
| `RECEIVED` | The player has already redeemed the code. |
| `SAME TYPE EXCHANGE` | The game accepted the redemption as a same-type exchange. |
| `TIME ERROR` | The code has expired. |
| `USED` | The code has reached its claim limit. |
| `TIMEOUT RETRY` | The server requested that the script retry the request. |

The `Data` and `Logs` directories are created beside the script as needed. Keep the history file if you want skip tracking between runs; remove or edit it only if you intentionally want to change that local behavior.

## Troubleshooting

- **No CSV files found:** Check the `-Csv` path, or create `Data\playerIDs.csv` for the default input.
- **Player skipped because no kingdom was provided:** Add a KID to that CSV row or pass `-Kingdom`.
- **Invalid player ID:** FIDs supplied with `-PlayerId` must contain digits only.
- **No active codes found:** Confirm internet access and check the active codes page. The site may have no active codes, or its layout may have changed.
- **A redemption is skipped as already recorded:** The FID/code pair is present in `Data\redemption_history.json`.
- **Request failures:** Check connectivity and retry later. The script logs request failures and makes a limited number of retry attempts.

## Related project

The script is a PowerShell port based on [justncodes/ks-giftcode](https://github.com/justncodes/ks-giftcode).
