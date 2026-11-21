#!/bin/bash

# memory_plan.sh - The host's memory plan for a HAF node, and the host-side parts of it
#
# Shows how RAM is shared out: PostgreSQL's shared_buffers and shared segment (which the haf
# container sizes at every start), the memory everything else on the host uses (measured), the
# kernel and dirty-page reserves, the ZFS ARC limit that leaves, the huge pages that hold the shared
# segment, and effective_cache_size.  The arithmetic is postgresql_memory.sh's.  --apply sets the
# parts that live on the host: zfs_arc_max, and the huge page reservation (reserve_huge_pages.sh).
#
# Usage:
#   sudo ./memory_plan.sh                    # Show the plan; changes nothing
#   sudo ./memory_plan.sh --apply            # Set zfs_arc_max and reserve the huge pages now
#   sudo ./memory_plan.sh --apply --persist  # ...and at every boot
#
# MEMORY_PLAN_ROOT (default /) points the script at a fixture root with proc/, sys/, etc/ and boot/
# in place of the host's, for tests; --apply then needs no root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${MEMORY_PLAN_ROOT:-/}"
CGROUP_DIR="${ROOT%/}/sys/fs/cgroup"
ZFS_ARC_MAX_PARAM="${ROOT%/}/sys/module/zfs/parameters/zfs_arc_max"
MODPROBE_DIR="${ROOT%/}/etc/modprobe.d"
# written by --persist when no "options zfs" line in MODPROBE_DIR sets zfs_arc_max (it replaces the
# value of those that do)
MODPROBE_FILE=haf-zfs-arc-max.conf
GIB=1073741824

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

Show the host's memory plan for HAF, and with --apply set its host-side parts.

OPTIONS:
    --apply             Set zfs_arc_max to the plan's limit and reserve the plan's huge pages
                        (reserve_huge_pages.sh; skipped while haf runs and they would change)
    --persist           With --apply: also make both the boot-time values ($MODPROBE_DIR,
                        /etc/sysctl.d)
    --arc-only          With --apply: only zfs_arc_max, leave the huge pages as they are
    --force             With --apply: replace a zfs_arc_max in $MODPROBE_DIR that differs from
                        the plan (without it, such a value is kept as set by hand, or refused
                        when it overcommits RAM)
    --sample-seconds N  Measure other services over N seconds (default 10; 0 takes one sample)
    --help              Show this help message

