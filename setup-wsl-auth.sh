#!/usr/bin/env bash
# Claude Usage Widget - WSL auth setup & verification.
# Run inside WSL:   bash setup-wsl-auth.sh
set -uo pipefail

UA='claude-code/2.0.0'
BETA='oauth-2025-04-20'
USAGE_URL='https://api.anthropic.com/api/oauth/usage'
PROFILE_URL='https://api.anthropic.com/api/oauth/profile'
CRED="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"

bold(){ printf '\033[1m%s\033[0m\n' "$*"; }
red(){  printf '\033[31m%s\033[0m\n' "$*"; }
grn(){  printf '\033[32m%s\033[0m\n' "$*"; }
yel(){  printf '\033[33m%s\033[0m\n' "$*"; }

BODY=$(mktemp); PBODY=$(mktemp)
trap 'rm -f "$BODY" "$PBODY"' EXIT

# Writes the response to a FIXED path and echoes the status code, so it still
# works when called as CODE=$(api ...) - a subshell cannot set a variable in
# its caller, but it can write to a file whose path the caller already knows.
api()  { curl -s -o "$BODY"  -w '%{http_code}' -m 20 -H "Authorization: Bearer $1" \
           -H "anthropic-beta: $BETA" -H 'Accept: application/json' -A "$UA" "$2"; }
apip() { curl -s -o "$PBODY" -w '%{http_code}' -m 20 -H "Authorization: Bearer $1" \
           -H "anthropic-beta: $BETA" -H 'Accept: application/json' -A "$UA" "$2"; }

