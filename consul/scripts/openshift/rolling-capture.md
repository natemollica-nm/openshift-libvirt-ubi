Rolling Capture

Sometimes it is necessary for a capture to run for an extended period of time. In those case it is not a
good idea to allow the capture file to grow indefinitely. Still check that enough disk space is available 
for the projected rolling capture. The arguments -w path -W n -C m will direct tcpdump to create "n" files 
of approximately "m" megabytes. The files will have the names path0 thru path(n-1). When the size of pathX 
exceeds m megabytes path(mod (X+1, n) is written or rewritten. Since tcpdump is by default run under the tcpdump
user ID it is necessary that this user ID has the necessary permissions to create the pathX files. The 
"-Z userID" can be used to change the ID that runs the tcpdump command.

It is important that the combination of file size and the number of files versus the rate at which the
files are cycled give you enough time to recognize that the event you are trying to capture has occurred 
and stop the capture before the file with the event is overwritten. The following script can help with that. 
It can be used to start tcpdump and then stop it when a trigger message is seen in a log file.

Example: ./pcapLogwatch.sh eth0 5 250 /tmp dumpfilename.pcap "" /var/log/messages "Time has been changed"

|         Script          | Device | Num. of Files | Filesize | Dump Directory |  Dumpfile   | Filter |       Logfile       | Trigger |
|:-----------------------:|:------:|:-------------:|:--------:|:--------------:|:-----------:|:------:|:-------------------:|:-------:|
| `oc-rolling-tcpdump.sh` | `eth0` |      `5`      |  `250`   |    `/tmp/`     | `dump.pcap` |   ""   | `/var/log/messages` |  Time   |

* `DEVICE` = (`eth0`) The interface you are capturing from (#ip a)
* `NUMBER-OF-FILES` = (`5`) number of files
* `SIZE-OF_FILES` = (`250`) Where 250 is size in MB
* `DUMP-DIRECTORY` = (`/tmp`) The directory to dump to
*` DUMP-FILE-NAME` = (`dump.pcap`) The name that will be given to your capture file
* `FILTER` = (`"""`) the tcpdump filter, can be a protocol or IP
* `LOG-FILE-NAME` = (`/var/log/messages`) The file that we are watching for our triggers
* `TRIGGER-STRING` = (Time has been changed) The error message that stops the rolling capture in the watched file