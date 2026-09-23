#!/usr/bin/env bash

# Parallelized script to find the first failing stg patch by testing each patch in a separate temporary copy.

set -e

# Default number of parallel jobs
PARALLEL_JOBS=8
# Fast mode: only run `lake build` instead of `lake exe test`
FAST_MODE=0

usage() {
    echo "Usage: $0 [-f|--fast] [-j JOBS] [JOBS]"
    echo "  -f, --fast     Run 'lake build' instead of 'lake exe test'"
    echo "  -j, --jobs     Number of parallel jobs (default: $PARALLEL_JOBS)"
    echo "  JOBS           Positional alternative to -j"
}

# Parse CLI arguments: support --fast/-f and jobs via -j/--jobs or positional
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--fast)
            FAST_MODE=1
            shift
            ;;
        -j|--jobs)
            shift
            if [[ -n "$1" && "$1" =~ ^[0-9]+$ && "$1" -ge 1 ]]; then
                PARALLEL_JOBS=$1
                shift
            else
                usage
                exit 1
            fi
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 ]]; then
                PARALLEL_JOBS=$1
                shift
            else
                usage
                exit 1
            fi
            ;;
    esac
done

echo "Using $PARALLEL_JOBS parallel jobs."
if [[ $FAST_MODE -eq 1 ]]; then
    echo "Fast mode enabled: will run 'lake build' instead of 'lake exe test'."
fi

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if stg is installed
if ! command -v stg &> /dev/null; then
    echo -e "${RED}Error: stacked-git (stg) is not installed. Please install it to continue.${NC}"
    exit 1
fi

# Check if we're in a stg repository
if ! stg series >/dev/null 2>&1; then
    echo -e "${RED}Error: Not in a stacked git repository or stg not initialized.${NC}"
    exit 1
fi

# Get all unpushed patches
PATCHES=$(stg series | grep '^-' | cut -c 2- | sed 's/^ *//' || echo "")

if [[ -z "$PATCHES" ]]; then
    echo -e "${YELLOW}No patches to push. All patches are already applied.${NC}"
    exit 0
fi

echo -e "${YELLOW}Found the following unapplied patches:${NC}"
echo "$PATCHES" | nl

# Store patches in an array
IFS=$'\n' read -r -d '' -a PATCH_ARRAY < <(echo "$PATCHES" && printf '\0')

# Clean up .lake folders before launching jobs to make copying faster
echo -e "${BLUE}Cleaning up .lake folders to speed up copying...${NC}"
rm -rf ./.lake >/dev/null 2>&1 || true
rm -rf ./test/Mathlib/.lake >/dev/null 2>&1 || true

# Create log directory for real-time monitoring
LOG_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="./patch_test_logs/$LOG_TIMESTAMP"
mkdir -p "$LOG_DIR"
echo -e "${BLUE}Logs will be written to: $LOG_DIR${NC}"

# Directory for temp clones
TMPDIR=$(mktemp -d)

# pids array for job management
pids=()

