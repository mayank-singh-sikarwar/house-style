<#
.SYNOPSIS
  setup.ps1 - One-step setup for house-style themes on Windows.
  Configures VS Code User Settings, D2 Tala/Arial tooling, and global export tasks.

.DESCRIPTION
  This script is idempotent and can be safely re-run at any time.
  It configures your personal environment globally so you can open any repo
  and write Marp slides and D2 diagrams without creating .vscode files in each repo.
#>

[CmdletBinding()]
param(
    # Overrides for tests: redirect every write into a sandbox.
    [string]$CodeUserDir = (Join-Path $env:APPDATA "Code\User"),
    [string]$HomeDir = $env:USERPROFILE,
    [switch]$NoPath,
    # Tests only: a text file that stands in for the User PATH (read and written instead of the real one).
    [string]$UserPathFile,
    # Base URL that holds phd.css / work.css. Default: derived from the GitHub remote.
    [string]$ThemeBaseUrl,
    # Tests only: stands in for `git remote get-url origin`.
    [string]$GitRemoteUrl
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  house-style - Personal Theme & Engine Setup       " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "Repo location: $RepoRoot`n"

$script:ExitCode = 0

# -----------------------------------------------------------------------------
# Safe JSONC handling (spec section 5.1): string-aware parse, abort on failure,
# no-op when unchanged, backup before write, atomic replace.
# -----------------------------------------------------------------------------

# Strip // and /* */ comments and trailing commas, but only outside string literals.
function Remove-JsonCSyntax([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0; $n = $Text.Length
    $inString = $false
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($inString) {
            [void]$sb.Append($c)
            if ($c -eq '\' -and $i + 1 -lt $n) { [void]$sb.Append($Text[$i + 1]); $i += 2; continue }
            if ($c -eq '"') { $inString = $false }
            $i++; continue
        }
        if ($c -eq '"') { $inString = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '*') {
            $end = $Text.IndexOf('*/', $i + 2)
            if ($end -lt 0) { throw "unterminated /* comment" }
            $i = $end + 2; continue
        }
        if ($c -eq ',') {
            # Trailing comma: next significant char (ignoring whitespace and comments) is } or ]
            $j = $i + 1
            while ($j -lt $n) {
                if ([char]::IsWhiteSpace($Text[$j])) { $j++; continue }
                if ($Text[$j] -eq '/' -and $j + 1 -lt $n -and $Text[$j + 1] -eq '/') {
                    while ($j -lt $n -and $Text[$j] -ne "`n") { $j++ }; continue
                }
                if ($Text[$j] -eq '/' -and $j + 1 -lt $n -and $Text[$j + 1] -eq '*') {
                    $e = $Text.IndexOf('*/', $j + 2); if ($e -lt 0) { break }; $j = $e + 2; continue
                }
                break
            }
            if ($j -lt $n -and ($Text[$j] -eq '}' -or $Text[$j] -eq ']')) { $i++; continue }
        }
        [void]$sb.Append($c); $i++
    }
    if ($inString) { throw "unterminated string" }
    return $sb.ToString()
}

function ConvertFrom-JsonC([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return [PSCustomObject]@{} }
    $clean = Remove-JsonCSyntax $Text
    if ([string]::IsNullOrWhiteSpace($clean)) { return [PSCustomObject]@{} }
    $parsed = ConvertFrom-Json $clean   # throws on invalid JSON
    if ($parsed -isnot [PSCustomObject]) { throw "top-level value is not a JSON object" }
    return $parsed
}

