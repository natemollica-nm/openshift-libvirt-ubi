#!/bin/sh

# pcap_watch.sh
# - capture packets until a given string is seen in a given logfile
#
# Usage:
#   pcap_watch.sh DEVICE NUMBER-OF-FILES SIZE-OF-FILES DUMP-DIRECTORY DUMP-FILE-NAME FILTER LOG-FILE-NAME TRIGGER-STRING
#
#
# Rolling Capture: https://access.redhat.com/solutions/8787
#  Sometimes it is necessary for a capture to run for an extended period of time. In those case it is not a good idea to
#  allow the capture file to grow indefinitely. Still check that enough disk space is available for the projected rolling
#  capture. The arguments -w path -W n -C m will direct tcpdump to create "n" files of approximately "m" megabytes.
#
#  The files will have the names path0 thru path(n-1). When the size of pathX exceeds m megabytes path(mod (X+1, n) is
#  written or rewritten. Since tcpdump is by default run under the tcpdump user ID it is necessary that this user ID has
#  the necessary permissions to create the pathX files. The "-Z userID" can be used to change the ID that runs the tcpdump
#  command.
#
#  It is important that the combination of file size and the number of files versus the rate at which the files are cycled
#  give you enough time to recognize that the event you are trying to capture has occurred and stop the capture before the
#  file with the event is overwritten. The following script can help with that. It can be used to start tcpdump and then stop
#  it when a trigger message is seen in a log file.
#
#  Example: ./pcap_watch.sh eth0 5 250 /tmp dumpfilename.pcap "" /var/log/messages "Time has been changed"

if [ $# -ne 8 ]; then
  echo "Usage:"
  echo pcapLogwatch.sh DEVICE NUMBER-OF-FILES SIZE-OF-FILES \
    DUMP-DIRECTORY DUMP-FILE-NAME FILTER LOG-FILE-NAME \
    TRIGGER-STRING
  echo Where:
  echo "  DEVICE           name of the device used for capturing packets"
  echo "  NUMBER-OF-FILES number of files in the capture ring"
  echo "  SIZE-OF-FILES   size of each file (approximately)"
  echo "  DUMP-DIRECTORY  directory to put the files"
  echo "  DUMP-FILE-NAME  base name of the capture files"
  echo "  FILTER          tcpdump filter string, may be \"\""
  echo "  LOG-FILE-NAME   name of log file containing the trigger"
  echo " TRIGGER-STRING   when this string is seen tcpdump will be stopped"
  exit
fi

# After setting the parameters below, this script will run
# a rolling packet capture until the string in $LOG_STRING
# is found in $LOG_FILE. Set the optional $DUMP_FILTER with
# whatever libpcap filter as needed.

# Interface to capture on:
DUMP_INTERFACE="$1"

# Number of capture files:
DUMP_NUM="$2"

# Size of capture files:
DUMP_SIZE="$3"

# Directory to save file to:
DUMP_DIR="$4"

# Filename to capture to:
DUMP_NAME="$5"

# libpcap Dump filter:
DUMP_FILTER="$6"

# Log file to monitor:
LOG_FILE="$7"

# String to match in LOG_FILE:
LOG_STRING="$8"

# Time to wait after LOG_STRING found
# until the dump is stopped (in seconds):
TIME_AFTER=1

mkdir -p "$DUMP_DIR"
chmod g+w "$DUMP_DIR"
chgrp tcpdump "$DUMP_DIR"

# -s: Option for snaplen. It tells tcpdump the amount of information (bytes) it should capture for each packet.
#     Tcpdump from RHEL 6 and newer, captures 65535 bytes of data from each packet by default. On previous versions
#     (RHEL 5 and older) tcpdumpcaptures 68 bytes by default. 68 bytes is often not sufficient to perform any sort of
#     troubleshooting or diagnosis. Please refer to the tcpdump(8) man page and search for "snaplen" if you are unsure
#     what the default is on your system.
#
#     If you want to capture all the data from network packets, run the tcpdump command with the "-s 0" option as
#     shown below. In the situation where network traffic is huge or there is need for capturing traffic for a
#     prolonged period of time, this might not produce the best result.
/usr/sbin/tcpdump -s 0 -w "$DUMP_DIR/$DUMP_NAME" -W "$DUMP_NUM" -C "$DUMP_SIZE" -i "$DUMP_INTERFACE" "$DUMP_FILTER" &
DUMP_PID=$!

tail --follow=name --pid=$DUMP_PID -n 0 "$LOG_FILE" | awk "/$LOG_STRING/{system(\"sleep $TIME_AFTER; kill $DUMP_PID\")}" &
disown -a -h
exit 0
# END pcapLogwatch.sh
#
# Capturing tips
#  Syntax of tcpdump command is relatively easy, however, in order to capture truly relevant network traffic which will
#  be useful for later analysis it'd be beneficial to follow these simple rules:
#
#  1.  Run packet capture simultaneously on both connection sides (client and server)
#  2.  Make sure packets are being captured when the issue is present
#  3.  Make sure the capture file is saved onto the local file system
#  4.  Note the system timezone, where the capture has been done for later analysis and possible correlations with system logs
#  5.  Use rolling capture for issues which are hard to reproduce or to prevent capture files from growing too big
#  6.  Use 'tcpdump -s <bytes>' to limit the amount of information which will be saved per packet
#  7.  Don't use text output but binary (files with extension .cap, .pcap, .etc)
#  8.  Avoid using 'tcpdump -i any' and be sure you are capturing on the right interface
#  9.  Avoid using capture filters if possible as this may capture additional clues visible for different traffic types.
#      However this may not always be feasible if there is high bandwidth usage on the interface as it could generate a
#      huge file. If filters are required please consult with the Red Hat case team first. When filtering for a specified
#      host or port take care to not discard one direction of the network conversation.
#  10. There is an application available on the Red Hat Customer portal that can help with syntax generation if required.
#      Please see: https://access.redhat.com/labs/nptcpdump/
#  11. Compress capture files (eg. using gzip)
