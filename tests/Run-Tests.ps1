<#
  Test suite for ClaudeUsageWidget.ps1. Runs under pwsh on Linux or Windows:

      pwsh -NoProfile -File tests/Run-Tests.ps1

  Loads only the non-UI part of the script (configuration .. window marker), so
  no WPF is needed. Network calls are stubbed at Invoke-RestMethod - never our own
  functions, because a stub of our own function keeps the suite green after the
  real one is deleted. The loopback listener is exercised for real.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Repo = Split-Path -Parent $PSScriptRoot
$Src  = Join-Path $Repo 'ClaudeUsageWidget.ps1'
$Text = [IO.File]::ReadAllText($Src)

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('cuw-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp | Out-Null

$markStart = '# ---------------------------------------------------------------- configuration'
$markEnd   = '# ---------------------------------------------------------------- window'
$i0 = $Text.IndexOf($markStart); $i1 = $Text.IndexOf($markEnd)
if ($i0 -lt 0 -or $i1 -le $i0) { throw 'section markers not found in ClaudeUsageWidget.ps1' }
$CorePath = Join-Path $Tmp 'core.ps1'
[IO.File]::WriteAllText($CorePath, $Text.Substring($i0, $i1 - $i0))
. $CorePath

# ------------------------------------------------------------------ harness

$Script:Results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $Script:Results.Add(@{ Name = $Name; Ok = $true }) ; Write-Host ("  ok    {0}" -f $Name) -ForegroundColor Green }
    catch { $Script:Results.Add(@{ Name = $Name; Ok = $false }); Write-Host ("  FAIL  {0}`n        {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red }
}
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }
function Eq($Actual, $Expected, [string]$What) {
    if ("$Actual" -cne "$Expected") { throw ("{0}: expected '{1}', got '{2}'" -f $What, $Expected, $Actual) }
}

# Network stub. $Script:Responder gets the call hashtable and returns an object or throws.
$Script:Calls = New-Object System.Collections.Generic.List[object]
$Script:Responder = { param($c) throw 'no responder set' }
function Invoke-RestMethod {
    param($Uri, $Method, $Body, $ContentType, $UserAgent, $TimeoutSec, $Headers)
    $c = @{ Uri = [string]$Uri; Method = $Method; Body = $Body; UserAgent = $UserAgent }
    $Script:Calls.Add($c)
    return (& $Script:Responder $c)
}
function HttpError([int]$Code) {
    throw (New-Object System.Exception ("The remote server returned an error: ({0}) Error." -f $Code))
}

# DPAPI exists only on Windows. Elsewhere use a reversible stand-in; a separate
# static check proves the real functions still use ProtectedData/CurrentUser.
$IsWin = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
if (-not $IsWin) {
    function Protect-LoginText([string]$Text)   { return 'TEST' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
    function Unprotect-LoginText([string]$Blob) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Blob.Trim().Substring(4))) }
}

$Script:LoginPath = Join-Path $Tmp 'widget-login.dat'
$Script:StatePath = Join-Path $Tmp 'widget-state.json'
$CcDir = Join-Path $Tmp 'cc'
New-Item -ItemType Directory -Path $CcDir | Out-Null
$CcFile = Join-Path $CcDir '.credentials.json'
$env:USERPROFILE = $null
Remove-Item Env:\CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue
$Mail = 'user@example.com'

