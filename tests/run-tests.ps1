<#
.SYNOPSIS
  Tests for setup.ps1. Every case runs the real script in a child process against a
  throwaway sandbox (-CodeUserDir / -HomeDir / -NoPath), so real config is never touched.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
#>
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Setup = Join-Path $RepoRoot 'setup.ps1'
$script:Failures = 0
$script:Passes = 0

# ---- helpers -----------------------------------------------------------------

function New-Sandbox {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("hs-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $sb = [PSCustomObject]@{
        Root    = $root
        CodeDir = Join-Path $root 'Code\User'
        HomeDir = Join-Path $root 'home'
    }
    New-Item -ItemType Directory -Force -Path $sb.HomeDir | Out-Null
    return $sb
}

function Remove-Sandbox($sb) {
    if (-not (Test-Path $sb.Root)) { return }
    # Remove links on their own first, so cleanup can never recurse into a link target (the repo).
    Get-ChildItem -Path $sb.Root -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object { [IO.Directory]::Delete($_.FullName) }
    Remove-Item -Path $sb.Root -Recurse -Force
}

function Invoke-Setup($sb, [string[]]$Extra = @()) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Setup `
        -CodeUserDir $sb.CodeDir -HomeDir $sb.HomeDir -NoPath @Extra 2>&1 | Out-String
    return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

function Assert([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:Passes++ }
    else { $script:Failures++; Write-Host "    FAIL: $Message" -ForegroundColor Red }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    Write-Host "- $Name"
    $sb = New-Sandbox
    try { & $Body $sb }
    catch { $script:Failures++; Write-Host "    ERROR: $_" -ForegroundColor Red }
    finally { Remove-Sandbox $sb }
}

# ---- guard: snapshot real config so we can prove it was not touched ----------

function Get-RealState {
    $files = @(
        (Join-Path $env:APPDATA 'Code\User\settings.json'),
        (Join-Path $env:APPDATA 'Code\User\tasks.json'),
        (Join-Path $env:APPDATA 'Code\User\snippets\d2.json')
    )
    $stamps = foreach ($f in $files) { if (Test-Path $f) { "$f=" + (Get-Item $f).LastWriteTimeUtc.Ticks } else { "$f=absent" } }
    $stamps += "PATH=" + [Environment]::GetEnvironmentVariable('Path', 'User')
    return ($stamps -join "`n")
}
$realBefore = Get-RealState

# ---- cases -------------------------------------------------------------------

Write-Host "setup.ps1 tests (sandboxed)`n"

Test-Case 'smoke: empty sandbox gets settings, tasks, theme link and wrapper' {
    param($sb)
    $r = Invoke-Setup $sb
    Assert ($r.ExitCode -eq 0) "exit code 0 (got $($r.ExitCode))`n$($r.Output)"
    Assert (Test-Path (Join-Path $sb.CodeDir 'settings.json')) 'settings.json created in sandbox'
    Assert (Test-Path (Join-Path $sb.CodeDir 'tasks.json')) 'tasks.json created in sandbox'
    $link = Get-Item (Join-Path $sb.HomeDir '.d2\themes') -Force -ErrorAction SilentlyContinue
    Assert ($null -ne $link -and $link.LinkType -eq 'Junction') '.d2\themes is a junction'
    Assert (Test-Path (Join-Path $sb.HomeDir '.d2\themes\theme.d2')) 'junction resolves to repo d2/'
    Assert (Test-Path (Join-Path $sb.HomeDir '.d2\bin\d2t.cmd')) 'd2t.cmd installed'
    Assert ($r.Output -match 'NoPath') 'PATH step reported as skipped'
}

$Fixtures = Join-Path $PSScriptRoot 'fixtures'
function Copy-Fixture($sb, [string]$Fixture, [string]$As) {
    New-Item -ItemType Directory -Force -Path $sb.CodeDir | Out-Null
    Copy-Item (Join-Path $Fixtures $Fixture) (Join-Path $sb.CodeDir $As)
}
function Read-Json([string]$Path) { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) }
function Get-Backups($sb) { return @(Get-ChildItem -Path $sb.CodeDir -Filter '*.bak-*' -ErrorAction SilentlyContinue) }

