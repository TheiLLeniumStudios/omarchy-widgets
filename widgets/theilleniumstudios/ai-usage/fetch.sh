#!/usr/bin/env bash
# Combined AI usage for the "ai usage" widget.
#
# Usage: fetch '<json>'
#   [{"id":"...","provider":"claude","name":"...","key":"...","extra":"..."}]
#   (or {"accounts":[...]}, for calling it by hand)
#
# providers: claude, opencode-go, openrouter, deepseek
#   claude       key = path to a Claude Code .credentials.json, or an OAuth
#                      access token. Empty = ~/.claude/.credentials.json.
#   opencode-go  key = OpenCode Go API key
#   openrouter   key = API key; extra = optional management key (/credits)
#   deepseek     key = API key; extra = optional platform usage token
#
# Prints one JSON object. A bad account gets an "error" field and the other
# accounts still work.
set -u
export LC_ALL=C
umask 077

CONFIG_JSON="${1:-}"
[ -n "$CONFIG_JSON" ] && [ -f "$CONFIG_JSON" ] && CONFIG_JSON=$(cat "$CONFIG_JSON" 2>/dev/null)
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/omalauncher-ai-usage"
mkdir -p "$CACHE" 2>/dev/null || true

now=$(date +%s)
today_start=$(date -d 'today 00:00' +%s 2>/dev/null || echo $((now - 86400)))
month_start=$(date -d "$(date +%Y-%m-01) 00:00" +%s 2>/dev/null || echo $((now - 30 * 86400)))
today_date=$(date +%F)
month=$(date +%-m)
year=$(date +%Y)

