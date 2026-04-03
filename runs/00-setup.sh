#!/usr/bin/env bash
#
# Interactive setup - collect machine-specific configuration
# Phase: 00 - Must run before all other phases
# Writes: ~/.env.local
#
# shellcheck source=../utils/utils.sh
source "$(dirname "$0")/../utils/utils.sh"

# ─── Flags ────────────────────────────────────────────────────────────────────

run_machine=0
run_monitors=0
run_git=0
run_all=1  # default when no section flags given

show_help() {
    cat <<EOF
Usage: ./runs/00-setup.sh [options]

With no section flags, runs the full interactive setup.
With section flags, runs only those sections and merges into ~/.env.local.

Section flags:
  -M, --machine    Configure machine type only
  -m, --monitors   Configure monitors only (implies desktop prompts)
  -g, --git        Configure git only

Monitor options:
  -t, --transform <n>   Secondary monitor transform (default: none)
                        0=normal, 1=90°, 2=180°, 3=270°
                        Stored as MONITOR_SECONDARY_TRANSFORM in ~/.env.local

Other:
  -h, --help       Show this help and exit
EOF
}

TRANSFORM_VALUE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -M|--machine)  run_machine=1;  run_all=0; shift ;;
        -m|--monitors) run_monitors=1; run_all=0; shift ;;
        -g|--git)      run_git=1;      run_all=0; shift ;;
        -t|--transform)
            if [[ -z "${2:-}" ]] || [[ "${2:0:1}" == "-" ]]; then
                echo "Error: --transform requires a value (0-3)" >&2
                show_help; exit 1
            fi
            if [[ ! "$2" =~ ^[0-3]$ ]]; then
                echo "Error: transform must be 0–3 (got: $2)" >&2
                exit 1
            fi
            TRANSFORM_VALUE="$2"; shift 2
            ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Error: Unknown option: $1" >&2; show_help; exit 1 ;;
    esac
done

print_header "Interactive Machine Setup"

# ─── Machine type ─────────────────────────────────────────────────────────────

detect_default_type() {
    if compgen -G "/sys/class/power_supply/BAT*" > /dev/null 2>&1; then
        echo "laptop"
    else
        echo "desktop"
    fi
}

prompt_machine_type() {
    local default
    default="$(detect_default_type)"

    log_section "Machine Type"
    log_info "Detected default: $default"
    read -r -p "Machine type (laptop/desktop) [$default]: " input
    MACHINE_TYPE="${input:-$default}"
    MACHINE_TYPE="${MACHINE_TYPE,,}"

    if [[ "$MACHINE_TYPE" != "laptop" && "$MACHINE_TYPE" != "desktop" ]]; then
        log_error "Invalid machine type: $MACHINE_TYPE"
        exit 1
    fi

    log_success "Machine type: $MACHINE_TYPE"
}

# ─── Monitor detection ────────────────────────────────────────────────────────

auto_detect_monitors() {
    command_exists hyprctl && command_exists jq || return 1

    local monitors_json
    monitors_json="$(hyprctl monitors -j 2>/dev/null)" || return 1
    [[ "$(jq 'length' <<< "$monitors_json")" -eq 0 ]] && return 1

    log_info "Detected monitors (sorted left → right):"
    jq -r 'sort_by(.x) | .[] | "    \(.name)  \(.width)x\(.height)  @ x=\(.x)"' <<< "$monitors_json"
    echo ""

    MONITOR_PRIMARY="$(jq -r 'sort_by(.x) | .[0].name' <<< "$monitors_json")"
    MONITOR_SECONDARY="$(jq -r 'sort_by(.x) | .[1].name // ""' <<< "$monitors_json")"
}