function NowMs { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Reset-World {
    Remove-Login
    if (Test-Path $CcFile) { Remove-Item $CcFile -Force }
    if (Test-Path $Script:StatePath) { Remove-Item $Script:StatePath -Force }
    $env:CLAUDE_CONFIG_DIR = $CcDir
    $Script:CredSources = $null
    $Script:State.CachedToken = $null; $Script:State.CachedExpires = 0; $Script:State.CachedRefresh = $null
    $Script:WidgetForceRefresh = $false; $Script:LastWidgetError = $null; $Script:LastRefreshError = $null
    $Script:UsedSource = $null
    $Script:Calls.Clear()
    $Script:Responder = { param($c) throw 'unexpected network call' }
}
function Set-ClaudeCodeLogin([string]$Access, [string]$Refresh, [double]$ExpiresAt) {
    $o = @{ claudeAiOauth = @{ accessToken = $Access; refreshToken = $Refresh; expiresAt = [int64]$ExpiresAt } }
    [IO.File]::WriteAllText($CcFile, ($o | ConvertTo-Json -Depth 5))
    $Script:CredSources = $null
}
function Set-WidgetLogin([string]$Access, [string]$Refresh, [double]$ExpiresAt, [string]$Email) {
    $doc = [ordered]@{ claudeAiOauth = [ordered]@{ accessToken = $Access; refreshToken = $Refresh; expiresAt = [int64]$ExpiresAt; scopes = @('user:profile', 'user:inference') } }
    if ($Email) { $doc.account = $Email }
    Save-Login $doc
}
function Get-QueryParams([string]$Url) {
    $h = @{}
    foreach ($kv in $Url.Substring($Url.IndexOf('?') + 1).Split('&')) {
        $eq = $kv.IndexOf('=')
        $h[$kv.Substring(0, $eq)] = [Uri]::UnescapeDataString($kv.Substring($eq + 1))
    }
    return $h
}

# Plays the browser: connect, send one GET, return the raw response once the server answered.
function Invoke-FakeBrowser($Srv, [string]$HostName, [string]$PathAndQuery) {
    if ($HostName -eq '127.0.0.1')  { $cl = New-Object System.Net.Sockets.TcpClient ([System.Net.Sockets.AddressFamily]::InterNetwork) }
    elseif ($HostName -eq '::1')    { $cl = New-Object System.Net.Sockets.TcpClient ([System.Net.Sockets.AddressFamily]::InterNetworkV6) }
    else                            { $cl = New-Object System.Net.Sockets.TcpClient }
    $cl.Connect($HostName, $Srv.Port)
    $req = "GET $PathAndQuery HTTP/1.1`r`nHost: localhost:$($Srv.Port)`r`nUser-Agent: test`r`nAccept: text/html`r`n`r`n"
    $b = [Text.Encoding]::ASCII.GetBytes($req)
    $st = $cl.GetStream(); $st.Write($b, 0, $b.Length); $st.Flush()
    $cb = $null
    for ($n = 0; $n -lt 100; $n++) {
        $cb = Step-CallbackServer $Srv
        if ($cb -or $st.DataAvailable) { break }
        Start-Sleep -Milliseconds 20
    }
    $cl.ReceiveTimeout = 3000
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 8192
    try { while (($k = $st.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $k) } } catch { }
    $cl.Close()
    return @{ Callback = $cb; Response = [Text.Encoding]::UTF8.GetString($ms.ToArray()) }
}

Write-Host ''
Write-Host 'ClaudeUsageWidget.ps1 tests' -ForegroundColor Cyan

# ------------------------------------------------------------------ static

Check 'script parses with no errors' {
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$e)
    Assert (@($e).Count -eq 0) ('parse errors: ' + (@($e) | ForEach-Object { $_.Message }) -join '; ')
}

Check 'script is pure ASCII with CRLF line endings' {
    $bytes = [IO.File]::ReadAllBytes($Src)
    for ($k = 0; $k -lt $bytes.Length; $k++) {
        if ($bytes[$k] -gt 127) { throw "non-ASCII byte at offset $k" }
        if ($bytes[$k] -eq 10 -and ($k -eq 0 -or $bytes[$k - 1] -ne 13)) { throw "bare LF at offset $k (run: git add --renormalize .)" }
    }
}

Check 'XAML is well-formed and every FindName target exists' {
    $m = [regex]::Match($Text, "\[xml\]\`$xaml = @'\r?\n(.*?)\r?\n'@", 'Singleline')
    Assert $m.Success 'XAML here-string not found'
    [xml]$x = $m.Groups[1].Value
    $names = @($x.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') })
    foreach ($f in [regex]::Matches($Text, "FindName\('([^']+)'\)")) {
        Assert ($names -contains $f.Groups[1].Value) ("FindName('{0}') has no x:Name in the XAML" -f $f.Groups[1].Value)
    }
    Assert ($names -contains 'SignInBtn') 'SignInBtn missing'
}

Check 'every command the script calls exists (or is Windows-only and whitelisted)' {
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    $winOnly = @('Get-Acl', 'Set-Acl', 'wsl.exe')
    $missing = @()
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $n = $c.GetCommandName()
        if (-not $n) { continue }
        if ($defined -contains $n -or $winOnly -contains $n) { continue }
        if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { $missing += $n }
    }
    Assert ($missing.Count -eq 0) ('undefined: ' + (($missing | Sort-Object -Unique) -join ', '))
}

Check 'login storage uses DPAPI, CurrentUser scope, owner-only ACL' {
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    $fn = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $fn[$f.Name] = $f.Extent.Text }
    foreach ($n in @('Protect-LoginText', 'Unprotect-LoginText')) {
        Assert ($fn.ContainsKey($n)) "$n is gone"
        Assert ($fn[$n] -match 'ProtectedData\]::(Un)?[Pp]rotect' -and $fn[$n] -match 'DataProtectionScope\]::CurrentUser') "$n no longer uses DPAPI CurrentUser"
    }
    Assert ($fn['Save-Login'] -match 'Protect-LoginText' -and $fn['Save-Login'] -match 'Set-OwnerOnlyAcl') 'Save-Login must encrypt and lock down the file'
    Assert ((Get-Content (Join-Path $Repo '.gitignore') -Raw) -match 'widget-login\.dat') 'widget-login.dat is not gitignored'
}