# Both helpers print "code\nbody"; the caller splits it. A command
# substitution runs in a subshell, so globals set inside would not escape.
fetch_json() {
  local url="$1" token="${2:-}" raw code
  local -a auth=()
  [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")
  raw=$(curl -sS --max-time 20 --connect-timeout 10 \
    -A 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36' \
    -H 'Accept: application/json' -H 'x-app-version: 1.0.0' \
    "${auth[@]}" -w $'\n%{http_code}' "$url" 2>/dev/null) || true
  code=${raw##*$'\n'}
  printf '%s\n%s' "${code:-000}" "${raw%$'\n'*}"
}

post_json() {
  local url="$1" data="$2" raw code
  raw=$(curl -sS --max-time 20 --connect-timeout 10 -X POST "$url" \
    -A 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36' \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -H 'x-app-version: 1.0.0' --data "$data" \
    -w $'\n%{http_code}' 2>/dev/null) || true
  code=${raw##*$'\n'}
  printf '%s\n%s' "${code:-000}" "${raw%$'\n'*}"
}

# ---------- Claude Code login ----------

claude_fields() {
  jq -r '[.claudeAiOauth.accessToken // "", .claudeAiOauth.refreshToken // "",
          ((.claudeAiOauth.expiresAt // 0) | tostring),
          (.claudeAiOauth.subscriptionType // "")] | @tsv' "$1" 2>/dev/null
}

# Prints the new access token, or nothing on failure. $3 is the token that was
# tried, so a token another process already refreshed is reused.
claude_refresh() {
  local cred="$1" rt="$2" tried="$3" at="" file_rt="" _sub="" body resp code exp_in exp_ms tmp url
  [ -n "$rt" ] || return 1

  if command -v flock >/dev/null 2>&1; then
    exec 9>"$cred.lock" || return 1
    flock -w 15 9 || return 1
  fi

  IFS=$'\t' read -r at file_rt _ _ < <(claude_fields "$cred")
  if [ -n "$at" ] && [ "$at" != "$tried" ]; then
    printf '%s' "$at"
    return 0
  fi

  body=$(jq -nc --arg rt "$rt" \
    '{grant_type:"refresh_token", refresh_token:$rt, client_id:"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}' 2>/dev/null) || return 1
  for url in https://platform.claude.com/v1/oauth/token https://console.anthropic.com/v1/oauth/token; do
    resp=$(post_json "$url" "$body")
    code=${resp%%$'\n'*}
    resp=${resp#*$'\n'}
    [ "$code" = 200 ] && break
  done
  [ "$code" = 200 ] || return 1

  at=$(printf '%s' "$resp" | jq -r '.access_token // empty' 2>/dev/null)
  [ -n "$at" ] || return 1
  file_rt=$(printf '%s' "$resp" | jq -r '.refresh_token // empty' 2>/dev/null)
  [ -n "$file_rt" ] || file_rt=$rt
  exp_in=$(printf '%s' "$resp" | jq -r '.expires_in // 0' 2>/dev/null)
  case $exp_in in '' | *[!0-9]*) exp_in=3600 ;; esac
  exp_ms=$(((now + exp_in) * 1000))

  tmp=$(mktemp "$cred.tmp.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  if jq --arg at "$at" --arg rt "$file_rt" --argjson exp "$exp_ms" \
    '.claudeAiOauth.accessToken = $at | .claudeAiOauth.refreshToken = $rt | .claudeAiOauth.expiresAt = $exp' \
    "$cred" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$cred"
  else
    rm -f "$tmp"
    return 1
  fi
  printf '%s' "$at"
}

claude_item() {
  local key="$1" at="" rt="" exp="" sub="" body code newat err="" cred=""
  if [ -z "$key" ]; then
    cred="$HOME/.claude/.credentials.json"
  else
    # The value comes from a file, so the shell never expanded a leading ~.
    case $key in
      "~/"*) key="$HOME/${key:2}" ;;
      "~") key="$HOME" ;;
    esac
    if [ -r "$key" ] || [[ "$key" == */* || "$key" == *.json ]]; then
      cred="$key"
    else
      # A raw OAuth access token, with no file to refresh.
      at="$key"
    fi
  fi

  if [ -n "$cred" ]; then
    if [ ! -r "$cred" ]; then
      jq -nc --arg p "$cred" '{error:("no Claude login at " + $p), plan:null, limits:[]}'
      return
    fi
    IFS=$'\t' read -r at rt exp sub < <(claude_fields "$cred")
    case $exp in '' | *[!0-9]*) exp=0 ;; esac
    if [ "$exp" -gt 0 ] && [ "$exp" -lt 100000000000 ]; then exp=$((exp * 1000)); fi
    if [ -n "$rt" ] && { [ -z "$at" ] || [ $((exp / 1000)) -le $((now + 120)) ]; }; then
      at=$(claude_refresh "$cred" "$rt" "$at")
    fi
  fi

  if [ -z "$at" ]; then
    jq -nc '{error:"login expired; open Claude Code once", plan:null, limits:[]}'
    return
  fi

  body=$(fetch_json "https://api.anthropic.com/api/oauth/usage" "$at")
  code=${body%%$'\n'*}
  body=${body#*$'\n'}
  if [ "$code" = 401 ] && [ -n "$rt" ]; then
    newat=$(claude_refresh "$cred" "$rt" "$at")
    if [ -n "$newat" ]; then
      body=$(fetch_json "https://api.anthropic.com/api/oauth/usage" "$newat")
      code=${body%%$'\n'*}
      body=${body#*$'\n'}
    fi
  fi

  if [ "$code" != 200 ]; then
    case $code in
      401) err="login expired; open Claude Code once" ;;
      429) err="rate limited; retry later" ;;
      000) err="offline" ;;
      *) err="usage unavailable (HTTP $code)" ;;
    esac
    jq -nc --arg e "$err" --arg plan "$sub" \
      '{error:$e, plan:(if $plan == "" then null else $plan end), limits:[]}'
    return
  fi

  printf '%s' "$body" | jq -c --arg plan "$sub" '
    def epoch:
      if . == null then null
      elif type == "number" then (if . > 100000000000 then (. / 1000 | floor) else floor end)
      else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
            | try fromdateiso8601 catch null) end;
    def pc:
      (tonumber? // null)
      | if . == null then null elif . > 0 and . < 1 then . * 100 else . end;
    . as $r
    | ([ $r.limits[]?
          | { label: (
                if .kind == "session" then "5h"
                elif .kind == "weekly_all" then "week"
                elif ((.scope.model.display_name? // "") != "") then ("week " + .scope.model.display_name)
                else (.kind // "limit") end),
              pct: ((.percent // .utilization // null) | pc),
              resets: (.resets_at | epoch) } ]
       | map(select(.pct != null))) as $m
    | ([ { label: "5h", pct: (($r.five_hour.utilization // $r.five_hour.percent // null) | pc),
            resets: (($r.five_hour.resets_at // null) | epoch) },
          { label: "week", pct: (($r.seven_day.utilization // $r.seven_day.percent // null) | pc),
            resets: (($r.seven_day.resets_at // null) | epoch) } ]
       | map(select(.pct != null))) as $l
    | { plan: (if $plan == "" then null else $plan end),
        limits: (if ($m | length) > 0 then $m else $l end),
        error: null }' 2>/dev/null \
    || jq -nc '{error:"could not read Claude usage", plan:null, limits:[]}'
}

# ---------- OpenCode Go ----------

opencode_item() {
  local key="$1" body code
  if [ -z "$key" ]; then
    printf '%s' '{"error":"an OpenCode Go API key is required","status":null,"rolling":null,"weekly":null,"monthly":null}'
    return
  fi
  body=$(fetch_json "https://opencode.ai/zen/go/v1/usage" "$key")
  code=${body%%$'\n'*}
  body=${body#*$'\n'}
  if [ "$code" != 200 ]; then
    case $code in
      401) printf '%s' '{"error":"OpenCode Go key is invalid or not entitled","status":null,"rolling":null,"weekly":null,"monthly":null}' ;;
      403) printf '%s' '{"error":"no OpenCode Go subscription on this key","status":null,"rolling":null,"weekly":null,"monthly":null}' ;;
      000) printf '%s' '{"error":"offline","status":null,"rolling":null,"weekly":null,"monthly":null}' ;;
      *) printf '%s' "{\"error\":\"usage unavailable (HTTP $code)\",\"status\":null,\"rolling\":null,\"weekly\":null,\"monthly\":null}" ;;
    esac
    return
  fi

  printf '%s' "$body" | jq -c --argjson t "$now" '
    def epoch:
      if . == null then null
      elif type == "number" then (if . > 100000000000 then (. / 1000 | floor) else floor end)
      else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
            | try fromdateiso8601 catch null) end;
    def pc:
      (tonumber? // null)
      | if . == null then null elif . > 0 and . < 1 then . * 100 else . end;
    def win($x):
      if $x == null then null
      else
        (($x.percent // $x.usagePercent // $x.usage_percent) | pc) as $p
        | (($x.resetsAt // $x.resets_at // $x.resetAt // $x.reset_at) | epoch) as $r
        | (if $r != null then $r
           else (($x.resetInSec // $x.reset_in_sec // null) as $s
                 | if $s == null then null else ($t + ($s | tonumber)) end)
           end) as $res
        | {pct: $p, resets: $res}
      end;
    {
      status: (.status // "active"),
      balance: (.useBalance // .use_balance // null),
      rolling: win(.usage.rolling // .rollingUsage // .rolling),
      weekly: win(.usage.weekly // .weeklyUsage // .weekly),
      monthly: win(.usage.monthly // .monthlyUsage // .monthly),
      error: null
    }
    | if (.rolling == null and .weekly == null and .monthly == null)
      then .error = "usage response had no known windows" else . end
  ' 2>/dev/null \
    || printf '%s' '{"error":"could not read OpenCode Go usage","status":null,"rolling":null,"weekly":null,"monthly":null}'
}

# ---------- OpenRouter ----------

openrouter_item() {
  local key="$1" mgmt="$2" body code cbody ccode ckey credits="null"
  if [ -z "$key" ]; then
    printf '%s' '{"error":"an OpenRouter API key is required","status":null,"remaining":null}'
    return
  fi
  body=$(fetch_json "https://openrouter.ai/api/v1/key" "$key")
  code=${body%%$'\n'*}
  body=${body#*$'\n'}
  if [ "$code" != 200 ]; then
    case $code in
      401) printf '%s' '{"error":"OpenRouter key is invalid","status":"invalid","remaining":null}' ;;
      000) printf '%s' '{"error":"offline","status":null,"remaining":null}' ;;
      *) printf '%s' "{\"error\":\"usage unavailable (HTTP $code)\",\"status\":null,\"remaining\":null}" ;;
    esac
    return
  fi

  ckey="${mgmt:-$key}"
  if [ -n "$ckey" ]; then
    cbody=$(fetch_json "https://openrouter.ai/api/v1/credits" "$ckey")
    ccode=${cbody%%$'\n'*}
    cbody=${cbody#*$'\n'}
    if [ "$ccode" = 200 ]; then
      credits=$(printf '%s' "$cbody" | jq -c '
        def n: (tonumber? // null);
        .data as $d
        | { total: ($d.total_credits | n),
            used: ($d.total_usage | n),
            remaining: ((($d.total_credits | n) // 0) - (($d.total_usage | n) // 0)) }' 2>/dev/null)
      [ -n "$credits" ] || credits="null"
    fi
  fi

  printf '%s' "$body" | jq -c --argjson t "$now" --argjson credits "$credits" '
    def epoch:
      if . == null then null
      elif type == "number" then (if . > 100000000000 then (. / 1000 | floor) else floor end)
      else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
            | try fromdateiso8601 catch null) end;
    def n: (tonumber? // null);
    .data as $d
    | (($d.expires_at // null) | epoch) as $exp
    | {
        label: ($d.label // null),
        is_free_tier: ($d.is_free_tier // false),
        is_management_key: ($d.is_management_key // false),
        usage: ($d.usage | n),
        today: ($d.usage_daily | n),
        week: ($d.usage_weekly | n),
        month: ($d.usage_monthly | n),
        limit: ($d.limit | n),
        limit_remaining: ($d.limit_remaining | n),
        limit_reset: ($d.limit_reset // null),
        expires: $exp,
        rate: ($d.rate_limit // null),
        budget: (if (($d.effective_budget | type) == "object") then
                  { limit: ($d.effective_budget.limit_usd | n),
                    remaining: ($d.effective_budget.remaining_usd | n),
                    spent: ($d.effective_budget.spend_usd | n),
                    reset: ($d.effective_budget.reset_interval // null),
                    resets: (($d.effective_budget.resets_at // null) | epoch) }
                else null end),
        free_daily: ($d.free_model_daily_requests // null),
        credits: $credits,
        remaining: (($credits.remaining) // ($d.effective_budget.remaining_usd | n) // ($d.limit_remaining | n) // null),
        status: (if $d.disabled == true then "disabled"
                 elif ($exp != null and $exp < $t) then "expired"
                 elif ($d.is_free_tier // false) then "free"
                 else "active" end),
        error: null
      }' 2>/dev/null \
    || printf '%s' '{"error":"could not read OpenRouter key","status":null,"remaining":null}'
}

# ---------- DeepSeek ----------

deepseek_item() {
  local key="$1" usage_token="$2" bbody bcode ubody ucode cbody ccode base bal cur est_json amount_json cost_json
  local usage_error="" estimated=true
  if [ -z "$key" ]; then
    printf '%s' '{"error":"a DeepSeek API key is required","available":null,"balance":null}'
    return
  fi

  bbody=$(fetch_json "https://api.deepseek.com/user/balance" "$key")
  bcode=${bbody%%$'\n'*}
  bbody=${bbody#*$'\n'}
  if [ "$bcode" != 200 ]; then
    case $bcode in
      401) printf '%s' '{"error":"DeepSeek key is invalid","available":null,"balance":null}' ;;
      000) printf '%s' '{"error":"offline","available":null,"balance":null}' ;;
      *) printf '%s' "{\"error\":\"balance unavailable (HTTP $bcode)\",\"available\":null,\"balance\":null}" ;;
    esac
    return
  fi

  base=$(printf '%s' "$bbody" | jq -c '
    def n: (tonumber? // null);
    { available: (.is_available // false),
      balances: [ .balance_infos[]?
                  | { currency: (.currency // null),
                      total: (.total_balance | n),
                      granted: (.granted_balance | n),
                      topped: (.topped_up_balance | n) } ] }
    | ([.balances[] | select(.currency == "USD")] + [.balances[] | select(.currency != "USD")]) as $b
    | $b[0] as $p
    | . + { currency: ($p.currency // null),
            balance: ($p.total // null),
            granted: ($p.granted // null),
            topped: ($p.topped // null),
            error: (if ($b | length) == 0 then "no balance information" else null end) }' 2>/dev/null)
  [ -n "$base" ] || base='{"error":"could not read DeepSeek balance","available":null,"balance":null}'

  bal=$(printf '%s' "$base" | jq -r '.balance // empty' 2>/dev/null)
  cur=$(printf '%s' "$base" | jq -r '.currency // empty' 2>/dev/null)

  # Local balance history: spend without a platform usage token.
  if [ -n "$bal" ] && [ -n "$cur" ]; then
    printf '{"t":%s,"balance":%s,"currency":"%s"}\n' "$now" "$bal" "$cur" \
      >>"$CACHE/deepseek.jsonl" 2>/dev/null || true
    if [ "$(wc -l <"$CACHE/deepseek.jsonl" 2>/dev/null || echo 0)" -gt 12000 ]; then
      tail -n 12000 "$CACHE/deepseek.jsonl" >"$CACHE/deepseek.tmp" 2>/dev/null \
        && mv -f "$CACHE/deepseek.tmp" "$CACHE/deepseek.jsonl"
    fi
  fi

  est_json='{"today":null,"month":null}'
  if [ -n "$bal" ] && [ -n "$cur" ] && [ -s "$CACHE/deepseek.jsonl" ]; then
    est_json=$(jq -sc --arg cur "$cur" --argjson bal "$bal" \
      --argjson ts "$today_start" --argjson ms "$month_start" '
      [ .[] | select(.currency == $cur) ] as $r
      | ([ $r[] | select(.t >= $ts) ] | first) as $t0
      | ([ $r[] | select(.t >= $ms) ] | first) as $m0
      | { today: (if $t0 then ([$t0.balance - $bal, 0] | max) else null end),
          month: (if $m0 then ([$m0.balance - $bal, 0] | max) else null end) }' \
      "$CACHE/deepseek.jsonl" 2>/dev/null)
    [ -n "$est_json" ] || est_json='{"today":null,"month":null}'
  fi

  if [ -n "$usage_token" ]; then
    ubody=$(fetch_json "https://platform.deepseek.com/api/v0/usage/amount?month=${month}&year=${year}" "$usage_token")
    ucode=${ubody%%$'\n'*}
    ubody=${ubody#*$'\n'}
    cbody=$(fetch_json "https://platform.deepseek.com/api/v0/usage/cost?month=${month}&year=${year}" "$usage_token")
    ccode=${cbody%%$'\n'*}
    cbody=${cbody#*$'\n'}
    if [ "$ucode" = 200 ] && [ "$ccode" = 200 ]; then
      amount_json=$(printf '%s' "$ubody" | jq -c --arg today "$today_date" '
        def n: (tonumber? // 0);
        def biz: if (.data.biz_data | type) == "array" then .data.biz_data[0] else .data.biz_data end;
        (biz // {}) as $b
        | { today_tokens: ([ $b.days[]? | select(.date == $today) | .data[]?.usage[]?
                             | select((.type // .kind) != "REQUEST")
                             | (.amount // .value // 0 | n) ] | add // 0) }' 2>/dev/null)
      cost_json=$(printf '%s' "$cbody" | jq -c --arg today "$today_date" '
        def n: (tonumber? // 0);
        def biz: if (.data.biz_data | type) == "array" then .data.biz_data[0] else .data.biz_data end;
        (biz // {}) as $b
        | { currency: ($b.currency // null),
            today: ([ $b.days[]? | select(.date == $today) | .data[]?.usage[]?
                      | select((.type // .kind) != "REQUEST")
                      | (.amount // .value // 0 | n) ] | add // 0),
            month: ([ $b.total[]?.usage[]?
                      | select((.type // .kind) != "REQUEST")
                      | (.amount // .value // 0 | n) ] | add // 0) }' 2>/dev/null)
      if [ -n "$amount_json" ] && [ -n "$cost_json" ]; then
        jq -cn --argjson base "$base" --argjson a "$amount_json" \
          --argjson c "$cost_json" '
          $base + { today: ($c.today // null), month: ($c.month // null),
                    today_tokens: ($a.today_tokens // null),
                    cost_currency: ($c.currency // $base.currency // null),
                    estimated: false, usage_error: null }'
        return
      fi
      usage_error="could not read DeepSeek usage"
    else
      usage_error="usage token expired; sign in to platform.deepseek.com"
    fi
  fi

  jq -cn --argjson base "$base" --argjson est "$est_json" --arg ue "$usage_error" '
    $base + { today: $est.today, month: $est.month, today_tokens: null,
              cost_currency: ($base.currency // null),
              estimated: true,
              usage_error: (if $ue == "" then null else $ue end) }'
}

# ---------- collect ----------

ACCOUNTS_JSON=$(printf '%s' "$CONFIG_JSON" | jq -c '
  if type == "array" then .
  elif type == "object" then (.accounts // [])
  else [] end' 2>/dev/null)
[ -n "$ACCOUNTS_JSON" ] || ACCOUNTS_JSON='[]'
COUNT=$(printf '%s' "$ACCOUNTS_JSON" | jq -r 'length' 2>/dev/null)
case $COUNT in '' | *[!0-9]*) COUNT=0 ;; esac

TMP=$(mktemp "$CACHE/accounts.XXXXXX") || TMP="$CACHE/accounts.tmp"
: >"$TMP"

for ((i = 0; i < COUNT; i++)); do
  ROW=$(printf '%s' "$ACCOUNTS_JSON" | jq -c ".[$i] | {id:(.id // \"$i\"), provider:(.provider // \"\"), name:(.name // \"\"), key:(.key // \"\"), extra:(.extra // \"\")}" 2>/dev/null)
  [ -n "$ROW" ] || continue
  IFS=$'\t' read -r id provider name key extra < <(printf '%s' "$ROW" | jq -r '[.id, .provider, .name, .key, .extra] | @tsv' 2>/dev/null)
  [ -n "$id" ] || id="$i"
  [ -n "$name" ] || name="$provider"

  case $provider in
    claude) data=$(claude_item "$key") ;;
    opencode-go) data=$(opencode_item "$key") ;;
    openrouter) data=$(openrouter_item "$key" "$extra") ;;
    deepseek) data=$(deepseek_item "$key" "$extra") ;;
    *) data='{"error":"unknown provider"}' ;;
  esac
  [ -n "$data" ] || data='{"error":"provider returned nothing"}'

  ITEM=$(jq -cn --arg id "$id" --arg provider "$provider" --arg name "$name" --argjson d "$data" '
    {id:$id, provider:$provider, name:$name, error:($d.error // null)} + {($provider): $d}' 2>/dev/null)
  [ -n "$ITEM" ] || ITEM=$(jq -cn --arg id "$id" --arg provider "$provider" --arg name "$name" \
    '{id:$id, provider:$provider, name:$name, error:"could not read provider data"}')
  printf '%s\n' "$ITEM" >>"$TMP"
done

jq -sc --argjson t "$now" '{updated:$t, accounts:.}' "$TMP" 2>/dev/null \
  || printf '{"updated":%s,"accounts":[]}\n' "$now"
rm -f "$TMP"