THE PLAN (whole GB; all from postgresql_memory.sh):
    shared_buffers      POSTGRESQL_SHARED_BUFFERS_GB, or ${PG_SHARED_BUFFERS_PERCENT}% of RAM capped at ${PG_SHARED_BUFFERS_MAX_GB}GB (the haf container's)
    shared segment      shared_buffers + ${PG_SHARED_SEGMENT_OVERHEAD_PERCENT}%, held in huge pages when they are reserved
    other services      HAF_OTHER_SERVICES_GB, or the measured peak + ${PG_OTHER_SERVICES_HEADROOM_PERCENT}%, at least ${PG_OTHER_SERVICES_MIN_GB}GB
    kernel, dirty pages ${PG_KERNEL_OVERHEAD_GB}GB and ${PG_MAX_DIRTY_GB}GB (reduce_writebacks.sh's vm.dirty_bytes)
    ZFS ARC limit       ZFS_ARC_MAX_GB, or RAM minus all of the above, at least ${PG_ZFS_ARC_MIN_GB}GB
    effective_cache_size shared_buffers + the ARC limit (the haf container sets it)

  Other services are everything on the host but PostgreSQL's shared segment and the ARC: every
  container (the haf project's own included: hived, PostgreSQL's backends, the apps, the proxies)
  and the processes outside containers.  Each cgroup counts memory.current minus its page cache,
  shared memory and huge pages (memory.stat's file and hugetlb), sampled once a second; the plan
  takes each one's peak.
  HAF_OTHER_SERVICES_GB and ZFS_ARC_MAX_GB are read from the environment or $SCRIPT_DIR/.env.

  --persist replaces the zfs_arc_max of each "options zfs" line in $MODPROBE_DIR/*.conf, or
  writes $MODPROBE_DIR/$MODPROBE_FILE when there is none, and updates the initramfs when it loads
  zfs.  A zfs_arc_max there that differs from the plan is taken as set by hand: --apply leaves it,
  and the runtime limit, alone and says so, unless --force is given or ZFS_ARC_MAX_GB is set.
  When that ARC limit, the huge pages (the plan's or vm.nr_hugepages, whichever is more) and the
  kernel, dirty-page and other-services reserves add up to more than RAM, --apply refuses to keep
  it and exits non-zero, changing nothing: the next boot would overcommit RAM.  The other services
  this refusal counts are HAF_OTHER_SERVICES_GB, or the fixed ${PG_SAFETY_MARGIN_GB}GB safety margin, never
  the measurement, which moves with whatever runs while it samples: a value that overcommits RAM
  only with the measured other services is kept, with a warning.

EXAMPLES:
    sudo $0
    sudo $0 --apply --persist                        # on a running node: the ARC limit
    docker compose stop haf && sudo $0 --apply --persist && docker compose start haf
    echo ZFS_ARC_MAX_GB=42 >> .env && sudo $0 --apply --persist   # make a hand-set 42GB the plan

EOF
}

# gb BYTES prints BYTES in GB with one decimal
gb() {
    awk -v bytes="$1" 'BEGIN { printf "%.1fGB", bytes / 1073741824 }'
}

# cgroup_used_bytes DIR prints the memory the cgroup DIR uses outside page cache, shared memory and
# huge pages (memory.current - memory.stat's file and hugetlb): ARC-backed file pages and
# PostgreSQL's shared segment have their own places in the plan.  memory.stat has hugetlb only when
# cgroup2 is mounted with memory_hugetlb_accounting, which charges huge pages to memory.current.
# Returns 1 when the cgroup is gone.
cgroup_used_bytes() {
    local current file hugetlb
    current=$(cat "$1/memory.current" 2> /dev/null) || return 1
    file=$(awk '$1 == "file" { print $2 }' "$1/memory.stat" 2> /dev/null || true)
    hugetlb=$(awk '$1 == "hugetlb" { print $2 }' "$1/memory.stat" 2> /dev/null || true)
    echo $((current - ${file:-0} - ${hugetlb:-0}))
}

# list_containers prints "ID NAME COMPOSE_PROJECT" for each running container
list_containers() {
    if ! command -v docker > /dev/null; then
        print_warning "docker not found: no per-container breakdown"
        return 0
    fi
    docker ps --no-trunc --format '{{.ID}} {{.Names}} {{.Label "com.docker.compose.project"}}' \
        || print_warning "docker ps failed: no per-container breakdown"
}

# container_cgroup ID prints the cgroup directory of container ID (systemd or cgroupfs driver)
container_cgroup() {
    local dir
    for dir in "$CGROUP_DIR/system.slice/docker-$1.scope" "$CGROUP_DIR/docker/$1"; do
        if [[ -f $dir/memory.current ]]; then
            echo "$dir"
            return 0
        fi
    done
    find "$CGROUP_DIR" -maxdepth 4 -type d \( -name "docker-$1.scope" -o -name "$1" \) -print -quit 2> /dev/null
}

# measure_other_services SECONDS HAF_PROJECT samples what every top-level cgroup and every
# container uses (cgroup_used_bytes) once a second for SECONDS, keeping each container's peak and
# the peak of the rest, the processes outside containers.  It sets MEASURED_BYTES to the sum of
# those peaks and BREAKDOWN to one "BYTES MARK NAME" line each, largest first, where MARK is * for
# the compose project HAF_PROJECT's containers.  Returns 1 without a cgroup v2 hierarchy to measure.
measure_other_services() {
    local seconds=$1 haf_project=$2 id name project dir used sample i
    local top_total container_total rest rest_peak=0
    local -a names=() marks=() dirs=() peaks=() tops=() unfound=()
    [[ -f $CGROUP_DIR/cgroup.controllers ]] || return 1

    while read -r id name project; do
        [[ -n $id ]] || continue
        dir=$(container_cgroup "$id")
        if [[ -z $dir ]]; then
            unfound+=("$name")
            continue
        fi
        names+=("$name")
        dirs+=("$dir")
        peaks+=(0)
        if [[ $project == "$haf_project" ]]; then marks+=("*"); else marks+=("-"); fi
    done < <(list_containers)
    if [[ ${#unfound[@]} -gt 0 ]]; then
        print_warning "No cgroup under $CGROUP_DIR for ${#unfound[@]} container(s) (${unfound[*]:0:3}...): what they use is counted with the processes outside containers"
    fi
    for dir in "$CGROUP_DIR"/*/; do
        if [[ -f ${dir}memory.current ]]; then tops+=("${dir%/}"); fi
    done
    # inside a container, /sys/fs/cgroup is its own cgroup, with nothing of the host's below it
    [[ ${#tops[@]} -gt 0 ]] || return 1

    for ((sample = 0; sample <= seconds; sample++)); do
        if [[ $sample -gt 0 ]]; then sleep 1; fi
        top_total=0
        for dir in "${tops[@]}"; do
            used=$(cgroup_used_bytes "$dir") || used=0
            top_total=$((top_total + used))
        done
        container_total=0
        for i in "${!dirs[@]}"; do
            used=$(cgroup_used_bytes "${dirs[i]}") || used=0
            container_total=$((container_total + used))
            if [[ $used -gt ${peaks[i]} ]]; then peaks[i]=$used; fi
        done
        rest=$((top_total - container_total))
        if [[ $rest -gt $rest_peak ]]; then rest_peak=$rest; fi
    done

    MEASURED_BYTES=$rest_peak
    BREAKDOWN="$rest_peak - (processes outside containers)"
    for i in "${!dirs[@]}"; do
        MEASURED_BYTES=$((MEASURED_BYTES + peaks[i]))
        BREAKDOWN+=$'\n'"${peaks[i]} ${marks[i]} ${names[i]}"
    done
    BREAKDOWN=$(sort -rn <<< "$BREAKDOWN")
}

# hand_set_arc_max PLAN_BYTES FORCE prints the boot-time zfs_arc_max in MODPROBE_DIR that --apply
# keeps: one that differs from the plan, unless FORCE is true or ZFS_ARC_MAX_GB is set (then the
# plan is that explicit choice).  Prints nothing when the plan may replace it.
hand_set_arc_max() {
    local boot
    boot=$(pg_modprobe_zfs_arc_max "$MODPROBE_DIR")
    if [[ -n $boot && $boot != "$1" && $2 == false && -z $ARC_OVERRIDE ]]; then
        echo "$boot"
    fi
}

# update_initramfs_for_zfs: an initramfs that loads the zfs module carries its own copy of
# $MODPROBE_DIR, which is the one the module gets at boot
update_initramfs_for_zfs() {
    local initrd
    initrd="${ROOT%/}/boot/initrd.img-$(uname -r)"
    if command -v lsinitramfs > /dev/null && [[ -f $initrd ]] && lsinitramfs "$initrd" 2> /dev/null | grep -q '/zfs\.ko'; then
        print_info "$initrd loads the zfs module: updating its copy of $MODPROBE_DIR"
        if update-initramfs -u > /dev/null; then
            print_success "Updated $initrd"
        else
            print_error "update-initramfs -u failed: the zfs module may get the old zfs_arc_max at boot"
            return 1
        fi
    else
        print_info "The zfs module is not in $initrd: it reads $MODPROBE_DIR when it loads at boot"
    fi
}

# persist_arc_max ARC_MAX_BYTES: make ARC_MAX_BYTES the zfs_arc_max the zfs module gets at boot
persist_arc_max() {
    local changed line
    if [[ $(pg_modprobe_zfs_arc_max "$MODPROBE_DIR") == "$1" ]]; then
        print_success "At boot: zfs_arc_max=$1 in $MODPROBE_DIR already (no change needed)"
        return 0
    fi
    changed=$(pg_modprobe_set_zfs_arc_max "$MODPROBE_DIR" "$1" "$MODPROBE_FILE")
    if [[ -z $changed ]]; then
        print_success "Wrote $MODPROBE_DIR/$MODPROBE_FILE: options zfs zfs_arc_max=$1"
    else
        while read -r line; do
            print_success "${line%: *}: zfs_arc_max changed from ${line##*: } to $1"
        done <<< "$changed"
    fi
    update_initramfs_for_zfs
}

# report_boot_arc_max ARC_MAX_BYTES: warn when the zfs_arc_max the zfs module gets at the next boot
# ($MODPROBE_DIR, or ZFS's default when nothing there sets it) is larger than ARC_MAX_BYTES
report_boot_arc_max() {
    local boot boot_source
    boot=$(pg_modprobe_zfs_arc_max "$MODPROBE_DIR")
    if [[ -n $boot && $boot != 0 ]]; then
        boot_source="zfs_arc_max=$boot in $MODPROBE_DIR"
    else
        boot=$(pg_zfs_arc_default_bytes "$ROOT")
        boot_source="ZFS's default of $boot (no nonzero zfs_arc_max in $MODPROBE_DIR)"
    fi
    if [[ $boot -le $1 ]]; then
        print_success "At boot: $boot_source, within $1"
    else
        print_warning "At boot: $boot_source, more than $1; the ARC may grow past it after a reboot"
        print_warning "To make $1 the boot-time limit: sudo $0 --apply --persist"
    fi
}

# apply_arc_max ARC_MAX_BYTES PERSIST FORCE OVERCOMMIT: set zfs_arc_max now (and at boot with
# PERSIST), or keep a hand-set boot-time value and the runtime limit as they are.  OVERCOMMIT is
# pg_overcommit_check's line when the boot-time value overcommits RAM with HAF_OTHER_SERVICES_GB or
# the fixed safety margin as other services (empty when it fits): a hand-set value that does is
# refused (returns 1, nothing changed).
apply_arc_max() {
    local plan=$1 persist=$2 force=$3 overcommit=$4 kept live file
    live=$(cat "$ZFS_ARC_MAX_PARAM")
    kept=$(hand_set_arc_max "$plan" "$force")
    if [[ -n $kept ]]; then
        file=$(pg_modprobe_zfs_arc_max_file "$MODPROBE_DIR")
        if [[ -n $overcommit ]]; then
            print_error "Refusing to keep zfs_arc_max=$kept ($(gb "$kept")) in $file, which differs from the plan's $plan ($(gb "$plan")): $overcommit"
            print_error "To replace it with the plan's $plan, now and at boot: sudo $0 --apply --persist --force; to make another value the plan: ZFS_ARC_MAX_GB in .env"
            return 1
        fi
        print_warning "Kept zfs_arc_max=$kept ($(gb "$kept")) in $file, which differs from the plan's $plan ($(gb "$plan")): taken as set by hand"
        print_warning "The runtime zfs_arc_max stays at $live too.  To replace both with the plan: --force; to make a value the plan: ZFS_ARC_MAX_GB in .env"
        if [[ $live -eq 0 || $live -gt $kept ]]; then
            print_warning "The runtime zfs_arc_max ($live) is larger than the kept boot-time $kept"
        fi
        return 0
    fi
    if [[ $live == "$plan" ]]; then
        print_success "zfs_arc_max is already $plan (no change needed)"
    elif echo "$plan" > "$ZFS_ARC_MAX_PARAM"; then
        print_success "zfs_arc_max: changed from $live to $plan (the ARC shrinks to it gradually)"
    else
        print_error "Failed to set zfs_arc_max"
        return 1
    fi
    if [[ $persist == true ]]; then
        persist_arc_max "$plan"
    else
        report_boot_arc_max "$plan"
    fi
}

# haf_running HAF_PROJECT: whether the compose project's haf service (PostgreSQL) has a running
# container
haf_running() {
    command -v docker > /dev/null || return 1
    [[ -n $(docker ps -q --filter "label=com.docker.compose.project=$1" --filter label=com.docker.compose.service=haf 2> /dev/null) ]]
}

# apply_huge_pages TARGET CURRENT PERSIST HAF_PROJECT OTHER_SERVICES_GB: reserve the plan's huge pages
# (reserve_huge_pages.sh).  While haf runs, its PostgreSQL holds its shared segment in the pages
# it started with, so a changed reservation is left for when haf is stopped.
apply_huge_pages() {
    local args=()
    if [[ $3 == true ]]; then args+=(--persist); fi
    if [[ $1 != "$2" ]] && haf_running "$4"; then
        print_warning "Huge pages: vm.nr_hugepages is $2, the plan $1, but haf is running: not changed"
        print_warning "To reserve them: docker compose stop haf && sudo $0 --apply ${args[*]} && docker compose start haf"
        return 0
    fi
    # its overcommit check counts the other services this plan does
    if ! HAF_OTHER_SERVICES_GB=$5 "$SCRIPT_DIR/reserve_huge_pages.sh" "${args[@]}"; then
        print_error "The huge pages were not reserved (see above); zfs_arc_max is handled as reported before"
        return 1
    fi
}

# row NAME VALUE SOURCE prints one line of the plan
row() {
    printf '  %-22s %9s  %s\n' "$1" "$2" "$3"
}

main() {
    local apply=false persist=false force=false arc_only=false seconds=10
    while [[ $# -gt 0 ]]; do
        case $1 in
            --apply) apply=true ;;
            --persist) persist=true ;;
            --force) force=true ;;
            --arc-only) arc_only=true ;;
            --sample-seconds)
                seconds=${2:-}
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Run '$0 --help' for usage information"
                exit 1
                ;;
        esac
        shift
    done
    if [[ ! $seconds =~ ^[0-9]+$ ]]; then
        print_error "--sample-seconds needs a whole number of seconds"
        exit 1
    fi
    if [[ $apply == false && ($persist == true || $force == true || $arc_only == true) ]]; then
        print_error "--persist, --force and --arc-only need --apply"
        exit 1
    fi
    if [[ $apply == true && $ROOT == / && $EUID -ne 0 ]]; then
        print_error "--apply must be run as root"
        echo "Please run with: sudo $0 $*"
        exit 1
    fi

    local work
    work=$(mktemp -d)
    # shellcheck disable=SC2064 # expand work now
    trap "rm -rf '$work'" EXIT

    local env_file="$SCRIPT_DIR/.env" total_kb ram_gb sb_override sb sb_source segment
    total_kb=$(pg_memory_total_kb "$ROOT")
    ram_gb=$((total_kb / 1048576))
    sb_override=$(pg_shared_buffers_override "$env_file")
    sb=$(pg_shared_buffers_gb "$total_kb" "$sb_override" 2> "$work/source") || { cat "$work/source" >&2; exit 1; }
    sb_source=$(sed -E 's/^shared_buffers = [0-9]+GB(: |, )//' "$work/source")
    if [[ -n $sb_override ]]; then sb_source="override: $sb_source"; else sb_source="formula: $sb_source"; fi
    segment=$(pg_shared_segment_gb "$sb")

    local other_override haf_project measured other other_source
    other_override=$(pg_setting HAF_OTHER_SERVICES_GB "$env_file")
    ARC_OVERRIDE=$(pg_setting ZFS_ARC_MAX_GB "$env_file")
    haf_project=$(pg_setting PROJECT_NAME "$env_file")
    haf_project=${haf_project:-haf}
    measured=
    if [[ -z $other_override ]] && [[ $seconds -gt 0 ]]; then
        print_info "Measuring the memory of other services over ${seconds}s..."
    fi
    if measure_other_services "$seconds" "$haf_project"; then
        measured=$MEASURED_BYTES
    fi
    if [[ -n $other_override ]]; then
        other=$other_override
        other_source="override: HAF_OTHER_SERVICES_GB"
        if [[ -n $measured ]]; then other_source+=" (measured $(gb "$measured"), not used)"; fi
    elif [[ -n $measured ]]; then
        other=$(pg_other_services_gb $((measured / 1024)))
        other_source="measurement: $(gb "$measured") peak over ${seconds}s + ${PG_OTHER_SERVICES_HEADROOM_PERCENT}%, at least ${PG_OTHER_SERVICES_MIN_GB}GB"
    else
        other=
        other_source="not measured (no cgroup v2 hierarchy at $CGROUP_DIR): the fixed safety margin; set HAF_OTHER_SERVICES_GB"
    fi

    local arc arc_source arc_bytes huge_page_kb huge_pages ecs
    arc=$(pg_zfs_arc_limit_gb "$total_kb" "$sb" "$other" "$ARC_OVERRIDE" 2> "$work/source") || { cat "$work/source" >&2; exit 1; }
    arc_source=$(sed -E 's/^ZFS ARC limit = [0-9]+GB(: |, )//' "$work/source")
    if [[ -n $ARC_OVERRIDE ]]; then
        arc_source="override: ZFS_ARC_MAX_GB (the formula gives $(pg_zfs_arc_max_gb "$total_kb" "$sb" "$other")GB)"
    else
        arc_source="formula: $arc_source"
    fi
    arc_bytes=$((arc * GIB))
    huge_page_kb=$(pg_huge_page_size_kb "$ROOT")
    huge_pages=$(pg_huge_pages_count "$sb" "$huge_page_kb")
    ecs=$(pg_effective_cache_size_gb "$total_kb" "$sb" "$arc")

    echo "Memory plan for HAF (GB = GiB):"
    row "RAM" "${ram_gb}GB" "measurement: MemTotal, or the cgroup memory limit when lower"
    row "shared_buffers" "${sb}GB" "$sb_source"
    row "shared segment" "${segment}GB" "formula: shared_buffers + ${PG_SHARED_SEGMENT_OVERHEAD_PERCENT}%"
    row "other services" "${other:-$PG_SAFETY_MARGIN_GB}GB" "$other_source"
    row "kernel" "${PG_KERNEL_OVERHEAD_GB}GB" "fixed reserve"
    row "dirty pages" "${PG_MAX_DIRTY_GB}GB" "fixed reserve (reduce_writebacks.sh's vm.dirty_bytes)"
    row "ZFS ARC limit" "${arc}GB" "$arc_source"
    row "huge pages" "$huge_pages" "formula: the shared segment in ${huge_page_kb}kB pages"
    row "effective_cache_size" "${ecs}GB" "formula: shared_buffers + the ARC limit, at most RAM (set by the haf container)"

    # the huge pages held at boot: the plan's, or more when more are reserved
    local current_huge_pages held_huge_pages check
    current_huge_pages=$(cat "${ROOT%/}/proc/sys/vm/nr_hugepages")
    held_huge_pages=$huge_pages
    if [[ $current_huge_pages -gt $huge_pages ]]; then held_huge_pages=$current_huge_pages; fi
    if ! check=$(pg_overcommit_check "$total_kb" "$arc_bytes" "$held_huge_pages" "$huge_page_kb" "$other"); then
        print_warning "The plan overcommits RAM: $check"
    fi

    if [[ -n $measured ]]; then
        local bytes mark name
        echo
        echo "Other services, peak over ${seconds}s of memory.current minus page cache, shared memory and huge pages (* = compose project $haf_project):"
        while read -r bytes mark name; do
            if [[ $mark == - ]]; then mark=" "; fi
            printf '  %s %-50s %8s\n' "$mark" "$name" "$(gb "$bytes")"
        done <<< "$BREAKDOWN"
        printf '    %-50s %8s\n' "total" "$(gb "$measured")"
    fi

    echo
    echo "Now:"
    local zfs=false live boot boot_bytes kept overcommit='' measured_overcommit=''
    if [[ -f $ZFS_ARC_MAX_PARAM ]]; then
        zfs=true
        live=$(cat "$ZFS_ARC_MAX_PARAM")
        boot=$(pg_modprobe_zfs_arc_max "$MODPROBE_DIR")
        if [[ $live -eq 0 ]]; then
            echo "  zfs_arc_max (runtime)  0, ZFS's default of $(gb "$(pg_zfs_arc_default_bytes "$ROOT")")"
        else
            echo "  zfs_arc_max (runtime)  $live ($(gb "$live"))"
        fi
        if [[ -n $boot ]]; then
            echo "  zfs_arc_max (at boot)  $boot ($(gb "$boot")), from $MODPROBE_DIR"
        else
            echo "  zfs_arc_max (at boot)  not set in $MODPROBE_DIR: ZFS's default"
        fi
        echo "  zfs_arc_max (plan)     $arc_bytes"
        # the check the haf container makes at every start, against this plan
        echo "  $(pg_zfs_arc_check "$ROOT" "$total_kb" "$sb" "$live" "$other" "$ARC_OVERRIDE" || true)"
        boot_bytes=$(pg_zfs_arc_bytes "$ROOT" "$boot")
        if check=$(pg_overcommit_check "$total_kb" "$boot_bytes" "$held_huge_pages" "$huge_page_kb" "$other"); then
            echo "  At boot: $check"
        else
            measured_overcommit=$check
            print_warning "At boot: $check"
        fi
        # --apply's refusal of a hand-set value counts HAF_OTHER_SERVICES_GB or the fixed safety
        # margin: the measurement depends on what ran during the sample
        if ! check=$(pg_overcommit_check "$total_kb" "$boot_bytes" "$held_huge_pages" "$huge_page_kb" "$other_override"); then
            overcommit=$check
        fi
        kept=$(hand_set_arc_max "$arc_bytes" "$force")
        if [[ $apply == false && -n $kept ]]; then
            if [[ -n $overcommit ]]; then
                echo "  --apply refuses to keep the boot-time $kept, which overcommits RAM: $overcommit (--force replaces it with the plan's)"
            elif [[ -n $measured_overcommit ]]; then
                echo "  --apply keeps the boot-time $kept, taken as set by hand, and the runtime limit (--force replaces them): it overcommits RAM only with the measured other services, not with the ${PG_SAFETY_MARGIN_GB}GB safety margin"
            else
                echo "  --apply keeps the boot-time $kept, taken as set by hand, and the runtime limit (--force replaces them)"
            fi
        elif [[ $apply == false && -n $measured_overcommit ]]; then
            echo "  --apply --persist makes the plan's $arc_bytes the boot-time limit"
        fi
    else
        echo "  ZFS module not loaded: there is no ARC limit to set"
    fi
    echo "  vm.nr_hugepages        $current_huge_pages (plan: $huge_pages)"
    if [[ $current_huge_pages -gt $huge_pages ]]; then
        print_warning "More huge pages are reserved than the shared segment needs; the plan does not count the excess"
    fi

    if [[ $apply == false ]]; then
        echo
        echo "Nothing was changed.  To apply the ARC limit and huge pages now and at every boot: sudo $0 --apply --persist"
        return 0
    fi

    echo
    if [[ $zfs == true ]]; then
        apply_arc_max "$arc_bytes" "$persist" "$force" "$overcommit"
    fi
    if [[ $arc_only == true ]]; then
        print_info "Huge pages left as they are (--arc-only)"
    else
        apply_huge_pages "$huge_pages" "$current_huge_pages" "$persist" "$haf_project" "$other"
    fi
}

main "$@"