# ------------------------------------------------------------------ PKCE and URLs

Check 'PKCE challenge matches the RFC 7636 test vector' {
    Eq (Get-PkceChallenge 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk') 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM' 'challenge'
}

Check 'random tokens are 43 url-safe chars and unique' {
    $a = New-RandomToken; $b = New-RandomToken
    Assert ($a -cmatch '^[A-Za-z0-9_-]{43}$') "bad token '$a'"
    Assert ($a -cne $b) 'two tokens were equal'
}

Check 'authorize URL carries exactly the parameters claude.ai accepts' {
    $u = Get-AuthorizeUrl 51234 'CHAL' 'STATE-1'
    Assert ($u.StartsWith('https://claude.ai/oauth/authorize?')) "wrong base: $u"
    $q = Get-QueryParams $u
    Eq (($q.Keys | Sort-Object) -join ',') 'client_id,code_challenge,code_challenge_method,redirect_uri,response_type,scope,state' 'keys'
    Eq $q.client_id '9d1c250a-e61b-44d9-88ed-5944d1962f5e' 'client_id'
    Eq $q.response_type 'code' 'response_type'
    Eq $q.redirect_uri 'http://localhost:51234/callback' 'redirect_uri'
    Eq $q.scope 'user:profile user:inference user:sessions:claude_code user:mcp_servers' 'scope'
    Eq $q.code_challenge_method 'S256' 'method'
    Eq $q.state 'STATE-1' 'state'
    Assert ($u -notmatch 'org%3Acreate_api_key' -and $u -notmatch 'code=true') 'Console scope or code=true leaked in'
    Assert ($u -match 'scope=user%3Aprofile%20user') 'spaces must be %20-encoded'
}

# ------------------------------------------------------------------ callback parsing

Check 'callback line: code and state' {
    $c = ConvertFrom-CallbackLine 'GET /callback?code=abc123&state=xyz HTTP/1.1'
    Eq $c.Code 'abc123' 'code'; Eq $c.State 'xyz' 'state'; Assert (-not $c.Error) 'unexpected error'
}
Check 'callback line: error_description wins over error, and is decoded' {
    $c = ConvertFrom-CallbackLine 'GET /callback?error=access_denied&error_description=User+said+no%21&state=s HTTP/1.1'
    Eq $c.Error 'User said no!' 'error'; Assert (-not $c.Code) 'code should be empty'
}
Check 'callback line: code#state shape (manual flow)' {
    $c = ConvertFrom-CallbackLine 'GET /callback?code=abc%23st8 HTTP/1.1'
    Eq $c.Code 'abc' 'code'; Eq $c.State 'st8' 'state'
}
Check 'callback line: anything else is ignored' {
    foreach ($l in @('GET /favicon.ico HTTP/1.1', 'POST /callback?code=a HTTP/1.1', 'GET /callbackx?code=a HTTP/1.1', '', 'garbage')) {
        Assert ($null -eq (ConvertFrom-CallbackLine $l)) "accepted '$l'"
    }
}
Check 'landing page is ASCII, bilingual, and escapes the error' {
    $h = Get-SignInPageHtml $false '<script>x</script>'
    Assert ($h -notmatch '<script>') 'error text not escaped'
    Assert ($h -match '&lt;script&gt;') 'escaped error missing'
    Assert ($h -match '&#x767B;&#x5165;') 'Chinese line missing'
    Assert (@($h.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count -eq 0) 'non-ASCII in page'
    Assert ((Get-SignInPageHtml $true $null) -match 'Signed in to Claude Usage') 'ok title missing'
}

# ------------------------------------------------------------------ token exchange

$TokResp = '{"token_type":"Bearer","access_token":"AT-new","refresh_token":"RT-new","expires_in":28800,"scope":"user:profile user:inference","account":{"uuid":"u1","email_address":"' + $Mail + '"}}'

Check 'code exchange posts the authorization_code grant to api.anthropic.com' {
    Reset-World
    $Script:Responder = { param($c) $TokResp | ConvertFrom-Json }
    $r = Invoke-CodeExchange 'CODE' 'VERIFIER' 'http://localhost:5/callback' 'ST'
    Eq $r.access_token 'AT-new' 'access_token'
    Eq $Script:Calls.Count 1 'calls'
    Eq $Script:Calls[0].Uri 'https://api.anthropic.com/v1/oauth/token' 'host'
    Assert ($Script:Calls[0].UserAgent -like 'claude-code/*') 'User-Agent missing'
    $b = $Script:Calls[0].Body | ConvertFrom-Json
    Eq (($b.PSObject.Properties.Name | Sort-Object) -join ',') 'client_id,code,code_verifier,grant_type,redirect_uri,state' 'body keys'
    Eq $b.grant_type 'authorization_code' 'grant_type'; Eq $b.code 'CODE' 'code'
    Eq $b.code_verifier 'VERIFIER' 'verifier'; Eq $b.redirect_uri 'http://localhost:5/callback' 'redirect'
    Eq $b.client_id '9d1c250a-e61b-44d9-88ed-5944d1962f5e' 'client_id'; Eq $b.state 'ST' 'state'
}
Check 'code exchange: a 4xx is final, never replayed on the fallback host' {
    Reset-World
    $Script:Responder = { param($c) HttpError 400 }
    $err = $null; try { Invoke-CodeExchange 'C' 'V' 'R' 'S' | Out-Null } catch { $err = $_.Exception.Message }
    Assert ($err -match 'rejected \(400\)') "wrong error: $err"
    Eq $Script:Calls.Count 1 'calls'
}
Check 'code exchange: a 404 or 5xx moves on to the next host' {
    Reset-World
    $Script:Responder = { param($c) if ($Script:Calls.Count -eq 1) { HttpError 404 } elseif ($Script:Calls.Count -eq 2) { HttpError 502 } else { $TokResp | ConvertFrom-Json } }
    $r = Invoke-CodeExchange 'C' 'V' 'R' 'S'
    Eq $r.access_token 'AT-new' 'token'; Eq $Script:Calls.Count 3 'calls'
}
Check 'code exchange: 200 without a token is an error, not a retry' {
    Reset-World
    $Script:Responder = { param($c) '{"error":"weird"}' | ConvertFrom-Json }
    $err = $null; try { Invoke-CodeExchange 'C' 'V' 'R' 'S' | Out-Null } catch { $err = $_.Exception.Message }
    Assert ($err -match 'no access token') "wrong error: $err"; Eq $Script:Calls.Count 1 'calls'
}
Check 'token response -> Claude Code credential shape with account email' {
    $d = New-LoginDocument ($TokResp | ConvertFrom-Json) 1000
    Eq $d.claudeAiOauth.accessToken 'AT-new' 'access'; Eq $d.claudeAiOauth.refreshToken 'RT-new' 'refresh'
    Eq $d.claudeAiOauth.expiresAt (1000 + 28800 * 1000) 'expiresAt'
    Eq ($d.claudeAiOauth.scopes -join ',') 'user:profile,user:inference' 'scopes'
    Eq $d.account $Mail 'account'
    Assert ($null -eq (New-LoginDocument ('{"refresh_token":"x"}' | ConvertFrom-Json) 0)) 'accepted a response with no access token'
    $c = New-CredSource 'x' (($d | ConvertTo-Json -Depth 6) | ConvertFrom-Json)
    Assert ($c -and $c.HasRefresh) 'New-CredSource does not understand the document'
}
Check 'browser result is checked before any exchange' {
    Reset-World
    $Script:Responder = { param($c) $TokResp | ConvertFrom-Json }
    $cases = @(
        @{ Cb = @{ Code = 'c'; State = 's'; Error = 'access_denied' }; Want = 'claude.ai said: access_denied' },
        @{ Cb = @{ Code = 'c'; State = 'other'; Error = $null };     Want = 'state mismatch' },
        @{ Cb = @{ Code = $null; State = 's'; Error = $null };       Want = 'no code' }
    )
    foreach ($k in $cases) {
        $err = $null; try { Complete-BrowserSignIn $k.Cb 'v' 's' 1 | Out-Null } catch { $err = $_.Exception.Message }
        Assert ($err -like ('*' + $k.Want + '*')) ("wanted '{0}', got '{1}'" -f $k.Want, $err)
    }
    Eq $Script:Calls.Count 0 'no exchange may happen for a bad redirect'
    $doc = Complete-BrowserSignIn @{ Code = 'c'; State = 's'; Error = $null } 'v' 's' 4242
    Eq $doc.account $Mail 'account'
    Eq (($Script:Calls[0].Body | ConvertFrom-Json).redirect_uri) 'http://localhost:4242/callback' 'redirect_uri matches the listener port'
}

# ------------------------------------------------------------------ the widget's own chain

Check 'login file round-trips and Sign out removes it' {
    Reset-World
    Set-WidgetLogin 'AT' 'RT-SECRET' ((NowMs) + 3600000) $Mail
    Assert (Test-Login) 'file not written'
    Assert ((Get-Content $Script:LoginPath -Raw) -notmatch 'RT-SECRET') 'refresh token stored in clear text'
    $d = Read-Login
    Eq $d.claudeAiOauth.refreshToken 'RT-SECRET' 'refresh'; Eq (Get-LoginEmail $d) $Mail 'email'
    Remove-Login
    Assert (-not (Test-Login)) 'still there after Remove-Login'
    Assert ($null -eq (Read-Login)) 'Read-Login after removal'
}
Check 'a valid widget login is used first, with no network call' {
    Reset-World
    Set-ClaudeCodeLogin 'CC-AT' 'CC-RT' ((NowMs) + 7200000)
    Set-WidgetLogin 'W-AT' 'W-RT' ((NowMs) + 3600000) $Mail
    Eq (Get-AccessToken) 'W-AT' 'token'
    Eq $Script:UsedSource 'Widget sign-in' 'source'
    Eq $Script:Calls.Count 0 'calls'
}
Check 'an expired widget login refreshes on its own chain and never touches Claude Code' {
    Reset-World
    Set-ClaudeCodeLogin 'CC-AT' 'CC-RT' ((NowMs) - 1000)
    $ccBefore = [IO.File]::ReadAllText($CcFile)
    Set-WidgetLogin 'W-AT' 'W-RT' ((NowMs) - 1000) $Mail
    $Script:Responder = { param($c) '{"access_token":"W-AT2","refresh_token":"W-RT2","expires_in":3600}' | ConvertFrom-Json }
    Eq (Get-AccessToken) 'W-AT2' 'token'
    Eq $Script:Calls.Count 1 'calls'
    Eq (($Script:Calls[0].Body | ConvertFrom-Json).refresh_token) 'W-RT' 'spent the widget refresh token'
    $d = Read-Login
    Eq $d.claudeAiOauth.refreshToken 'W-RT2' 'rotated refresh token saved'
    Eq $d.claudeAiOauth.accessToken 'W-AT2' 'new access token saved'
    Eq (Get-LoginEmail $d) $Mail 'account kept across refresh'
    Eq ($d.claudeAiOauth.scopes -join ',') 'user:profile,user:inference' 'scopes kept'
    Eq ([IO.File]::ReadAllText($CcFile)) $ccBefore 'Claude Code credentials file changed'
    Assert (-not $Script:State.CachedRefresh) 'leaked into the Claude Code chain cache'
    Eq $Script:UsedSource 'Widget sign-in (refreshed)' 'source'
}
Check 'a refresh without a new refresh_token keeps the old one' {
    Reset-World
    Set-WidgetLogin 'W-AT' 'W-RT' ((NowMs) - 1000) $null
    $Script:Responder = { param($c) '{"access_token":"W-AT2","expires_in":3600}' | ConvertFrom-Json }
    Eq (Get-AccessToken) 'W-AT2' 'token'
    Eq (Read-Login).claudeAiOauth.refreshToken 'W-RT' 'refresh token lost'
}
Check 'a rejected widget refresh drops the login and falls back to Claude Code' {
    Reset-World
    Set-ClaudeCodeLogin 'CC-AT' 'CC-RT' ((NowMs) + 7200000)
    Set-WidgetLogin 'W-AT' 'W-RT' ((NowMs) - 1000) $null
    $Script:Responder = { param($c) HttpError 400 }
    Eq (Get-AccessToken) 'CC-AT' 'token'
    Assert (-not (Test-Login)) 'dead login kept - would retry forever'
    Assert ($Script:LastRefreshError -like 'Widget sign-in*') "refresh error not reported: $Script:LastRefreshError"
    Eq $Script:Calls.Count 1 'calls'
}
Check 'offline with only a widget login: an error, not "no login", and the login is kept' {
    Reset-World
    Set-WidgetLogin 'W-AT' 'W-RT' ((NowMs) - 1000) $null
    $Script:Responder = { param($c) throw (New-Object System.Exception 'No such host is known.') }
    $err = $null; try { Get-AccessToken | Out-Null } catch { $err = $_.Exception.Message }
    Assert ($err -and $err -ne 'NOTOKEN') "got '$err'"
    Assert ($err -like 'Widget sign-in*') "error does not say which login: $err"
    Assert (Test-Login) 'login dropped on a network error'
}
Check 'no login anywhere -> NOTOKEN (the card then offers Sign in with Google)' {
    Reset-World
    $err = $null; try { Get-AccessToken | Out-Null } catch { $err = $_.Exception.Message }
    Eq $err 'NOTOKEN' 'error'
}
Check 'after a 401 the widget token gets one forced refresh' {
    Reset-World
    Set-WidgetLogin 'W-AT' 'W-RT' ((NowMs) + 3600000) $null
    $Script:WidgetForceRefresh = $true
    $Script:Responder = { param($c) '{"access_token":"W-AT2","refresh_token":"W-RT2","expires_in":3600}' | ConvertFrom-Json }
    Eq (Get-AccessToken) 'W-AT2' 'token'
    Assert (-not $Script:WidgetForceRefresh) 'flag not cleared'
    $Script:Calls.Clear()
    Eq (Get-AccessToken) 'W-AT2' 'second call'
    Eq $Script:Calls.Count 0 'refreshed again without cause'
}
Check 'Claude Code logins still work with no widget login (unchanged path)' {
    Reset-World
    Set-ClaudeCodeLogin 'CC-AT' 'CC-RT' ((NowMs) - 1000)
    $Script:Responder = { param($c) '{"access_token":"CC-AT2","refresh_token":"CC-RT2","expires_in":3600}' | ConvertFrom-Json }
    Eq (Get-AccessToken) 'CC-AT2' 'token'
    Eq $Script:State.CachedRefresh 'CC-RT2' 'rotated token kept in widget-state.json'
    Assert (-not (Test-Login)) 'a Claude Code refresh must not create a widget login'
}

# ------------------------------------------------------------------ live loopback

$HasV6 = $false
try { $t6 = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::IPv6Loopback), 0; $t6.Start(); $t6.Stop(); $HasV6 = $true } catch { }

$LoopHosts = @('127.0.0.1', 'localhost')
if ($HasV6) { $LoopHosts += '::1' } else { Write-Host '  (no IPv6 loopback in this environment - skipping ::1)' -ForegroundColor DarkGray }
foreach ($LoopHost in $LoopHosts) {
    Check ("loopback listener answers the redirect on {0}" -f $LoopHost) {
        $srv = Start-CallbackServer
        try {
            Assert ($srv.Port -gt 0) 'no port'
            if ($HasV6) { Eq @($srv.Listeners).Count 2 'listeners (v4 + v6)' }
            $r = Invoke-FakeBrowser $srv $LoopHost '/callback?code=CODE1&state=ST1'
            Assert $r.Callback 'no callback returned'
            Eq $r.Callback.Code 'CODE1' 'code'; Eq $r.Callback.State 'ST1' 'state'
            Assert ($r.Response.StartsWith('HTTP/1.1 200 OK')) ('bad response: ' + $r.Response.Split("`n")[0])
            Assert ($r.Response -match 'Signed in to Claude Usage') 'landing page missing'
            Assert $srv.Done 'server not marked done'
        } finally { Stop-CallbackServer $srv }
    }
}

Check 'idle pre-connect sockets and /favicon.ico do not end or stall the listener' {
    $srv = Start-CallbackServer
    try {
        $idle = New-Object System.Net.Sockets.TcpClient ([System.Net.Sockets.AddressFamily]::InterNetwork)
        $idle.Connect('127.0.0.1', $srv.Port)          # Chrome-style speculative connection, sends nothing
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Assert ($null -eq (Step-CallbackServer $srv)) 'idle socket produced a callback'
        Assert ($sw.ElapsedMilliseconds -lt 500) ('Step blocked for {0} ms' -f $sw.ElapsedMilliseconds)
        $fav = Invoke-FakeBrowser $srv '127.0.0.1' '/favicon.ico'
        Assert ($null -eq $fav.Callback) 'favicon treated as the redirect'
        Assert ($fav.Response.StartsWith('HTTP/1.1 404')) 'favicon not answered with 404'
        Assert (-not $srv.Done) 'favicon ended the listener'
        $r = Invoke-FakeBrowser $srv '127.0.0.1' '/callback?error=access_denied&state=S'
        Eq $r.Callback.Error 'access_denied' 'error'
        Assert ($r.Response -match 'Sign-in did not finish') 'failure page missing'
        $idle.Close()
    } finally { Stop-CallbackServer $srv }
}

Check 'end to end: authorize URL -> browser redirect -> exchange -> widget login used' {
    Reset-World
    $Script:Responder = { param($c) $TokResp | ConvertFrom-Json }
    $srv = Start-CallbackServer
    try {
        $verifier = New-RandomToken; $state = New-RandomToken
        $q = Get-QueryParams (Get-AuthorizeUrl $srv.Port (Get-PkceChallenge $verifier) $state)
        $redirect = [Uri]$q.redirect_uri
        Eq $redirect.Port $srv.Port 'redirect port'
        $r = Invoke-FakeBrowser $srv $redirect.Host ($redirect.AbsolutePath + '?code=THECODE&state=' + [Uri]::EscapeDataString($q.state))
        $doc = Complete-BrowserSignIn $r.Callback $verifier $state $srv.Port
        $sent = $Script:Calls[0].Body | ConvertFrom-Json
        Eq $sent.code 'THECODE' 'code sent'
        Eq (Get-PkceChallenge $sent.code_verifier) $q.code_challenge 'verifier matches the challenge'
        Save-Login $doc
        $Script:Calls.Clear()
        Eq (Get-AccessToken) 'AT-new' 'token'
        Eq $Script:UsedSource 'Widget sign-in' 'source'
    } finally { Stop-CallbackServer $srv }
}

# ------------------------------------------------------------------ UI glue (no WPF)
#
# The card's sign-in wiring lives after the window marker. Pull those functions and
# the sign-in timer's Tick handler out of the real script, and drive them against
# stand-in controls. Only WPF itself is faked: B, Show-Message and Render draw.

$ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
$UiFns = @('Set-Hint', 'Update-SignInUi', 'Update-Usage', 'Request-Refresh', 'Start-SignIn',
           'Complete-SignIn', 'Invoke-SignInButton', 'Invoke-SignOut', 'Get-SignInMenuLabel')
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($UiFns -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) }
}
$tickAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                       $n.Expression.Extent.Text -eq '$signInTimer' -and $n.Member.Extent.Text -eq 'Add_Tick' }, $true)
$SignInTick = [scriptblock]::Create($tickAst.Arguments[0].ScriptBlock.EndBlock.Extent.Text)