Test-Case 'jsonc: comments, trailing commas, globs and // in strings all survive' {
    param($sb)
    Copy-Fixture $sb 'settings-jsonc.json' 'settings.json'
    $r = Invoke-Setup $sb
    Assert ($r.ExitCode -eq 0) "exit code 0 (got $($r.ExitCode))`n$($r.Output)"
    $s = Read-Json (Join-Path $sb.CodeDir 'settings.json')
    Assert ($s.'editor.fontSize' -eq 14) 'editor.fontSize kept'
    Assert ($s.'search.exclude'.'dist/*.map' -eq $true) 'search.exclude "dist/*.map" kept'
    Assert ($s.'files.exclude'.'**/.git' -eq $true -and $s.'files.exclude'.'out/**' -eq $true) 'files.exclude globs kept'
    Assert ($s.'my.note' -eq 'see // docs') '"see // docs" string intact'
    Assert ($s.'my.url' -eq 'https://example.com/a/*b') 'URL with /* intact'
    Assert ($s.'my.quote' -eq 'it''s "quoted" \ back') 'escaped quotes and backslash intact'
    Assert ((@($s.'my.single').Count -eq 1) -and (@($s.'my.single')[0] -eq 'only')) 'one-element array kept as array'
    Assert ($null -ne $s.PSObject.Properties['my.empty'] -and @($s.'my.empty').Count -eq 0) 'empty array kept'
    Assert ($null -ne $s.PSObject.Properties['my.emptyObj']) 'empty object kept'
    Assert ($s.'my.nested'.a[2].PSObject.Properties['b'] -and $null -eq $s.'my.nested'.a[2].b) 'nested null kept'
    $themes = @($s.'markdown.marp.themes')
    Assert ($themes[0] -eq 'C:/other/custom.css') 'unrelated Marp theme kept first'
    Assert (-not ($themes -match '/old/place/')) 'stale phd.css path from old location replaced'
    Assert ($themes.Count -eq 4) "4 themes total: custom + phd + work + classic (got $($themes.Count))"
    Assert (-not ($themes -match '(dtp|splice).css$')) 'retired dtp/splice entries removed'
    Assert ((Get-Backups $sb).Count -eq 1) 'exactly one backup of settings.json'
}

Test-Case 'format: written JSON uses 2-space indentation and readable characters' {
    param($sb)
    Copy-Fixture $sb 'settings-jsonc.json' 'settings.json'
    $r = Invoke-Setup $sb
    Assert ($r.ExitCode -eq 0) "exit code 0`n$($r.Output)"
    $text = [IO.File]::ReadAllText((Join-Path $sb.CodeDir 'settings.json'))
    $lines = $text.TrimEnd("`n").Split("`n")
    $bad = @($lines | Where-Object { $_ -notmatch '^(  )*\S' -or $_ -match '\S {2,}' -or $_ -match "`r" })
    Assert ($bad.Count -eq 0) "every line is 2-space indented, no runs of spaces, LF endings (bad: $($bad[0]))"
    Assert ($text -match '(?m)^  "editor\.fontSize": 14,$') 'top-level key formatted as  "key": value,'
    Assert ($text.Contains('"my.quote": "it''s \"quoted\" \\ back"')) "apostrophe written as ' (not '), escapes kept"
    Assert ($text.Contains('"my.empty": []') -and $text.Contains('"my.emptyObj": {}')) 'empty array/object written inline'
    Assert ($text -match '(?s)"my\.single": \[\n    "only"\n  \]') 'arrays expanded one item per line'
    Assert ($text.EndsWith("}`n")) 'ends with newline'
}

Test-Case 'jsonc: unparseable settings.json is left byte-identical and setup exits non-zero' {
    param($sb)
    Copy-Fixture $sb 'settings-broken.json' 'settings.json'
    $p = Join-Path $sb.CodeDir 'settings.json'
    $hashBefore = (Get-FileHash $p).Hash
    $r = Invoke-Setup $sb
    Assert ($r.ExitCode -ne 0) 'non-zero exit code'
    Assert ((Get-FileHash $p).Hash -eq $hashBefore) 'settings.json byte-identical'
    Assert ($r.Output -match [regex]::Escape($p)) 'error names the file'
    Assert ((Get-Backups $sb).Count -eq 0) 'no backup written for an untouched file'
    Assert (Test-Path (Join-Path $sb.CodeDir 'tasks.json')) 'other steps still ran (tasks.json created)'
}

Test-Case 'tasks: user tasks survive in order; house-style tasks replaced, not duplicated' {
    param($sb)
    Copy-Fixture $sb 'tasks-jsonc.json' 'tasks.json'
    $r = Invoke-Setup $sb
    Assert ($r.ExitCode -eq 0) "exit code 0 (got $($r.ExitCode))`n$($r.Output)"
    $t = Read-Json (Join-Path $sb.CodeDir 'tasks.json')
    $labels = @($t.tasks | ForEach-Object { $_.label })
    Assert ($labels[0] -eq 'my build' -and $labels[1] -eq 'my test') "user tasks first, in order (got: $($labels -join ' | '))"
    Assert (@($t.tasks[0].args).Count -eq 1 -and @($t.tasks[0].problemMatcher)[0] -eq '$gcc') 'one-element arrays in user task kept'
    Assert (@($labels | Where-Object { $_ -like 'house-style:*' }).Count -eq 3) 'exactly three house-style tasks (no duplicates)'
}

