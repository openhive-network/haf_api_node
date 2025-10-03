#!/bin/bash

# reduce_writebacks.sh - Optimize Linux VM parameters for initial HAF sync
#
# This script modifies kernel VM parameters to reduce write-back frequency,
# which significantly improves performance during initial blockchain sync.
#
# Usage:
#   sudo ./reduce_writebacks.sh          # Apply optimized settings
#   sudo ./reduce_writebacks.sh --restore # Restore original settings
#   ./reduce_writebacks.sh --help        # Show this help

set -euo pipefail

# Configuration
SAVED_VALUES_FILE=".reduce_writebacks.original"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# VM parameters to configure
# Format: "parameter_name|new_value|description"
declare -a VM_PARAMS=(
    "vm.dirty_bytes|12000000000|Maximum dirty memory before forced writeback (12GB)"
    "vm.dirty_background_bytes|5000000000|Threshold for background writeback (5GB)"
    "vm.dirty_expire_centisecs|300000|Age at which dirty data expires (5 min)"
    "vm.dirty_writeback_centisecs|50000|Interval for writeback thread wakeup (50 sec)"
    "vm.swappiness|0|Tendency to swap memory pages (0 = avoid swapping)"
)

# Print functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Show help message
show_help() {
    cat << EOF
Usage: sudo $0 [OPTIONS]

Optimize Linux VM parameters for HAF initial sync performance.

OPTIONS:
    --restore    Restore original VM parameter values
    --dry-run    Show what would be changed without applying
    --help       Show this help message

VM PARAMETERS:
EOF
    for param_info in "${VM_PARAMS[@]}"; do
        IFS='|' read -r param value desc <<< "$param_info"
        printf "  %-30s %s\n" "$param" "$desc"
    done
    cat << EOF

NOTES:
    - Must be run as root
    - Settings automatically reset on reboot
    - Original values are saved to: $SAVED_VALUES_FILE
    - Use --restore to manually revert changes

EXAMPLES:
    sudo $0              # Apply optimized settings
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

    for param_info in "${VM_PARAMS[@]}"; do
        IFS='|' read -r param _ _ <<< "$param_info"
        local current_value
        current_value=$(get_sysctl_value "$param")

        # Special handling: dirty_bytes and dirty_ratio are mutually exclusive
        # Save whichever one is active (non-zero)
        if [[ "$param" == "vm.dirty_bytes" ]]; then
            if [[ "$current_value" == "0" ]]; then
                # Bytes mode inactive, save ratio instead
                local ratio_value
                ratio_value=$(get_sysctl_value "vm.dirty_ratio")
                echo "vm.dirty_ratio=${ratio_value}" >> "$temp_file"
                continue
            fi
        elif [[ "$param" == "vm.dirty_background_bytes" ]]; then
            if [[ "$current_value" == "0" ]]; then
                # Bytes mode inactive, save ratio instead
                local ratio_value
                ratio_value=$(get_sysctl_value "vm.dirty_background_ratio")
                echo "vm.dirty_background_ratio=${ratio_value}" >> "$temp_file"
                continue
            fi
        fi

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

    # First pass: check what needs to be changed
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
        print_success "All VM parameters are already optimized - no changes needed"
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

        local current_value
        current_value=$(get_sysctl_value "$param")

        if [[ "$current_value" == "$value" ]]; then
            print_success "$param is already set to $value (no change needed)"
        else
            print_warning "$param: restoring from $current_value to $value"
            if sysctl -w "${param}=${value}" > /dev/null 2>&1; then
                print_success "$param restored successfully"
                changes_made=true
            else
                print_error "Failed to restore $param"
            fi
        fi
    done < "$SAVED_VALUES_FILE"

    echo

    if [[ "$changes_made" == "true" ]]; then
        print_success "Original VM parameters have been restored"
    else
        print_success "All VM parameters were already at their original values"
    fi
}

# Main execution
main() {
    local mode="apply"
    local dry_run=false

    # Parse arguments
    for arg in "$@"; do
        case $arg in
            --restore)
                mode="restore"
                ;;
            --dry-run)
                dry_run=true
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

    # Check root privileges
    check_root "$@"

    # Execute requested mode
    case $mode in
        apply)
            apply_settings "$dry_run"
            ;;
        restore)
            restore_settings
            ;;
    esac
}

main "$@"