function B([string]$hex) { return $hex }
$Script:Shown = $null; $Script:Renders = 0
function Show-Message([string]$t) { $Script:Shown = $t }
function Render { $Script:Renders++ }
function New-Ctl { return [pscustomobject]@{ Text = ''; Visibility = 'Collapsed'; Foreground = ''; Background = '' } }
$hintText = New-Ctl; $statusText = New-Ctl; $accountText = New-Ctl; $signInBtn = New-Ctl; $signInText = New-Ctl
$signInTimer = [pscustomobject]@{ Running = $false }
$signInTimer | Add-Member ScriptMethod Start { $this.Running = $true }
$signInTimer | Add-Member ScriptMethod Stop  { $this.Running = $false }
$RefreshSeconds = 180
$Script:Opened = New-Object System.Collections.Generic.List[string]
function Start-Process($FilePath) { $Script:Opened.Add([string]$FilePath) }
$UsageJson = '{"limits":[{"kind":"session","percent":12,"resets_at":"2030-01-01T00:00:00Z"}]}'

function Reset-Ui {
    Reset-World
    $Script:SignIn = $null; $Script:NeedsSignIn = $false; $Script:Account = $null
    $Script:LastData = $null; $Script:LastOk = $null; $Script:Backoff = 0
    $Script:Opened.Clear(); $Script:Shown = $null
    foreach ($c in @($hintText, $statusText, $accountText, $signInBtn, $signInText)) { $c.Text = ''; $c.Visibility = 'Collapsed' }
}
# Plays claude.ai sending the browser back, while the widget's timer ticks.
function Invoke-BrowserReturn([string]$Query) {
    $port = $Script:SignIn.Srv.Port
    $cl = New-Object System.Net.Sockets.TcpClient ([System.Net.Sockets.AddressFamily]::InterNetwork)
    $cl.Connect('127.0.0.1', $port)
    $b = [Text.Encoding]::ASCII.GetBytes("GET /callback?$Query HTTP/1.1`r`nHost: localhost:$port`r`n`r`n")
    $st = $cl.GetStream(); $st.Write($b, 0, $b.Length)
    for ($n = 0; $n -lt 100 -and $Script:SignIn; $n++) { & $SignInTick; Start-Sleep -Milliseconds 20 }
    $cl.ReceiveTimeout = 3000
    $sr = New-Object System.IO.StreamReader $st
    $resp = ''; try { $resp = $sr.ReadToEnd() } catch { }
    $cl.Close()
    return $resp
}