# Cleanup function
cleanup() {
    echo -e "${YELLOW}Cleaning up temporary directories...${NC}"
    # Kill any remaining background jobs
    if ((${#pids[@]})); then
        kill "${pids[@]}" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR" 2>/dev/null || true
    echo -e "${YELLOW}Log files are preserved in: $LOG_DIR${NC}"
}

# Set up trap for cleanup
trap cleanup EXIT INT TERM

# Function to test a patch in a temp clone
run_patch_test() {
    (
        local patch_idx=$1
        local patch_name=$2
        local tmp_clone="$TMPDIR/clone_$patch_idx"
        local log_file="$LOG_DIR/patch_${patch_idx}_${patch_name}.log"
        local status_file="$LOG_DIR/patch_${patch_idx}_${patch_name}.status"
        # Ensure the temporary clone is removed as soon as this job finishes (success, fail, or kill)
        local -i cleaned_up=0
        cleanup_tmp() {
            if (( cleaned_up == 0 )); then
                # Leave the clone directory before removing it to avoid EBUSY
                cd "$TMPDIR" 2>/dev/null || cd /
                rm -rf "$tmp_clone" 2>/dev/null || true
                cleaned_up=1
            fi
        }
        trap 'cleanup_tmp' EXIT INT TERM
        # Open log file for stdout/stderr, but keep fd 3 for status file
        exec 3>"$status_file"
        exec >"$log_file" 2>&1
        echo "=========================================="
        echo "Testing patch: $patch_name (index $patch_idx)"
        echo "Started at: $(date)"
        echo "=========================================="
        echo "RUNNING" >&3
        log_and_fail() {
            local message="$1"
            echo "$message"
            echo "ERROR" >&3
            exit 1
        }
        [[ -d "$TMPDIR" ]] || log_and_fail "TMPDIR $TMPDIR does not exist"
        echo "Creating copy of repository..."
        cp -a . "$tmp_clone" || log_and_fail "Copy failed"
        echo "Successfully created copy at: $tmp_clone"
        echo "Entering clone directory..."
        cd "$tmp_clone" || log_and_fail "Failed to enter clone directory: $tmp_clone"
        echo "Successfully entered directory: $(pwd)"
        echo "Going to patch: $patch_name..."
        stg goto "$patch_name" || log_and_fail "Failed to goto patch $patch_name"
        echo "Successfully went to patch: $patch_name"
        # Choose command based on FAST_MODE
        local cmd_desc="lake exe test"
        local -a test_cmd=("lake" "exe" "test")
        if [[ "${FAST_MODE:-0}" -eq 1 ]]; then
            cmd_desc="lake build"
            test_cmd=("lake" "build")
        fi
        echo "Running: $cmd_desc"
        echo "TESTING" >&3
        if "${test_cmd[@]}"; then
            echo "PASS" >&3
            echo "=========================================="
            echo "PASSED at: $(date)"
            echo "=========================================="
        else
            echo "FAIL" >&3
            echo "=========================================="
            echo "FAILED at: $(date)"
            echo "=========================================="
            cp "$log_file" "$TMPDIR/test_failure_$patch_idx.txt" 2>/dev/null || true
        fi
    # Proactively cleanup the temporary clone before exiting the subshell
    cleanup_tmp
        exec 3>&-
    )
}

# Function to check for any completed jobs and handle early termination
check_for_failure() {
    local first_failure_idx=-1 first_failure_status=""
    for idx in "${!PATCH_ARRAY[@]}"; do
        local status_file="$LOG_DIR/patch_${idx}_${PATCH_ARRAY[$idx]}.status"
        if [[ -f "$status_file" ]]; then
            local status
            status=$(cat "$status_file")
            # Only check the last non-empty line for the status
            status=$(echo "$status" | awk 'NF {line=$0} END{print line}')
            if [[ "$status" == FAIL || "$status" == ERROR ]]; then
                if [[ $first_failure_idx -eq -1 ]] || (( idx < first_failure_idx )); then
                    first_failure_idx=$idx
                    first_failure_status="$status"
                fi
            fi
        fi
    done
    if [[ $first_failure_idx -ne -1 ]]; then
        echo -e "${RED}Found failing patch: ${PATCH_ARRAY[$first_failure_idx]}${NC}"
        echo -e "${YELLOW}Terminating jobs for patches after index $first_failure_idx...${NC}"

        # Kill only jobs working on patches after the failing one
        for pid_to_check in "${!pid_to_idx[@]}"; do
            local idx=${pid_to_idx[$pid_to_check]}
            if (( idx > first_failure_idx )); then
                kill "$pid_to_check" 2>/dev/null || true
            fi
        done
        wait 2>/dev/null || true # Wait for killed jobs to exit

        # Report the failure and exit
        echo -e "${RED}✗ $first_failure_result${NC}"
        local patch_name="${PATCH_ARRAY[$first_failure_idx]}"
        echo -e "${RED}First failing patch: $patch_name (index $first_failure_idx)${NC}"
        echo -e "${YELLOW}To debug this patch, run: stg goto $patch_name${NC}"
        echo -e "${YELLOW}Full log available at: $LOG_DIR/patch_${first_failure_idx}_${patch_name}.log${NC}"
        return 42
    fi
    return 0
}

# Export function and variables for parallel execution
export -f run_patch_test
export TMPDIR LOG_DIR GREEN RED YELLOW BLUE NC PATCH_ARRAY FAST_MODE

echo -e "${BLUE}Starting parallel testing of ${#PATCH_ARRAY[@]} patches...${NC}"
echo -e "${YELLOW}You can monitor progress in real-time by checking the log files in: $LOG_DIR${NC}"
echo -e "${YELLOW}For example: tail -f $LOG_DIR/patch_0_*.log${NC}"
echo ""

# Launch tests in parallel with job control and early termination
pids=()
declare -A pid_to_idx
first_failure_idx=-1

# Temporarily disable set -e for the entire parallel section
set +e

for idx in "${!PATCH_ARRAY[@]}"; do
    if [[ $first_failure_idx -ne -1 ]]; then
        break
    fi

    # Limit number of parallel jobs
    if ((${#pids[@]} >= PARALLEL_JOBS)); then
        # Wait for any job to finish
        wait -n -p finished_pid
        finished_idx=${pid_to_idx[$finished_pid]}
        # Check the status file of the finished job
        status_file="$LOG_DIR/patch_${finished_idx}_${PATCH_ARRAY[$finished_idx]}.status"
        if [[ -f "$status_file" ]]; then
            status=$(awk 'NF {line=$0} END{print line}' "$status_file")
            if [[ "$status" == FAIL || "$status" == ERROR ]]; then
                first_failure_idx=$finished_idx
                echo -e "${RED}Found failing patch: ${PATCH_ARRAY[$finished_idx]}${NC}"
                break
            fi
        fi
        unset "pid_to_idx[$finished_pid]"
        pids=("${pids[@]/$finished_pid}")
    fi
    echo -e "${YELLOW}Starting test for patch ($((idx+1))/${#PATCH_ARRAY[@]}): ${PATCH_ARRAY[$idx]}${NC}"
    run_patch_test "$idx" "${PATCH_ARRAY[$idx]}" < /dev/null &
    pid=$!
    pids+=($pid)
    pid_to_idx[$pid]=$idx
done

# Wait for all remaining jobs to complete and check their exit status
for pid in "${pids[@]}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        wait "$pid"
    fi
done

# Final check for failures
check_for_failure
result=$?

if [[ $result -eq 42 ]]; then
    # Failure already reported
    exit 1
elif [[ $result -ne 0 ]]; then
    echo -e "${RED}An unexpected error occurred in check_for_failure.${NC}"
    exit 1
fi

echo -e "${GREEN}All patches passed successfully!${NC}"
exit 0
