#!/usr/bin/env bash
# Run the OpenDJ server
# We consolidate all of the writable DJ directories to /opt/opendj/data
# This allows us to to mount a data volume on that root which  gives us
# persistence across restarts of OpenDJ.
# For Docker - mount a data volume on /opt/opendj/data
# For Kubernetes mount a PV
#
# Copyright (c) 2016-2017 ForgeRock AS. Use of this source code is subject to the
# Common Development and Distribution License (CDDL) that can be found in the LICENSE file

cd /opt/opendj

# If the pod was terminated abnormally the lock file may not have gotten cleaned up.

rm -f /opt/opendj/locks/server.lock
mkdir -p locks

restore() 
{
    echo "Attempting to restore from backup"
    if [ -z "$RESTORE_PATH" ]; then 
        scripts/restore.sh -o
    else
        scripts/restore.sh -o -p "$RESTORE_PATH"
    fi
}

# Check for a mounted secret volume. Fall back to secrets bundled in the image if we can't find them.
if [ ! -d "$SECRET_PATH" ]; then
    echo "Warning; Cannot find mounted secret volume on $SECRET_PATH. Falling back to using secrets bundled in the image"

    export DIR_MANAGER_PW_FILE=/opt/opendj/secrets/dirmanager.pw
    export MONITOR_PW_FILE=/opt/opendj/secrets/monitor.pw
    export KEYSTORE_FILE=/opt/opendj/secrets/keystore.pkcs12
    export KEYSTORE_PIN_FILE=/opt/opendj/secrets/keystore.pin
fi


# Create top level symbolic links if there is a persistent data volume mounted.
# todo: When commons configuration is finalized, we should modify config.ldif to point to the directory locations.
if [ -d data/db ]; then
    for d in data/*
    do
        echo "Creating symbolic link $d"
        ln -s $d
    done
fi


# Uncomment this to print experimental VM settings to stdout.
#java -XX:+UnlockExperimentalVMOptions -XX:+UseCGroupMemoryLimitForHeap -XX:MaxRAMFraction=1 -XshowSettings:vm -version

source /opt/opendj/env.sh

setup() {
      # If the instance data does not exist we need to run setup.
    if [ ! -d ./data/db ] ; then
      echo "Instance data Directory is empty. Creating new DJ instance"
      BOOTSTRAP="${BOOTSTRAP:-/opt/opendj/bootstrap/setup-directory.sh}"
      # DS setup complains if the directory is not empty.
      echo "Running $BOOTSTRAP"
      "${BOOTSTRAP}"
    else
        echo "Instance directory ./data/db is not empty. Setup will be skipped"
    fi
}

start() {
    echo "Starting OpenDJ"
    echo "Server id $SERVER_ID"
    exec tini -v -- ./bin/start-ds --nodetach
}

pause() {
    while true; do
        sleep 1000
    done
}

# Restore from a backup
restore() {
       if [ -d ./data/db ] ; then
        echo "It looks like there is existing directory data. Restore will not run."
        exit 0
       fi

        # run setup - because the directory needs to be configured
       # todo - See if we can restore a saved template instead.
       unset NUMBER_SAMPLE_USERS
       setup

       # We are currently using dsreplication initialize-all to load data from the first server 
       # So we restore data only on the first server and let initialization copy the data.
       if [[ $HOSTNAME = *"0"* ]]; then 
            echo "Restoring data from backup on host $HOSTNAME"
            scripts/restore.sh -o
       fi
}

CMD="${1:-run}"

echo "Command is $CMD"


case "$CMD" in
run)
    # Setup (if configuration does not already exist), and then start.
    # This is the default action.
    setup
    start
    ;;
setup)
    # Configure/setup only.
    setup
    ;;
start)
    # Start only. Will fail if there is no configuration
    start
    ;;
run-post-setup-job)
    # Runs post setup job that configures replication
    bootstrap/replicate-ds2ds.sh 
    ;;
restore-from-backup)
    restore
    ;;
restore-and-verify)
    # Restore from backup, and then verify the integrity of the data.
    scripts/restore.sh -o
    scripts/verify.sh
    ;;
backup)
    shift
    /opt/opendj/scripts/backup.sh "$@"
    ;;
proxy)
    bootstrap/setup-proxy.sh
    start
    ;;
pause) 
    pause
    ;;
*)
    exec "$@"
esac