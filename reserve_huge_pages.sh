#!/bin/bash

# reserve_huge_pages.sh - Reserve huge pages for the haf container's PostgreSQL shared memory
#
# PostgreSQL runs with huge_pages = try: it maps its shared segment (shared_buffers plus lock
# tables, buffer descriptors, wal_buffers) on huge pages when the host has reserved enough of them,
# and falls back to 4kB pages otherwise.  This script sets vm.nr_hugepages to the shared segment
# postgresql_memory.sh sizes for the haf container's shared_buffers.  Reserved huge pages are taken
# out of general RAM until released; memory_plan.sh's ZFS ARC limit already leaves room for that
# segment, so they are not counted twice.  memory_plan.sh --apply runs this script.
#
# Usage:
#   sudo ./reserve_huge_pages.sh            # Reserve them now (stop haf first, see --help)
#   sudo ./reserve_huge_pages.sh --persist  # ...and at every boot (/etc/sysctl.d)
#   sudo ./reserve_huge_pages.sh --release  # Give them back to general RAM
#   ./reserve_huge_pages.sh --dry-run       # Show the reservation without changing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSCTL_FILE=/etc/sysctl.d/60-haf-huge-pages.conf

# shellcheck source=postgresql_memory.sh
. "$SCRIPT_DIR/postgresql_memory.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

show_help() {
    cat << EOF
Usage: sudo $0 [OPTIONS]

Reserve vm.nr_hugepages for the haf container's PostgreSQL shared memory.

OPTIONS:
    --persist       Also write $SYSCTL_FILE, so the reservation is made at boot
    --release       Set vm.nr_hugepages to 0 (and remove $SYSCTL_FILE)
    --dry-run       Show the reservation without applying it (no root needed)
    --help          Show this help message

SIZING:
  shared_buffers is the haf container's (postgresql_memory.sh): POSTGRESQL_SHARED_BUFFERS_GB from
  the environment or $SCRIPT_DIR/.env when set, otherwise ${PG_SHARED_BUFFERS_PERCENT}% of RAM capped at
  ${PG_SHARED_BUFFERS_MAX_GB}GB.  The reservation is shared_buffers + ${PG_SHARED_SEGMENT_OVERHEAD_PERCENT}% (rounded up to whole GB), the shared
  segment memory_plan.sh's ZFS ARC limit leaves room for.  PostgreSQL uses huge pages only
  when its whole segment fits in them; the haf container's log reports huge_pages_status and the
  exact count PostgreSQL needed (shared_memory_size_in_huge_pages) after each start.

NOTES:
    - Run it while haf is stopped: a running PostgreSQL without huge pages holds its shared
      memory in 4kB pages, which the reservation would need as well.  Then start haf.
    - Reserving needs that much free, unfragmented memory; the script compacts memory first and
      undoes a partial reservation.  At boot (--persist) memory is not fragmented yet.
    - Without --persist the reservation lasts until reboot.

EXAMPLES:
    sudo docker compose stop haf && sudo $0 --persist && sudo docker compose start haf
    sudo $0 --release

EOF
}

meminfo_kb() {
    awk -v key="$1:" '$1 == key { print $2 }' /proc/meminfo
}

write_sysctl_file() {
    cat > "$SYSCTL_FILE" << EOF
# Written by haf_api_node's reserve_huge_pages.sh: huge pages for PostgreSQL's shared memory
vm.nr_hugepages = $1
EOF
    print_success "Wrote $SYSCTL_FILE: the reservation is made at every boot"
}

# set_huge_pages TARGET CURRENT HUGE_PAGE_KB: raise or lower vm.nr_hugepages to TARGET, or leave
# it at CURRENT when the kernel cannot reserve all of them
set_huge_pages() {
    local target=$1 current=$2 huge_page_kb=$3
    if [[ $target -gt $current ]]; then
        local needed_kb available_kb
        needed_kb=$(((target - current) * huge_page_kb))
        available_kb=$(meminfo_kb MemAvailable)
        if [[ $needed_kb -gt $available_kb ]]; then
            print_error "Reserving $((target - current)) more huge pages needs $((needed_kb / 1048576))GB, but only $((available_kb / 1048576))GB is available"
            print_error "If haf is running, its PostgreSQL holds that memory in 4kB pages: stop haf, rerun this script, then start haf"
            return 1
        fi
        echo 1 > /proc/sys/vm/compact_memory
    fi

    sysctl -w "vm.nr_hugepages=$target" > /dev/null
    local reserved
    reserved=$(sysctl -n vm.nr_hugepages)
    if [[ $reserved -lt $target ]]; then
        # PostgreSQL would fall back to 4kB pages and leave a partial reservation unused
        sysctl -w "vm.nr_hugepages=$current" > /dev/null
        print_error "The kernel reserved only $reserved of $target huge pages (memory is too fragmented); vm.nr_hugepages is back at $current"
        print_error "Reserve them at boot instead: sudo $0 --persist, then reboot"
        return 1
    fi
    print_success "vm.nr_hugepages: changed from $current to $target"
}

main() {
    local dry_run=false persist=false release=false
    for arg in "$@"; do
        case $arg in
            --dry-run) dry_run=true ;;
            --persist) persist=true ;;
            --release) release=true ;;
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
    if [[ $persist == true && $release == true ]]; then
        print_error "--persist and --release exclude each other"
        exit 1
    fi
    if [[ $dry_run == false && $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Please run with: sudo $0 $*"
        exit 1
    fi

    local huge_page_kb current target
    huge_page_kb=$(pg_huge_page_size_kb /)
    current=$(sysctl -n vm.nr_hugepages)
    if [[ $release == true ]]; then
        target=0
    else
        # pg_shared_buffers_gb reports on stderr how it chose the value
        local shared_buffers_gb
        shared_buffers_gb=$(pg_shared_buffers_gb "$(pg_memory_total_kb /)" "$(pg_shared_buffers_override "$SCRIPT_DIR/.env")")
        target=$(pg_huge_pages_count "$shared_buffers_gb" "$huge_page_kb")
        print_info "PostgreSQL's shared segment: $(pg_shared_segment_gb "$shared_buffers_gb")GB (shared_buffers ${shared_buffers_gb}GB + segment overhead) = $target huge pages of ${huge_page_kb}kB"
    fi

    if [[ $dry_run == true ]]; then
        print_info "vm.nr_hugepages would change from $current to $target; dry run, nothing changed"
        exit 0
    fi

    if [[ $persist == true ]]; then
        write_sysctl_file "$target"
    elif [[ $release == true && -f $SYSCTL_FILE ]]; then
        rm "$SYSCTL_FILE"
        print_success "Removed $SYSCTL_FILE"
    fi

    if [[ $current -eq $target ]]; then
        print_success "vm.nr_hugepages is already $target (no change needed)"
    else
        set_huge_pages "$target" "$current" "$huge_page_kb"
    fi

    if [[ $release == true ]]; then
        print_info "Huge pages a running PostgreSQL still uses are freed when it stops; it falls back to 4kB pages at its next start"
    else
        print_info "PostgreSQL maps its shared memory at start: (re)start haf; its log reports huge_pages_status"
    fi
}

main "$@"
