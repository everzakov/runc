#!/usr/bin/env bats

load helpers

function setup() {
    setup_busybox
    HELPER="tpm-helper"
	cp "${TESTBINDIR}/${HELPER}" rootfs/bin/
    VTPM_GENERATED_DEVICE_NAME="tpm0000"
    VTPM_GENERATED_DEVICE="/dev/$VTPM_GENERATED_DEVICE_NAME"
    VTPM_GENERATED_DEVICE_PATH_ARG="-devicePath=$VTPM_GENERATED_DEVICE"
    echo $VTPM_GENERATED_DEVICE
    VTPM_CONTAINER_DEVICE_NAME="tpm0"
    VTPM_CONTAINER_DEVICE="/dev/$VTPM_CONTAINER_DEVICE_NAME"
    VTPM_CONTAINER_DEVICE_PATH_ARG="-devicePath=$VTPM_CONTAINER_DEVICE"
    echo $VTPM_CONTAINER_DEVICE

    if [ $EUID -eq 0 ]; then
        SWTPM_DIR=$(mktemp -d)
        test_major=${RUN_IN_CONTAINER_MAJOR:-0}
        test_minor=${RUN_IN_CONTAINER_MINOR:-0}
        # create generated path
        swtpm_cuse -n "$VTPM_GENERATED_DEVICE_NAME" --log "file=$SWTPM_DIR/swtpm.log" --pid "file=$SWTPM_DIR/swtpm.pid" --tpmstate "dir=$SWTPM_DIR" --flags not-need-init,startup-clear --tpm2 --maj=$test_major --min=$test_minor

        # in docker container we need to mknod device

        if [ "$test_major" -ne 0 ]; then
            mknod "$VTPM_GENERATED_DEVICE" c $test_major $test_minor            
        else
            test_minor=$(ls -la "$VTPM_GENERATED_DEVICE" | awk '{print $6}')
            test_major=$(ls -la "$VTPM_GENERATED_DEVICE" | awk '{print $5}')
            test_major=${test_major::-1}
        fi

        # remove comment if you want to read from device in custom user namespace
        # chmod 666 "$VTPM_GENERATED_DEVICE"
    fi

    to_umount_list="$(mktemp "$BATS_RUN_TMPDIR/userns-mounts.XXXXXX")"
}

function teardown() {
	teardown_bundle
    if [ $EUID -eq 0 ]; then
        kill -10 $(cat "$SWTPM_DIR/swtpm.pid")

        rm "$VTPM_GENERATED_DEVICE" || true
    fi

    if [ -v to_umount_list ]; then
		while read -r mount_path; do
			umount -l "$mount_path" || :
			rm -rf "$mount_path"
		done <"$to_umount_list"
		rm -f "$to_umount_list"
		unset to_umount_list
	fi
}

@test "vtpm with mknod command" {
    requires root
    update_config '	.process.args = ["/bin/'"$HELPER"'", "'"$VTPM_CONTAINER_DEVICE_PATH_ARG"'"]
                    | .linux.resources.vtpms = [{"containerPath": "'"$VTPM_CONTAINER_DEVICE"'", "vtpmMajor": '"$test_major"', "vtpmMinor": '"$test_minor"', "fileMode": 432}]'
    runc run tst1
    [ "$status" -eq 0 ]

    update_config ' .process.args = ["/bin/'"$HELPER"'", "'"$VTPM_GENERATED_DEVICE_PATH_ARG"'"]
                    | .linux.resources.vtpms |= map(if .containerPath == "'"$VTPM_CONTAINER_DEVICE"'" then (.containerPath = "'"$VTPM_GENERATED_DEVICE"'" ) else . end)'
    runc run tst2
    [ "$status" -eq 0 ]
}

