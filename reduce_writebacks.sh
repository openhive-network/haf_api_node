#!/bin/bash

# reduce_writebacks.sh - Optimize Linux VM and ZFS parameters for initial HAF sync
#
# This script modifies kernel VM parameters and ZFS ARC settings to reduce
# write-back frequency and manage memory allocation, which significantly
# improves performance during initial blockchain sync.
#
# Usage:
#   sudo ./reduce_writebacks.sh          # Apply optimized settings
#   sudo ./reduce_writebacks.sh --restore # Restore original settings
#   ./reduce_writebacks.sh --help        # Show this help
#
# The script now also manages ZFS ARC max to prevent memory exhaustion

set -euo pipefail

# Configuration
SAVED_VALUES_FILE=".reduce_writebacks.original"

# Memory allocation constants (in GB, easy to modify)
# These are used to calculate ZFS ARC max
POSTGRESQL_SHARED_BUFFERS_GB=16  # PostgreSQL shared_buffers setting
KERNEL_OVERHEAD_GB=2              # Kernel slab, pagetables, etc.
SAFETY_MARGIN_GB=10               # Free memory for bursts, containers
# Note: Max dirty pages (12GB) is taken from vm.dirty_bytes setting

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

# Calculate ZFS ARC max based on system memory
# Returns the value in bytes
calculate_arc_max() {
    # Get total RAM in GB
    local total_ram_bytes=$(free -b | grep Mem: | awk '{print $2}')
    local total_ram_gb=$((total_ram_bytes / 1024 / 1024 / 1024))

    # Get max dirty pages from our setting (12GB)
    local max_dirty_gb=12

    # Calculate ARC max using the formula:
    # ARC_MAX = Total_RAM - (PG_shared_buffers + Kernel_overhead + Max_dirty_pages + Safety_margin)
    local reserved_gb=$((POSTGRESQL_SHARED_BUFFERS_GB + KERNEL_OVERHEAD_GB + max_dirty_gb + SAFETY_MARGIN_GB))
    local arc_max_gb=$((total_ram_gb - reserved_gb))

    # Ensure we don't set a negative or too small value
    if [[ $arc_max_gb -lt 20 ]]; then
        print_warning "System has insufficient memory for recommended settings" >&2
        print_warning "Calculated ARC max would be ${arc_max_gb}GB, using minimum of 20GB" >&2
        arc_max_gb=20
    fi

    # Convert to bytes
    local arc_max_bytes=$((arc_max_gb * 1024 * 1024 * 1024))

    # Print info messages to stderr so they don't interfere with the return value
    print_info "System RAM: ${total_ram_gb}GB" >&2
    print_info "Reserved: PostgreSQL=${POSTGRESQL_SHARED_BUFFERS_GB}GB, Kernel=${KERNEL_OVERHEAD_GB}GB, Dirty=${max_dirty_gb}GB, Safety=${SAFETY_MARGIN_GB}GB" >&2
    print_info "Calculated ZFS ARC max: ${arc_max_gb}GB" >&2

    echo "$arc_max_bytes"
}

# Check if ZFS module is loaded
is_zfs_available() {
    if [[ -d /sys/module/zfs ]]; then
        return 0
    else
        return 1
    fi
}

# Get current value of a ZFS parameter
get_zfs_param() {
    local param=$1
    if is_zfs_available && [[ -f "/sys/module/zfs/parameters/$param" ]]; then
        cat "/sys/module/zfs/parameters/$param" 2>/dev/null || echo "unknown"
    else
        echo "unavailable"
    fi
}

# Set a ZFS parameter
set_zfs_param() {
    local param=$1
    local value=$2

    if ! is_zfs_available; then
        print_warning "ZFS module not loaded, skipping $param"
        return 1
    fi

    if [[ -f "/sys/module/zfs/parameters/$param" ]]; then
        # Use tee to write with sudo privileges (script is run with sudo)
        if echo "$value" | tee "/sys/module/zfs/parameters/$param" > /dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    else
        print_warning "ZFS parameter $param not found"
        return 1
    fi
}

