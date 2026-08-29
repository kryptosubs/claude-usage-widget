<#
  Claude Usage Widget - a small always-on-top Windows desktop widget that shows
  live Claude usage (5-hour session window, weekly, per-model weekly, extra usage).

  Requires nothing but Windows PowerShell 5.1 (built in). No install, no Node, no Electron.
  Reads your existing Claude Code OAuth token; never asks you to log in again.

  Usage:  right-click ClaudeUsageWidget.ps1 -> Run with PowerShell
     or:  double-click Start-Widget.vbs (no console window)
#>

[CmdletBinding()]
param(
    [int]$RefreshSeconds = 180,
    [switch]$Diagnose            # print a plain-text health report and exit
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, System.Windows.Forms

# ---------------------------------------------------------------- configuration

$Script:Root       = $PSScriptRoot
if (-not $Script:Root) { $Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$Script:StatePath  = Join-Path $Script:Root 'widget-state.json'
$Script:ClientId   = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'   # Claude Code's public OAuth client
$Script:UsageUrl   = 'https://api.anthropic.com/api/oauth/usage'
$Script:ProfileUrl = 'https://api.anthropic.com/api/oauth/profile'
# console.anthropic.com was retired and now 404s. api.anthropic.com is the live one;
# the others are kept as fallbacks in case it moves again.
$Script:TokenUrls  = @(
    'https://api.anthropic.com/v1/oauth/token',
    'https://platform.claude.com/v1/oauth/token',
    'https://console.anthropic.com/v1/oauth/token'
)
$Script:UserAgent  = 'claude-code/2.0.0'   # required: without it the endpoint uses a harsh rate-limit bucket

$Script:State = [ordered]@{
    Left           = $null
    Top            = $null
    Opacity        = 0.95
    ScaleOverride  = 'auto'   # 'auto' | 'percent' | 'fraction'
    CachedToken    = $null
    CachedExpires  = 0
    CachedRefresh  = $null    # our own rotated refresh token - see Get-AccessToken
}

function Load-State {
    if (Test-Path $Script:StatePath) {
        try {
            $j = Get-Content $Script:StatePath -Raw | ConvertFrom-Json
            foreach ($k in @($Script:State.Keys)) {
                if ($j.PSObject.Properties.Name -contains $k) { $Script:State[$k] = $j.$k }
            }
        } catch { }
    }
}
$Script:StateProtected = $false
# widget-state.json holds a refresh token, so it must not be world-readable.
# The script can live anywhere (Downloads, a shared folder), so don't rely on
# the parent directory's ACL - set an explicit owner-only rule once.
function Protect-StateFile {
    if ($Script:StateProtected) { return }
    try {
        $acl = Get-Acl -Path $Script:StatePath
        $acl.SetAccessRuleProtection($true, $false)   # stop inheriting, drop inherited entries
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        $me   = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -Path $Script:StatePath -AclObject $acl
        $Script:StateProtected = $true
    } catch { }
}

function Save-State {
    try {
        ($Script:State | ConvertTo-Json -Compress) | Set-Content -Path $Script:StatePath -Encoding UTF8
        Protect-StateFile
    } catch { }
}

# ---------------------------------------------------------------- token discovery

function Get-WindowsCredentialPaths {
    $paths = @()
    # CLAUDE_CONFIG_DIR relocates .credentials.json when set
    if ($env:CLAUDE_CONFIG_DIR) { $paths += (Join-Path $env:CLAUDE_CONFIG_DIR '.credentials.json') }
    if ($env:USERPROFILE)       { $paths += (Join-Path $env:USERPROFILE '.claude\.credentials.json') }
    return @($paths | Sort-Object -Unique)
}

function Get-WslDistros {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode   # wsl.exe -l emits UTF-16LE
        $raw = & wsl.exe -l -q 2>$null
    } catch { return @() }
    finally { try { [Console]::OutputEncoding = $prev } catch { } }
    return @($raw | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
}

# Returns every readable credentials file in the distro, as @{ Path; Json }.
# Not just the default user's: Claude Code is often run as root or another user
# inside WSL, and CLAUDE_CONFIG_DIR can move the file elsewhere entirely.
function Read-WslCredentials([string]$Distro) {
    $script = 'for c in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$HOME/.claude" /root/.claude /home/*/.claude; do ' +
              'f="$c/.credentials.json"; if [ -r "$f" ]; then echo "===$f"; cat "$f"; echo; fi; done'
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $raw = & wsl.exe -d $Distro -e bash -lc $script 2>$null
    } catch { return @() }
    finally { try { [Console]::OutputEncoding = $prev } catch { } }
    if (-not $raw) { return @() }

    $out  = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $path = $null
    $buf  = New-Object System.Text.StringBuilder
    $flush = {
        if ($path -and $buf.Length -gt 0 -and $seen.Add($path)) {
            try { $out.Add(@{ Path = $path; Json = ($buf.ToString() | ConvertFrom-Json) }) } catch { }
        }
    }
    foreach ($line in @($raw)) {
        $l = "$line"
        if ($l.StartsWith('===')) {
            & $flush
            $path = $l.Substring(3).Trim()
            $buf  = New-Object System.Text.StringBuilder
        }
        elseif ($path) { [void]$buf.Append($l) }
    }
    & $flush
    # NB: @($list) throws "Argument types do not match" on a generic List - use ToArray()
    return $out.ToArray()
}

function Read-JsonFile([string]$Path) {
    try {
        if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json) }
    } catch { }
    return $null
}

