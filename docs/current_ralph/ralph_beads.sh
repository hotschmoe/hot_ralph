#!/bin/bash
# hot_ralph - Beads-integrated development loop
# Requires: .beads directory with ready tasks already created
# Uses beads (br) for atomic task tracking
set -e

AUTO_MODE=false
PROJECT_DIR="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto|-a) AUTO_MODE=true ;;
        *) PROJECT_DIR="$1" ;;
    esac
    shift
done

JQ_STREAM='select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty'

log() { echo "[$(date '+%H:%M:%S')] $*"; }

die() { echo "ERROR: $*" >&2; exit 1; }

require_file() {
    [[ -f "$PROJECT_DIR/$1" ]] || die "Missing $1"
}

require_command() {
    command -v "$1" &>/dev/null || die "$1 is required${2:+ - $2}"
}

check_requirements() {
    require_file SPEC.md
    require_file VISION.md
    require_file TESTING.md
    require_command jq
    require_command claude
    require_command br "https://github.com/Dicklesworthstone/beads_rust"

    [[ -d "$PROJECT_DIR/.beads" ]] || die ".beads directory not found - run: br init"
    mkdir -p "$PROJECT_DIR/.hot_ralph"
}

run_claude() {
    local label="${2:-claude}"
    local outfile="$PROJECT_DIR/.hot_ralph/$(date '+%Y%m%d_%H%M%S')_${label}.md"
    log "Output: $outfile"

    claude --print --verbose --output-format stream-json --dangerously-skip-permissions "$1" \
        | jq --unbuffered -rj "$JQ_STREAM" \
        | tee "$outfile"
    echo
}

prompt_user() {
    if [[ "$AUTO_MODE" == true ]]; then
        echo "${2:-y}"
        return
    fi
    read -p "$1" -n 1 -r
    echo
    echo "$REPLY"
}

beads_ready_count() {
    br ready --json 2>/dev/null | jq 'length // 0'
}

beads_get_next() {
    br ready --json 2>/dev/null | jq 'sort_by(.priority, .created_at) | .[0] // empty'
}

beads_claim() {
    br update "$1" --status in_progress --json &>/dev/null
    log "Claimed task: $1"
}

beads_complete() {
    br close "$1" --reason "${2:-Completed}" --json &>/dev/null
    log "Completed task: $1"
}

beads_sync() {
    br sync &>/dev/null
    log "Beads synced"
}

commit_beads() {
    beads_sync
    git diff --quiet .beads/ 2>/dev/null || {
        git add .beads/
        git commit -m "$1" --no-verify 2>/dev/null || true
    }
}

commit_all() {
    git diff --quiet 2>/dev/null && [[ -z $(git status --porcelain 2>/dev/null) ]] && return
    git add -A
    git commit -m "$1" --no-verify 2>/dev/null || true
}

graceful_exit() {
    echo
    log "Interrupted - syncing beads..."
    beads_sync
    exit 0
}

countdown_window() {
    local seconds="${1:-5}"
    trap graceful_exit SIGINT
    echo
    for ((i=seconds; i>0; i--)); do
        printf "\r[Ctrl+C to stop] Next task in %d... " "$i"
        sleep 1
    done
    printf "\r%-40s\r" " "
    trap - SIGINT
}

cd "$PROJECT_DIR"
check_requirements

[[ $(beads_ready_count) -gt 0 ]] || die "No ready tasks - run: br create \"Task\" --type task --description \"...\""

log "Starting hot_ralph (beads mode)"
log "Project: $PROJECT_DIR"
[[ "$AUTO_MODE" == true ]] && log "AUTO MODE ENABLED"

while true; do
    # Window for user to Ctrl+C between tasks
    countdown_window 5

    task_json=$(beads_get_next)

    if [[ -z "$task_json" || "$task_json" == "null" ]]; then
        echo
        echo "==============================================================="
        echo "  ALL TASKS COMPLETE!"
        echo "==============================================================="
        commit_beads "beads: final sync"
        git push 2>/dev/null || true
        run_claude "All beads tasks are complete.
Review @VISION.md - does the codebase embody the vision?
Summarize what was built and identify any remaining gaps." "final_review"
        exit 0
    fi

    # Extract all task fields in one jq call
    eval "$(echo "$task_json" | jq -r '@sh "task_id=\(.id) task_title=\(.title) task_desc=\(.description // "No description") task_priority=\(.priority) task_tags=\(.tags // [] | join(", "))"')"
    ready_count=$(beads_ready_count)

    echo
    echo "---------------------------------------------------------------"
    echo "  TASK: $task_title"
    echo "  ID: $task_id | Priority: $task_priority | Ready: $ready_count"
    [[ -n "$task_tags" ]] && echo "  Tags: $task_tags"
    echo "---------------------------------------------------------------"
    echo "$task_desc"
    echo "---------------------------------------------------------------"

    case "$(prompt_user "Execute? [Y/n/s(kip)/v(iew all)/q] " "y")" in
        [Qq]) log "Exiting - syncing beads..."; beads_sync; exit 0 ;;
        [Ss]) log "Skipping task (marking complete)"; beads_complete "$task_id" "Skipped by user"; continue ;;
        [Vv]) log "Ready tasks:"; br ready; continue ;;
        [Nn]) log "Skipping task (remains in queue)"; continue ;;
    esac

    beads_claim "$task_id"
    log "Executing task..."

    safe_task_id="${task_id//[^[:alnum:]]/_}"

    run_claude "You are implementing a single atomic task.

## Task
**$task_title**

$task_desc

## Context Files
- @SPEC.md - Project specification
- @VISION.md - Project vision
- @TESTING.md - Testing requirements

## Instructions
1. Implement ONLY what this task specifies - no more, no less
2. Run any validation criteria specified in the description
3. If validation passes, commit with message based on task title
4. Report success or failure clearly

This is an ATOMIC task. Stay focused." "task_${safe_task_id}"

    echo
    case "$(prompt_user "Task successful? [Y/n/r(etry)] " "y")" in
        [Nn])
            log "Task not complete - keeping in progress"
            ;;
        [Rr])
            log "Retrying task..."
            br update "$task_id" --status open --json &>/dev/null
            continue
            ;;
        *)
            log "Running code simplifier..."
            run_claude "Review the code changes made for task: $task_title

Use the code-simplifier:code-simplifier agent approach:
1. Find recently modified files (check git status and git diff)
2. Simplify and refine code for clarity, consistency, and maintainability
3. Preserve all functionality - no behavior changes
4. Run tests to verify nothing broke
5. If tests pass, commit any simplification changes

Focus on the code that was just modified. Keep changes minimal and safe." "simplify_${safe_task_id}"

            git diff --quiet 2>/dev/null || {
                log "Committing simplification changes..."
                commit_all "refactor: simplify code from $task_id"
            }
            beads_complete "$task_id" "Completed successfully"
            commit_beads "beads: complete $task_id"
            ;;
    esac

    (( RANDOM % 5 == 0 )) && {
        log "Pushing to remote..."
        git push 2>/dev/null || log "Push failed (will retry later)"
    }
done
