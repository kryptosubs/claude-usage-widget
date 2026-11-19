<#
  Claude Usage Widget - a small always-on-top Windows desktop widget that shows
  live Claude usage (5-hour session window, weekly, per-model weekly, extra usage).

  Requires nothing but Windows PowerShell 5.1 (built in). No install, no Node, no Electron.
  Reads your existing Claude Code OAuth token, or signs itself in with Google through
  claude.ai (the same PKCE flow as Claude Code's /login) and keeps that login on its own.

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

# The widget's own browser sign-in (see "the widget's own sign-in" below).
$Script:LoginPath    = Join-Path $Script:Root 'widget-login.dat'
$Script:AuthorizeUrl = 'https://claude.ai/oauth/authorize'
# What a claude.ai (subscription) login needs. org:create_api_key is a Console scope
# and makes the claude.ai authorize page refuse the request.
$Script:SignInScopes = 'user:profile user:inference user:sessions:claude_code user:mcp_servers'

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
# widget-state.json and widget-login.dat hold refresh tokens, so they must not be
# world-readable. The script can live anywhere (Downloads, a shared folder), so
# don't rely on the parent directory's ACL - set an explicit owner-only rule.
function Set-OwnerOnlyAcl([string]$Path) {
    try {
        $acl = Get-Acl -Path $Path
        $acl.SetAccessRuleProtection($true, $false)   # stop inheriting, drop inherited entries
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        $me   = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -Path $Path -AclObject $acl
        return $true
    } catch { return $false }
}
function Protect-StateFile {
    if ($Script:StateProtected) { return }
    if (Set-OwnerOnlyAcl $Script:StatePath) { $Script:StateProtected = $true }
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

# Get-Usage rewraps its error to say WHICH call failed, which buries the original
# WebException - the only object carrying .Response - one level down. Reading
# $_.Exception.Response off the wrapper silently yields 0, so a usage 401 looked
# like a generic failure: the widget showed 'offline' instead of 'auth' and skipped
# the cache-clearing that lets it notice a fresh login. Walk the chain instead.
function Get-HttpStatus($errRecord) {
    if (-not $errRecord) { return 0 }
    $ex = $errRecord
    if ($errRecord.PSObject.Properties.Name -contains 'Exception') { $ex = $errRecord.Exception }
    $depth = 0
    while ($ex -and $depth -lt 6) {
        try {
            if ($ex.PSObject.Properties.Name -contains 'Response' -and $ex.Response) {
                $r = $ex.Response
                if ($r.PSObject.Properties.Name -contains 'StatusCode') { return [int]$r.StatusCode }
            }
        } catch { }
        $ex = $ex.InnerException
        $depth++
    }
    # last resort: both PowerShell editions put the code in the message text
    $msg = ''
    try { if ($errRecord.Exception) { $msg = [string]$errRecord.Exception.Message } } catch { }
    if ($msg -match '\((\d{3})\)')      { return [int]$Matches[1] }
    if ($msg -match '\b([45]\d{2})\b')  { return [int]$Matches[1] }
    return 0
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
            $sc = Get-HttpStatus $_
            # 400/401 means the endpoint is alive and rejected the token - trying the
            # other hosts would just repeat the same rejection
            if ($sc -eq 400 -or $sc -eq 401) { throw ('REFRESH_REJECTED:' + $sc) }
        }
    }
    if ($last) { throw ('REFRESH_FAILED:' + $last.Exception.Message) }
    throw 'REFRESH_FAILED:unknown'
}

# ---------------------------------------------------------------- the widget's own sign-in
#
# The same OAuth flow Claude Code's /login uses: PKCE, Claude Code's public client
# id, a localhost redirect. The browser opens claude.ai, where "Continue with Google"
# (or whatever the account uses) does the actual sign-in; if the browser is already
# signed in to claude.ai it is one "Authorize" click. claude.ai then redirects to a
# one-shot listener on the loopback interface with a code, which is exchanged for an
# access + refresh token pair.
#
# The result is the widget's OWN login, kept in widget-login.dat (DPAPI-encrypted to
# this Windows user, owner-only ACL). It is a separate refresh chain from Claude
# Code's, so the widget refreshing never rotates Claude Code's token out from under
# it, and Claude Code logging out or expiring no longer leaves the widget with
# nothing to read. It is tried before any Claude Code login.

function ConvertTo-Base64Url([byte[]]$Bytes) {
    return ([Convert]::ToBase64String($Bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# 32 random bytes -> 43 url-safe chars: a valid PKCE verifier, also used as state.
function New-RandomToken([int]$Bytes = 32) {
    $b = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return (ConvertTo-Base64Url $b)
}

function Get-PkceChallenge([string]$Verifier) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (ConvertTo-Base64Url ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($Verifier)))) }
    finally { $sha.Dispose() }
}

function Get-RedirectUri([int]$Port) { return ('http://localhost:{0}/callback' -f $Port) }

# No code=true here: that switches claude.ai to the copy-and-paste flow.
function Get-AuthorizeUrl([int]$Port, [string]$Challenge, [string]$State) {
    $q = [ordered]@{
        client_id             = $Script:ClientId
        response_type         = 'code'
        redirect_uri          = (Get-RedirectUri $Port)
        scope                 = $Script:SignInScopes
        code_challenge        = $Challenge
        code_challenge_method = 'S256'
        state                 = $State
    }
    $pairs = foreach ($k in $q.Keys) { $k + '=' + [Uri]::EscapeDataString([string]$q[$k]) }
    return ($Script:AuthorizeUrl + '?' + ($pairs -join '&'))
}

# First line of an HTTP request -> @{ Code; State; Error }, or $null for anything
# other than GET /callback (browsers also ask for /favicon.ico).
function ConvertFrom-CallbackLine([string]$Line) {
    if (-not $Line) { return $null }
    $parts = $Line.Split(' ')
    if ($parts.Count -lt 2 -or $parts[0] -cne 'GET') { return $null }
    $target = $parts[1]; $path = $target; $query = ''
    $qi = $target.IndexOf('?')
    if ($qi -ge 0) { $path = $target.Substring(0, $qi); $query = $target.Substring($qi + 1) }
    if ($path -ne '/callback') { return $null }

    $p = @{}
    foreach ($kv in $query.Split('&')) {
        if (-not $kv) { continue }
        $eq = $kv.IndexOf('=')
        if ($eq -lt 0) { $k = $kv; $v = '' } else { $k = $kv.Substring(0, $eq); $v = $kv.Substring($eq + 1) }
        try {
            $k = [Uri]::UnescapeDataString($k.Replace('+', ' '))
            $v = [Uri]::UnescapeDataString($v.Replace('+', ' '))
        } catch { continue }
        if ($v -and -not $p.ContainsKey($k)) { $p[$k] = $v }
    }
    $code = $p['code']; $state = $p['state']
    # the manual flow hands out "code#state"; accept that shape too
    if ($code -and $code.Contains('#')) {
        $h = $code.IndexOf('#')
        if (-not $state) { $state = $code.Substring($h + 1) }
        $code = $code.Substring(0, $h)
    }
    $err = $p['error_description']
    if (-not $err) { $err = $p['error'] }
    return @{ Code = $code; State = $state; Error = $err }
}