function New-CredSource($label, $obj) {
    if (-not $obj) { return $null }
    if ($obj.PSObject.Properties.Name -notcontains 'claudeAiOauth') { return $null }
    $o = $obj.claudeAiOauth
    if (-not $o -or -not $o.accessToken) { return $null }
    $exp = 0
    if ($o.PSObject.Properties.Name -contains 'expiresAt' -and $o.expiresAt) { $exp = [double]$o.expiresAt }
    $hasRefresh = ($o.PSObject.Properties.Name -contains 'refreshToken' -and $o.refreshToken)
    return @{ Label = $label; Oauth = $o; ExpiresAt = $exp; HasRefresh = $hasRefresh }
}

function Invoke-TokenRefresh([string]$RefreshToken) {
    $body = @{ grant_type = 'refresh_token'; refresh_token = $RefreshToken; client_id = $Script:ClientId } | ConvertTo-Json -Compress
    $last = $null
    foreach ($url in $Script:TokenUrls) {
        try {
            return Invoke-RestMethod -Uri $url -Method Post -Body $body `
                     -ContentType 'application/json' -UserAgent $Script:UserAgent -TimeoutSec 15
        }
        catch {
            $last = $_
            $sc = 0
            try { if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch { }
            # 400/401 means the endpoint is alive and rejected the token - trying the
            # other hosts would just repeat the same rejection
            if ($sc -eq 400 -or $sc -eq 401) { throw ('REFRESH_REJECTED:' + $sc) }
        }
    }
    if ($last) { throw ('REFRESH_FAILED:' + $last.Exception.Message) }
    throw 'REFRESH_FAILED:unknown'
}

# Collect EVERY Claude Code login on this machine, not just the first one found.
# A stale native-Windows install and a live WSL install commonly coexist; picking
# whichever we stumbled on first is how you end up authenticating with a dead token.
$Script:CredSources = $null
function Get-CredentialSources([switch]$Force) {
    if ($Script:CredSources -and -not $Force) { return $Script:CredSources }
    $found = New-Object System.Collections.Generic.List[object]

    foreach ($p in Get-WindowsCredentialPaths) {
        $c = New-CredSource ("Windows: $p") (Read-JsonFile $p)
        if ($c) { $found.Add($c) }
    }
    foreach ($d in Get-WslDistros) {
        foreach ($hit in @(Read-WslCredentials $d)) {
            $c = New-CredSource ("WSL[$d]: " + $hit.Path) $hit.Json
            if ($c) { $found.Add($c) }
        }
    }

    # freshest token first, so a live login always beats an abandoned one
    $Script:CredSources = @($found | Sort-Object -Property @{ Expression = { $_.ExpiresAt } } -Descending)
    # callers must use @(Get-CredentialSources): PowerShell unrolls a 1-element
    # array on return, and @() at the call site restores array semantics.
    return $Script:CredSources
}

function Get-AccessToken {
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) { return $env:CLAUDE_CODE_OAUTH_TOKEN }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($Script:State.CachedToken -and $Script:State.CachedExpires -gt ($now + 60000)) {
        return $Script:State.CachedToken
    }

    $sources = @(Get-CredentialSources)
    if ($sources.Count -eq 0) {
        $sources = @(Get-CredentialSources -Force)
        if ($sources.Count -eq 0) { throw 'NOTOKEN' }
    }

    # pass 1: any login whose access token is still valid
    foreach ($c in $sources) {
        if ($c.ExpiresAt -eq 0 -or $c.ExpiresAt -gt ($now + 60000)) {
            $Script:UsedSource = $c.Label
            return $c.Oauth.accessToken
        }
    }

    # pass 2: expired - refresh.
    #
    # OAuth refresh tokens ROTATE: the server hands back a new refresh_token and the
    # one we just spent is invalidated. Discarding it means the next refresh replays a
    # dead token and fails forever, so we persist ours and prefer it over the copy in
    # Claude Code's file, which goes stale the moment we refresh once. That is what
    # lets the widget keep itself signed in indefinitely without touching that file.
    $candidates = New-Object System.Collections.Generic.List[object]
    if ($Script:State.CachedRefresh) {
        $candidates.Add(@{ Label = 'widget-state.json'; Token = $Script:State.CachedRefresh; Own = $true })
    }
    foreach ($c in $sources) {
        if ($c.HasRefresh) { $candidates.Add(@{ Label = $c.Label; Token = $c.Oauth.refreshToken; Own = $false }) }
    }

    $errs = @()
    foreach ($cand in $candidates.ToArray()) {
        try {
            $t = Invoke-TokenRefresh $cand.Token
            if ($t -and $t.access_token) {
                $Script:State.CachedToken = $t.access_token
                $ttl = 3600
                if ($t.PSObject.Properties.Name -contains 'expires_in' -and $t.expires_in) { $ttl = [int]$t.expires_in }
                $Script:State.CachedExpires = $now + ($ttl * 1000)
                if ($t.PSObject.Properties.Name -contains 'refresh_token' -and $t.refresh_token) {
                    $Script:State.CachedRefresh = $t.refresh_token
                }
                Save-State
                $Script:UsedSource = $cand.Label + ' (refreshed)'
                return $t.access_token
            }
        }
        catch {
            $errs += ('{0} -> {1}' -f $cand.Label, $_.Exception.Message)
            # our stored token is spent or revoked - drop it and fall back to the file
            if ($cand.Own) { $Script:State.CachedRefresh = $null; Save-State }
        }
    }
    if ($errs.Count) { $Script:LastRefreshError = ($errs -join ' | ') }

    # pass 3: nothing refreshed - send the freshest token we have and let the server decide
    $Script:CredSources = $null   # rescan next time; a login may appear while we run
    $Script:UsedSource = $sources[0].Label + ' (stale)'
    return $sources[0].Oauth.accessToken
}

# ---------------------------------------------------------------- usage fetch

$Script:LastRefreshError = $null
$Script:UsedSource = $null
function Get-Usage {
    $Script:LastRefreshError = $null
    $token = Get-AccessToken
    $headers = @{
        'Authorization'   = "Bearer $token"
        'anthropic-beta'  = 'oauth-2025-04-20'
        'Accept'          = 'application/json'
    }
    try {
        return Invoke-RestMethod -Uri $Script:UsageUrl -Headers $headers -Method Get `
                    -UserAgent $Script:UserAgent -TimeoutSec 15
    }
    catch {
        # make it obvious which call failed - a bare '404' told us nothing useful
        throw (New-Object System.Exception (('usage endpoint: ' + $_.Exception.Message), $_.Exception))
    }
}

function Get-Profile {
    $token = Get-AccessToken
    $headers = @{
        'Authorization'  = "Bearer $token"
        'anthropic-beta' = 'oauth-2025-04-20'
        'Accept'         = 'application/json'
    }
    return Invoke-RestMethod -Uri $Script:ProfileUrl -Headers $headers -Method Get `
                -UserAgent $Script:UserAgent -TimeoutSec 15
}

# the profile payload is undocumented, so dig for an email rather than assume a shape
function Get-ProfileEmail($p) {
    if (-not $p) { return $null }
    foreach ($k in @('email','email_address')) {
        if ($p.PSObject.Properties.Name -contains $k -and $p.$k) { return [string]$p.$k }
    }
    foreach ($o in @('account','user','organization')) {
        if ($p.PSObject.Properties.Name -contains $o -and $p.$o) {
            foreach ($k in @('email','email_address','name')) {
                if ($p.$o.PSObject.Properties.Name -contains $k -and $p.$o.$k) { return [string]$p.$o.$k }
            }
        }
    }
    return $null
}

function Get-ScopeName($l) {
    if ($l.PSObject.Properties.Name -notcontains 'scope' -or -not $l.scope) { return $null }
    $sc = $l.scope
    if ($sc.PSObject.Properties.Name -contains 'model' -and $sc.model) {
        if ($sc.model.PSObject.Properties.Name -contains 'display_name' -and $sc.model.display_name) {
            return [string]$sc.model.display_name
        }
    }
    if ($sc.PSObject.Properties.Name -contains 'surface' -and $sc.surface) {
        if ($sc.surface -is [string]) { return [string]$sc.surface }
        if ($sc.surface.PSObject.Properties.Name -contains 'display_name' -and $sc.surface.display_name) {
            return [string]$sc.surface.display_name
        }
    }
    return $null
}

# The API returns a `limits` array alongside the older named keys. Prefer it:
# `percent` is an unambiguous 0-100, `severity` is the server's own judgement, and
# new limit kinds (per-model, per-surface) show up without hardcoding their names.
# The response also carries null placeholders under internal codenames - those are
# not in `limits`, which is another reason to drive off it.
function Get-LimitRows($d) {
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not $d) { return $rows.ToArray() }

    $fromLimits = $false
    if ($d.PSObject.Properties.Name -contains 'limits' -and $d.limits) {
        foreach ($l in @($d.limits)) {
            if (-not $l -or $l.PSObject.Properties.Name -notcontains 'percent') { continue }
            $kind  = ''; $reset = ''; $sev = ''
            if ($l.PSObject.Properties.Name -contains 'kind')      { $kind  = [string]$l.kind }
            if ($l.PSObject.Properties.Name -contains 'resets_at') { $reset = [string]$l.resets_at }
            if ($l.PSObject.Properties.Name -contains 'severity')  { $sev   = [string]$l.severity }
            $pct = [double]$l.percent

            # a scoped cap with no usage and no window has not kicked in - showing it is noise
            if ($kind -eq 'weekly_scoped' -and $pct -le 0 -and -not $reset) { continue }

            switch ($kind) {
                'session'       { $label = 'Session (5h)' }
                'weekly_all'    { $label = 'Week (all models)' }
                'weekly_scoped' { $label = 'Week' }
                default         { $label = (Get-Culture).TextInfo.ToTitleCase(($kind -replace '_', ' ')) }
            }
            if ($kind -eq 'weekly_scoped') {
                $n = Get-ScopeName $l
                if ($n) { $label = 'Week - ' + $n }
            }
            $rows.Add(@{ Label = $label; Percent = $pct; Reset = $reset; Severity = $sev })
            $fromLimits = $true
        }
    }

    if (-not $fromLimits) {
        $defs = @(
            @{ Key = 'five_hour';        Label = 'Session (5h)' },
            @{ Key = 'seven_day';        Label = 'Week (all models)' },
            @{ Key = 'seven_day_opus';   Label = 'Week - Opus' },
            @{ Key = 'seven_day_sonnet'; Label = 'Week - Sonnet' }
        )
        foreach ($def in $defs) {
            if ($d.PSObject.Properties.Name -notcontains $def.Key) { continue }
            $w = $d.($def.Key)
            if (-not $w -or $w.PSObject.Properties.Name -notcontains 'utilization') { continue }
            $pct = ConvertTo-Percent $w.utilization
            if ($null -eq $pct) { continue }
            $reset = ''
            if ($w.PSObject.Properties.Name -contains 'resets_at') { $reset = [string]$w.resets_at }
            $rows.Add(@{ Label = $def.Label; Percent = $pct; Reset = $reset; Severity = '' })
        }
    }

    if ($d.PSObject.Properties.Name -contains 'extra_usage' -and $d.extra_usage -and $d.extra_usage.is_enabled) {
        $e = $d.extra_usage
        $pct = 0
        if ($e.PSObject.Properties.Name -contains 'utilization' -and $null -ne $e.utilization) { $pct = ConvertTo-Percent $e.utilization }
        $sub = 'extra usage credits'
        if ($e.PSObject.Properties.Name -contains 'used_credits' -and $null -ne $e.used_credits -and
            $e.PSObject.Properties.Name -contains 'monthly_limit' -and $null -ne $e.monthly_limit) {
            $sub = ('${0:0.00} of ${1:0.00} this month' -f [double]$e.used_credits, [double]$e.monthly_limit)
        }
        $rows.Add(@{ Label = 'Extra usage'; Percent = $pct; Reset = $sub; Severity = ''; Literal = $true })
    }
    return $rows.ToArray()
}

function ConvertTo-Percent($value) {
    if ($null -eq $value) { return $null }
    $v = [double]$value
    switch ($Script:State.ScaleOverride) {
        'percent'  { return $v }
        'fraction' { return $v * 100 }
    }
    # auto: the API reports 0-100. A fractional value at or below 1 is a 0-1 ratio.
    if ($v -le 1 -and $v -ne [math]::Floor($v)) { return $v * 100 }
    return $v
}

function Format-Countdown([string]$iso) {
    if (-not $iso) { return '' }
    try {
        $t = [datetimeoffset]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture,
                                    [Globalization.DateTimeStyles]::AssumeUniversal)
    } catch { return '' }
    $span = $t - [datetimeoffset]::UtcNow
    if ($span.TotalSeconds -le 0) { return 'resetting...' }

    # round the remainder UP to the next whole minute so a countdown never reads low
    $mins = [int][math]::Ceiling($span.TotalMinutes)
    if ($mins -ge 1440)   { $rel = 'resets in {0}d {1}h' -f [int][math]::Floor($mins / 1440), [int][math]::Floor(($mins % 1440) / 60) }
    elseif ($mins -ge 60) { $rel = 'resets in {0}h {1}m' -f [int][math]::Floor($mins / 60), ($mins % 60) }
    else                  { $rel = 'resets in {0}m' -f $mins }

    # ...plus the wall-clock time it lands on, in the viewer's own locale and zone
    $local = $t.ToLocalTime()
    $today = [datetimeoffset]::Now.Date
    if     ($local.Date -eq $today)                { $abs = $local.ToString('t') }
    elseif ($local.Date -lt $today.AddDays(7))     { $abs = $local.ToString('ddd ') + $local.ToString('t') }
    else                                           { $abs = $local.ToString('MMM d ') + $local.ToString('t') }

    return ('{0} ({1})' -f $rel, $abs)
}


# ---------------------------------------------------------------- diagnostics

function Invoke-Diagnose {
    Load-State
    Write-Host ''
    Write-Host 'Claude Usage Widget - diagnostics' -ForegroundColor Cyan
    Write-Host '---------------------------------'

    if ($env:CLAUDE_CODE_OAUTH_TOKEN) { Write-Host 'token source : CLAUDE_CODE_OAUTH_TOKEN env var' -ForegroundColor Green }
    else {
        Write-Host 'Claude Code logins found on this machine:'
        $sources = @(Get-CredentialSources -Force)
        if ($sources.Count -eq 0) {
            Write-Host '  (none)' -ForegroundColor Red
            Write-Host ''
            Write-Host 'Searched:'
            foreach ($p in Get-WindowsCredentialPaths) { Write-Host ("  {0}" -f $p) }
            $d = @(Get-WslDistros)
            if ($d.Count) { foreach ($x in $d) { Write-Host ("  WSL[{0}] ~/.claude, /root/.claude, /home/*/.claude" -f $x) } }
            else { Write-Host '  (no WSL distros detected)' }
            Write-Host ''
            Write-Host 'RESULT: run "claude" once in your terminal to sign in.' -ForegroundColor Red
            return
        }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        foreach ($c in $sources) {
            $when = 'no expiry recorded'; $colour = 'Gray'
            if ($c.ExpiresAt -gt 0) {
                $exp = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$c.ExpiresAt).ToLocalTime()
                if ($c.ExpiresAt -gt ($now + 60000)) { $when = ('valid until ' + $exp.ToString('yyyy-MM-dd HH:mm')); $colour = 'Green' }
                else { $when = ('EXPIRED ' + $exp.ToString('yyyy-MM-dd HH:mm')); $colour = 'Yellow' }
            }
            $r = 'no refresh token'
            if ($c.HasRefresh) { $r = 'refresh token present' }
            Write-Host ("  {0}" -f $c.Label)
            Write-Host ("      {0}, {1}" -f $when, $r) -ForegroundColor $colour
        }
        if ($Script:State.CachedRefresh) {
            Write-Host ''
            Write-Host '  widget-state.json: holds its own rotated refresh token (self-renewing)' -ForegroundColor Green
        }
        Write-Host ''
        Write-Host '(the freshest login is used; expired ones are refreshed or skipped)' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'refresh endpoints:'
    foreach ($u in $Script:TokenUrls) {
        try {
            Invoke-WebRequest -Uri $u -Method Post -Body '{}' -ContentType 'application/json' `
                -UserAgent $Script:UserAgent -TimeoutSec 10 -UseBasicParsing | Out-Null
            Write-Host ("  {0}  reachable" -f $u)
        } catch {
            $sc = 0
            try { if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch { }
            if ($sc -eq 400 -or $sc -eq 401) { Write-Host ("  {0}  OK (alive, {1})" -f $u, $sc) -ForegroundColor Green }
            elseif ($sc -eq 404)             { Write-Host ("  {0}  404 - retired" -f $u) -ForegroundColor DarkGray }
            else                             { Write-Host ("  {0}  unreachable ({1})" -f $u, $_.Exception.Message) -ForegroundColor DarkGray }
        }
    }

    Write-Host ''
    try {
        $u = Get-Usage
        Write-Host 'usage endpoint: OK' -ForegroundColor Green
        if ($Script:UsedSource) { Write-Host ("  authenticated via: {0}" -f $Script:UsedSource) -ForegroundColor Green }
        if ($Script:LastRefreshError) { Write-Host ("  (note: refresh said {0})" -f $Script:LastRefreshError) -ForegroundColor Yellow }
        try {
            $prof = Get-Profile
            $mail = Get-ProfileEmail $prof
            if ($mail) { Write-Host ("  account: {0}" -f $mail) -ForegroundColor Cyan }
            else { Write-Host '  account: (email not present in profile payload)' -ForegroundColor DarkGray }
            Write-Host ''
            Write-Host 'raw profile:'
            $prof | ConvertTo-Json -Depth 6 | Write-Host
        } catch { Write-Host ("  profile lookup failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray }
        Write-Host ''
        Write-Host 'raw response:'
        $u | ConvertTo-Json -Depth 6 | Write-Host
        Write-Host ''
        Write-Host 'as the widget will show it:'
        foreach ($r in @(Get-LimitRows $u)) {
            $reset = $r.Reset
            if (-not $r.ContainsKey('Literal')) { $reset = Format-Countdown $r.Reset }
            Write-Host ("  {0,-20} {1,5:0}%   {2}" -f $r.Label, $r.Percent, $reset)
        }
    }
    catch {
        $sc = 0
        try { if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch { }
        Write-Host ("usage endpoint: FAILED  {0}" -f ($_.Exception.Message -replace '^usage endpoint: ', '')) -ForegroundColor Red
        if ($Script:UsedSource) { Write-Host ("  tried with: {0}" -f $Script:UsedSource) }
        if ($Script:LastRefreshError) { Write-Host ("  refresh error: {0}" -f $Script:LastRefreshError) -ForegroundColor Red }
        if ($sc -eq 401 -or $sc -eq 403) {
            Write-Host '  -> no usable login: expired and not refreshable.' -ForegroundColor Yellow
            Write-Host '     Run "claude" (in WSL if that is where you use it) and /login again.'
            Write-Host '     Note: "claude setup-token" does NOT work here - the usage endpoint'
            Write-Host '     rejects those sk-ant-oat01 tokens with 403.'
        }
        if ($sc -eq 429) { Write-Host '  -> rate limited. Wait a few minutes and try again.' }
        if ($sc -eq 404) { Write-Host '  -> endpoint moved. Update $Script:UsageUrl in this script.' }
    }
    Write-Host ''
}

# ---------------------------------------------------------------- window

if ($Diagnose) { Invoke-Diagnose; return }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Usage" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="Height" Width="292"
        WindowStartupLocation="Manual" ResizeMode="NoResize">
  <Border CornerRadius="14" Background="#F21B1B1F" BorderBrush="#26FFFFFF" BorderThickness="1" Padding="14,12,14,13">
    <StackPanel>
      <Grid Margin="0,0,0,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="CLAUDE USAGE" Foreground="#FFFFFF" FontFamily="Segoe UI"
                   FontSize="11" FontWeight="SemiBold" Opacity="0.92" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="1" x:Name="StatusText" Text="" Foreground="#9A9AA5" FontFamily="Segoe UI"
                   FontSize="10" VerticalAlignment="Center"/>
        <!-- Background must be a real brush, not null, or it will not be hit-testable -->
        <Border Grid.Column="2" x:Name="CloseBtn" Background="#00FFFFFF" Cursor="Hand" CornerRadius="4"
                Margin="9,-3,-4,-3" Padding="6,2,6,3" ToolTip="Close (Esc)" VerticalAlignment="Center">
          <TextBlock x:Name="CloseGlyph" Text="&#x2715;" Foreground="#8A8A95" FontFamily="Segoe UI"
                     FontSize="11" VerticalAlignment="Center"/>
        </Border>
      </Grid>
      <TextBlock x:Name="AccountText" Text="" Foreground="#8A8A95" FontFamily="Segoe UI" FontSize="10"
                 Margin="0,-6,0,9" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
      <StackPanel x:Name="Rows"/>
      <TextBlock x:Name="HintText" Text="" Foreground="#8A8A95" FontFamily="Segoe UI" FontSize="10"
                 TextWrapping="Wrap" Margin="0,8,0,0" Visibility="Collapsed"/>
    </StackPanel>
  </Border>
</Window>
'@

Load-State

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$rows       = $win.FindName('Rows')
$statusText = $win.FindName('StatusText')
$hintText   = $win.FindName('HintText')
$accountText = $win.FindName('AccountText')
$closeBtn   = $win.FindName('CloseBtn')
$closeGlyph = $win.FindName('CloseGlyph')
$win.Opacity = [double]$Script:State.Opacity

if ($null -ne $Script:State.Left -and $null -ne $Script:State.Top) {
    $win.Left = [double]$Script:State.Left; $win.Top = [double]$Script:State.Top
} else {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $win.Left = $wa.Right - 312; $win.Top = $wa.Top + 20
}


# ---------------------------------------------------------------- wpf helpers

$Script:BrushCache = @{}
function B([string]$hex) {
    if (-not $Script:BrushCache.ContainsKey($hex)) {
        $conv = New-Object System.Windows.Media.BrushConverter
        $Script:BrushCache[$hex] = $conv.ConvertFromString($hex)
    }
    return $Script:BrushCache[$hex]
}
function Th($l, $t, $r, $b) { return (New-Object System.Windows.Thickness ([double]$l), ([double]$t), ([double]$r), ([double]$b)) }
function CR([double]$r)     { return (New-Object System.Windows.CornerRadius $r) }
function FF([string]$n)     { return (New-Object System.Windows.Media.FontFamily $n) }

$BarWidth = 264.0
function Get-BarColour($percent, $severity) {
    $rank = 0
    $p = [double]$percent
    if     ($p -ge 90) { $rank = 2 }
    elseif ($p -ge 75) { $rank = 1 }
    switch -Regex ("$severity".ToLower()) {
        '^(warn|warning|elevated|medium)$'                 { if ($rank -lt 1) { $rank = 1 } }
        '^(critical|severe|high|exceeded|blocked|locked)$' { $rank = 2 }
    }
    switch ($rank) { 2 { return '#F87171' } 1 { return '#FBBF24' } default { return '#4ADE80' } }
}

function New-UsageRow($label, $percent, $reset, $severity) {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = (Th 0 0 0 11)

    $g = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::Auto
    $c2 = New-Object Windows.Controls.ColumnDefinition
    $c3 = New-Object Windows.Controls.ColumnDefinition; $c3.Width = [System.Windows.GridLength]::Auto
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2); $g.ColumnDefinitions.Add($c3)

    $lb = New-Object Windows.Controls.TextBlock
    $lb.Text = $label; $lb.FontFamily = (FF 'Segoe UI'); $lb.FontSize = 12
    $lb.Foreground = (B '#E6E6EC')
    [Windows.Controls.Grid]::SetColumn($lb, 0); $g.Children.Add($lb) | Out-Null

    $pv = New-Object Windows.Controls.TextBlock
    $pv.Text = ('{0:0}%' -f $percent); $pv.FontFamily = (FF 'Segoe UI'); $pv.FontSize = 12
    $pv.FontWeight = [System.Windows.FontWeights]::SemiBold; $pv.Foreground = (B '#FFFFFF')
    [Windows.Controls.Grid]::SetColumn($pv, 2); $g.Children.Add($pv) | Out-Null
    $sp.Children.Add($g) | Out-Null

    $track = New-Object Windows.Controls.Border
    $track.Height = 5; $track.CornerRadius = (CR 3); $track.Background = (B '#1FFFFFFF')
    $track.Margin = (Th 0 5 0 0); $track.HorizontalAlignment = 'Left'; $track.Width = $BarWidth

    $fill = New-Object Windows.Controls.Border
    $fill.Height = 5; $fill.CornerRadius = (CR 3); $fill.HorizontalAlignment = 'Left'
    $p = [math]::Max(0, [math]::Min(100, [double]$percent))
    $fill.Width = [math]::Max(3, $BarWidth * $p / 100)
    $fill.Background = (B (Get-BarColour $p $severity))
    $track.Child = $fill
    $sp.Children.Add($track) | Out-Null

    $rs = New-Object Windows.Controls.TextBlock
    $rs.Text = $reset; $rs.FontFamily = (FF 'Segoe UI'); $rs.FontSize = 10
    $rs.Foreground = (B '#8A8A95'); $rs.Margin = (Th 0 4 0 0)
    $sp.Children.Add($rs) | Out-Null
    return $sp
}

function Show-Message([string]$text) {
    $rows.Children.Clear()
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontFamily = (FF 'Segoe UI'); $tb.FontSize = 11
    $tb.Foreground = (B '#C9C9D2'); $tb.TextWrapping = 'Wrap'
    $rows.Children.Add($tb) | Out-Null
}

# ---------------------------------------------------------------- refresh loop

$Script:Account     = $null
$Script:LastData    = $null
$Script:LastOk      = $null
$Script:Backoff     = 0
$Script:NextFetchAt = [datetime]::MinValue

function Render {
    if (-not $Script:LastData) { return }
    $d = $Script:LastData
    $rows.Children.Clear()

    foreach ($r in @(Get-LimitRows $d)) {
        $reset = $r.Reset
        if (-not $r.ContainsKey('Literal')) { $reset = Format-Countdown $r.Reset }
        $rows.Children.Add((New-UsageRow $r.Label $r.Percent $reset $r.Severity)) | Out-Null
    }

    if ($rows.Children.Count -eq 0) { Show-Message 'No usage windows reported for this account.' }

    if ($Script:LastOk) {
        $age = [int]([datetime]::UtcNow - $Script:LastOk).TotalSeconds
        if ($age -lt 90) { $statusText.Text = 'live'; $statusText.Foreground = (B '#4ADE80') }
        elseif ($age -lt 600) { $statusText.Text = ('{0}m ago' -f [int][math]::Floor($age / 60)); $statusText.Foreground = (B '#9A9AA5') }
        else { $statusText.Text = 'stale'; $statusText.Foreground = (B '#FBBF24') }
    }
}

function Update-Usage {
    try {
        $Script:LastData = Get-Usage
        $Script:LastOk   = [datetime]::UtcNow
        $Script:Backoff  = 0
        if (-not $Script:Account) {
            try {
                $Script:Account = Get-ProfileEmail (Get-Profile)
                if ($Script:Account) { $accountText.Text = $Script:Account; $accountText.Visibility = 'Visible' }
            } catch { }   # cosmetic only - never let this break the usage display
        }
        $hintText.Visibility = 'Collapsed'
        Render
    }
    catch {
        $msg  = $_.Exception.Message
        $code = 0
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }

        if ($msg -eq 'NOTOKEN') {
            Show-Message "Couldn't find a Claude Code login on this PC.`n`nRun `"claude`" once in your terminal (Windows or WSL) to sign in, then click this widget to retry."
            $statusText.Text = 'no token'; $statusText.Foreground = (B '#F87171')
            $Script:Backoff = 4
            return
        }
        if ($code -eq 401 -or $code -eq 403) {
            $Script:CredSources = $null            # re-scan: the user may have just logged in
            $Script:State.CachedToken = $null
            $Script:Account = $null
            $hintText.Text = 'Login expired - run /login in Claude Code, or set CLAUDE_CODE_OAUTH_TOKEN (see README).'
            $hintText.Visibility = 'Visible'
            $statusText.Text = 'auth'; $statusText.Foreground = (B '#F87171')
        }
        elseif ($code -eq 429) {
            $hintText.Text = 'Rate limited by the usage API - backing off.'
            $hintText.Visibility = 'Visible'
            $statusText.Text = 'throttled'; $statusText.Foreground = (B '#FBBF24')
        }
        else {
            if ($Script:LastRefreshError) { $msg = ('{0} / refresh: {1}' -f $msg, $Script:LastRefreshError) }
            $hintText.Text = ('Fetch failed: {0}  -  run with -Diagnose for detail' -f $msg)
            $hintText.Visibility = 'Visible'
            $statusText.Text = 'offline'; $statusText.Foreground = (B '#FBBF24')
        }
        if (-not $Script:LastData) { Show-Message 'Waiting for usage data...' }
        $Script:Backoff = [math]::Min(5, $Script:Backoff + 1)   # 180s -> up to ~16 min
    }
    finally {
        $mult = [math]::Pow(2, $Script:Backoff)
        $Script:NextFetchAt = [datetime]::UtcNow.AddSeconds($RefreshSeconds * $mult)
    }
}

# ---------------------------------------------------------------- interaction

# Every quit route funnels through here so the tray icon can never be orphaned.
function Close-Widget {
    try { if ($timer) { $timer.Stop() } } catch { }
    try { if ($tray)  { $tray.Visible = $false; $tray.Dispose() } } catch { }
    try { $win.Close() } catch { }
}

# PowerShell event handlers get (sender, eventArgs) as $args - $_ is NOT populated here.
$win.Add_MouseLeftButtonDown({
    param($sender, $e)
    if ($e -and $e.ClickCount -eq 2) { $Script:NextFetchAt = [datetime]::MinValue; $Script:Backoff = 0 }
    else { try { $win.DragMove() } catch { } }
})
$win.Add_LocationChanged({
    $Script:State.Left = $win.Left; $Script:State.Top = $win.Top; Save-State
})

# Esc closes, like any ordinary window
$win.Add_KeyDown({
    param($sender, $e)
    if ($e -and $e.Key -eq 'Escape') { Close-Widget }
})

# --- close button -------------------------------------------------
# MouseLeftButtonDown bubbles to the window, whose handler calls DragMove() and
# captures the mouse - so mark it handled here or the click never lands.
$closeBtn.Add_MouseLeftButtonDown({
    param($sender, $e)
    if ($e) { $e.Handled = $true }
    Close-Widget
})
$closeBtn.Add_MouseEnter({ $closeBtn.Background = (B '#E0F87171'); $closeGlyph.Foreground = (B '#FFFFFF') })
$closeBtn.Add_MouseLeave({ $closeBtn.Background = (B '#00FFFFFF'); $closeGlyph.Foreground = (B '#8A8A95') })

# --- right-click menu on the widget itself, so quitting is discoverable
# without hunting for a tray icon Windows may have hidden in the overflow
$ctx = New-Object System.Windows.Controls.ContextMenu
$ctxRefresh = New-Object System.Windows.Controls.MenuItem
$ctxRefresh.Header = 'Refresh now'
$ctxRefresh.Add_Click({ $Script:NextFetchAt = [datetime]::MinValue; $Script:Backoff = 0 })
$ctxHide = New-Object System.Windows.Controls.MenuItem
$ctxHide.Header = 'Hide to tray'
$ctxHide.Add_Click({ $win.Hide() })
$ctxClose = New-Object System.Windows.Controls.MenuItem
$ctxClose.Header = 'Close'
$ctxClose.Add_Click({ Close-Widget })
$ctx.Items.Add($ctxRefresh) | Out-Null
$ctx.Items.Add($ctxHide)    | Out-Null
$ctx.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$ctx.Items.Add($ctxClose)   | Out-Null
$win.ContextMenu = $ctx

# --- tray icon ---------------------------------------------------
$bmp = New-Object System.Drawing.Bitmap 32, 32
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.SmoothingMode = 'AntiAlias'
$gfx.Clear([System.Drawing.Color]::Transparent)
$gfx.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(217, 119, 87))), 2, 2, 28, 28)
$gfx.Dispose()
$icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icon
$tray.Text = 'Claude Usage'
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $menu.Items.Add('Show / hide')
$miRef  = $menu.Items.Add('Refresh now')
$menu.Items.Add('-') | Out-Null
$miStart = $menu.Items.Add('Run at Windows startup')
$miDim   = $menu.Items.Add('Toggle transparency')
$menu.Items.Add('-') | Out-Null
$miExit = $menu.Items.Add('Exit')
$tray.ContextMenuStrip = $menu

$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Widget.lnk'
$miStart.Checked = Test-Path $startupLnk

$miShow.Add_Click({ if ($win.Visibility -eq 'Visible') { $win.Hide() } else { $win.Show(); $win.Activate() } })
$miRef.Add_Click({ $Script:NextFetchAt = [datetime]::MinValue; $Script:Backoff = 0 })
$miDim.Add_Click({
    if ($win.Opacity -gt 0.8) { $win.Opacity = 0.62 } else { $win.Opacity = 0.95 }
    $Script:State.Opacity = $win.Opacity; Save-State
})
$miStart.Add_Click({
    if (Test-Path $startupLnk) { Remove-Item $startupLnk -Force; $miStart.Checked = $false }
    else {
        $vbs = Join-Path $Script:Root 'Start-Widget.vbs'
        $sh  = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($startupLnk)
        if (Test-Path $vbs) {
            $lnk.TargetPath = 'wscript.exe'; $lnk.Arguments = ('"{0}"' -f $vbs)
        } else {
            $lnk.TargetPath = 'powershell.exe'
            $lnk.Arguments  = ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
        }
        $lnk.WorkingDirectory = $Script:Root
        $lnk.Save(); $miStart.Checked = $true
    }
})
$miExit.Add_Click({ Close-Widget })
$tray.Add_MouseDoubleClick({ $win.Show(); $win.Activate() })

$win.Add_Closed({ $tray.Visible = $false; $tray.Dispose(); [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })

# --- ticker: 1s for countdowns, RefreshSeconds for network ------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    if ([datetime]::UtcNow -ge $Script:NextFetchAt) { Update-Usage }
    elseif ($Script:LastData) { Render }
    if ($Script:LastData) {
        $t = @()
        foreach ($k in @('five_hour','seven_day')) {
            if ($Script:LastData.PSObject.Properties.Name -contains $k -and $Script:LastData.$k) {
                $t += ('{0} {1:0}%' -f $(if ($k -eq 'five_hour') { '5h' } else { '7d' }), (ConvertTo-Percent $Script:LastData.$k.utilization))
            }
        }
        if ($t.Count) { $tray.Text = 'Claude Usage - ' + ($t -join '  ') }
    }
})

Show-Message 'Loading...'
$win.Show()
$timer.Start()
[System.Windows.Threading.Dispatcher]::Run()

# The message loop has ended. Release everything explicitly and exit, so a stray
# handle can never leave powershell.exe running invisibly in the background.
try { $timer.Stop() } catch { }
try { if ($tray) { $tray.Visible = $false; $tray.Dispose() } } catch { }
try { $icon.Dispose() } catch { }
try { $bmp.Dispose() } catch { }
[Environment]::Exit(0)