# Show help message
show_help() {
    cat << EOF
Usage: sudo $0 [OPTIONS]

Optimize Linux VM and ZFS ARC parameters for HAF initial sync performance.

OPTIONS:
    --restore       Restore original VM and ZFS parameter values
    --dry-run       Show what would be changed without applying
    --no-zfs        Skip ZFS ARC max configuration
    --help          Show this help message

VM PARAMETERS:
EOF
    for param_info in "${VM_PARAMS[@]}"; do
        IFS='|' read -r param value desc <<< "$param_info"
        printf "  %-30s %s\n" "$param" "$desc"
    done
    cat << EOF

ZFS PARAMETERS:
  zfs_arc_max                    Calculated based on system RAM minus allocations

MEMORY ALLOCATION:
  The ZFS ARC max is calculated as:
    Total RAM - (PostgreSQL shared_buffers + Kernel overhead + Max dirty pages + Safety margin)

  Current configuration:
    PostgreSQL shared_buffers: ${POSTGRESQL_SHARED_BUFFERS_GB}GB
    Kernel overhead: ${KERNEL_OVERHEAD_GB}GB
    Max dirty pages: 12GB (from vm.dirty_bytes)
    Safety margin: ${SAFETY_MARGIN_GB}GB

NOTES:
    - Must be run as root
    - Settings automatically reset on reboot
    - Original values are saved to: $SAVED_VALUES_FILE
    - Use --restore to manually revert changes

EXAMPLES:
    sudo $0              # Apply all optimized settings
    sudo $0 --no-zfs    # Apply VM settings only, skip ZFS ARC
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
#   $2 - skip_zfs (optional): if "true", don't save ZFS values
save_original_values() {
    local skip_prompt=${1:-false}
    local skip_zfs=${2:-false}
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
    echo "# Original sysctl and ZFS values saved on $(date)" > "$temp_file"

    # Save VM parameters
    for param_info in "${VM_PARAMS[@]}"; do
        IFS='|' read -r param _ _ <<< "$param_info"
        local current_value
        current_value=$(get_sysctl_value "$param")
        echo "${param}=${current_value}" >> "$temp_file"
    done

    # Save ZFS parameters if available and not skipped
    if [[ "$skip_zfs" == "false" ]] && is_zfs_available; then
        local zfs_arc_max
        zfs_arc_max=$(get_zfs_param "zfs_arc_max")
        echo "zfs.zfs_arc_max=${zfs_arc_max}" >> "$temp_file"
    fi

    mv "$temp_file" "$SAVED_VALUES_FILE"
    print_success "Original values saved"
    return 0
}

# Apply optimized settings
apply_settings() {
    local dry_run=${1:-false}
    local skip_zfs=${2:-false}
    local changes_needed=false

    print_info "Checking current VM parameter values..."
    echo

    # Calculate ZFS ARC max first (unless skipped)
    local arc_max_bytes
    if [[ "$skip_zfs" == "false" ]] && is_zfs_available; then
        arc_max_bytes=$(calculate_arc_max)
        echo
    fi

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

    # Check ZFS ARC max if ZFS is available and not skipped
    if [[ "$skip_zfs" == "false" ]] && is_zfs_available; then
        local current_arc_max
        current_arc_max=$(get_zfs_param "zfs_arc_max")
        if [[ "$current_arc_max" == "$arc_max_bytes" ]]; then
            print_success "zfs_arc_max is already set to $arc_max_bytes (no change needed)"
        else
            print_warning "zfs_arc_max: needs change from $current_arc_max to $arc_max_bytes"
            changes_needed=true
        fi
    elif [[ "$skip_zfs" == "true" ]] && is_zfs_available; then
        print_info "Skipping ZFS ARC max configuration (--no-zfs specified)"
    fi

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
            save_original_values "true" "$skip_zfs" || true  # Skip prompt, we already asked
            echo
        else
            print_warning "Keeping existing backup - you won't be able to restore to the current values!"
            echo
        fi
    else
        save_original_values "true" "$skip_zfs" || true  # No prompt needed, file doesn't exist
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

    # Apply ZFS ARC max if available and not skipped
    if [[ "$skip_zfs" == "false" ]] && is_zfs_available; then
        local current_arc_max
        current_arc_max=$(get_zfs_param "zfs_arc_max")
        if [[ "$current_arc_max" != "$arc_max_bytes" ]]; then
            if set_zfs_param "zfs_arc_max" "$arc_max_bytes"; then
                print_success "zfs_arc_max: changed from $current_arc_max to $arc_max_bytes"
            else
                print_error "Failed to update zfs_arc_max"
            fi
        fi
    fi

    # Print reminder
    echo
    if [[ "$skip_zfs" == "true" ]]; then
        print_success "VM parameters have been optimized for HAF initial sync"
    else
        print_success "VM and ZFS parameters have been optimized for HAF initial sync"
    fi
    echo
    print_warning "IMPORTANT NOTES:"
    echo "  • These settings will automatically reset on the next reboot"
    echo "  • To manually restore original values before rebooting, run:"
    echo "      sudo $0 --restore"
    if [[ "$skip_zfs" == "false" ]] && is_zfs_available; then
        local arc_max_gb=$((arc_max_bytes / 1024 / 1024 / 1024))
        echo "  • ZFS ARC is limited to ${arc_max_gb}GB to prevent memory exhaustion"
    fi
    echo
}

# Restore original settings
restore_settings() {
    if [[ ! -f "$SAVED_VALUES_FILE" ]]; then
        print_error "No saved values file found: $SAVED_VALUES_FILE"
        echo "Run the script without --restore first to create a baseline"
        exit 1
    fi

    print_info "Restoring original VM and ZFS parameter values from: $SAVED_VALUES_FILE"
    echo

    local changes_made=false

    while IFS='=' read -r param value; do
        # Skip comments and empty lines
        [[ "$param" =~ ^#.*$ ]] && continue
        [[ -z "$param" ]] && continue

        # Check if it's a ZFS parameter
        if [[ "$param" == "zfs.zfs_arc_max" ]]; then
            if is_zfs_available; then
                local current_value
                current_value=$(get_zfs_param "zfs_arc_max")

                if [[ "$current_value" == "$value" ]]; then
                    print_success "zfs_arc_max is already set to $value (no change needed)"
                else
                    print_warning "zfs_arc_max: restoring from $current_value to $value"

                    if set_zfs_param "zfs_arc_max" "$value"; then
                        print_success "zfs_arc_max restored successfully"
                        changes_made=true
                    else
                        print_error "Failed to restore zfs_arc_max"
                    fi
                fi
            else
                print_warning "ZFS module not loaded, skipping zfs_arc_max restore"
            fi
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
        print_success "Original VM and ZFS parameters have been restored"
    else
        print_success "All parameters were already at their original values"
    fi
}

# Main execution
main() {
    local mode="apply"
    local dry_run=false
    local skip_zfs=false

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
                skip_zfs=true
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
            apply_settings "$dry_run" "$skip_zfs"
            ;;
        restore)
            restore_settings
            ;;
    esac
}

main "$@"