Check 'UI: no login -> card says so and shows the Sign in with Google button' {
    Reset-Ui
    Update-Usage
    Eq $Script:Shown 'Not signed in.' 'message'
    Eq $statusText.Text 'no login' 'status'
    Eq $signInBtn.Visibility 'Visible' 'button'
    Eq $signInText.Text 'Sign in with Google...' 'button text'
    Eq (Get-SignInMenuLabel) 'Sign in with Google...' 'menu label'
}
Check 'UI: full sign-in through the card button, then live usage' {
    Reset-Ui
    Update-Usage
    $Script:Responder = { param($c)
        if ($c.Uri -like '*/oauth/token') { return ($TokResp | ConvertFrom-Json) }
        if ($c.Uri -like '*/oauth/usage') { return ($UsageJson | ConvertFrom-Json) }
        throw ('unexpected ' + $c.Uri) }
    Invoke-SignInButton
    Assert $Script:SignIn 'sign-in did not start'
    Eq $Script:Opened.Count 1 'browser opened'
    Assert $signInTimer.Running 'poll timer not started'
    Eq $signInText.Text 'Cancel sign-in' 'button while waiting'
    Eq $hintText.Text 'Finish signing in in your browser...' 'hint'
    $q = Get-QueryParams $Script:Opened[0]
    Eq ([Uri]$q.redirect_uri).Port $Script:SignIn.Srv.Port 'redirect port'
    $resp = Invoke-BrowserReturn ('code=C1&state=' + [Uri]::EscapeDataString($q.state))
    Assert ($resp -match 'Signed in to Claude Usage') 'browser did not get the success page'
    Assert (-not $Script:SignIn) 'still signing in'
    Assert (-not $signInTimer.Running) 'poll timer left running'
    Assert (Test-Login) 'login not saved'
    Eq $accountText.Text $Mail 'account shown'
    Eq $hintText.Visibility 'Collapsed' 'hint cleared'
    Eq $Script:NextFetchAt ([datetime]::MinValue) 'refresh not requested'
    Eq (Get-SignInMenuLabel) 'Sign in again...' 'menu label after sign-in'
    Update-Usage
    Assert $Script:LastData 'no usage after sign-in'
    Eq $signInBtn.Visibility 'Collapsed' 'button still showing'
    Eq $Script:UsedSource 'Widget sign-in' 'source'
}
Check 'UI: a redirect with the wrong state is refused and nothing is saved' {
    Reset-Ui
    $Script:Responder = { param($c) throw 'no network call expected' }
    Invoke-SignInButton
    $resp = Invoke-BrowserReturn 'code=C1&state=forged'
    Assert (-not (Test-Login)) 'saved a login from a forged redirect'
    Assert ($hintText.Text -like 'Sign-in failed: state mismatch*') ('hint: ' + $hintText.Text)
    Eq $Script:Calls.Count 0 'exchanged a forged code'
}
Check 'UI: cancel closes the listener; timeout gives up' {
    Reset-Ui
    Invoke-SignInButton
    $port = $Script:SignIn.Srv.Port
    Invoke-SignInButton
    Eq $hintText.Text 'Sign-in cancelled.' 'cancel hint'
    Assert (-not $Script:SignIn) 'still signing in'
    $refused = $false
    try { $t = New-Object System.Net.Sockets.TcpClient ([System.Net.Sockets.AddressFamily]::InterNetwork); $t.Connect('127.0.0.1', $port); $t.Close() } catch { $refused = $true }
    Assert $refused 'listener still accepting after cancel'
    Invoke-SignInButton
    $Script:SignIn.Deadline = [datetime]::UtcNow.AddSeconds(-1)
    & $SignInTick
    Assert ($hintText.Text -like '*timed out*') ('hint: ' + $hintText.Text)
}
Check 'UI: Sign out forgets the login and the old numbers' {
    Reset-Ui
    Set-WidgetLogin 'W-AT' 'W-RT' ((NowMs) + 3600000) $Mail
    $Script:Responder = { param($c) if ($c.Uri -like '*/oauth/usage') { return ($UsageJson | ConvertFrom-Json) }; throw 'x' }
    $Script:Account = $Mail
    Update-Usage
    Assert $Script:LastData 'no data'
    Invoke-SignOut
    Assert (-not (Test-Login)) 'login kept'
    Update-Usage
    Assert (-not $Script:LastData) 'old account numbers still shown'
    Eq $Script:Shown 'Not signed in.' 'message'
}
Check 'UI: a 401 on the widget token -> auth, button back, forced refresh queued' {
    Reset-Ui
    Set-WidgetLogin 'W-AT' 'W-RT' ((NowMs) + 3600000) $null
    $Script:Responder = { param($c) HttpError 401 }
    Update-Usage
    Eq $statusText.Text 'auth' 'status'
    Eq $signInBtn.Visibility 'Visible' 'button'
    Eq $hintText.Text 'Login expired. Sign in again to resume.' 'hint'
    Assert $Script:WidgetForceRefresh 'no forced refresh queued'
}

# ------------------------------------------------------------------ summary

Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
$fail = @($Script:Results | Where-Object { -not $_.Ok }).Count
Write-Host ''
if ($fail) { Write-Host ("{0} of {1} checks FAILED" -f $fail, $Script:Results.Count) -ForegroundColor Red; exit 1 }
Write-Host ("all {0} checks passed" -f $Script:Results.Count) -ForegroundColor Green
exit 0
