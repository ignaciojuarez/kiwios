#!/bin/sh
set -eu
export LC_ALL=C

mode=${1:-}

case "$mode" in
    cpu)
        idle=$(/usr/bin/top -l 1 -n 0 2>/dev/null | /usr/bin/awk -F'[,:% ]+' '
            /^CPU usage:/ { for (i = 1; i <= NF; i++) if ($i == "idle") { print $(i-1); exit } }
        ')
        if [ -z "$idle" ]; then
            printf '%s\n' '{"t":"error","msg":"macOS did not report CPU usage"}'
            exit 2
        fi
        used=$(/usr/bin/awk -v idle="$idle" 'BEGIN { printf "%.1f", 100 - idle }')
        printf '{"t":"ok","msg":"CPU usage is %s%%","state":{"value":%s,"unit":"%%","detail":"Current total utilization"}}\n' "$used" "$used"
        ;;
    memory)
        free=$(/usr/bin/memory_pressure -Q 2>/dev/null | /usr/bin/awk -F': ' '
            /free percentage:/ { gsub(/%/, "", $2); print $2; exit }
        ')
        case "$free" in
            ''|*[!0-9.]*)
                printf '%s\n' '{"t":"error","msg":"macOS did not report memory pressure"}'
                exit 2
                ;;
        esac
        used=$(/usr/bin/awk -v free="$free" 'BEGIN { printf "%.0f", 100 - free }')
        printf '{"t":"ok","msg":"Memory usage is %s%%","state":{"value":%s,"unit":"%%","detail":"Derived from system memory pressure"}}\n' "$used" "$used"
        ;;
    thermals)
        status=$(/usr/bin/pmset -g therm 2>&1 | /usr/bin/awk '
            BEGIN { status = "Nominal" }
            !/^Note: No / { status = "Elevated" }
            END { print status }
        ')
        if [ "$status" = "Nominal" ]; then severity=ok; else severity=warn; fi
        printf '{"t":"%s","msg":"Thermal pressure is %s","state":{"value":"%s","detail":"Reported by macOS power management"}}\n' "$severity" "$status" "$status"
        ;;
    drive-temperatures)
        smartctl=$(command -v smartctl || true)
        if [ -z "$smartctl" ]; then
            printf '%s\n' '{"t":"error","msg":"smartmontools is missing; install the required package from Plugins"}'
            exit 2
        fi
        scan=$($smartctl --scan 2>/dev/null || true)
        disk_list=$(/usr/sbin/diskutil list -plist 2>/dev/null || true)
        disk_count=$(printf '%s' "$disk_list" | /usr/bin/plutil -extract AllDisksAndPartitions raw -o - - 2>/dev/null || true)
        case "$disk_count" in ''|*[!0-9]*) disk_count=0 ;; esac
        volume_title() {
            target=$1
            disk_index=0
            while [ "$disk_index" -lt "$disk_count" ]; do
                disk_key="AllDisksAndPartitions.$disk_index"
                disk_id=$(printf '%s' "$disk_list" | /usr/bin/plutil -extract "$disk_key.DeviceIdentifier" raw -o - - 2>/dev/null || true)
                store=$(printf '%s' "$disk_list" | /usr/bin/plutil -extract "$disk_key.APFSPhysicalStores.0.DeviceIdentifier" raw -o - - 2>/dev/null || true)
                collection=
                case "$store" in "$target"|"$target"s[0-9]*) collection=APFSVolumes ;; esac
                [ "$disk_id" = "$target" ] && collection=Partitions
                if [ -n "$collection" ]; then
                    volume_count=$(printf '%s' "$disk_list" | /usr/bin/plutil -extract "$disk_key.$collection" raw -o - - 2>/dev/null || true)
                    case "$volume_count" in ''|*[!0-9]*) volume_count=0 ;; esac
                    volume_index=0
                    while [ "$volume_index" -lt "$volume_count" ]; do
                        volume_key="$disk_key.$collection.$volume_index"
                        mountpoint=$(printf '%s' "$disk_list" | /usr/bin/plutil -extract "$volume_key.MountPoint" raw -o - - 2>/dev/null || true)
                        case "$mountpoint" in
                            /|/Volumes/*)
                                printf '%s' "$disk_list" | /usr/bin/plutil -extract "$volume_key.VolumeName" raw -o - - 2>/dev/null || true
                                return
                                ;;
                        esac
                        volume_index=$((volume_index + 1))
                    done
                fi
                disk_index=$((disk_index + 1))
            done
        }
        rows=
        separator=
        count=0
        while read -r device option type rest; do
            [ "$option" = "-d" ] || continue
            case "$type" in
                ''|*[!A-Za-z0-9,+._-]*) continue ;;
            esac
            case "$device" in
                /dev/disk[0-9]*|IOService:/*) ;;
                *) continue ;;
            esac
            if [ "$type" = "nvme" ]; then
                data=$($smartctl --attributes --json --quietmode=noserial --device="$type" "$device" 2>/dev/null || true)
            else
                data=$($smartctl --attributes --json --quietmode=noserial --nocheck=standby,0 --device="$type" "$device" 2>/dev/null || true)
            fi
            temperature=$(printf '%s' "$data" | /usr/bin/plutil -extract temperature.current raw -o - - 2>/dev/null || true)
            case "$temperature" in
                ''|*[!0-9.-]*) continue ;;
            esac
            bsd=${device##*/}
            case "$device" in
                IOService:/*)
                    bsd=$(/usr/sbin/ioreg -r -n "$bsd" -l -w0 2>/dev/null | /usr/bin/awk -F'"' '/"BSD Name"/ { print $4; exit }')
                    ;;
            esac
            case "$bsd" in disk[0-9]*) ;; *) bsd= ;; esac
            model=$(printf '%s' "$data" | /usr/bin/plutil -extract model_name raw -o - - 2>/dev/null || true)
            if [ -n "$bsd" ]; then
                friendly=$(volume_title "$bsd")
                [ -n "$friendly" ] && model=$friendly
                device="/dev/$bsd"
            fi
            if [ -z "$model" ]; then
                if [ "$type" = "nvme" ]; then model="NVMe drive"; else model="$type drive"; fi
            fi
            model=$(printf '%s' "$model" | /usr/bin/awk '{ gsub(/["\\]/, "?"); gsub(/[[:cntrl:]]/, " "); printf "%.120s", $0 }')
            case "$device" in IOService:/*) device=${device##*/} ;; esac
            device=$(printf '%s' "$device" | /usr/bin/awk '{ gsub(/["\\]/, "?"); printf "%s", $0 }')
            count=$((count + 1))
            row=$(printf '{"id":"drive-%s","model":"%s","device":"%s","temperature-c":%s}' "$count" "$model" "$device" "$temperature")
            rows="${rows}${separator}${row}"
            separator=,
        done <<EOF
$scan
EOF
        if [ -z "$rows" ]; then
            severity=warn
            message="No readable drive temperatures were reported"
        else
            severity=ok
            message="Drive temperatures read successfully"
        fi
        printf '{"t":"%s","msg":"%s","state":{"columns":[{"id":"model","label":"Drive"},{"id":"device","label":"Device"},{"id":"temperature-c","label":"Temperature °C"}],"rows":[%s]}}\n' "$severity" "$message" "$rows"
        ;;
    *)
        printf '%s\n' '{"t":"error","msg":"Unknown monitor check"}'
        exit 2
        ;;
esac
