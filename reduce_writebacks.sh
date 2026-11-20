#!/bin/bash

# reduce_writebacks.sh - Optimize Linux VM writeback parameters for initial HAF sync
#
# This script modifies kernel VM parameters (vm.dirty_* and friends) to reduce
# write-back frequency, which significantly improves performance during initial
# blockchain sync.  The ZFS ARC limit is memory_plan.sh's.
#
# Usage:
#   sudo ./reduce_writebacks.sh          # Apply optimized settings
#   sudo ./reduce_writebacks.sh --restore # Restore original settings
#   ./reduce_writebacks.sh --help        # Show this help
#
# --zfs-only [--persist] is a deprecated alias of memory_plan.sh --apply --arc-only [--persist], and
# --zfs-only --dry-run of memory_plan.sh.

set -euo pipefail

# Configuration
SAVED_VALUES_FILE=".reduce_writebacks.original"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# VM parameters to configure; vm.dirty_bytes is the dirty-page reserve memory_plan.sh plans with
# (postgresql_memory.sh's PG_MAX_DIRTY_GB)
# Format: "parameter_name|new_value|description"
declare -a VM_PARAMS=(
    "vm.dirty_bytes|12000000000|Maximum dirty memory before forced writeback (12GB)"
    "vm.dirty_background_bytes|5000000000|Threshold for background writeback (5GB)"
    "vm.dirty_expire_centisecs|300000|Age at which dirty data expires (50 min)"
    "vm.dirty_writeback_centisecs|50000|Interval for writeback thread wakeup (500 sec)"
    "vm.swappiness|1|Tendency to swap memory pages (1 = minimal swapping)"
    "vm.min_free_kbytes|262144|Minimum free memory for atomic allocations (256MB)"
)

# Print functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Show help message
show_help() {
    cat << EOF
Usage: sudo $0 [OPTIONS]

Optimize Linux VM writeback parameters for HAF initial sync performance.

OPTIONS:
    --restore       Restore original VM parameter values
    --dry-run       Show what would be changed without applying
    --zfs-only      Deprecated: runs memory_plan.sh --apply --arc-only (memory_plan.sh with --dry-run)
    --persist       With --zfs-only: memory_plan.sh --apply --arc-only --persist
    --no-zfs        Deprecated, no effect: this script no longer sets the ZFS ARC limit
    --help          Show this help message

VM PARAMETERS:
EOF
    for param_info in "${VM_PARAMS[@]}"; do
        IFS='|' read -r param value desc <<< "$param_info"
        printf "  %-30s %s\n" "$param" "$desc"
    done
    cat << EOF

ZFS ARC LIMIT:
  The ZFS ARC limit (zfs_arc_max) is part of the host's memory plan, next to PostgreSQL's
  shared_buffers and the memory the other services use: see sudo $SCRIPT_DIR/memory_plan.sh,
  and apply it with sudo $SCRIPT_DIR/memory_plan.sh --apply --persist.  Its 12GB dirty-page
  reserve is vm.dirty_bytes here.

NOTES:
    - Must be run as root
    - Settings automatically reset on reboot
    - Original values are saved to: $SAVED_VALUES_FILE
    - Use --restore to manually revert changes

EXAMPLES:
    sudo $0              # Apply all optimized settings
    sudo $0 --restore    # Restore original settings
    sudo $0 --dry-run    # Preview changes

EOF
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Please run with: sudo $0 $*"
        exit 1
    fi
}

# Get current value of a sysctl parameter
get_sysctl_value() {
    local param=$1
    sysctl -n "$param" 2>/dev/null || echo "unknown"
}

