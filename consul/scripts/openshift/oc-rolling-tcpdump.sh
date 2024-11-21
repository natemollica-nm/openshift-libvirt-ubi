#!/bin/sh

# Capture packets until a given string is seen in a log file using tcpdump
# Usage: script --interface INTERFACE --file-count FILE_COUNT --file-size FILE_SIZE --dump-dir DUMP_DIR --dump-file DUMP_FILE --filter TCPDUMP_FILTER --log-file LOG_FILE --trigger-string TCPDUMP_TRIGGER_STRING

# Function to display usage
usage() {
    echo "Description:"
    echo "  This script captures network traffic using tcpdump on a specified interface, with a rolling capture"
    echo "  (ring buffer) that automatically stops when a given string is found in a monitored log file."
    echo
    echo "Usage:"
    echo "  $(basename "$0" .sh) --interface INTERFACE --file-count FILE_COUNT --file-size FILE_SIZE --dump-dir DUMP_DIR --dump-file DUMP_FILE --filter TCPDUMP_FILTER --log-file LOG_FILE --trigger-string TCPDUMP_TRIGGER_STRING"
    echo
    echo "  --interface              Name of the device used for capturing packets (e.g., eth0)"
    echo "  --file-count             Number of files in the capture ring (e.g., 5)"
    echo "  --file-size              Size of each file in MB (e.g., 100)"
    echo "  --dump-dir               Directory to save the capture files (e.g., /tmp/tcpdump)"
    echo "  --dump-file              Base name of the capture files (e.g., capture.pcap)"
    echo "  --filter                 tcpdump filter string (can be empty, e.g., 'port 80')"
    echo "  --log-file               Log file to monitor for the trigger (e.g., /var/log/app.log)"
    echo "  --trigger-string         String in log file to trigger tcpdump termination (e.g., 'Error found')"
    echo
    echo "Example:"
    echo "  $(basename "$0" .sh) --interface eth0 --file-count 5 --file-size 250 --dump-dir /tmp --dump-file dump.pcap --filter 'port 80' --log-file /var/log/messages --trigger-string 'TLS_error:'"
    echo
    exit 1
}


# Parse the command-line options
while [ "$#" -gt 0 ]; do
    case "$1" in
        --interface)
            DUMP_INTERFACE="$2"
            shift 2
            ;;
        --file-count)
            DUMP_NUM="$2"
            shift 2
            ;;
        --file-size)
            DUMP_SIZE="$2"
            shift 2
            ;;
        --dump-dir)
            DUMP_DIR="$2"
            shift 2
            ;;
        --dump-file)
            DUMP_NAME="$2"
            shift 2
            ;;
        --filter)
            DUMP_TCPDUMP_FILTER="$2"
            shift 2
            ;;
        --log-file)
            LOG_FILE="$2"
            shift 2
            ;;
        --trigger-string)
            LOG_STRING="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check if all necessary variables are set
[ -z "$DUMP_INTERFACE" ] || [ -z "$DUMP_NUM" ] || [ -z "$DUMP_SIZE" ] || [ -z "$DUMP_DIR" ] || [ -z "$DUMP_NAME" ] || [ -z "$LOG_FILE" ] || [ -z "$LOG_STRING" ] && usage

# Time to wait after LOG_STRING is found until the dump is stopped (in seconds):
TIME_AFTER=60

# Create the dump directory, set group write permission, and change the group to 'tcpdump'
mkdir -p "$DUMP_DIR"
chmod g+w "$DUMP_DIR"
chgrp tcpdump "$DUMP_DIR"

# Start tcpdump with a ring buffer (-W) and file size limit (-C), capturing to specified interface and filter
/usr/sbin/tcpdump -s 0 -w "$DUMP_DIR/$DUMP_NAME" -W "$DUMP_NUM" -C "$DUMP_SIZE" -i "$DUMP_INTERFACE" "$DUMP_TCPDUMP_FILTER" &
DUMP_PID=$!  # Store the process ID of tcpdump

# Monitor the log file for the trigger string, and stop tcpdump when it's found
tail -f "$LOG_FILE" | awk "/$LOG_STRING/{system(\"sleep $TIME_AFTER; kill $DUMP_PID\")}" &

# Ensure the script is not blocked by terminal sessions
disown -h "$DUMP_PID"

exit 0