@test "vtpm with mknod command with permissions" {
    requires root
    update_config '	.process.args = ["/bin/'"$HELPER"'", "'"$VTPM_CONTAINER_DEVICE_PATH_ARG"'"]
                    | .process.user = {"uid" : 103, "gid": 104}
                    | .linux.resources.vtpms = [{"containerPath": "'"$VTPM_CONTAINER_DEVICE"'", "vtpmMajor": '"$test_major"', "vtpmMinor": '"$test_minor"', "fileMode": 432, "uid": 103, "gid": 104}]'
    runc run tst1
    [ "$status" -eq 0 ]

    update_config '.process.user = {"uid" : 105, "gid": 106}'
    runc run tst2
    [ "$status" -ne 0 ]

    update_config ' .process.args = ["/bin/'"$HELPER"'", "'"$VTPM_GENERATED_DEVICE_PATH_ARG"'"]
                    | .process.user = {"uid" : 103, "gid": 104}
                    | .linux.resources.vtpms  |= map(if .containerPath == "'"$VTPM_CONTAINER_DEVICE"'" then (.containerPath = "'"$VTPM_GENERATED_DEVICE"'" ) else . end)'
    runc run tst3
    [ "$status" -eq 0 ]

    update_config '.process.user = {"uid" : 105, "gid": 106}'
    runc run tst4
    [ "$status" -ne 0 ]
}

@test "vtpm with mount command with user namespace" {
    requires root

    update_config '	.process.args = ["/bin/'"$HELPER"'", "'"$VTPM_GENERATED_DEVICE_PATH_ARG"'"]
                    | .linux.resources.vtpms = [{"containerPath": "'"$VTPM_GENERATED_DEVICE"'", "hostPath": "'"$VTPM_GENERATED_DEVICE"'", "vtpmMajor": '"$test_major"', "vtpmMinor": '"$test_minor"', "fileMode": 432}]
                    | .linux.namespaces += [{"type": "user"}]
                    | .linux.uidMappings += [{"hostID": 100000, "containerID": 0, "size": 65534}]
                    | .linux.gidMappings += [{"hostID": 200000, "containerID": 0, "size": 65534}] '
    remap_rootfs
    runc run tst1
    [ "$status" -eq 0 ]

    # this can not be run because we have no container path in host
    update_config ' .process.args = ["/bin/'"$HELPER"'", "'"$VTPM_CONTAINER_DEVICE_PATH_ARG"'"]
                    | .linux.resources.vtpms |= map(if .containerPath == "'"$VTPM_GENERATED_DEVICE"'" then (.containerPath = "'"$VTPM_CONTAINER_DEVICE"'" ) else . end)'
    runc run tst2
    [ "$status" -eq 0 ]
}

@test "vtpm with mount command with user namespace with permissions" {
    requires root

    update_config '	.process.args = ["/bin/'"$HELPER"'", "'"$VTPM_GENERATED_DEVICE_PATH_ARG"'"]
                    | .process.user = {"uid" : 103, "gid": 104}
                    | .linux.resources.vtpms = [{"containerPath": "'"$VTPM_GENERATED_DEVICE"'", "hostPath": "'"$VTPM_GENERATED_DEVICE"'", "vtpmMajor": '"$test_major"', "vtpmMinor": '"$test_minor"', "fileMode": 432, "uid": 103, "gid": 104}]
                    | .linux.namespaces += [{"type": "user"}]
                    | .linux.uidMappings += [{"hostID": 100000, "containerID": 0, "size": 65534}]
                    | .linux.gidMappings += [{"hostID": 200000, "containerID": 0, "size": 65534}] '
    remap_rootfs
    runc run tst1
    [ "$status" -eq 0 ]

    # container can be run because we have set 666 file mode for generated device
    update_config '.process.user = {"uid" : 105, "gid": 106}'
    runc run tst2
    [ "$status" -ne 0 ]

    # this can not be run because we have no container path in host
    update_config ' .process.args = ["/bin/'"$HELPER"'", "'"$VTPM_CONTAINER_DEVICE_PATH_ARG"'"]
                    | .process.user = {"uid" : 103, "gid": 104}
                    | .linux.resources.vtpms |= map(if .containerPath == "'"$VTPM_GENERATED_DEVICE"'" then (.containerPath = "'"$VTPM_CONTAINER_DEVICE"'" ) else . end)'
    runc run tst3
    [ "$status" -eq 0 ]

    update_config '.process.user = {"uid" : 105, "gid": 106}'
    runc run tst4
    [ "$status" -ne 0 ]
}

