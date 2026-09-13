#!/bin/sh
set -eu

mode=${1:-root}
warning_used_percent=90

if [ -n "${KIWIOS_CONFIG_FILE:-}" ] && [ -f "$KIWIOS_CONFIG_FILE" ]; then
    configured=$(/usr/bin/plutil -extract warning_used_percent raw -o - "$KIWIOS_CONFIG_FILE" 2>/dev/null || true)
    case "$configured" in
        80|85|90|95) warning_used_percent=$configured ;;
    esac
fi

if [ "$mode" = "root" ]; then
    if ! capacity=$(/bin/df -Pk / 2>/dev/null); then
        printf '{"t":"error","msg":"Could not read system volume capacity; verify that the volume is mounted"}\n'
        exit 2
    fi

    fields=$(printf '%s\n' "$capacity" | /usr/bin/awk 'NR == 2 { used = $5; sub(/%$/, "", used); print $4, used }')
    set -- $fields
    if [ "$#" -ne 2 ]; then
        printf '{"t":"error","msg":"System volume capacity returned an unexpected result"}\n'
        exit 2
    fi

    free_kb=$1
    used_percent=$2
    case "$free_kb:$used_percent" in
        *[!0-9:]*|:*)
            printf '{"t":"error","msg":"System volume capacity returned invalid values"}\n'
            exit 2
            ;;
    esac

    free_gb=$(/usr/bin/awk -v value="$free_kb" 'BEGIN { printf "%.1f", value / 1048576 }')
    if [ "$used_percent" -ge "$warning_used_percent" ]; then
        printf '{"t":"warn","msg":"System volume is %s%% used; free space when practical","state":{"value":"%s","unit":"GB free","detail":"%s%% used; warning at %s%%"}}\n' "$used_percent" "$free_gb" "$used_percent" "$warning_used_percent"
    else
        printf '{"t":"ok","msg":"System volume has %s GB free","state":{"value":"%s","unit":"GB free","detail":"%s%% used; warning at %s%%"}}\n' "$free_gb" "$free_gb" "$used_percent" "$warning_used_percent"
    fi
    exit 0
fi

if [ "$mode" != "table" ]; then
    printf '{"t":"error","msg":"Unknown volume-health mode"}\n'
    exit 2
fi

if ! capacity=$(/bin/df -Pk 2>/dev/null); then
    printf '{"t":"error","msg":"Could not read mounted filesystem capacity"}\n'
    exit 2
fi

printf '%s\n' "$capacity" | /usr/bin/awk -v warning="$warning_used_percent" '
function json(value, output, i, character) {
    output = ""
    for (i = 1; i <= length(value); i++) {
        character = substr(value, i, 1)
        if (character == "\\") output = output "\\\\"
        else if (character == "\"") output = output "\\\""
        else if (character == "\t") output = output "\\t"
        else if (character == "\r") output = output "\\r"
        else if (character ~ /[[:cntrl:]]/) output = output "?"
        else output = output character
    }
    return output
}
NR > 1 {
    capacity_field = 0
    for (i = 4; i <= NF; i++) {
        if ($i ~ /^[0-9]+%$/ && $(i - 1) ~ /^[0-9]+$/ && $(i - 2) ~ /^[0-9]+$/ && $(i - 3) ~ /^[0-9]+$/) {
            capacity_field = i
            break
        }
    }
    if (capacity_field == 0 || capacity_field == NF) {
        invalid++
        next
    }
    used = $capacity_field
    sub(/%$/, "", used)
    used += 0
    total_kb = $(capacity_field - 3)
    free_kb = $(capacity_field - 1)
    mount = $(capacity_field + 1)
    for (i = capacity_field + 2; i <= NF; i++) mount = mount " " $i
    # User storage mounts live at / or /Volumes. Ignore devfs, auto_home,
    # simulator/Cryptex images, and other synthetic system filesystems.
    if (mount != "/" && mount !~ /^\/Volumes\//) next
    seen++
    if (count >= 100) next
    if (length(mount) > 64) mount = substr(mount, 1, 61) "..."
    status = used >= warning ? "Needs attention" : "OK"
    if (used >= warning) warnings++
    count++
    rows[count] = sprintf("{\"id\":\"volume-%d\",\"mount\":\"%s\",\"total-gb\":%.1f,\"free-gb\":%.1f,\"used-percent\":%d,\"status\":\"%s\"}", count, json(mount), total_kb / 1048576, free_kb / 1048576, used, status)
}
END {
    if (invalid > 0 || count == 0) {
        print "{\"t\":\"error\",\"msg\":\"Mounted filesystem capacity returned an unexpected result\"}"
        exit 2
    }
    severity = warnings > 0 ? "warn" : "ok"
    if (warnings > 0)
        message = sprintf("%d of %d shown filesystems need attention at %d%% used", warnings, count, warning)
    else if (seen > count)
        message = sprintf("Showing the first %d of %d mounted filesystems; none shown need attention", count, seen)
    else
        message = sprintf("All %d mounted filesystems are below %d%% used", count, warning)
    printf "{\"t\":\"%s\",\"msg\":\"%s\",\"state\":{\"columns\":[{\"id\":\"mount\",\"label\":\"Mount\"},{\"id\":\"total-gb\",\"label\":\"Total GB\"},{\"id\":\"free-gb\",\"label\":\"Free GB\"},{\"id\":\"used-percent\",\"label\":\"Used %%\"},{\"id\":\"status\",\"label\":\"Status\"}],\"rows\":[", severity, message
    for (i = 1; i <= count; i++) printf "%s%s", (i == 1 ? "" : ","), rows[i]
    print "]}}"
}'