Test-Case 'idempotent: second run writes nothing and makes no new backups' {
    param($sb)
    Copy-Fixture $sb 'settings-jsonc.json' 'settings.json'
    Copy-Fixture $sb 'tasks-jsonc.json' 'tasks.json'
    $r1 = Invoke-Setup $sb
    Assert ($r1.ExitCode -eq 0) "first run exit 0`n$($r1.Output)"
    $files = @(@('settings.json', 'tasks.json', 'snippets\d2.json') | ForEach-Object { Join-Path $sb.CodeDir $_ }) +
             @(@('d2t.ps1', 'd2t.cmd') | ForEach-Object { Join-Path $sb.HomeDir ".d2\bin\$_" })
    $stamps = $files | ForEach-Object { (Get-Item $_).LastWriteTimeUtc.Ticks }
    $backups = (Get-Backups $sb).Count
    Start-Sleep -Milliseconds 1100
    $r2 = Invoke-Setup $sb
    Assert ($r2.ExitCode -eq 0) "second run exit 0`n$($r2.Output)"
    $stamps2 = $files | ForEach-Object { (Get-Item $_).LastWriteTimeUtc.Ticks }
    Assert ((@($stamps) -join ',') -eq (@($stamps2) -join ',')) 'no file rewritten on second run'
    Assert ((Get-Backups $sb).Count -eq $backups) 'no new backups on second run'
    Assert ($r2.Output -match 'already up to date') 'second run reports up to date'
    # (Copy-Item keeps the source timestamp, so check the report rather than mtimes for the wrapper)
    Assert ($r2.Output -match 'd2t wrapper already up to date') 'wrapper not re-copied on second run'
    Assert (@(Get-ChildItem $sb.CodeDir -Filter '*.tmp-*').Count -eq 0) 'no temp files left behind'
}

Test-Case 'settings: D2.previewLayout set, stray rev-1 d2.layout removed' {
    param($sb)
    New-Item -ItemType Directory -Force -Path $sb.CodeDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $sb.CodeDir 'settings.json'), '{ "a": 1, "d2.layout": "tala", "z": 2 }')
    $r = Invoke-Setup $sb
    Assert ($r.ExitCode -eq 0) "exit code 0`n$($r.Output)"
    $s = Read-Json (Join-Path $sb.CodeDir 'settings.json')
    Assert ($s.'D2.previewLayout' -eq 'tala') 'D2.previewLayout = tala'
    Assert ($null -eq $s.PSObject.Properties['d2.layout']) 'd2.layout removed'
    Assert ($s.'markdown.marp.enableHtml' -eq $true) 'markdown.marp.enableHtml = true'
}

# Marp for VS Code only loads themes from https URLs or paths inside the open workspace,
# so markdown.marp.themes gets raw.githubusercontent.com URLs derived from the git remote.
function Get-SetupThemes($sb, [string[]]$Extra) {
    $r = Invoke-Setup $sb $Extra
    $s = Read-Json (Join-Path $sb.CodeDir 'settings.json')
    return [PSCustomObject]@{ ExitCode = $r.ExitCode; Output = $r.Output; Themes = (@($s.'markdown.marp.themes') -join '|') }
}
function Join-Themes([string]$Base) { (@('phd', 'work', 'classic') | ForEach-Object { "$Base/$_.css" }) -join '|' }