# Save original values to file
# Parameters:
#   $1 - skip_prompt (optional): if "true", don't prompt before overwriting
save_original_values() {
    local skip_prompt=${1:-false}
    local temp_file="${SAVED_VALUES_FILE}.tmp"

    if [[ -f "$SAVED_VALUES_FILE" ]] && [[ "$skip_prompt" == "false" ]]; then
        print_warning "Original values file already exists: $SAVED_VALUES_FILE"
        read -p "Overwrite? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Keeping existing saved values file"
            return 1
        fi
    fi

    print_info "Saving original values to: $SAVED_VALUES_FILE"

    # Save with timestamp
    echo "# Original sysctl values saved on $(date)" > "$temp_file"

    # Save VM parameters
    for param_info in "${VM_PARAMS[@]}"; do
        IFS='|' read -r param _ _ <<< "$param_info"
        local current_value
        current_value=$(get_sysctl_value "$param")
        echo "${param}=${current_value}" >> "$temp_file"
    done

    mv "$temp_file" "$SAVED_VALUES_FILE"
    print_success "Original values saved"
    return 0
}

# Apply optimized settings
apply_settings() {
    local dry_run=${1:-false}
    local changes_needed=false

    print_info "Checking current VM parameter values..."
    echo

    # First pass: check what needs to be changed (VM parameters)
    for param_info in "${VM_PARAMS[@]}"; do
        IFS='|' read -r param new_value desc <<< "$param_info"
        local current_value
        current_value=$(get_sysctl_value "$param")

        if [[ "$current_value" == "$new_value" ]]; then
            print_success "$param is already set to $new_value (no change needed)"
        else
            print_warning "$param: needs change from $current_value to $new_value"
            changes_needed=true
        fi
    done

    echo

    if [[ "$changes_needed" == "false" ]]; then
        print_success "All parameters are already optimized - no changes needed"
        return 0
    fi

    if [[ "$dry_run" == "true" ]]; then
        print_info "Dry run complete - no changes were applied"
        return 0
    fi

    # Save original values BEFORE making any changes
    if [[ -f "$SAVED_VALUES_FILE" ]]; then
        print_warning "Original values file already exists: $SAVED_VALUES_FILE"
        echo "We need to save the CURRENT values before changing them, but a backup file already exists."
        read -p "Overwrite the existing backup with current values? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            save_original_values "true" || true  # Skip prompt, we already asked
            echo
        else
            print_warning "Keeping existing backup - you won't be able to restore to the current values!"
            echo
        fi
    else
        save_original_values "true" || true  # No prompt needed, file doesn't exist
        echo
    fi

    # Second pass: apply the changes
    print_info "Applying changes..."
    echo

    # Apply VM parameters
    for param_info in "${VM_PARAMS[@]}"; do
        IFS='|' read -r param new_value desc <<< "$param_info"
        local current_value
        current_value=$(get_sysctl_value "$param")

        if [[ "$current_value" != "$new_value" ]]; then
            if sysctl -w "${param}=${new_value}" > /dev/null 2>&1; then
                print_success "$param: changed from $current_value to $new_value"
            else
                print_error "Failed to update $param"
            fi
        fi
    done

    # Print reminder
    echo
    print_success "VM parameters have been optimized for HAF initial sync"
    echo
    print_warning "IMPORTANT NOTES:"
    echo "  • These settings will automatically reset on the next reboot"
    echo "  • To manually restore original values before rebooting, run:"
    echo "      sudo $0 --restore"
    echo "  • The ZFS ARC limit is memory_plan.sh's: sudo $SCRIPT_DIR/memory_plan.sh"
    echo
}

