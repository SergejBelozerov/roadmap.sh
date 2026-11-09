#!/usr/bin/env bash
# Report server-wide resource usage and a snapshot of visible processes.
set -euo pipefail
export LC_ALL=C

printf 'CPU usage (1-second sample)\n'
{
    head -n 1 /proc/stat
    sleep 1
    head -n 1 /proc/stat
} | awk '
    $1 == "cpu" {
        samples++
        for (i = 2; i <= 9; i++) {
            if (samples == 1) {
                first[i] = $i
            } else {
                delta = $i - first[i]
                # Linux can report a decrease in iowait.
                if (delta < 0) delta = 0
                total += delta
                if (i == 5 || i == 6) idle += delta
            }
        }
    }
    END {
        if (samples != 2 || total <= 0) {
            print "Could not calculate CPU usage." > "/dev/stderr"
            exit 1
        }
        printf "  %.1f%% busy\n", 100 * (total - idle) / total
    }
'

printf '\nRAM usage\n'
awk '
    { memory[$1] = $2 }
    END {
        total = memory["MemTotal:"]
        if (total <= 0) {
            print "Could not read total RAM." > "/dev/stderr"
            exit 1
        }
        # Estimate available RAM on kernels predating MemAvailable.
        if ("MemAvailable:" in memory) {
            available = memory["MemAvailable:"]
        } else {
            available = memory["MemFree:"] + memory["Buffers:"] + memory["Cached:"]
            available += memory["SReclaimable:"] - memory["Shmem:"]
        }
        if (available < 0) available = 0
        if (available > total) available = total
        used = total - available
        printf "  Total      %10.1f MiB\n", total / 1024
        printf "  Used       %10.1f MiB (%5.1f%%)\n", used / 1024, 100 * used / total
        printf "  Available  %10.1f MiB (%5.1f%%)\n", available / 1024, 100 * available / total
    }
' /proc/meminfo

printf '\nFilesystem usage (1 KiB blocks)\n'
df -Pk | awk '
    BEGIN {
        printf "%-24s %12s %12s %12s %7s %7s  %s\n",
               "Filesystem", "Total", "Used", "Available", "Used%", "Free%", "Mounted on"
    }
    NR > 1 && match($0, /[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+-?[0-9]+[[:space:]]+(-?[0-9]+%|-)[[:space:]]+/) {
        device = substr($0, 1, RSTART - 1)
        mount = substr($0, RSTART + RLENGTH)
        counts = substr($0, RSTART, RLENGTH)
        sub(/^[[:space:]]+/, "", counts)
        split(counts, blocks, /[[:space:]]+/)
        used = blocks[2]
        available = blocks[3]
        # Use the same capacity basis as df, excluding reserved blocks.
        capacity = used + available
        used_pct = capacity > 0 ? sprintf("%.1f%%", 100 * used / capacity) : "-"
        free_pct = capacity > 0 ? sprintf("%.1f%%", 100 * available / capacity) : "-"
        printf "%-24s %12s %12s %12s %7s %7s  %s\n",
               device, blocks[1], used, available, used_pct, free_pct, mount
    }
'

# Keep the command last so spaces in a process name do not affect sorting.
processes=$(ps -e -o pid= -o pcpu= -o pmem= -o rss= -o comm=)
print_top_processes() {
    local sort_key=$1
    printf '%7s %7s %7s %10s  %s\n' PID '%CPU' '%MEM' 'RSS (KiB)' COMMAND
    printf '%s\n' "$processes" |
        sort -k"$sort_key","$sort_key"nr -k1,1n |
        awk 'NR <= 5 && NF >= 5 {
            command = $0
            sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", command)
            printf "%7s %7s %7s %10s  %s\n", $1, $2, $3, $4, command
        }'
}

printf '\nTop five processes by CPU (lifetime average)\n'
print_top_processes 2
printf '\nTop five processes by memory\n'
print_top_processes 4