show_usage() { # $1 = body file
  python3 - "$1" <<'PY'
import json,sys,datetime
d=json.load(open(sys.argv[1]))
def pct(v):
    if v is None: return None
    v=float(v)
    return v*100 if (v<=1 and v!=int(v)) else v
def when(s):
    if not s: return ''
    try: t=datetime.datetime.fromisoformat(s.replace('Z','+00:00'))
    except Exception: return ''
    m=int((t-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//60)+1
    if m<=0: return 'resetting'
    if m>=1440: rel=f'resets in {m//1440}d {(m%1440)//60}h'
    elif m>=60: rel=f'resets in {m//60}h {m%60}m'
    else:       rel=f'resets in {m}m'
    loc=t.astimezone()                      # the box's local zone
    today=datetime.datetime.now().date()
    if loc.date()==today:                       abs_=loc.strftime('%-I:%M %p')
    elif loc.date()<today+datetime.timedelta(days=7): abs_=loc.strftime('%a %-I:%M %p')
    else:                                       abs_=loc.strftime('%b %-d %-I:%M %p')
    return f'{rel} ({abs_})'
rows=[('Session (5h)','five_hour'),('Week (all)','seven_day'),
      ('Week Opus','seven_day_opus'),('Week Sonnet','seven_day_sonnet')]
for label,k in rows:
    w=d.get(k)
    if not isinstance(w,dict): continue
    p=pct(w.get('utilization'))
    if p is None: continue
    bar='#'*int(p/5)+'.'*(20-int(p/5))
    print(f'  {label:<14} [{bar}] {p:5.1f}%   {when(w.get("resets_at"))}')
# money arrives in MINOR units (cents) with an explicit exponent/decimal_places;
# reading it raw overstates every figure by 100x
def money(v, exp, cur='USD'):
    if v is None: return None
    try: e=int(exp)
    except Exception: e=2
    if e<0 or e>6: e=2
    sym={'USD':'$','EUR':chr(0x20ac),'GBP':chr(0xa3),'JPY':chr(0xa5)}.get(cur or 'USD','')
    amt=float(v)/(10**e)
    return f'{sym}{amt:,.{e}f}' if sym else f'{amt:,.{e}f} {cur}'
sp=d.get('spend') or {}
if sp.get('enabled'):
    u=sp.get('used') or {}
    exp=u.get('exponent'); cur=u.get('currency')
    used=money(u.get('amount_minor'), exp, cur)
    lim=sp.get('limit')
    if isinstance(lim,dict): lim=money(lim.get('amount_minor'), exp, cur)
    elif lim is not None:    lim=money(lim, exp, cur)
    if used and lim: print(f'  Extra usage    {used} of {lim} this month')
    elif used:       print(f'  Extra usage    {used} used this month')
else:
    e=d.get('extra_usage') or {}
    if e.get('is_enabled'):
        dp=e.get('decimal_places'); cur=e.get('currency')
        used=money(e.get('used_credits'), dp, cur); lim=money(e.get('monthly_limit'), dp, cur)
        if used and lim: print(f'  Extra usage    {used} of {lim} this month')
        elif used:       print(f'  Extra usage    {used} used this month')
PY
}

echo
bold 'Claude Usage Widget - WSL setup'
echo   '-------------------------------'

command -v claude >/dev/null 2>&1 || { red 'claude CLI not found in this WSL distro.'; echo 'Install it, or run this in the distro where you use Claude Code.'; exit 1; }

# ---------- 1. check the existing login ----------
TOKEN=''
if [ -r "$CRED" ]; then
  TOKEN=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("claudeAiOauth",{}).get("accessToken",""))' "$CRED" 2>/dev/null)
fi

if [ -n "$TOKEN" ]; then
  CODE=$(api "$TOKEN" "$USAGE_URL")
  if [ "$CODE" = "200" ]; then
    grn "Existing login works ($CRED)"
  else
    yel "Existing login returned HTTP $CODE - it has expired."
    TOKEN=''
  fi
else
  yel "No usable login found at $CRED"
fi

# ---------- 2. sign in if needed ----------
if [ -z "$TOKEN" ]; then
  echo
  bold 'Sign in now:'
  echo '  1) A browser link will be shown. Open it and approve as the account you want to monitor.'
  echo '  2) If it shows a code, paste the code back into the terminal.'
  echo
  read -r -p 'Press Enter to run "claude /login" ...' _
  claude /login || true
  echo
  TOKEN=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("claudeAiOauth",{}).get("accessToken",""))' "$CRED" 2>/dev/null)
  [ -z "$TOKEN" ] && { red 'Still no credentials. Run "claude" manually, use /login, then re-run this script.'; exit 1; }
  CODE=$(api "$TOKEN" "$USAGE_URL")
  [ "$CODE" = "200" ] || { red "Login stored but usage check returned HTTP $CODE."; exit 1; }
  grn 'Signed in.'
fi

# ---------- 3. show who and how much ----------
echo
PCODE=$(apip "$TOKEN" "$PROFILE_URL")
if [ "$PCODE" = "200" ]; then
  EMAIL=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for k in ("email","email_address"):
    if d.get(k): print(d[k]); raise SystemExit
for o in ("account","user","organization"):
    v=d.get(o) or {}
    for k in ("email","email_address","name"):
        if isinstance(v,dict) and v.get(k): print(v[k]); raise SystemExit
' "$PBODY" 2>/dev/null)
  [ -n "$EMAIL" ] && bold "Account: $EMAIL"
fi
CODE=$(api "$TOKEN" "$USAGE_URL")
bold 'Current usage:'
show_usage "$BODY"

# ---------- 4. durability note ----------
# `claude setup-token` tokens (sk-ant-oat01-...) are REJECTED by the usage endpoint
# with HTTP 403 - verified on a real token. They are scoped to model requests only,
# so they cannot drive this widget. The prompt that used to offer that path has been
# removed: it could not succeed, and it asked you to handle a live 1-year credential
# for nothing.
echo
echo 'Note: the widget uses the /login credentials above. It refreshes them'
echo 'automatically, so it keeps working as long as you use Claude Code now and then.'
echo 'If the login eventually expires, the widget shows "auth" - run /login again.'
echo

grn 'Done. Start the widget on Windows (Start-Widget.vbs).'