# Restore original settings
restore_settings() {
    if [[ ! -f "$SAVED_VALUES_FILE" ]]; then
        print_error "No saved values file found: $SAVED_VALUES_FILE"
        echo "Run the script without --restore first to create a baseline"
        exit 1
    fi

    print_info "Restoring original VM parameter values from: $SAVED_VALUES_FILE"
    echo

    local changes_made=false

    while IFS='=' read -r param value; do
        # Skip comments and empty lines
        [[ "$param" =~ ^#.*$ ]] && continue
        [[ -z "$param" ]] && continue

        # Files saved by older versions carry zfs_arc_max, which memory_plan.sh owns now
        if [[ "$param" == "zfs.zfs_arc_max" ]]; then
            print_info "zfs_arc_max (saved as $value) is left as it is: it is memory_plan.sh's"
            continue
        fi

        # Regular sysctl parameters
        local current_value
        current_value=$(get_sysctl_value "$param")

        if [[ "$current_value" == "$value" ]]; then
            print_success "$param is already set to $value (no change needed)"
        else
            print_warning "$param: restoring from $current_value to $value"

            # Special handling: can't set dirty_bytes/dirty_background_bytes to 0 directly
            # Need to set ratio parameters instead to switch back to ratio mode
            if [[ "$param" == "vm.dirty_bytes" ]] && [[ "$value" == "0" ]]; then
                local default_ratio=20
                if sysctl -w "vm.dirty_ratio=${default_ratio}" > /dev/null 2>&1; then
                    print_success "$param restored (by setting vm.dirty_ratio=$default_ratio)"
                    changes_made=true
                else
                    print_error "Failed to restore $param"
                fi
            elif [[ "$param" == "vm.dirty_background_bytes" ]] && [[ "$value" == "0" ]]; then
                local default_ratio=10
                if sysctl -w "vm.dirty_background_ratio=${default_ratio}" > /dev/null 2>&1; then
                    print_success "$param restored (by setting vm.dirty_background_ratio=$default_ratio)"
                    changes_made=true
                else
                    print_error "Failed to restore $param"
                fi
            else
                # Normal restore
                if sysctl -w "${param}=${value}" > /dev/null 2>&1; then
                    print_success "$param restored successfully"
                    changes_made=true
                else
                    print_error "Failed to restore $param"
                fi
            fi
        fi
    done < "$SAVED_VALUES_FILE"

    echo

    if [[ "$changes_made" == "true" ]]; then
        print_success "Original VM parameters have been restored"
    else
        print_success "All parameters were already at their original values"
    fi
}

# run_memory_plan DRY_RUN PERSIST: the deprecated --zfs-only, which memory_plan.sh replaces
run_memory_plan() {
    local args=()
    if [[ $1 == false ]]; then
        args+=(--apply --arc-only)
        if [[ $2 == true ]]; then args+=(--persist); fi
    fi
    print_warning "--zfs-only is deprecated: the ZFS ARC limit is memory_plan.sh's; running: $SCRIPT_DIR/memory_plan.sh ${args[*]}"
    exec "$SCRIPT_DIR/memory_plan.sh" "${args[@]}"
}

# Main execution
main() {
    local mode="apply"
    local dry_run=false
    local zfs_only=false
    local persist=false

    # Parse arguments
    for arg in "$@"; do
        case $arg in
            --restore)
                mode="restore"
                ;;
            --dry-run)
                dry_run=true
                ;;
            --no-zfs)
                print_warning "--no-zfs is deprecated and has no effect: this script no longer sets the ZFS ARC limit"
                ;;
            --zfs-only)
                zfs_only=true
                ;;
            --persist)
                persist=true
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $arg"
                echo "Run '$0 --help' for usage information"
                exit 1
                ;;
        esac
    done

    if [[ "$zfs_only" == "true" && "$mode" == "restore" ]]; then
        print_error "--zfs-only excludes --restore"
        exit 1
    fi
    if [[ "$persist" == "true" && "$zfs_only" == "false" ]]; then
        print_error "--persist needs --zfs-only"
        exit 1
    fi

    # Check root privileges
    check_root "$@"

    # Execute requested mode
    case $mode in
        apply)
            if [[ "$zfs_only" == "true" ]]; then
                run_memory_plan "$dry_run" "$persist"
            else
                apply_settings "$dry_run"
            fi
            ;;
        restore)
            restore_settings
            ;;
    esac
}

main "$@"