prompt_monitors() {
    log_section "Monitor Configuration"
    MONITOR_PRIMARY=""
    MONITOR_SECONDARY=""
    MONITOR_SECONDARY_TRANSFORM=""

    if [[ "$MACHINE_TYPE" == "laptop" ]]; then
        MONITOR_PRIMARY="eDP-1"
        MONITOR_SECONDARY=""
        log_info "Laptop: primary set to $MONITOR_PRIMARY, no secondary"
        return
    fi

    if auto_detect_monitors; then
        log_info "Auto-detected — primary: $MONITOR_PRIMARY, secondary: ${MONITOR_SECONDARY:-none}"
    else
        log_warning "Could not auto-detect monitors (hyprctl/jq unavailable or not running)"
    fi

    read -r -p "Primary monitor name [$MONITOR_PRIMARY]: " input
    MONITOR_PRIMARY="${input:-$MONITOR_PRIMARY}"

    if [[ -z "$MONITOR_PRIMARY" ]]; then
        log_error "Primary monitor is required for desktop"
        exit 1
    fi

    read -r -p "Secondary monitor name (leave blank for none) [$MONITOR_SECONDARY]: " input
    MONITOR_SECONDARY="${input:-$MONITOR_SECONDARY}"

    # Transform — use flag value if given, otherwise prompt when there's a secondary
    if [[ -n "$MONITOR_SECONDARY" ]]; then
        if [[ -n "$TRANSFORM_VALUE" ]]; then
            MONITOR_SECONDARY_TRANSFORM="$TRANSFORM_VALUE"
            log_info "Secondary transform set via flag: $MONITOR_SECONDARY_TRANSFORM"
        else
            echo ""
            log_info "Secondary monitor orientation:"
            echo "    0 = normal (landscape)"
            echo "    1 = 90°  clockwise"
            echo "    2 = 180° (flipped)"
            echo "    3 = 270° clockwise (portrait, common for vertical monitors)"
            read -r -p "Transform for $MONITOR_SECONDARY [0]: " input
            input="${input:-0}"
            if [[ ! "$input" =~ ^[0-3]$ ]]; then
                log_error "Invalid transform: $input (must be 0–3)"
                exit 1
            fi
            MONITOR_SECONDARY_TRANSFORM="$input"
        fi
    fi

    log_success "Primary: $MONITOR_PRIMARY"
    if [[ -n "$MONITOR_SECONDARY" ]]; then
        log_success "Secondary: $MONITOR_SECONDARY (transform: $MONITOR_SECONDARY_TRANSFORM)"
    fi
}

# ─── Git configuration ────────────────────────────────────────────────────────

prompt_git_config() {
    log_section "Git Configuration"

    read -r -p "Git personal name: "  GIT_USER_NAME
    read -r -p "Git personal email: " GIT_USER_EMAIL
    read -r -p "Git work name (leave blank to skip): "  GIT_WORK_NAME
    read -r -p "Git work email (leave blank to skip): " GIT_WORK_EMAIL
    read -r -p "Company name (leave blank to skip): " COMPANY_NAME
}

# ─── Write ~/.env.local (merge-aware) ────────────────────────────────────────
#
# Instead of overwriting the whole file, we update only the keys that
# were collected in this run, preserving anything else already in the file.

upsert_env_key() {
    local key="$1" value="$2" file="$3"
    # Quote value if it contains spaces
    local entry
    if [[ "$value" == *" "* ]]; then
        entry="export ${key}=\"${value}\""
    else
        entry="export ${key}=${value}"
    fi

    if grep -q "^export ${key}=" "$file" 2>/dev/null; then
        sed -i "s|^export ${key}=.*|${entry}|" "$file"
    else
        echo "$entry" >> "$file"
    fi
}