Test-Case 'marp themes: https URLs from the GitHub remote (https and ssh forms), override, fallback' {
    param($sb)
    $raw = 'https://raw.githubusercontent.com/someone/house-style/main/themes'
    $r = Get-SetupThemes $sb @('-GitRemoteUrl', 'https://github.com/someone/house-style.git')
    Assert ($r.ExitCode -eq 0) "exit code 0`n$($r.Output)"
    Assert ($r.Themes -eq (Join-Themes $raw)) "https remote -> raw URLs (got $($r.Themes))"
    $r = Get-SetupThemes $sb @('-GitRemoteUrl', 'git@github.com:someone/house-style.git')
    Assert ($r.Themes -eq (Join-Themes $raw)) "ssh remote -> raw URLs (got $($r.Themes))"
    $r = Get-SetupThemes $sb @('-GitRemoteUrl', 'https://github.com/someone/house-style')
    Assert ($r.Themes -eq (Join-Themes $raw)) "remote without .git -> raw URLs (got $($r.Themes))"
    $r = Get-SetupThemes $sb @('-GitRemoteUrl', 'https://github.com/someone/house-style.git', '-ThemeBaseUrl', 'https://example.test/t/')
    Assert ($r.Themes -eq (Join-Themes 'https://example.test/t')) "-ThemeBaseUrl wins, trailing / trimmed (got $($r.Themes))"
    $r = Get-SetupThemes $sb @('-GitRemoteUrl', 'https://gitlab.example/x/y.git')
    Assert ($r.ExitCode -eq 0) 'non-GitHub remote still exits 0'
    Assert ($r.Themes -eq (Join-Themes ($RepoRoot.Replace('\', '/') + '/themes'))) "non-GitHub remote falls back to local paths (got $($r.Themes))"
    Assert ($r.Output -match '\[!\].*preview') 'non-GitHub remote warns that live preview will not show the themes'
}

Test-Case 'tasks: absolute wrapper command, themed and pinned Marp export' {
    param($sb)
    $r = Invoke-Setup $sb
    Assert ($r.ExitCode -eq 0) "exit code 0`n$($r.Output)"
    $t = Read-Json (Join-Path $sb.CodeDir 'tasks.json')
    $d2 = $t.tasks | Where-Object { $_.label -eq 'house-style: Export D2 to SVG (Tala + Arial)' }
    $marp = $t.tasks | Where-Object { $_.label -eq 'house-style: Export Marp Deck to PDF' }
    Assert ($null -ne $d2 -and $null -ne $marp) 'both house-style tasks present with spec labels'
    Assert ($d2.command -eq (Join-Path $sb.HomeDir '.d2\bin\d2t.cmd')) "D2 task command is absolute d2t.cmd (got $($d2.command))"
    Assert ((@($d2.args) -join ' ') -eq '${file} ${fileDirname}/${fileBasenameNoExtension}.svg') 'D2 task args'
    $a = @($marp.args)
    Assert ($a -contains '@marp-team/marp-cli@4.5.1') 'marp-cli pinned to 4.5.1'
    $i = [array]::IndexOf($a, '--theme-set')
    Assert ($i -ge 0 -and $a[$i + 1] -eq ($RepoRoot.Replace('\', '/') + '/themes')) "--theme-set points at repo themes (got $($a -join ' '))"
    Assert ($a -contains '--pdf' -and $a -contains '--allow-local-files') 'pdf flags kept'
    # The user's default terminal may be Git Bash, which eats the backslashes in the command and ${file}.
    # Live preview: d2t --watch on the open file (Tala via d2t's default, so no --layout), as a background task
    $pv = $t.tasks | Where-Object { $_.label -eq 'house-style: Preview D2 (live, Tala + Arial)' }
    Assert ($null -ne $pv) 'preview task present'
    if ($null -ne $pv) {
        Assert ($pv.command -eq $d2.command) 'preview task uses the same absolute d2t.cmd'
        Assert ((@($pv.args) -join ' ') -eq '--watch ${file} ${fileDirname}/${fileBasenameNoExtension}.svg') "preview args (got $(@($pv.args) -join ' '))"
        Assert (-not ((@($pv.args) -join ' ') -match '--layout|-l ')) 'preview passes no --layout (d2t defaults to Tala)'
        Assert ($pv.isBackground -eq $true) 'preview is a background task'
        $bg = $pv.problemMatcher.background
        $pat = $pv.problemMatcher.pattern
        # Lines as d2 v0.9.0 prints them in --watch mode
        Assert ('info: compiling pipeline.d2...' -match $bg.beginsPattern) 'background beginsPattern matches d2 "compiling" line'
        Assert ('info: detected change in pipeline.d2: recompiling...' -match $bg.beginsPattern) 'beginsPattern matches the recompile-on-save line'
        Assert ('success: successfully compiled pipeline.d2 to C:/x/pipeline.svg in 51ms' -match $bg.endsPattern) 'endsPattern matches a successful compile'
        $errLine = 'err: failed to compile bad.d2: C:\x\bad.d2:1:1: connection missing destination'
        Assert ($errLine -match $bg.endsPattern) 'endsPattern matches a failed compile'
        $m = [regex]::Match($errLine, $pat.regexp)
        Assert ($m.Success -and $m.Groups[$pat.file].Value -eq 'C:\x\bad.d2' -and $m.Groups[$pat.line].Value -eq '1' -and $m.Groups[$pat.message].Value -eq 'connection missing destination') 'error pattern extracts file, line and message'
    }
    foreach ($task in @($d2, $marp, $pv)) {
        if ($null -eq $task) { continue }
        Assert ($task.options.shell.executable -eq 'cmd.exe' -and (@($task.options.shell.args) -join ' ') -eq '/d /c') "$($task.label): pins cmd.exe as its shell"
    }
}

# ---- d2t wrapper (via d2t.cmd, as the VS Code task runs it) -------------------
# A stub d2.cmd first on PATH records the arguments the wrapper passes.
function Get-D2tArgs($sb, [string[]]$D2tArgs, [string]$D2Layout = $null) {
    $stub = Join-Path $sb.Root 'stub'
    New-Item -ItemType Directory -Force -Path $stub | Out-Null
    $argsFile = Join-Path $stub 'args.txt'
    Set-Content -Path (Join-Path $stub 'd2.cmd') -Value "@echo %* > `"$argsFile`"" -Encoding ASCII
    $oldPath = $env:Path; $oldLayout = $env:D2_LAYOUT
    try {
        $env:Path = "$stub;$oldPath"
        $env:D2_LAYOUT = $D2Layout
        & (Join-Path $RepoRoot 'd2\d2t.cmd') @D2tArgs *> $null
    } finally { $env:Path = $oldPath; $env:D2_LAYOUT = $oldLayout }
    return ([IO.File]::ReadAllText($argsFile)).Trim()
}

Test-Case 'd2t.cmd/ps1: Tala by default; --layout / -l / D2_LAYOUT override it' {
    param($sb)
    $a = Get-D2tArgs $sb @('in.d2', 'out.svg')
    Assert ($a -match '--layout tala') "default adds --layout tala (got: $a)"
    Assert ($a -match '--font-regular \S*arial\.ttf') "Arial font flags added (got: $a)"
    Assert ($a.EndsWith('in.d2 out.svg')) "user args passed through last (got: $a)"
    $a = Get-D2tArgs $sb @('--layout', 'elk', 'in.d2', 'out.svg')
    Assert ($a -notmatch 'tala') "--layout elk respected (got: $a)"
    $a = Get-D2tArgs $sb @('--layout=elk', 'in.d2', 'out.svg')
    Assert ($a -notmatch 'tala') "--layout=elk respected (got: $a)"
    $a = Get-D2tArgs $sb @('-l', 'elk', 'in.d2', 'out.svg')
    Assert ($a -notmatch 'tala') "-l elk respected (got: $a)"
    $a = Get-D2tArgs $sb @('in.d2', 'out.svg') 'elk'
    Assert ($a -notmatch '--layout') "D2_LAYOUT=elk respected (got: $a)"
}

Test-Case 'd2t.cmd/ps1: real render embeds Arial' {
    param($sb)
    if (-not (Get-Command d2 -ErrorAction SilentlyContinue)) { Write-Host '    (skipped: d2 not installed)'; return }
    $x = Join-Path $sb.Root 'x.d2'; Set-Content -Path $x -Value 'a -> b' -Encoding ASCII
    $wrapped = Join-Path $sb.Root 'wrapped.svg'; $plain = Join-Path $sb.Root 'plain.svg'
    # d2 logs to stderr; under 'Stop', Windows PowerShell 5.1 turns that into a terminating error
    $ErrorActionPreference = 'Continue'
    & (Join-Path $RepoRoot 'd2\d2t.cmd') --layout elk $x $wrapped *> $null
    & d2 --layout elk $x $plain *> $null
    $ErrorActionPreference = 'Stop'
    Assert ((Test-Path $wrapped) -and (Get-Item $wrapped).Length -gt 0) 'wrapper renders an SVG'
    Assert ((Get-FileHash $wrapped).Hash -ne (Get-FileHash $plain).Hash) 'wrapper embeds a different (Arial) font than plain d2'
}

Test-Case 'themes: terminal variants compile by absolute import; bare d2 uses Tala' {
    param($sb)
    if (-not (Get-Command d2 -ErrorAction SilentlyContinue)) { Write-Host '    (skipped: d2 not installed)'; return }
    $ErrorActionPreference = 'Continue'   # d2 logs to stderr
    $themes = ($RepoRoot.Replace('\', '/')) + '/d2'
    $svg = @{}
    foreach ($v in @('theme', 'theme-dark', 'theme-terminal', 'theme-terminal-dark', 'theme-colour', 'theme-colour-dark', 'theme-colour-terminal', 'theme-colour-terminal-dark')) {
        $f = Join-Path $sb.Root "$v.d2"
        Set-Content -Path $f -Encoding ASCII -Value "...@`"$themes/$v`"`na: Slide {class: store}`nb: Model {class: primary-solid}`na -> b`ng: Group {c: Card; d: Db {shape: cylinder}; p: Doc {shape: page}}"
        & d2 $f (Join-Path $sb.Root "$v.svg") *> $null
        $svg[$v] = if (Test-Path (Join-Path $sb.Root "$v.svg")) { [IO.File]::ReadAllText((Join-Path $sb.Root "$v.svg")) } else { '' }
        Assert ($svg[$v].Length -gt 0) "$v compiles from an absolute import"
    }
    Assert ($svg['theme-terminal'] -match 'mono' -and $svg['theme-terminal-dark'] -match 'mono') 'terminal variants use a monospace font'
    Assert ($svg['theme'] -notmatch 'mono') 'base theme does not'
    # Colour variants tint an unclassed container (B4 -> primary-soft) and stroke lines in primary; base stays grey
    foreach ($v in @('theme-colour', 'theme-colour-terminal')) {
        Assert ($svg[$v] -match '#E7EEF4' -and $svg[$v] -match '#3B6EA5') "$v tints default containers and lines"
        # shapes nested in a container use AA5 / AB5 (top-level ones use AA4 / AB4)
        Assert ($svg[$v] -match 'fill="#E8F3ED" class="[^"]*fill-AA5') "$v tints nested cylinders (AA5 -> ok-soft)"
        Assert ($svg[$v] -match 'fill="#FDF5E8" class="[^"]*fill-AB5') "$v tints nested pages (AB5 -> warn-soft)"
    }
    Assert ($svg['theme-colour-terminal'] -match 'mono' -and $svg['theme-colour-terminal-dark'] -match 'mono') 'colour-terminal variants use a monospace font'
    Assert ($svg['theme-colour'] -notmatch 'mono') 'colour variant keeps Arial-style (no monospace)'
    Assert ($svg['theme'] -notmatch '#E7EEF4') 'base theme leaves default containers untinted'
    Assert ($svg['theme-colour-dark'] -ne $svg['theme-dark']) 'dark colour variant differs from dark base'
    # Bare d2 (no --layout, no D2_LAYOUT) must match an explicit --layout tala render
    $f = Join-Path $sb.Root 'theme.d2'; $oldLayout = $env:D2_LAYOUT; $env:D2_LAYOUT = $null
    & d2 $f (Join-Path $sb.Root 'bare.svg') *> $null
    & d2 --layout tala $f (Join-Path $sb.Root 'tala.svg') *> $null
    & d2 --layout elk $f (Join-Path $sb.Root 'elk.svg') *> $null
    $env:D2_LAYOUT = $oldLayout
    $h = @('bare', 'tala', 'elk') | ForEach-Object { (Get-FileHash (Join-Path $sb.Root "$_.svg")).Hash }
    Assert ($h[0] -eq $h[1]) 'bare d2 render == --layout tala render'
    Assert ($h[0] -ne $h[2]) '--layout elk still overrides the theme default'
    $ErrorActionPreference = 'Stop'
}

Test-Case 'snippets: d2theme* snippets written, user snippets kept, bodies compile' {
    param($sb)
    New-Item -ItemType Directory -Force -Path (Join-Path $sb.CodeDir 'snippets') | Out-Null
    [IO.File]::WriteAllText((Join-Path $sb.CodeDir 'snippets\d2.json'),
        "{ // mine`n  `"my box`": { `"prefix`": `"box`", `"body`": [`"x: {shape: rectangle}`"] },`n}")
    $r = Invoke-Setup $sb
    Assert ($r.ExitCode -eq 0) "exit code 0`n$($r.Output)"
    $sn = Read-Json (Join-Path $sb.CodeDir 'snippets\d2.json')
    Assert ($null -ne $sn.'my box') 'existing user snippet kept'
    $homeFwd = $sb.HomeDir.Replace('\', '/')
    $all = @($sn.PSObject.Properties | ForEach-Object { $_.Value })
    $ErrorActionPreference = 'Continue'
    foreach ($v in @('theme', 'theme-dark', 'theme-terminal', 'theme-terminal-dark', 'theme-colour', 'theme-colour-dark', 'theme-colour-terminal', 'theme-colour-terminal-dark')) {
        $s = $all | Where-Object { $_.prefix -eq ('d2' + $v) }
        Assert ($null -ne $s) "snippet with prefix d2$v exists"
        if ($null -eq $s) { continue }
        $body = @($s.body)[0]
        Assert ($body -eq "...@`"$homeFwd/.d2/themes/$v`"") "d2$v body is the quoted absolute import (got $body)"
        if (Get-Command d2 -ErrorAction SilentlyContinue) {
            $f = Join-Path $sb.Root "$v.d2"
            Set-Content -Path $f -Encoding ASCII -Value "$body`na -> b"
            & d2 $f (Join-Path $sb.Root "$v.svg") *> $null
            Assert (Test-Path (Join-Path $sb.Root "$v.svg")) "d2$v snippet body compiles via the sandbox .d2\themes junction"
        }
    }
    $ErrorActionPreference = 'Stop'
    Assert ($r.Output -match [regex]::Escape("...@`"$homeFwd/.d2/themes/theme`"")) 'setup prints the exact import line'
    Assert ($r.Output -notmatch '@~/') 'setup no longer advertises the broken ~ import'
}

# Run setup with a modified PATH (stub dirs prepended, dirs holding `code` removed).
function Invoke-SetupWithPath($sb, [string[]]$Prepend = @(), [switch]$HideVSCode) {
    $old = $env:Path
    try {
        $dirs = @($old.Split(';') | Where-Object { $_ })
        if ($HideVSCode) {
            $dirs = @($dirs | Where-Object { -not (Test-Path (Join-Path $_ 'code.cmd')) -and -not (Test-Path (Join-Path $_ 'code.exe')) -and -not (Test-Path (Join-Path $_ 'code')) })
        }
        $env:Path = (@($Prepend) + $dirs) -join ';'
        $out = & "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $Setup `
            -CodeUserDir $sb.CodeDir -HomeDir $sb.HomeDir -NoPath 2>&1 | Out-String
        return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    } finally { $env:Path = $old }
}

Test-Case 'vscode missing: editor steps skipped, Code\User not created, rest still runs' {
    param($sb)
    $r = Invoke-SetupWithPath $sb -HideVSCode
    Assert ($r.ExitCode -eq 0) "exit code 0 (got $($r.ExitCode))`n$($r.Output)"
    Assert (-not (Test-Path $sb.CodeDir)) 'Code\User dir not created'
    Assert ($r.Output -match 'VS Code not found') 'warning printed'
    Assert (Test-Path (Join-Path $sb.HomeDir '.d2\themes\theme.d2')) 'themes link still created'
    Assert (Test-Path (Join-Path $sb.HomeDir '.d2\bin\d2t.cmd')) 'wrapper still installed'
}

Test-Case 'vscode present via existing User dir even without `code` on PATH' {
    param($sb)
    New-Item -ItemType Directory -Force -Path $sb.CodeDir | Out-Null
    $r = Invoke-SetupWithPath $sb -HideVSCode
    Assert ($r.ExitCode -eq 0) "exit code 0`n$($r.Output)"
    Assert (Test-Path (Join-Path $sb.CodeDir 'settings.json')) 'settings.json written'
}

Test-Case 'toolchain: old D2 without Tala gets an upgrade hint; real D2 reports OK' {
    param($sb)
    $stub = Join-Path $sb.Root 'stub'; New-Item -ItemType Directory -Force -Path $stub | Out-Null
    Set-Content -Path (Join-Path $stub 'd2.cmd') -Encoding ASCII -Value @(
        '@echo off',
        'if "%1"=="--version" (echo v0.8.0) else (echo dagre elk)')
    $r = Invoke-SetupWithPath $sb -Prepend $stub
    Assert ($r.ExitCode -eq 0) "exit code 0 with old D2 (got $($r.ExitCode))"
    Assert ($r.Output -match 'D2 v0\.8\.0 is older than 0\.9\.0') "version hint (got: $($r.Output -split "`n" | Select-String 'D2'))"
    Assert ($r.Output -match 'Tala layout engine not available') 'tala hint'
    if (Get-Command d2 -ErrorAction SilentlyContinue) {
        $r2 = Invoke-Setup $sb
        Assert ($r2.Output -match '\[OK\] D2 v\d+\.\d+\.\d+ with Tala') "real d2 reported OK (got: $($r2.Output -split "`n" | Select-String 'D2'))"
    }
}

# ---- T9: links and PATH ------------------------------------------------------
function Get-LinkTarget([string]$Path) {
    $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $i -or -not $i.LinkType) { return $null }
    return (@($i.Target)[0]).TrimEnd('\')
}
$RepoD2 = Join-Path $RepoRoot 'd2'

Test-Case 'link: junction to another dir is re-pointed; old target untouched' {
    param($sb)
    $other = Join-Path $sb.Root 'other'; New-Item -ItemType Directory -Force -Path $other | Out-Null
    Set-Content (Join-Path $other 'keep.txt') 'x'
    New-Item -ItemType Directory -Force -Path (Join-Path $sb.HomeDir '.d2') | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $sb.HomeDir '.d2\themes') -Target $other | Out-Null
    $r = Invoke-Setup $sb
    Assert ($r.ExitCode -eq 0) "exit code 0`n$($r.Output)"
    Assert ((Get-LinkTarget (Join-Path $sb.HomeDir '.d2\themes')) -eq $RepoD2) 're-pointed to repo d2'
    Assert (Test-Path (Join-Path $other 'keep.txt')) 'old target contents untouched'
}

Test-Case 'link: dangling junction (target deleted) is re-pointed' {
    param($sb)
    $other = Join-Path $sb.Root 'gone'; New-Item -ItemType Directory -Force -Path $other | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $sb.HomeDir '.d2') | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $sb.HomeDir '.d2\themes') -Target $other | Out-Null
    Remove-Item -LiteralPath $other -Force
    $r = Invoke-Setup $sb
    Assert ($r.ExitCode -eq 0) "exit code 0`n$($r.Output)"
    Assert ((Get-LinkTarget (Join-Path $sb.HomeDir '.d2\themes')) -eq $RepoD2) 're-pointed to repo d2'
}

Test-Case 'link: a real directory at .d2\themes is left alone and setup exits non-zero' {
    param($sb)
    $real = Join-Path $sb.HomeDir '.d2\themes'; New-Item -ItemType Directory -Force -Path $real | Out-Null
    Set-Content (Join-Path $real 'mine.d2') 'x'
    $r = Invoke-Setup $sb
    Assert ($r.ExitCode -ne 0) 'non-zero exit code'
    Assert ($null -eq (Get-LinkTarget $real) -and (Test-Path (Join-Path $real 'mine.d2'))) 'directory and contents untouched'
    Assert ($r.Output -match 'not a link') 'warning explains why'
    Assert (Test-Path (Join-Path $sb.CodeDir 'settings.json')) 'other steps still ran'
}

function Invoke-SetupPathFile($sb, [string]$Content) {
    $f = Join-Path $sb.Root 'userpath.txt'
    [IO.File]::WriteAllText($f, $Content)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Setup `
        -CodeUserDir $sb.CodeDir -HomeDir $sb.HomeDir -UserPathFile $f 2>&1 | Out-String
    return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $out; Path = [IO.File]::ReadAllText($f) }
}

Test-Case 'PATH: exact-entry match (case, trailing \), substring is not a match' {
    param($sb)
    $bin = Join-Path $sb.HomeDir '.d2\bin'
    $r = Invoke-SetupPathFile $sb "C:\a;$($bin.ToUpper())\;C:\b"
    Assert ($r.ExitCode -eq 0) "exit code 0`n$($r.Output)"
    Assert ($r.Path -eq "C:\a;$($bin.ToUpper())\;C:\b") 'already present (different case + trailing \): PATH unchanged'
    Assert ($r.Output -match 'already in User PATH') 'reports already present'

    $r = Invoke-SetupPathFile $sb "C:\a;$bin-old;C:\b"
    $entries = $r.Path.Split(';') | Where-Object { $_ }
    Assert ($entries -contains $bin) "substring look-alike is not a match: entry added (got $($r.Path))"
    Assert ($entries -contains "$bin-old" -and $entries[0] -eq 'C:\a') 'existing entries kept in order'
    Assert ($r.Output -match 'Restart VS Code') 'restart notice printed'

    $r2 = Invoke-SetupPathFile $sb $r.Path
    Assert ($r2.Path -eq $r.Path) 'second run leaves PATH unchanged'
}

Write-Host '- encoding: .ps1 files are ASCII (Windows PowerShell 5.1 misreads UTF-8 without a BOM)'
foreach ($f in @('setup.ps1', 'd2\d2t.ps1', 'tests\run-tests.ps1')) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $RepoRoot $f))
    $start = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $nonAscii = @($bytes[$start..($bytes.Length - 1)] | Where-Object { $_ -gt 127 }).Count
    Assert ($nonAscii -eq 0) "$f contains $nonAscii non-ASCII bytes"
}

# ---- result ------------------------------------------------------------------

Assert ((Get-RealState) -eq $realBefore) 'real VS Code config and User PATH untouched by the test run'
Assert (Test-Path (Join-Path $RepoRoot 'd2\theme.d2')) 'repo d2/ intact after sandbox cleanup'

Write-Host "`n$script:Passes passed, $script:Failures failed"
if ($script:Failures -gt 0) { exit 1 } else { exit 0 }
