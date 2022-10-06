#!/bin/bash

set -ue

HOST=${1:-}

((UID != 0)) && exec sudo -E $0 $HOST

BACKUP_NUM=999
MIN_FREE_SPACE=$((1 * 1024 * 1024))
WORK_DIR=$(dirname $(readlink -f $0))

[[ "$WORK_DIR" =~ backup ]] || {
    echo "Error: WORK_DIR \"$WORK_DIR\" doesn't match \"backup\""
    exit
}

get_lock() {
    local pid PID_LIST=$1
    while true; do
        while read pid; do
            kill -0 $pid || continue
            [ "$pid" != "$BASHPID" ] && return 1
            echo $BASHPID >$PID_LIST.new && mv $PID_LIST.new $PID_LIST && return 0
        done < $PID_LIST
        echo $BASHPID >>$PID_LIST
    done 2>/dev/null
}

rsync_options=""
remote_host=""
if [ -z "$HOST" ] ; then
    HOST=$(hostname -s)
else
    rsync_options="-e ssh"
    remote_host="${SUDO_USER}@${HOST}:"
fi

[ -d ${WORK_DIR}/${HOST} ] || {
    echo "Error: directory ${WORK_DIR}/${HOST} doesn't exist"
    exit
}

get_lock /tmp/$(basename $0).$HOST.pid || {
    echo "Error: another backup for $HOST is in progress"
    exit
}

[ -f ${WORK_DIR}/${HOST}/.config ] && . ${WORK_DIR}/${HOST}/.config
latest=${WORK_DIR}/${HOST}/latest/
previous=$(ls -dt ${WORK_DIR}/${HOST}/* | head -n1)
ls -dt ${WORK_DIR}/${HOST}/* | tail -n +${BACKUP_NUM} | xargs rm -rf
[ -n "$previous" ] && rsync_options+=" --link-dest=$previous"

while true; do
    rsync -av --ignore-errors --rsync-path='sudo rsync' $rsync_options ${remote_host}{/home,/etc} $latest || :
    avail=$(df --output=avail $WORK_DIR|tail -n 1)
    ((avail > MIN_FREE_SPACE)) && break
    # if free space on the backup storage is less than MIN_FREE_SPACE we find oldest backup and delete it
    # we keep last 5 backups for each host
    # directories archive and lost+found are ignored
    # after oldest backup is deleted we retry backup
    dirs2rm=$(ls -dt $WORK_DIR/*/*|grep -vP "$WORK_DIR/(archive|lost.found)"|grep -v -f <(for x in $WORK_DIR/*; do [ -d $x ] && ls -dt $x/*|head -n5; done)|tail -n1)
    echo "Deleting $dirs2rm"
    rm -rf $dirs2rm
done

get_interval_label() {
    local label timestamp now=$(date +%s) dir_name
    declare -A interval_seconds=([monthly]=$((28*24*3600)) [weekly]=$((7*24*3600)) [daily]=$((24*3600)))
    for label in monthly weekly daily; do
        dir_name=$(ls -dt ${WORK_DIR}/${HOST}/*_${label} 2>/dev/null | head -n1)
        timestamp=0
        [ -n "$dir_name" ] && timestamp=$(date -d "$(basename $dir_name | sed -e 's/_[^_]*$//' -e 's/_/ /')" +%s)
        ((now - timestamp > ${interval_seconds[$label]})) && echo -n $label && return
    done
    echo -n "hourly"
}

mv $latest ${WORK_DIR}/${HOST}/$(date +%F_%T)_$(get_interval_label)/