# The page the browser lands on. Both languages; Chinese as HTML entities so this
# file stays pure ASCII.
function Get-SignInPageHtml([bool]$Ok, [string]$ErrorText) {
    if ($Ok) {
        $title = 'Signed in to Claude Usage'; $colour = '#5fd38d'
        $en = 'You can close this tab.'
        $zh = 'Claude Usage &#x5DF2;&#x767B;&#x5165;&#xFF0C;&#x53EF;&#x4EE5;&#x95DC;&#x9589;&#x9019;&#x500B;&#x5206;&#x9801;&#x3002;'
    } else {
        $title = 'Sign-in did not finish'; $colour = '#ff6b6b'
        $en = 'Go back to Claude Usage and try again.'
        $zh = '&#x767B;&#x5165;&#x6C92;&#x6709;&#x5B8C;&#x6210;&#xFF0C;&#x8ACB;&#x56DE;&#x5230; Claude Usage &#x518D;&#x8A66;&#x4E00;&#x6B21;&#x3002;'
    }
    $detail = ''
    if ($ErrorText) { $detail = '<p class=e>' + [System.Net.WebUtility]::HtmlEncode($ErrorText) + '</p>' }
    return ('<!doctype html><html><head><meta charset="utf-8"><title>{0}</title>' +
            '<style>body{{font:15px "Segoe UI",system-ui,sans-serif;background:#1f1f1f;color:#eee;' +
            'display:flex;align-items:center;justify-content:center;height:100vh;margin:0}}' +
            'div{{text-align:center}}h1{{font-size:20px;color:{1}}}.e{{color:#aaa;font-size:13px}}</style>' +
            '</head><body><div><h1>{0}</h1><p>{2}</p><p>{3}</p>{4}</div></body></html>') -f $title, $colour, $en, $zh, $detail
}

# Token response -> a document in Claude Code's own credential shape, so
# New-CredSource and the refresh code handle it unchanged.
function New-LoginDocument($Resp, [double]$NowMs) {
    if (-not $Resp -or $Resp.PSObject.Properties.Name -notcontains 'access_token' -or -not $Resp.access_token) { return $null }
    $ttl = 3600
    if ($Resp.PSObject.Properties.Name -contains 'expires_in' -and $Resp.expires_in) { $ttl = [double]$Resp.expires_in }
    $o = [ordered]@{ accessToken = [string]$Resp.access_token; expiresAt = [int64]($NowMs + $ttl * 1000) }
    if ($Resp.PSObject.Properties.Name -contains 'refresh_token' -and $Resp.refresh_token) { $o.refreshToken = [string]$Resp.refresh_token }
    if ($Resp.PSObject.Properties.Name -contains 'scope' -and $Resp.scope) {
        $o.scopes = @(([string]$Resp.scope).Split(' ') | Where-Object { $_ })
    }
    $doc = [ordered]@{ claudeAiOauth = $o }
    if ($Resp.PSObject.Properties.Name -contains 'account' -and $Resp.account) {
        foreach ($k in @('email_address', 'email')) {
            if ($Resp.account.PSObject.Properties.Name -contains $k -and $Resp.account.$k) { $doc.account = [string]$Resp.account.$k; break }
        }
    }
    return $doc
}

# DPAPI, CurrentUser scope: only this Windows account on this PC can decrypt it.
function Protect-LoginText([string]$Text) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null,
               [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($enc)
}
function Unprotect-LoginText([string]$Blob) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $dec = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Blob.Trim()), $null,
               [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($dec)
}

function Save-Login($Doc) {
    $json = $Doc | ConvertTo-Json -Depth 6 -Compress
    Set-Content -LiteralPath $Script:LoginPath -Value (Protect-LoginText $json) -Encoding ASCII
    [void](Set-OwnerOnlyAcl $Script:LoginPath)
}
function Read-Login {
    try {
        if (-not (Test-Path -LiteralPath $Script:LoginPath)) { return $null }
        return ((Unprotect-LoginText (Get-Content -LiteralPath $Script:LoginPath -Raw)) | ConvertFrom-Json)
    } catch { return $null }   # unreadable (another user, another PC): treat as signed out
}
function Test-Login { return [bool](Test-Path -LiteralPath $Script:LoginPath) }
function Remove-Login {
    try { if (Test-Path -LiteralPath $Script:LoginPath) { Remove-Item -LiteralPath $Script:LoginPath -Force } } catch { }
}
# Takes either shape: the dictionary New-LoginDocument builds, or the object Read-Login parses.
function Get-LoginEmail($Doc) {
    if (-not $Doc) { return $null }
    if ($Doc -is [System.Collections.IDictionary]) {
        if ($Doc.Contains('account') -and $Doc['account']) { return [string]$Doc['account'] }
        return $null
    }
    if ($Doc.PSObject.Properties.Name -contains 'account' -and $Doc.account) { return [string]$Doc.account }
    return $null
}