# Re-indent compact JSON with 2 spaces (Windows PowerShell 5.1's ConvertTo-Json output is ragged),
# and undo 5.1's needless ' < > & escapes. String-aware; output uses LF.
function Format-Json([string]$Compact) {
    $sb = New-Object System.Text.StringBuilder
    $decode = @{ '0027' = "'"; '003c' = '<'; '003e' = '>'; '0026' = '&' }
    $indent = 0; $inString = $false; $i = 0; $n = $Compact.Length
    while ($i -lt $n) {
        $c = $Compact[$i]
        if ($inString) {
            if ($c -eq '\' -and $i + 1 -lt $n) {
                $next = $Compact[$i + 1]
                if ($next -eq 'u' -and $i + 5 -lt $n -and $decode.ContainsKey($Compact.Substring($i + 2, 4).ToLower())) {
                    [void]$sb.Append($decode[$Compact.Substring($i + 2, 4).ToLower()]); $i += 6; continue
                }
                [void]$sb.Append($c).Append($next); $i += 2; continue
            }
            if ($c -eq '"') { $inString = $false }
            [void]$sb.Append($c); $i++; continue
        }
        switch ($c) {
            '"' { $inString = $true; [void]$sb.Append($c) }
            { $_ -eq '{' -or $_ -eq '[' } {
                $close = if ($c -eq '{') { '}' } else { ']' }
                if ($i + 1 -lt $n -and $Compact[$i + 1] -eq $close) { [void]$sb.Append("$c$close"); $i++ }
                else { $indent++; [void]$sb.Append($c).Append("`n").Append('  ' * $indent) }
            }
            { $_ -eq '}' -or $_ -eq ']' } { $indent--; [void]$sb.Append("`n").Append('  ' * $indent).Append($c) }
            ',' { [void]$sb.Append(",`n").Append('  ' * $indent) }
            ':' { [void]$sb.Append(': ') }
            default { if (-not [char]::IsWhiteSpace($c)) { [void]$sb.Append($c) } }
        }
        $i++
    }
    return $sb.ToString()
}