write_env_local() {
    # Create file with header if it doesn't exist yet
    if [[ ! -f "$ENV_LOCAL" ]]; then
        cat > "$ENV_LOCAL" <<'HEADER'
# Machine configuration — generated by 00-setup.sh
# Edit manually or re-run ./runs/00-setup.sh [--monitors|--git] to update

HEADER
    fi

<<<<<<< HEAD
# Git
export GIT_USER_NAME="$GIT_USER_NAME"
export GIT_USER_EMAIL="$GIT_USER_EMAIL"
export GIT_WORK_NAME="$GIT_WORK_NAME"
export GIT_WORK_EMAIL="$GIT_WORK_EMAIL"
export COMPANY_NAME="$COMPANY_NAME"
ENV
=======
    [[ -n "${MACHINE_TYPE:-}" ]]                  && upsert_env_key "MACHINE_TYPE"                  "$MACHINE_TYPE"                  "$ENV_LOCAL"
    [[ -n "${MONITOR_PRIMARY:-}" ]]               && upsert_env_key "MONITOR_PRIMARY"               "$MONITOR_PRIMARY"               "$ENV_LOCAL"
    # Always write secondary (may be intentionally empty)
    [[ -v MONITOR_SECONDARY ]]                    && upsert_env_key "MONITOR_SECONDARY"             "$MONITOR_SECONDARY"             "$ENV_LOCAL"
    [[ -v MONITOR_SECONDARY_TRANSFORM ]]          && upsert_env_key "MONITOR_SECONDARY_TRANSFORM"   "$MONITOR_SECONDARY_TRANSFORM"   "$ENV_LOCAL"
    [[ -n "${GIT_USER_NAME:-}" ]]                 && upsert_env_key "GIT_USER_NAME"                 "$GIT_USER_NAME"                 "$ENV_LOCAL"
    [[ -n "${GIT_USER_EMAIL:-}" ]]                && upsert_env_key "GIT_USER_EMAIL"                "$GIT_USER_EMAIL"                "$ENV_LOCAL"
    [[ -v GIT_WORK_NAME ]]                        && upsert_env_key "GIT_WORK_NAME"                 "$GIT_WORK_NAME"                 "$ENV_LOCAL"
    [[ -v GIT_WORK_EMAIL ]]                       && upsert_env_key "GIT_WORK_EMAIL"                "$GIT_WORK_EMAIL"                "$ENV_LOCAL"
>>>>>>> 2e97d76 (automated dev commit)

    log_success "Written to $ENV_LOCAL"
    echo ""
    cat "$ENV_LOCAL"
}

# ─── Run ──────────────────────────────────────────────────────────────────────

# Load existing env so prompts can show current values as defaults
[[ -f "$ENV_LOCAL" ]] && source "$ENV_LOCAL"

if [[ $run_all -eq 1 ]]; then
    prompt_machine_type
    prompt_monitors
    prompt_git_config
else
    # Need MACHINE_TYPE for monitor prompts even in partial runs
    if [[ $run_monitors -eq 1 && -z "${MACHINE_TYPE:-}" ]]; then
        log_warning "MACHINE_TYPE not set in ~/.env.local — running machine type prompt too"
        prompt_machine_type
    fi
    [[ $run_machine -eq 1 ]]  && prompt_machine_type
    [[ $run_monitors -eq 1 ]] && prompt_monitors
    [[ $run_git -eq 1 ]]      && prompt_git_config

    # --transform alone, no --monitors: just update the transform key
    if [[ $run_monitors -eq 0 && -n "$TRANSFORM_VALUE" ]]; then
        log_section "Monitor Transform"
        MONITOR_SECONDARY_TRANSFORM="$TRANSFORM_VALUE"
        log_success "Secondary transform → $MONITOR_SECONDARY_TRANSFORM"
    fi
fi

log_section "Summary"
[[ -n "${MACHINE_TYPE:-}" ]]                && echo "  Machine type  : $MACHINE_TYPE"
[[ -n "${MONITOR_PRIMARY:-}" ]]             && echo "  Primary mon.  : $MONITOR_PRIMARY"
[[ -n "${MONITOR_SECONDARY:-}" ]]           && echo "  Secondary mon.: $MONITOR_SECONDARY (transform: ${MONITOR_SECONDARY_TRANSFORM:-0})"
[[ -z "${MONITOR_SECONDARY:-}" ]]           && [[ -v MONITOR_SECONDARY ]] && echo "  Secondary mon.: none"
[[ -n "${GIT_USER_NAME:-}" ]]               && echo "  Git name      : $GIT_USER_NAME"
[[ -n "${GIT_USER_EMAIL:-}" ]]              && echo "  Git email     : $GIT_USER_EMAIL"
[[ -n "${GIT_WORK_NAME:-}" ]]               && echo "  Work name     : $GIT_WORK_NAME"
[[ -n "${GIT_WORK_EMAIL:-}" ]]              && echo "  Work email    : $GIT_WORK_EMAIL"
echo ""

read -r -p "Save this configuration? (Y/n): " confirm
if [[ "${confirm,,}" == "n" ]]; then
    log_warning "Aborted — nothing written"
    exit 1
fi

write_env_local

print_footer "Setup complete — continuing install..."