@test "vtpm with mount command with external user namespace" {
    requires root

    update_config ' .process.args = ["sleep", "infinity"]
                    | .linux.namespaces += [{"type": "user"}]
                    | .linux.uidMappings += [{"hostID": 100000, "containerID": 0, "size": 65534}]
                    | .linux.gidMappings += [{"hostID": 200000, "containerID": 0, "size": 65534}] '
    remap_rootfs
	runc run -d --console-socket "$CONSOLE_SOCKET" target_userns
	[ "$status" -eq 0 ]

    userns_pid="$(__runc state target_userns | jq .pid)"
	userns_path="$(mktemp "$BATS_RUN_TMPDIR/userns.XXXXXX")"
	mount --bind "/proc/$userns_pid/ns/user" "$userns_path"
	echo "$userns_path" >>"$to_umount_list"

    update_config ' .process.args = ["/bin/'"$HELPER"'", "'"$VTPM_GENERATED_DEVICE_PATH_ARG"'"]
                    | .linux.resources.vtpms = [{"containerPath": "'"$VTPM_GENERATED_DEVICE"'", "hostPath": "'"$VTPM_GENERATED_DEVICE"'", "vtpmMajor": '"$test_major"', "vtpmMinor": '"$test_minor"', "fileMode": 432}]
                    | .linux.namespaces |= map(if .type == "user" then (.path = "'"$userns_path"'") else . end)
		            | del(.linux.uidMappings)
		            | del(.linux.gidMappings)'

    runc run in_userns_1
	[ "$status" -eq 0 ]

    # this can not be run because we have no container path in host
    update_config ' .process.args = ["/bin/'"$HELPER"'", "'"$VTPM_CONTAINER_DEVICE_PATH_ARG"'"]
                    | .linux.resources.vtpms |= map(if .containerPath == "'"$VTPM_GENERATED_DEVICE"'" then (.containerPath = "'"$VTPM_CONTAINER_DEVICE"'" ) else . end)'
    runc run in_userns_2
	[ "$status" -eq 0 ]
}

@test "vtpm with mount command with external user namespace and permissions" {
    
    update_config ' .process.args = ["sleep", "infinity"]
                    | .linux.namespaces += [{"type": "user"}]
                    | .linux.uidMappings += [{"hostID": 100000, "containerID": 0, "size": 65534}]
                    | .linux.gidMappings += [{"hostID": 200000, "containerID": 0, "size": 65534}]'
    remap_rootfs
	runc run -d --console-socket "$CONSOLE_SOCKET" target_userns
	[ "$status" -eq 0 ]

    userns_pid="$(__runc state target_userns | jq .pid)"
	userns_path="$(mktemp "$BATS_RUN_TMPDIR/userns.XXXXXX")"
	mount --bind "/proc/$userns_pid/ns/user" "$userns_path"
	echo "$userns_path" >>"$to_umount_list"

    update_config ' .process.args = ["/bin/'"$HELPER"'", "'"$VTPM_GENERATED_DEVICE_PATH_ARG"'"]
                    | .process.user = {"uid" : 103, "gid": 104}
                    | .linux.resources.vtpms = [{"containerPath": "'"$VTPM_GENERATED_DEVICE"'", "hostPath": "'"$VTPM_GENERATED_DEVICE"'","vtpmMajor": '"$test_major"', "vtpmMinor": '"$test_minor"', "fileMode": 432, "uid": 103, "gid": 104}]
                    | .linux.namespaces |= map(if .type == "user" then (.path = "'"$userns_path"'") else . end)
		            | del(.linux.uidMappings)
		            | del(.linux.gidMappings)'

    runc run in_userns_1
	[ "$status" -eq 0 ]

    # container can be run because we have set 666 file mode for generated device
    update_config '.process.user = {"uid" : 105, "gid": 106}'
    runc run in_userns_2
    [ "$status" -ne 0 ]

    # this can not be run because we have no container path in host
    update_config ' .process.args = ["/bin/'"$HELPER"'", "'"$VTPM_CONTAINER_DEVICE_PATH_ARG"'"]
                    | .process.user = {"uid" : 103, "gid": 104}
                    | .linux.resources.vtpms |= map(if .containerPath == "'"$VTPM_GENERATED_DEVICE"'" then (.containerPath = "'"$VTPM_CONTAINER_DEVICE"'" ) else . end)'
    runc run in_userns_3
	[ "$status" -eq 0 ]

    update_config '.process.user = {"uid" : 105, "gid": 106}'
    runc run in_userns_4
    [ "$status" -ne 0 ]
}