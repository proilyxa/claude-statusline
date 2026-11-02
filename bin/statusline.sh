#!/bin/bash
set -f
export LC_NUMERIC=C

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ─────────────────────────────────────────────
color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

format_epoch_time() {
    local epoch=$1
    local style=$2
    [ -z "$epoch" ] || [ "$epoch" = "null" ] || [ "$epoch" = "0" ] && return

    local result=""
    case "$style" in
        time)
            result=$(date -j -r "$epoch" +"%H:%M" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%H:%M" 2>/dev/null)
            result=$(echo "$result" | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        datetime)
            result=$(date -j -r "$epoch" +"%b %-d, %H:%M" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d, %H:%M" 2>/dev/null)
            result=$(echo "$result" | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        *)
            result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
            result=$(echo "$result" | tr '[:upper:]' '[:lower:]')
            ;;
    esac
    printf "%s" "$result"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(env TZ=UTC date -d "${stripped/T/ }" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(date -d "${stripped/T/ }" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

# Format a number as a rounded integer (awk, so the locale's decimal separator doesn't matter)
round_pct() {
    awk -v v="$1" 'BEGIN { printf "%.0f", v }'
}

# Seconds since a file was last modified; a large number if it doesn't exist
file_age() {
    local file=$1 mtime
    if [ -f "$file" ]; then
        mtime=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null)
        echo $(( $(date +%s) - mtime ))
    else
        echo 999999
    fi
}

# ── Extract JSON data (single jq call) ─────────────────
US=$'\x1f'
IFS="$US" read -r model_name size input_tokens cache_create cache_read ctx_used_pct \
    cwd effort five_hour_pct_raw five_hour_reset_raw \
    seven_day_pct_raw seven_day_reset_raw cc_version <<< "$(echo "$input" | jq -r '[
        (.model.display_name // "Claude"),
        (.context_window.context_window_size // 0),
        (.context_window.current_usage.input_tokens // 0),
        (.context_window.current_usage.cache_creation_input_tokens // 0),
        (.context_window.current_usage.cache_read_input_tokens // 0),
        (.context_window.used_percentage // ""),
        (.cwd // .workspace.current_dir // ""),
        (.effort.level // ""),
        (.rate_limits.five_hour.used_percentage // ""),
        (.rate_limits.five_hour.resets_at // ""),
        (.rate_limits.seven_day.used_percentage // ""),
        (.rate_limits.seven_day.resets_at // ""),
        (.version // "")
    ] | map(tostring) | join("\u001f")' 2>/dev/null)"

[ -z "$model_name" ] && model_name="Claude"

# Context usage: prefer the percentage Claude Code computes, fall back to counting tokens
if [ -n "$ctx_used_pct" ]; then
    pct_used=$(round_pct "$ctx_used_pct")
else
    [ "${size:-0}" -gt 0 ] 2>/dev/null || size=200000
    current=$(( ${input_tokens:-0} + ${cache_create:-0} + ${cache_read:-0} ))
    pct_used=$(( current * 100 / size ))
fi

# Effort: the session's level from stdin, falling back to settings.json
if [ -z "$effort" ]; then
    settings_path="$HOME/.claude/settings.json"
    [ -f "$settings_path" ] && effort=$(jq -r '.effortLevel // empty' "$settings_path" 2>/dev/null)
    [ -z "$effort" ] && effort="default"
fi

# ── LINE 1: Model │ Context % │ Directory (branch) │ Effort ──
pct_color=$(color_for_pct "$pct_used")
[ -z "$cwd" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

skip_perms=""
parent_cmd=$(ps -o args= -p "$PPID" 2>/dev/null)
if [[ "$parent_cmd" == *"--dangerously-skip-permissions"* ]]; then
    skip_perms="⚡  "
fi

line1="${blue}${model_name}${reset}"
line1+="${sep}"
line1+="✍️ ${pct_color}${pct_used}%${reset}"
line1+="${sep}"
line1+="${skip_perms}${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
line1+="${sep}"
case "$effort" in
    max)    line1+="${red}◉ ${effort}${reset}" ;;
    xhigh)  line1+="${magenta}◉ ${effort}${reset}" ;;
    high)   line1+="${magenta}● ${effort}${reset}" ;;
    medium) line1+="${dim}◑ ${effort}${reset}" ;;
    low)    line1+="${dim}◔ ${effort}${reset}" ;;
    *)      line1+="${dim}◑ ${effort}${reset}" ;;
esac

# ── Rate limits from stdin (primary) ───────────────────
# Claude Code omits five_hour when no 5h window is active, so each window is checked separately.
has_stdin_rates=false
five_hour_pct=""
five_hour_reset_epoch=""
seven_day_pct=""
seven_day_reset_epoch=""

if [ -n "$five_hour_pct_raw" ]; then
    has_stdin_rates=true
    five_hour_pct=$(round_pct "$five_hour_pct_raw")
    five_hour_reset_epoch="$five_hour_reset_raw"
fi
if [ -n "$seven_day_pct_raw" ]; then
    has_stdin_rates=true
    seven_day_pct=$(round_pct "$seven_day_pct_raw")
    seven_day_reset_epoch="$seven_day_reset_raw"
fi

# ── Usage API cache ─────────────────────────────────────
# The API is the fallback for rate limits and the only source for extra usage.
cache_dir="${CLAUDE_STATUSLINE_CACHE_DIR:-/tmp/claude}"
cache_file="$cache_dir/statusline-usage-cache.json"
attempt_file="$cache_dir/statusline-usage-attempt"
fail_file="$cache_dir/statusline-usage-fail"
cache_stale_max=3600   # never show cached data older than this
fail_backoff=300       # wait this long after a failed request (e.g. HTTP 429)
attempt_lock=15        # don't start a request while another one is in flight
if $has_stdin_rates; then
    refresh_interval=300   # only extra usage needs the API, refresh rarely and in the background
else
    refresh_interval=60
fi
[ -d "$cache_dir" ] || mkdir -p "$cache_dir"

fetch_usage() {
    local token="" blob response

    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        token="$CLAUDE_CODE_OAUTH_TOKEN"
    elif command -v security >/dev/null 2>&1; then
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        [ -n "$blob" ] && token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    fi
    if [ -z "$token" ]; then
        local creds_file="${HOME}/.claude/.credentials.json"
        [ -f "$creds_file" ] && token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
    fi
    if [ -z "$token" ] && command -v secret-tool >/dev/null 2>&1; then
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        [ -n "$blob" ] && token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    fi

    if [ -n "$token" ]; then
        response=$(curl -s --max-time 5 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/${cc_version:-2.1.34}" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
            echo "$response" > "$cache_file.tmp" && mv "$cache_file.tmp" "$cache_file"
            rm -f "$fail_file"
            return 0
        fi
    fi
    touch "$fail_file"
    return 1
}

if [ "$(file_age "$cache_file")" -ge "$refresh_interval" ] \
    && [ "$(file_age "$fail_file")" -ge "$fail_backoff" ] \
    && [ "$(file_age "$attempt_file")" -ge "$attempt_lock" ]; then
    touch "$attempt_file"
    if $has_stdin_rates; then
        fetch_usage >/dev/null 2>&1 </dev/null &
    else
        fetch_usage
    fi
fi

usage_data=""
extra_enabled="false"
if [ "$(file_age "$cache_file")" -lt "$cache_stale_max" ]; then
    usage_data=$(cat "$cache_file" 2>/dev/null)
fi

if [ -n "$usage_data" ]; then
    IFS="$US" read -r c_five_pct c_five_reset c_seven_pct c_seven_reset \
        extra_enabled extra_pct_raw extra_used_raw extra_limit_raw <<< "$(echo "$usage_data" | jq -r '[
            (.five_hour.utilization // 0),
            (.five_hour.resets_at // ""),
            (.seven_day.utilization // 0),
            (.seven_day.resets_at // ""),
            (.extra_usage.is_enabled // false),
            (.extra_usage.utilization // 0),
            (.extra_usage.used_credits // 0),
            (.extra_usage.monthly_limit // 0)
        ] | map(tostring) | join("\u001f")' 2>/dev/null)"
    [ -z "$extra_enabled" ] && extra_enabled="false"

    if ! $has_stdin_rates; then
        now_epoch=$(date +%s)
        # A window whose reset time has passed is stale: hide it instead of showing old numbers
        c_five_epoch=$(iso_to_epoch "$c_five_reset")
        if [ -z "$c_five_epoch" ] || [ "$c_five_epoch" -gt "$now_epoch" ]; then
            five_hour_pct=$(round_pct "$c_five_pct")
            five_hour_reset_epoch="$c_five_epoch"
        fi
        c_seven_epoch=$(iso_to_epoch "$c_seven_reset")
        if [ -z "$c_seven_epoch" ] || [ "$c_seven_epoch" -gt "$now_epoch" ]; then
            seven_day_pct=$(round_pct "$c_seven_pct")
            seven_day_reset_epoch="$c_seven_epoch"
        fi
    fi
fi

# ── Rate limit lines ────────────────────────────────────
rate_lines=""
bar_width=10

if [ -n "$five_hour_pct" ]; then
    five_hour_reset=$(format_epoch_time "$five_hour_reset_epoch" "time")
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")
    five_hour_pct_color=$(color_for_pct "$five_hour_pct")
    five_hour_pct_fmt=$(printf "%3d" "$five_hour_pct")

    rate_lines+="${white}current${reset} ${five_hour_bar} ${five_hour_pct_color}${five_hour_pct_fmt}%${reset}"
    [ -n "$five_hour_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${five_hour_reset}${reset}"
fi

if [ -n "$seven_day_pct" ]; then
    seven_day_reset=$(format_epoch_time "$seven_day_reset_epoch" "datetime")
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")
    seven_day_pct_color=$(color_for_pct "$seven_day_pct")
    seven_day_pct_fmt=$(printf "%3d" "$seven_day_pct")

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}weekly${reset}  ${seven_day_bar} ${seven_day_pct_color}${seven_day_pct_fmt}%${reset}"
    [ -n "$seven_day_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${seven_day_reset}${reset}"
fi

if [ "$extra_enabled" = "true" ]; then
    extra_pct=$(round_pct "$extra_pct_raw")
    extra_used=$(awk -v v="$extra_used_raw" 'BEGIN { printf "%.2f", v / 100 }')
    extra_limit=$(awk -v v="$extra_limit_raw" 'BEGIN { printf "%.2f", v / 100 }')
    extra_bar=$(build_bar "$extra_pct" "$bar_width")
    extra_pct_color=$(color_for_pct "$extra_pct")

    extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ -z "$extra_reset" ]; then
        extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    fi

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}extra${reset}   ${extra_bar} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset} ${dim}⟳${reset} ${white}${extra_reset}${reset}"
fi

# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"

exit 0