# Same token endpoints as refresh. A code works once, so a 4xx is final: replaying
# it on the fallback host would only earn a second, more confusing rejection.
function Invoke-CodeExchange([string]$Code, [string]$Verifier, [string]$RedirectUri, [string]$State) {
    $body = [ordered]@{
        grant_type    = 'authorization_code'
        code          = $Code
        redirect_uri  = $RedirectUri
        client_id     = $Script:ClientId
        code_verifier = $Verifier
        state         = $State
    } | ConvertTo-Json -Compress
    $last = 'no token endpoint reachable'
    foreach ($url in $Script:TokenUrls) {
        try {
            $r = Invoke-RestMethod -Uri $url -Method Post -Body $body `
                     -ContentType 'application/json' -UserAgent $Script:UserAgent -TimeoutSec 20
        }
        catch {
            $sc = Get-HttpStatus $_
            $detail = ''
            try { if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = [string]$_.ErrorDetails.Message } } catch { }
            if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
            if ($sc -ge 400 -and $sc -lt 500 -and $sc -ne 404) {
                throw ('token exchange rejected ({0}) {1}' -f $sc, $detail).Trim()
            }
            $last = $_.Exception.Message
            continue
        }
        if ($r -and $r.PSObject.Properties.Name -contains 'access_token' -and $r.access_token) { return $r }
        throw 'no access token in the token response'   # the code is spent either way
    }
    throw ('token exchange failed: ' + $last)
}

# Everything after the browser comes back: check it, exchange the code, and return
# a login document ready for Save-Login. Throws a short, user-readable reason.
function Complete-BrowserSignIn($Callback, [string]$Verifier, [string]$State, [int]$Port) {
    if (-not $Callback) { throw 'no redirect from the browser' }
    if ($Callback.Error) { throw ('claude.ai said: ' + $Callback.Error) }
    if ($Callback.State -cne $State) { throw 'state mismatch (ignored a stray redirect)' }
    if (-not $Callback.Code) { throw 'no code in the redirect' }
    $r = Invoke-CodeExchange $Callback.Code $Verifier (Get-RedirectUri $Port) $State
    $doc = New-LoginDocument $r ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    if (-not $doc) { throw 'no access token in the token response' }
    return $doc
}

# --- one-shot HTTP listener on the loopback interface, polled from the UI timer.
#
# Plain TcpListeners on 127.0.0.1 and ::1, not HttpListener: no http.sys URL
# reservation, no admin rights, no firewall prompt (loopback only). Nothing here
# blocks: connections are accepted when Pending() and read only when DataAvailable,
# so a browser's idle pre-connect socket can never stall the widget.

function Start-CallbackServer {
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $v4 = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
        $v4.Start()
        $port = ([System.Net.IPEndPoint]$v4.LocalEndpoint).Port
        $ls = @($v4)
        try {
            $v6 = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::IPv6Loopback), $port
            $v6.Start()
            $ls += $v6
        }
        catch {
            # "localhost" may resolve to ::1 first. If something else already owns that
            # port on ::1 the browser could land there, so pick another port. With no
            # IPv6 loopback at all, 127.0.0.1 alone is fine.
            $inUse = $false
            $ex = $_.Exception
            while ($ex) {
                if ($ex -is [System.Net.Sockets.SocketException] -and
                    $ex.SocketErrorCode -eq [System.Net.Sockets.SocketError]::AddressAlreadyInUse) { $inUse = $true }
                $ex = $ex.InnerException
            }
            if ($inUse) { try { $v4.Stop() } catch { }; continue }
        }
        return @{ Port = $port; Listeners = $ls; Conns = (New-Object System.Collections.Generic.List[object]); Done = $false }
    }
    throw 'no free loopback port'
}

function Send-HttpResponse($Stream, [string]$Status, [string]$Html) {
    $body = [Text.Encoding]::UTF8.GetBytes($Html)
    # build the string first: inside a method call's parentheses the comma would
    # split the -f arguments into method arguments
    $headText = ("HTTP/1.1 {0}`r`nContent-Type: text/html; charset=utf-8`r`n" +
                 "Content-Length: {1}`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n") -f $Status, $body.Length
    $head = [Text.Encoding]::ASCII.GetBytes($headText)
    $Stream.Write($head, 0, $head.Length)
    if ($body.Length) { $Stream.Write($body, 0, $body.Length) }
    $Stream.Flush()
}

function Close-CallbackConn($Srv, $Conn) {
    try { $Conn.Client.Close() } catch { }
    [void]$Srv.Conns.Remove($Conn)
}

# Call repeatedly. Returns the callback (once) when the browser comes back, else $null.
function Step-CallbackServer($Srv) {
    if (-not $Srv -or $Srv.Done) { return $null }
    foreach ($l in $Srv.Listeners) {
        while ($l.Pending()) {
            $c = $l.AcceptTcpClient()
            $Srv.Conns.Add(@{ Client = $c; Data = (New-Object System.IO.MemoryStream); Since = [datetime]::UtcNow })
        }
    }
    foreach ($cn in $Srv.Conns.ToArray()) {
        try {
            $s = $cn.Client.GetStream()
            $buf = New-Object byte[] 4096
            while ($s.DataAvailable -and $cn.Data.Length -lt 16384) {
                $n = $s.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $cn.Data.Write($buf, 0, $n)
            }
            $text = [Text.Encoding]::ASCII.GetString($cn.Data.ToArray())
            # answer only once the whole request is in: closing a socket with unread
            # bytes makes Windows send a reset, and the browser shows an error page
            if ($text.IndexOf("`r`n`r`n") -lt 0 -and $cn.Data.Length -lt 16384) {
                if (([datetime]::UtcNow - $cn.Since).TotalSeconds -gt 10) { Close-CallbackConn $Srv $cn }
                continue
            }
            $first = $text.Split([string[]]@("`r`n"), [StringSplitOptions]::None)[0]
            $cb = ConvertFrom-CallbackLine $first
            if (-not $cb) {
                Send-HttpResponse $s '404 Not Found' ''
                Close-CallbackConn $Srv $cn
                continue
            }
            Send-HttpResponse $s '200 OK' (Get-SignInPageHtml ([bool]($cb.Code -and -not $cb.Error)) $cb.Error)
            Close-CallbackConn $Srv $cn
            $Srv.Done = $true
            return $cb
        }
        catch { Close-CallbackConn $Srv $cn }
    }
    return $null
}

function Stop-CallbackServer($Srv) {
    if (-not $Srv) { return }
    foreach ($l in @($Srv.Listeners)) { try { $l.Stop() } catch { } }
    foreach ($cn in $Srv.Conns.ToArray()) { Close-CallbackConn $Srv $cn }
    $Srv.Done = $true
}

# --- the widget login as a token source.
#
# Returns an access token, or $null to fall back to Claude Code's logins. The widget
# refreshes this chain itself and writes every rotated refresh token back to
# widget-login.dat, so it stays signed in for as long as it keeps running.
$Script:WidgetForceRefresh = $false   # set after a 401/403 on the widget's token
$Script:LastWidgetError    = $null
function Get-WidgetAccessToken([double]$NowMs) {
    $doc = Read-Login
    if (-not $doc) { return $null }
    $c = New-CredSource 'Widget sign-in' $doc
    if (-not $c) { return $null }

    if (-not $Script:WidgetForceRefresh -and ($c.ExpiresAt -eq 0 -or $c.ExpiresAt -gt ($NowMs + 60000))) {
        $Script:UsedSource = 'Widget sign-in'
        return $c.Oauth.accessToken
    }
    if (-not $c.HasRefresh) { return $null }

    try { $t = Invoke-TokenRefresh $c.Oauth.refreshToken }
    catch {
        $Script:LastWidgetError = 'Widget sign-in -> ' + $_.Exception.Message
        # rejected = revoked or already spent: it can never work again, so drop it
        # and let the card offer "Sign in with Google" instead of retrying forever
        if ($_.Exception.Message -like 'REFRESH_REJECTED*') { Remove-Login; $Script:WidgetForceRefresh = $false }
        return $null
    }
    $new = New-LoginDocument $t $NowMs
    if (-not $new) { $Script:LastWidgetError = 'Widget sign-in -> no access token in refresh response'; return $null }
    # keep what a refresh response may leave out
    if (-not $new.claudeAiOauth.Contains('refreshToken')) { $new.claudeAiOauth.refreshToken = [string]$c.Oauth.refreshToken }
    if (-not $new.claudeAiOauth.Contains('scopes') -and $c.Oauth.PSObject.Properties.Name -contains 'scopes' -and $c.Oauth.scopes) {
        $new.claudeAiOauth.scopes = @($c.Oauth.scopes)
    }
    if (-not $new.Contains('account')) { $mail = Get-LoginEmail $doc; if ($mail) { $new.account = $mail } }
    try { Save-Login $new }
    catch { $Script:LastWidgetError = 'Widget sign-in -> could not save the renewed login: ' + $_.Exception.Message }
    $Script:WidgetForceRefresh = $false
    $Script:UsedSource = 'Widget sign-in (refreshed)'
    return $new.claudeAiOauth.accessToken
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

    # the widget's own sign-in comes first: refreshing it touches nobody else's token
    $Script:LastWidgetError = $null
    $w = Get-WidgetAccessToken $now
    if ($w) { return $w }
    $errs = @()
    if ($Script:LastWidgetError) { $errs += $Script:LastWidgetError; $Script:LastRefreshError = $Script:LastWidgetError }

    if ($Script:State.CachedToken -and $Script:State.CachedExpires -gt ($now + 60000)) {
        $Script:UsedSource = 'widget-state.json (cached)'
        return $Script:State.CachedToken
    }

    $sources = @(Get-CredentialSources)
    if ($sources.Count -eq 0) {
        $sources = @(Get-CredentialSources -Force)
        if ($sources.Count -eq 0) {
            # still signed in, just could not renew (offline?) - that is not "no login"
            if ($Script:LastWidgetError -and (Test-Login)) { throw $Script:LastWidgetError }
            throw 'NOTOKEN'
        }
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
        # make it obvious which call failed - a bare '404' told us nothing useful.
        # The original exception is kept as InnerException; Get-HttpStatus digs the
        # status back out of it, because this wrapper has no .Response of its own.
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

# Money in this API arrives in MINOR units (cents for USD) with an explicit
# exponent / decimal_places. Reading it as a major unit overstates every figure
# by 100x, which is exactly what "$5000.00 of $5000.00" looked like.
function ConvertFrom-MinorUnits($value, $exponent) {
    if ($null -eq $value) { return $null }
    $e = 2
    if ($null -ne $exponent) { try { $e = [int]$exponent } catch { $e = 2 } }
    if ($e -lt 0 -or $e -gt 6) { $e = 2 }
    return [double]$value / [math]::Pow(10, $e)
}

function Format-Money($amount, $currency, $exponent) {
    if ($null -eq $amount) { return '' }
    $e = 2
    if ($null -ne $exponent) { try { $e = [int]$exponent } catch { $e = 2 } }
    if ($e -lt 0 -or $e -gt 6) { $e = 2 }
    $cur = 'USD'
    if ($currency) { $cur = [string]$currency }
    # built from char codes so this file stays pure ASCII
    switch ($cur) {
        'USD'   { $sym = '$' }
        'EUR'   { $sym = [string][char]0x20AC }
        'GBP'   { $sym = [string][char]0x00A3 }
        'JPY'   { $sym = [string][char]0x00A5 }
        default { $sym = '' }
    }
    $num = ([double]$amount).ToString('N' + $e)
    if ($sym) { return ($sym + $num) }
    return ($num + ' ' + $cur)
}

# Reads either shape: the newer `spend` object (amount_minor/exponent) or the
# older `extra_usage` (used_credits/monthly_limit scaled by decimal_places).
function Get-SpendRow($d) {
    $sp = $null
    if ($d.PSObject.Properties.Name -contains 'spend') { $sp = $d.spend }
    if ($sp -and $sp.PSObject.Properties.Name -contains 'enabled' -and $sp.enabled) {
        $exp = $null; $cur = $null; $used = $null
        if ($sp.PSObject.Properties.Name -contains 'used' -and $sp.used) {
            $u = $sp.used
            if ($u.PSObject.Properties.Name -contains 'exponent')     { $exp = $u.exponent }
            if ($u.PSObject.Properties.Name -contains 'currency')     { $cur = $u.currency }
            if ($u.PSObject.Properties.Name -contains 'amount_minor') { $used = ConvertFrom-MinorUnits $u.amount_minor $exp }
        }
        $limit = $null
        if ($sp.PSObject.Properties.Name -contains 'limit' -and $null -ne $sp.limit) {
            if ($sp.limit -is [System.Management.Automation.PSObject] -or $sp.limit -is [pscustomobject]) {
                if ($sp.limit.PSObject.Properties.Name -contains 'amount_minor') { $limit = ConvertFrom-MinorUnits $sp.limit.amount_minor $exp }
            } else { $limit = ConvertFrom-MinorUnits $sp.limit $exp }
        }
        $pct = 0
        if ($sp.PSObject.Properties.Name -contains 'percent' -and $null -ne $sp.percent) { $pct = [double]$sp.percent }
        $sev = ''
        if ($sp.PSObject.Properties.Name -contains 'severity') { $sev = [string]$sp.severity }

        $sub = 'extra usage'
        if ($null -ne $used -and $null -ne $limit) { $sub = ('{0} / {1} mo' -f (Format-Money $used $cur $exp), (Format-Money $limit $cur $exp)) }
        elseif ($null -ne $used)                   { $sub = ('{0} used'     -f (Format-Money $used $cur $exp)) }
        return @{ Label = 'Extra usage'; Short = 'Extra'; Percent = $pct; Reset = $sub; Severity = $sev; Literal = $true }
    }

    if ($d.PSObject.Properties.Name -contains 'extra_usage' -and $d.extra_usage -and $d.extra_usage.is_enabled) {
        $e2 = $d.extra_usage
        $dp = $null; $cur = $null
        if ($e2.PSObject.Properties.Name -contains 'decimal_places') { $dp  = $e2.decimal_places }
        if ($e2.PSObject.Properties.Name -contains 'currency')       { $cur = $e2.currency }
        $used = $null; $limit = $null
        if ($e2.PSObject.Properties.Name -contains 'used_credits')  { $used  = ConvertFrom-MinorUnits $e2.used_credits  $dp }
        if ($e2.PSObject.Properties.Name -contains 'monthly_limit') { $limit = ConvertFrom-MinorUnits $e2.monthly_limit $dp }
        $pct = 0
        if ($e2.PSObject.Properties.Name -contains 'utilization' -and $null -ne $e2.utilization) { $pct = ConvertTo-Percent $e2.utilization }

        $sub = 'extra usage credits'
        if ($null -ne $used -and $null -ne $limit) { $sub = ('{0} / {1} mo' -f (Format-Money $used $cur $dp), (Format-Money $limit $cur $dp)) }
        elseif ($null -ne $used)                   { $sub = ('{0} used'     -f (Format-Money $used $cur $dp)) }
        return @{ Label = 'Extra usage'; Short = 'Extra'; Percent = $pct; Reset = $sub; Severity = ''; Literal = $true }
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

            # Short is what the compact layout shows; Label is kept for -Diagnose
            switch ($kind) {
                'session'       { $label = 'Session (5h)';      $short = '5h' }
                'weekly_all'    { $label = 'Week (all models)'; $short = '7d' }
                'weekly_scoped' { $label = 'Week';              $short = 'wk' }
                default         { $label = (Get-Culture).TextInfo.ToTitleCase(($kind -replace '_', ' ')); $short = $label }
            }
            if ($kind -eq 'weekly_scoped') {
                $n = Get-ScopeName $l
                if ($n) { $label = 'Week - ' + $n; $short = $n }
            }
            $rows.Add(@{ Label = $label; Short = $short; Percent = $pct; Reset = $reset; Severity = $sev })
            $fromLimits = $true
        }
    }

    if (-not $fromLimits) {
        $defs = @(
            @{ Key = 'five_hour';        Label = 'Session (5h)';      Short = '5h' },
            @{ Key = 'seven_day';        Label = 'Week (all models)'; Short = '7d' },
            @{ Key = 'seven_day_opus';   Label = 'Week - Opus';       Short = 'Opus' },
            @{ Key = 'seven_day_sonnet'; Label = 'Week - Sonnet';     Short = 'Sonnet' }
        )
        foreach ($def in $defs) {
            if ($d.PSObject.Properties.Name -notcontains $def.Key) { continue }
            $w = $d.($def.Key)
            if (-not $w -or $w.PSObject.Properties.Name -notcontains 'utilization') { continue }
            $pct = ConvertTo-Percent $w.utilization
            if ($null -eq $pct) { continue }
            $reset = ''
            if ($w.PSObject.Properties.Name -contains 'resets_at') { $reset = [string]$w.resets_at }
            $rows.Add(@{ Label = $def.Label; Short = $def.Short; Percent = $pct; Reset = $reset; Severity = '' })
        }
    }

    $spendRow = Get-SpendRow $d
    if ($spendRow) { $rows.Add($spendRow) }
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

function Format-Countdown([string]$iso, [switch]$Short) {
    if (-not $iso) { return '' }
    try {
        $t = [datetimeoffset]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture,
                                    [Globalization.DateTimeStyles]::AssumeUniversal)
    } catch { return '' }
    $span = $t - [datetimeoffset]::UtcNow
    if ($span.TotalSeconds -le 0) { if ($Short) { return 'resetting' } return 'resetting...' }

    # round the remainder UP to the next whole minute so a countdown never reads low
    $mins = [int][math]::Ceiling($span.TotalMinutes)
    # -Short drops the 'resets in' words and the inner spaces: same numbers, ~40px less
    if ($Short) {
        if ($mins -ge 1440)   { $rel = '{0}d{1}h' -f [int][math]::Floor($mins / 1440), [int][math]::Floor(($mins % 1440) / 60) }
        elseif ($mins -ge 60) { $rel = '{0}h{1}m' -f [int][math]::Floor($mins / 60), ($mins % 60) }
        else                  { $rel = '{0}m' -f $mins }
    } else {
        if ($mins -ge 1440)   { $rel = 'resets in {0}d {1}h' -f [int][math]::Floor($mins / 1440), [int][math]::Floor(($mins % 1440) / 60) }
        elseif ($mins -ge 60) { $rel = 'resets in {0}h {1}m' -f [int][math]::Floor($mins / 60), ($mins % 60) }
        else                  { $rel = 'resets in {0}m' -f $mins }
    }

    # ...plus the wall-clock time it lands on, in the viewer's own locale and zone
    $local = $t.ToLocalTime()
    $today = [datetimeoffset]::Now.Date
    if     ($local.Date -eq $today)                { $abs = $local.ToString('t') }
    elseif ($local.Date -lt $today.AddDays(7))     { $abs = $local.ToString('ddd ') + $local.ToString('t') }
    else                                           { $abs = $local.ToString('MMM d ') + $local.ToString('t') }

    if ($Short) { return ('{0}  {1}' -f $rel, $abs) }
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
        $now0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Write-Host 'Widget sign-in (Sign in with Google, used first):'
        $wdoc = Read-Login
        $wc = $null
        if ($wdoc) { $wc = New-CredSource 'Widget sign-in' $wdoc }
        if ($wc) {
            $who = Get-LoginEmail $wdoc
            if (-not $who) { $who = '(no email recorded)' }
            $exp = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$wc.ExpiresAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
            $state = 'access token expired, will refresh'
            if ($wc.ExpiresAt -gt ($now0 + 60000)) { $state = 'access token valid until ' + $exp }
            Write-Host ("  {0}: {1}" -f $who, $state) -ForegroundColor Green
            Write-Host ("  {0}" -f $Script:LoginPath) -ForegroundColor DarkGray
        }
        elseif (Test-Login) { Write-Host ("  {0} exists but cannot be read by this Windows user" -f $Script:LoginPath) -ForegroundColor Yellow }
        else { Write-Host '  (not signed in - use "Sign in with Google" on the widget)' -ForegroundColor DarkGray }
        Write-Host ''

        Write-Host 'Claude Code logins found on this machine:'
        $sources = @(Get-CredentialSources -Force)
        if ($sources.Count -eq 0 -and $wc) { Write-Host '  (none - fine, the widget sign-in above is used)' -ForegroundColor DarkGray }
        elseif ($sources.Count -eq 0) {
            Write-Host '  (none)' -ForegroundColor Red
            Write-Host ''
            Write-Host 'Searched:'
            foreach ($p in Get-WindowsCredentialPaths) { Write-Host ("  {0}" -f $p) }
            $d = @(Get-WslDistros)
            if ($d.Count) { foreach ($x in $d) { Write-Host ("  WSL[{0}] ~/.claude, /root/.claude, /home/*/.claude" -f $x) } }
            else { Write-Host '  (no WSL distros detected)' }
            Write-Host ''
            Write-Host 'RESULT: click "Sign in with Google" on the widget (or run "claude" and /login).' -ForegroundColor Red
            return
        }
        $now = $now0
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
            $sc = Get-HttpStatus $_
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
        $sc = Get-HttpStatus $_
        Write-Host ("usage endpoint: FAILED  {0}" -f ($_.Exception.Message -replace '^usage endpoint: ', '')) -ForegroundColor Red
        if ($Script:UsedSource) { Write-Host ("  tried with: {0}" -f $Script:UsedSource) }
        if ($Script:LastRefreshError) { Write-Host ("  refresh error: {0}" -f $Script:LastRefreshError) -ForegroundColor Red }
        if ($sc -eq 401 -or $sc -eq 403) {
            Write-Host '  -> no usable login: expired and not refreshable.' -ForegroundColor Yellow
            Write-Host '     Click "Sign in with Google" on the widget, or run "claude"'
            Write-Host '     (in WSL if that is where you use it) and /login again.'
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
        Topmost="True" ShowInTaskbar="False" SizeToContent="Height" Width="224"
        WindowStartupLocation="Manual" ResizeMode="NoResize">
  <Border CornerRadius="10" Background="#F21B1B1F" BorderBrush="#26FFFFFF" BorderThickness="1" Padding="10,7,10,8">
    <StackPanel>
      <!-- one header line: identity on the left, status and close on the right -->
      <Grid Margin="0,0,0,5">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" x:Name="AccountText" Text="Claude Usage" Foreground="#8A8A95"
                   FontFamily="Segoe UI" FontSize="10" VerticalAlignment="Center"
                   TextTrimming="CharacterEllipsis"/>
        <TextBlock Grid.Column="1" x:Name="StatusText" Text="" Foreground="#9A9AA5" FontFamily="Segoe UI"
                   FontSize="9" VerticalAlignment="Center" Margin="6,0,0,0"/>
        <!-- Background must be a real brush, not null, or it will not be hit-testable -->
        <Border Grid.Column="2" x:Name="CloseBtn" Background="#00FFFFFF" Cursor="Hand" CornerRadius="3"
                Margin="5,-2,-3,-2" Padding="5,1,5,2" ToolTip="Close (Esc)" VerticalAlignment="Center">
          <TextBlock x:Name="CloseGlyph" Text="&#x2715;" Foreground="#8A8A95" FontFamily="Segoe UI"
                     FontSize="10" VerticalAlignment="Center"/>
        </Border>
      </Grid>
      <StackPanel x:Name="Rows"/>
      <TextBlock x:Name="HintText" Text="" Foreground="#8A8A95" FontFamily="Segoe UI" FontSize="9"
                 TextWrapping="Wrap" Margin="0,5,0,0" Visibility="Collapsed"/>
      <!-- shown only when there is no usable login, or while signing in -->
      <Border x:Name="SignInBtn" Background="#D97757" CornerRadius="5" Cursor="Hand" Margin="0,6,0,0"
              Padding="8,4,8,5" Visibility="Collapsed" ToolTip="Opens claude.ai in your browser">
        <TextBlock x:Name="SignInText" Text="Sign in with Google..." Foreground="#FFFFFF" FontFamily="Segoe UI"
                   FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Center"/>
      </Border>
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
$signInBtn  = $win.FindName('SignInBtn')
$signInText = $win.FindName('SignInText')
$win.Opacity = [double]$Script:State.Opacity

if ($null -ne $Script:State.Left -and $null -ne $Script:State.Top) {
    $win.Left = [double]$Script:State.Left; $win.Top = [double]$Script:State.Top
} else {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $win.Left = $wa.Right - 244; $win.Top = $wa.Top + 20   # card is 224 wide + 20 margin
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

$RowWidth  = 204.0   # content width inside the card (card 224 - 2x10 padding)
$RowHeight = 18.0

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

# Compact row: label, percent and reset sit on ONE line, and the progress bar is
# painted behind them instead of occupying its own line and its own column. That
# removes two of the three lines each metric used to take.
function New-UsageRow($label, $percent, $reset, $severity, $short) {
    $g = New-Object Windows.Controls.Grid
    $g.Height = $RowHeight
    $g.Margin = (Th 0 0 0 3)

    $track = New-Object Windows.Controls.Border
    $track.CornerRadius = (CR 4); $track.Background = (B '#14FFFFFF')
    $g.Children.Add($track) | Out-Null

    $p = [math]::Max(0, [math]::Min(100, [double]$percent))
    $fill = New-Object Windows.Controls.Border
    $fill.CornerRadius = (CR 4); $fill.HorizontalAlignment = 'Left'
    $fill.Width = [math]::Max(2, $RowWidth * $p / 100)
    # same hue as before at ~35% alpha, so the text on top stays readable
    $fill.Background = (B ('#59' + (Get-BarColour $p $severity).Substring(1)))
    $g.Children.Add($fill) | Out-Null

    $inner = New-Object Windows.Controls.Grid
    $inner.Margin = (Th 7 0 7 0)
    foreach ($w in @('Auto','Auto','*','Auto')) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        if ($w -eq 'Auto') { $cd.Width = [System.Windows.GridLength]::Auto }
        $inner.ColumnDefinitions.Add($cd)
    }

    $lb = New-Object Windows.Controls.TextBlock
    $lb.Text = $short; $lb.FontFamily = (FF 'Segoe UI'); $lb.FontSize = 11
    $lb.Foreground = (B '#D8D8E0'); $lb.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($lb, 0); $inner.Children.Add($lb) | Out-Null

    $pv = New-Object Windows.Controls.TextBlock
    $pv.Text = ('{0:0}%' -f $percent); $pv.FontFamily = (FF 'Segoe UI'); $pv.FontSize = 11
    $pv.FontWeight = [System.Windows.FontWeights]::SemiBold; $pv.Foreground = (B '#FFFFFF')
    $pv.VerticalAlignment = 'Center'; $pv.Margin = (Th 6 0 0 0)
    [Windows.Controls.Grid]::SetColumn($pv, 1); $inner.Children.Add($pv) | Out-Null

    $rs = New-Object Windows.Controls.TextBlock
    $rs.Text = $reset; $rs.FontFamily = (FF 'Segoe UI'); $rs.FontSize = 10
    $rs.Foreground = (B '#A8A8B4'); $rs.VerticalAlignment = 'Center'
    $rs.TextTrimming = 'CharacterEllipsis'; $rs.Margin = (Th 6 0 0 0)
    $rs.ToolTip = ('{0} - {1}' -f $label, $reset)     # full label still reachable
    [Windows.Controls.Grid]::SetColumn($rs, 3); $inner.Children.Add($rs) | Out-Null

    $g.Children.Add($inner) | Out-Null
    return $g
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
$Script:NeedsSignIn = $false
$Script:SignIn      = $null   # @{ Srv; Verifier; State; Deadline } while the browser is out

function Set-Hint([string]$text) {
    if ($text) { $hintText.Text = $text; $hintText.Visibility = 'Visible' }
    else { $hintText.Visibility = 'Collapsed' }
}

function Update-SignInUi {
    if ($Script:SignIn) {
        $signInText.Text = 'Cancel sign-in'; $signInBtn.Background = (B '#2EFFFFFF')
        $signInBtn.Visibility = 'Visible'
    } elseif ($Script:NeedsSignIn) {
        $signInText.Text = 'Sign in with Google...'; $signInBtn.Background = (B '#D97757')
        $signInBtn.Visibility = 'Visible'
    } else {
        $signInBtn.Visibility = 'Collapsed'
    }
}

function Render {
    if (-not $Script:LastData) { return }
    $d = $Script:LastData
    $rows.Children.Clear()

    foreach ($r in @(Get-LimitRows $d)) {
        $reset = $r.Reset
        if (-not $r.ContainsKey('Literal')) { $reset = Format-Countdown $r.Reset -Short }
        $short = $r.Label
        if ($r.ContainsKey('Short') -and $r.Short) { $short = $r.Short }
        $rows.Children.Add((New-UsageRow $r.Label $r.Percent $reset $r.Severity $short)) | Out-Null
    }

    if ($rows.Children.Count -eq 0) { Show-Message 'No usage windows reported.' }

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
        $Script:NeedsSignIn = $false
        if (-not $Script:Account) {
            try {
                $Script:Account = Get-ProfileEmail (Get-Profile)
                if ($Script:Account) { $accountText.Text = $Script:Account }
            } catch { }   # cosmetic only - never let this break the usage display
        }
        if (-not $Script:SignIn) { Set-Hint '' }
        Render
    }
    catch {
        $msg  = $_.Exception.Message
        $code = Get-HttpStatus $_

        if ($msg -eq 'NOTOKEN') {
            $Script:NeedsSignIn = $true
            $Script:Account = $null
            $Script:LastData = $null   # e.g. just signed out: don't keep showing that account's numbers
            $Script:LastOk = $null
            $accountText.Text = 'Claude Usage'
            Show-Message 'Not signed in.'
            if (-not $Script:SignIn) { Set-Hint 'Sign in with Google through claude.ai.' }
            $statusText.Text = 'no login'; $statusText.Foreground = (B '#F87171')
            $Script:Backoff = 4
            return
        }
        if ($code -eq 401 -or $code -eq 403) {
            # a rejected widget token gets one forced refresh before giving up on it
            if ("$Script:UsedSource" -like 'Widget sign-in*') { $Script:WidgetForceRefresh = $true }
            $Script:CredSources = $null            # re-scan: the user may have just logged in
            $Script:State.CachedToken = $null
            $Script:Account = $null
            $Script:NeedsSignIn = $true
            $accountText.Text = 'Claude Usage'
            if (-not $Script:SignIn) { Set-Hint 'Login expired. Sign in again to resume.' }
            $statusText.Text = 'auth'; $statusText.Foreground = (B '#F87171')
        }
        elseif ($code -eq 429) {
            $hintText.Text = 'Rate limited - backing off.'
            $hintText.Visibility = 'Visible'
            $statusText.Text = 'throttled'; $statusText.Foreground = (B '#FBBF24')
        }
        else {
            if ($Script:LastRefreshError) { $msg = ('{0} / refresh: {1}' -f $msg, $Script:LastRefreshError) }
            $hintText.Text = ('Fetch failed - run Diagnose.cmd. ({0})' -f $msg)
            $hintText.Visibility = 'Visible'
            $statusText.Text = 'offline'; $statusText.Foreground = (B '#FBBF24')
        }
        if (-not $Script:LastData) { Show-Message 'Waiting for usage data...' }
        $Script:Backoff = [math]::Min(5, $Script:Backoff + 1)   # 180s -> up to ~16 min
    }
    finally {
        $mult = [math]::Pow(2, $Script:Backoff)
        $Script:NextFetchAt = [datetime]::UtcNow.AddSeconds($RefreshSeconds * $mult)
        Update-SignInUi
    }
}

# ---------------------------------------------------------------- sign in with Google

function Request-Refresh { $Script:NextFetchAt = [datetime]::MinValue; $Script:Backoff = 0 }

function Start-SignIn {
    if ($Script:SignIn) { return }
    try { $srv = Start-CallbackServer }
    catch { Set-Hint ('Sign-in failed: could not listen for the browser ({0})' -f $_.Exception.Message); return }
    $verifier = New-RandomToken
    $state    = New-RandomToken
    $url = Get-AuthorizeUrl $srv.Port (Get-PkceChallenge $verifier) $state
    $Script:SignIn = @{ Srv = $srv; Verifier = $verifier; State = $state; Deadline = [datetime]::UtcNow.AddMinutes(5) }
    Set-Hint 'Finish signing in in your browser...'
    Update-SignInUi
    $signInTimer.Start()
    try { Start-Process $url }
    catch {
        # no default browser registered: hand the link over instead
        try { [System.Windows.Clipboard]::SetText($url) } catch { }
        Set-Hint 'Could not open a browser. The sign-in link is on the clipboard - paste it into one.'
    }
}

# $Callback is the browser's redirect, or $null with $Reason when it never came.
function Complete-SignIn($Callback, [string]$Reason) {
    $si = $Script:SignIn
    if (-not $si) { return }
    $Script:SignIn = $null
    $signInTimer.Stop()
    Stop-CallbackServer $si.Srv
    try {
        if (-not $Callback) { throw $Reason }
        $doc = Complete-BrowserSignIn $Callback $si.Verifier $si.State $si.Srv.Port
        try { Save-Login $doc } catch { throw ('could not save the login ({0})' -f $_.Exception.Message) }
        $Script:WidgetForceRefresh = $false
        $Script:NeedsSignIn = $false
        $Script:Account = Get-LoginEmail $doc
        if ($Script:Account) { $accountText.Text = $Script:Account }
        Set-Hint ''
        Request-Refresh
    }
    catch {
        $m = $_.Exception.Message
        if ($m -eq 'cancelled') { Set-Hint 'Sign-in cancelled.' }
        else { Set-Hint ('Sign-in failed: ' + $m) }
    }
    Update-SignInUi
}

function Invoke-SignInButton {
    if ($Script:SignIn) { Complete-SignIn $null 'cancelled' } else { Start-SignIn }
}

function Invoke-SignOut {
    if ($Script:SignIn) { Complete-SignIn $null 'cancelled' }
    Remove-Login
    $Script:WidgetForceRefresh = $false
    $Script:Account = $null
    $accountText.Text = 'Claude Usage'
    Request-Refresh
}

# Polls the loopback listener while the browser is out. Separate from the 1s ticker
# so the redirect is answered promptly; never blocks (see Step-CallbackServer).
$signInTimer = New-Object System.Windows.Threading.DispatcherTimer
$signInTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$signInTimer.Add_Tick({
    $si = $Script:SignIn
    if (-not $si) { $signInTimer.Stop(); return }
    if ([datetime]::UtcNow -gt $si.Deadline) { Complete-SignIn $null 'timed out waiting for the browser'; return }
    $cb = $null
    try { $cb = Step-CallbackServer $si.Srv }
    catch { Complete-SignIn $null ('could not listen for the browser ({0})' -f $_.Exception.Message); return }
    if ($cb) { Complete-SignIn $cb $null }
})

# ---------------------------------------------------------------- interaction

# Every quit route funnels through here so the tray icon can never be orphaned.
function Close-Widget {
    try { if ($Script:SignIn) { $signInTimer.Stop(); Stop-CallbackServer $Script:SignIn.Srv; $Script:SignIn = $null } } catch { }
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

# --- sign-in button (same DragMove trap as the close button) -----
$signInBtn.Add_MouseLeftButtonDown({
    param($sender, $e)
    if ($e) { $e.Handled = $true }
    Invoke-SignInButton
})
$signInBtn.Add_MouseEnter({ if (-not $Script:SignIn) { $signInBtn.Background = (B '#E38A6D') } else { $signInBtn.Background = (B '#40FFFFFF') } })
$signInBtn.Add_MouseLeave({ Update-SignInUi })

function Get-SignInMenuLabel {
    if ($Script:SignIn) { return 'Cancel sign-in' }
    if (Test-Login)     { return 'Sign in again...' }
    return 'Sign in with Google...'
}

# --- right-click menu on the widget itself, so quitting is discoverable
# without hunting for a tray icon Windows may have hidden in the overflow
$ctx = New-Object System.Windows.Controls.ContextMenu
$ctxRefresh = New-Object System.Windows.Controls.MenuItem
$ctxRefresh.Header = 'Refresh now'
$ctxRefresh.Add_Click({ Request-Refresh })
$ctxSignIn = New-Object System.Windows.Controls.MenuItem
$ctxSignIn.Header = 'Sign in with Google...'
$ctxSignIn.Add_Click({ Invoke-SignInButton })
$ctxSignOut = New-Object System.Windows.Controls.MenuItem
$ctxSignOut.Header = 'Sign out'
$ctxSignOut.Add_Click({ Invoke-SignOut })
$ctx.Add_Opened({
    $ctxSignIn.Header = Get-SignInMenuLabel
    if (Test-Login) { $ctxSignOut.Visibility = 'Visible' } else { $ctxSignOut.Visibility = 'Collapsed' }
})
$ctxHide = New-Object System.Windows.Controls.MenuItem
$ctxHide.Header = 'Hide to tray'
$ctxHide.Add_Click({ $win.Hide() })
$ctxClose = New-Object System.Windows.Controls.MenuItem
$ctxClose.Header = 'Close'
$ctxClose.Add_Click({ Close-Widget })
$ctx.Items.Add($ctxRefresh) | Out-Null
$ctx.Items.Add($ctxHide)    | Out-Null
$ctx.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$ctx.Items.Add($ctxSignIn)  | Out-Null
$ctx.Items.Add($ctxSignOut) | Out-Null
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
$miSignIn  = $menu.Items.Add('Sign in with Google...')
$miSignOut = $menu.Items.Add('Sign out')
$menu.Items.Add('-') | Out-Null
$miExit = $menu.Items.Add('Exit')
$tray.ContextMenuStrip = $menu
$menu.Add_Opening({
    $miSignIn.Text = Get-SignInMenuLabel
    $miSignOut.Visible = (Test-Login)
})
$miSignIn.Add_Click({ Invoke-SignInButton })
$miSignOut.Add_Click({ Invoke-SignOut })

$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Widget.lnk'
$miStart.Checked = Test-Path $startupLnk

$miShow.Add_Click({ if ($win.Visibility -eq 'Visible') { $win.Hide() } else { $win.Show(); $win.Activate() } })
$miRef.Add_Click({ Request-Refresh })
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