# Set a property, keeping its position if it already exists.
function Set-JsonProperty($Obj, [string]$Name, $Value) {
    if ($Obj.PSObject.Properties[$Name]) { $Obj.PSObject.Properties[$Name].Value = $Value }
    else { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

# Read -> mutate -> write only if changed.
# Returns 'created' | 'updated' | 'unchanged' | 'failed' | 'skipped' (VS Code not installed).
function Update-JsonFile([string]$Path, [scriptblock]$Mutate) {
    if (-not $script:VSCodePresent) { return 'skipped' }
    $exists = Test-Path -LiteralPath $Path
    $obj = [PSCustomObject]@{}
    if ($exists) {
        try {
            $raw = [IO.File]::ReadAllText($Path)
            $obj = ConvertFrom-JsonC $raw
        } catch {
            Write-Host "[x] Could not parse $Path" -ForegroundColor Red
            Write-Host "    $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    File left untouched. Fix it (or move it aside) and re-run setup." -ForegroundColor Red
            $script:ExitCode = 1
            return 'failed'
        }
    }
    $before = ConvertTo-Json -InputObject $obj -Depth 100 -Compress
    $obj = & $Mutate $obj
    $after = ConvertTo-Json -InputObject $obj -Depth 100 -Compress
    if ($exists -and $before -eq $after) { return 'unchanged' }

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($exists) {
        $backup = "$Path.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $Path -Destination $backup -Force
    }
    $tmp = "$Path.tmp-" + [guid]::NewGuid().ToString('N')
    $json = Format-Json (ConvertTo-Json -InputObject $obj -Depth 100 -Compress)
    [IO.File]::WriteAllText($tmp, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    # [NullString]::Value: a plain $null is passed to .NET as "" and File.Replace rejects it
    if ($exists) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
    if ($exists) { return 'updated' } else { return 'created' }
}

function Write-FileResult([string]$What, [string]$Path, [string]$Result) {
    switch ($Result) {
        'failed'    { }
        'skipped'   { Write-Host "[-] $What skipped (VS Code not found)" -ForegroundColor Yellow }
        'unchanged' { Write-Host "[=] $What already up to date -> $Path" -ForegroundColor Green }
        default     { Write-Host "[+] $What $Result -> $Path" -ForegroundColor Green }
    }
}

# -----------------------------------------------------------------------------
# 0. Is VS Code installed? (spec section 6) A User dir from an earlier launch, or `code` on PATH.
#    If not: skip every editor step and never create Code\User.
# -----------------------------------------------------------------------------
$script:VSCodePresent = (Test-Path -LiteralPath $CodeUserDir) -or [bool](Get-Command code -ErrorAction SilentlyContinue)
if (-not $script:VSCodePresent) {
    Write-Host "[!] VS Code not found (no $CodeUserDir and no 'code' on PATH)." -ForegroundColor Yellow
    Write-Host "    Skipping VS Code settings, tasks and snippets; re-run setup after installing VS Code." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# 1. VS Code User Settings (Global Marp & D2 themes)
# -----------------------------------------------------------------------------
$codeUserDir = $CodeUserDir
$settingsPath = Join-Path $codeUserDir "settings.json"

# Marp for VS Code only loads themes from https URLs or from paths inside the open workspace;
# an absolute local path is silently dropped. So register the GitHub raw URLs of this repo.
function Get-ThemeBaseUrl {
    if ($ThemeBaseUrl) { return $ThemeBaseUrl.TrimEnd('/') }
    $remote = $GitRemoteUrl
    if (-not $remote) {
        $ErrorActionPreference = 'Continue'
        try { $remote = (& git -C $RepoRoot remote get-url origin 2>$null | Out-String).Trim() } catch { $remote = $null }
    }
    if ($remote -match 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?/?$') {
        return "https://raw.githubusercontent.com/$($Matches[1])/$($Matches[2])/main/themes"
    }
    return $null
}
$themeBase = Get-ThemeBaseUrl
if (-not $themeBase) {
    $themeBase = (Join-Path $RepoRoot 'themes').Replace('\', '/')
    Write-Host "[!] No GitHub remote found: Marp live preview will not show the house themes (PDF export still will)." -ForegroundColor Yellow
    Write-Host "    Re-run with -ThemeBaseUrl https://<host>/<path-to>/themes" -ForegroundColor Yellow
}
$marpThemes = @('phd', 'work') | ForEach-Object { "$themeBase/$_.css" }

$result = Update-JsonFile $settingsPath {
    param($s)
    # Keep non-house themes in order; replace old phd/work paths (repo moves) and drop the retired dtp/splice themes
    $existing = @()
    if ($s.PSObject.Properties['markdown.marp.themes']) { $existing = @($s.'markdown.marp.themes') }
    $kept = @($existing | Where-Object { $_ -notmatch '(?i)(/|\\)(dtp|phd|splice|work)\.css$' })
    Set-JsonProperty $s 'markdown.marp.themes' (@($kept + $marpThemes))
    Set-JsonProperty $s 'markdown.marp.enableHtml' $true
    # D2 extension (terrastruct.d2) preview layout; 'd2.layout' was a rev-1 key no extension reads
    Set-JsonProperty $s 'D2.previewLayout' 'tala'
    $s.PSObject.Properties.Remove('d2.layout')
    return $s
}
Write-FileResult 'VS Code User Settings' $settingsPath $result

# -----------------------------------------------------------------------------
# 2. Global D2 Themes Directory Junction
# -----------------------------------------------------------------------------
$d2UserDir = Join-Path $HomeDir ".d2"
$d2ThemesJunction = Join-Path $d2UserDir "themes"
$d2Source = Join-Path $RepoRoot "d2"

if (-not (Test-Path $d2UserDir)) {
    New-Item -ItemType Directory -Path $d2UserDir -Force | Out-Null
}

# Get-Item (not Test-Path) so a dangling junction is still seen as present
$item = Get-Item -LiteralPath $d2ThemesJunction -Force -ErrorAction SilentlyContinue
if ($null -ne $item) {
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        $target = "$(@($item.Target)[0])".TrimEnd('\')   # Target is string[] in Windows PowerShell 5.1
        if ($target -ne $d2Source.TrimEnd('\')) {
            # Delete the link only. Directory.Delete (non-recursive) never enters the link target.
            [IO.Directory]::Delete($d2ThemesJunction)
            New-Item -ItemType Junction -Path $d2ThemesJunction -Target $d2Source | Out-Null
            Write-Host "[+] Re-pointed global D2 themes junction -> $d2Source (was $target)" -ForegroundColor Green
        } else {
            Write-Host "[=] Global D2 themes junction already configured:" -ForegroundColor Green
            Write-Host "    $d2ThemesJunction -> $d2Source"
        }
    } else {
        Write-Host "[x] $d2ThemesJunction exists and is not a link (a real folder or file). Leaving it untouched." -ForegroundColor Red
        Write-Host "    Move it aside and re-run setup to link it to $d2Source." -ForegroundColor Red
        $script:ExitCode = 1
    }
} else {
    New-Item -ItemType Junction -Path $d2ThemesJunction -Target $d2Source | Out-Null
    Write-Host "[+] Created global D2 themes junction:" -ForegroundColor Green
    Write-Host "    $d2ThemesJunction -> $d2Source"
}

# -----------------------------------------------------------------------------
# 3. Global d2t Wrapper & PATH Setup
# -----------------------------------------------------------------------------
$d2BinDir = Join-Path $d2UserDir "bin"
if (-not (Test-Path $d2BinDir)) {
    New-Item -ItemType Directory -Path $d2BinDir -Force | Out-Null
}

# Copy only when missing or different, so a re-run makes no writes.
$copied = 0
foreach ($w in @('d2t.ps1', 'd2t.cmd')) {
    $from = Join-Path $d2Source $w; $to = Join-Path $d2BinDir $w
    if (-not (Test-Path -LiteralPath $to) -or (Get-FileHash $from).Hash -ne (Get-FileHash $to).Hash) {
        Copy-Item -LiteralPath $from -Destination $to -Force; $copied++
    }
}
if ($copied -gt 0) { Write-Host "[+] Installed d2t compiler wrapper to $d2BinDir" -ForegroundColor Green }
else { Write-Host "[=] d2t wrapper already up to date -> $d2BinDir" -ForegroundColor Green }

# Add ~/.d2/bin to User PATH if missing. Entries are compared exactly (ignoring case and a
# trailing \), so a look-alike such as ...\.d2\bin-old does not count as present.
if ($NoPath) {
    Write-Host "[i] -NoPath: skipping User PATH update" -ForegroundColor Yellow
} else {
    if ($UserPathFile) { $userPath = if (Test-Path $UserPathFile) { [IO.File]::ReadAllText($UserPathFile) } else { '' } }
    else { $userPath = [Environment]::GetEnvironmentVariable("Path", "User") }
    if ($null -eq $userPath) { $userPath = "" }
    $want = $d2BinDir.TrimEnd('\')
    $present = @($userPath.Split(';') | Where-Object { $_.Trim().TrimEnd('\') -ieq $want }).Count -gt 0
    if ($present) {
        Write-Host "[=] $d2BinDir is already in User PATH" -ForegroundColor Green
    } else {
        $newUserPath = if ($userPath -eq '' -or $userPath.EndsWith(';')) { "$userPath$d2BinDir;" } else { "$userPath;$d2BinDir;" }
        if ($UserPathFile) { [IO.File]::WriteAllText($UserPathFile, $newUserPath) }
        else { [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User") }
        $env:Path = "$env:Path;$d2BinDir"
        Write-Host "[+] Added $d2BinDir to User PATH" -ForegroundColor Green
        Write-Host "    Restart VS Code and open terminals to pick it up (the VS Code tasks work without it)." -ForegroundColor Yellow
    }
}

# -----------------------------------------------------------------------------
# 4. VS Code User Tasks (Export SVG / PDF without CLI)
# -----------------------------------------------------------------------------
$tasksPath = Join-Path $codeUserDir "tasks.json"
$MarpCliVersion = '4.5.1'
$themeSetDir = (Join-Path $RepoRoot 'themes').Replace('\', '/')

# Pin the task shell to cmd.exe: if the user's default terminal is Git Bash, bash strips the
# backslashes from the command and ${file} ("C:Usersme.d2bind2t.cmd: command not found").
$taskShell = [PSCustomObject]@{
    shell = [PSCustomObject]@{
        executable = 'cmd.exe'
        args       = @('/d', '/c')
    }
}

# Absolute command: works in VS Code windows opened before the PATH change, and the .cmd
# shim runs d2t.ps1 with -ExecutionPolicy Bypass (PowerShell would otherwise prefer d2t.ps1).
$d2Task = [PSCustomObject]@{
    label         = "house-style: Export D2 to SVG (Tala + Arial)"
    type          = "shell"
    command       = (Join-Path $d2BinDir 'd2t.cmd')
    args          = @('${file}', '${fileDirname}/${fileBasenameNoExtension}.svg')
    options       = $taskShell
    group         = "build"
    presentation  = [PSCustomObject]@{
        reveal = "silent"
        panel  = "shared"
    }
    problemMatcher = @()
}

$marpTask = [PSCustomObject]@{
    label         = "house-style: Export Marp Deck to PDF"
    type          = "shell"
    command       = "npx"
    # --theme-set: Marp CLI does not read VS Code's markdown.marp.themes
    args          = @("--yes", "@marp-team/marp-cli@$MarpCliVersion", '${file}', "--theme-set", $themeSetDir, "--pdf", "--allow-local-files", "-o", '${fileDirname}/${fileBasenameNoExtension}.pdf')
    options       = $taskShell
    group         = "build"
    presentation  = [PSCustomObject]@{
        reveal = "silent"
        panel  = "shared"
    }
    problemMatcher = @()
}

$result = Update-JsonFile $tasksPath {
    param($t)
    $existing = @()
    if ($t.PSObject.Properties['tasks']) {
        $existing = @($t.tasks | Where-Object { "$($_.label)" -notmatch '^(house-style:|D2: Export SVG|Marp: Export)' })
    }
    if (-not $t.PSObject.Properties['version']) { Set-JsonProperty $t 'version' '2.0.0' }
    Set-JsonProperty $t 'tasks' (@($existing) + @($d2Task, $marpTask))
    return $t
}
Write-FileResult 'VS Code User Tasks' $tasksPath $result
if ($result -notin @('failed', 'skipped')) {
    Write-Host "    - 'house-style: Export D2 to SVG (Tala + Arial)'"
    Write-Host "    - 'house-style: Export Marp Deck to PDF'"
}

# -----------------------------------------------------------------------------
# 4b. D2 import snippets (spec section 5.3). D2 does not expand ~ in imports, so the
#     snippets insert a quoted absolute path for this machine.
# -----------------------------------------------------------------------------
$snippetsPath = Join-Path $codeUserDir "snippets\d2.json"
$homeFwd = $HomeDir.Replace('\', '/')
$importLine = "...@`"$homeFwd/.d2/themes/theme`""

$result = Update-JsonFile $snippetsPath {
    param($sn)
    foreach ($p in @($sn.PSObject.Properties | Where-Object { $_.Name -like 'house-style:*' })) {
        $sn.PSObject.Properties.Remove($p.Name)
    }
    foreach ($v in @('theme', 'theme-dark', 'theme-terminal', 'theme-terminal-dark')) {
        Set-JsonProperty $sn "house-style: import $v" ([PSCustomObject]@{
            prefix      = "d2$v"
            body        = @("...@`"$homeFwd/.d2/themes/$v`"")
            description = "Import the house D2 theme '$v' (absolute path for this machine)"
        })
    }
    return $sn
}
Write-FileResult 'VS Code D2 snippets' $snippetsPath $result
if ($result -notin @('failed', 'skipped')) {
    Write-Host "    - d2theme, d2theme-dark, d2theme-terminal, d2theme-terminal-dark"
}

# -----------------------------------------------------------------------------
# 5. Toolchain Sanity Check
# -----------------------------------------------------------------------------
Write-Host "`nToolchain Check:" -ForegroundColor Cyan
# D2 >= 0.9.0 bundles Tala (spec section 5.4). Hints only; never fails setup.
$MinD2 = [version]'0.9.0'
if (Get-Command d2 -ErrorAction SilentlyContinue) {
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # d2 may log to stderr
    $d2VerText = "$(& d2 --version 2>&1)".Trim()
    $layouts = "$(& d2 layout 2>&1)"
    $ErrorActionPreference = $prevEap
    $d2Ver = $null
    if ($d2VerText -match '(\d+\.\d+\.\d+)') { $d2Ver = [version]$Matches[1] }
    $hasTala = $layouts -match '(?m)\btala\b'
    if ($d2Ver -and $d2Ver -ge $MinD2 -and $hasTala) {
        Write-Host "  [OK] D2 v$d2Ver with Tala" -ForegroundColor Green
    } else {
        if (-not $d2Ver -or $d2Ver -lt $MinD2) {
            Write-Host "  [!] D2 $d2VerText is older than $MinD2 (Tala is bundled from $MinD2). Upgrade: winget upgrade Terrastruct.D2" -ForegroundColor Yellow
        }
        if (-not $hasTala) {
            Write-Host "  [!] Tala layout engine not available; d2t still works with D2_LAYOUT=elk." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  [!] D2 CLI not found. Install via: winget install Terrastruct.D2" -ForegroundColor Yellow
}

if (Get-Command npx -ErrorAction SilentlyContinue) {
    Write-Host "  [OK] npx (Node.js) is available for Marp CLI export." -ForegroundColor Green
} else {
    Write-Host "  [!] Node.js/npx not found. VS Code Marp extension preview works out of the box," -ForegroundColor Yellow
    Write-Host "      but the export task requires Node.js (winget install OpenJS.NodeJS.LTS)." -ForegroundColor Yellow
}

Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host "  Setup Complete!                                   " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "How to use in any repository without .vscode files:"
Write-Host "1. Marp Slides: add 'theme: phd' or 'theme: work' to frontmatter."
Write-Host "2. D2 Diagrams: in a .d2 file type 'd2theme' (or d2theme-dark / d2theme-terminal / d2theme-terminal-dark),"
Write-Host "   or put this line at the top:  $importLine"
Write-Host "3. Export: run 'Ctrl+Shift+P' -> 'Tasks: Run Task' -> select export task."

if ($script:ExitCode -ne 0) {
    Write-Host "`n[x] Setup finished with errors (see [x] lines above)." -ForegroundColor Red
}
exit $script:ExitCode
