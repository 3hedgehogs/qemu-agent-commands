#!/bin/bash
set -eu
set -o pipefail

QEMU_VM=
COMMAND_ARGS=
VIRSH_RETURN=

main() {
    while getopts ":hm:" opt; do
        case $opt in
            m)
                QEMU_VM=$OPTARG
                ;;
            h)
                usage
                exit
                ;;
            \?)
                echo "Invalid option -$OPTARG" >&2
                usage >&2
                exit 1
                ;;
            :)
                echo "Option -$OPTARG requires an argument" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    shift $((OPTIND-1))

    if [[ $# -lt 1 ]]; then
        usage >&2
        exit 1
    fi

    local COMMAND="$1"
    shift

    COMMAND_ARGS=("$@")

    if [[ -z "$QEMU_VM" ]]; then
        echo "Must specify -q <virtual host name>" >&2
        usage >&2
        exit 1
    fi

    if [[ ! -x "/usr/bin/jq" ]]; then
        echo "ERROR: /usr/bin/jq command is absent" >&2 && return 1
    fi

    proxy_cmd "cmd_$COMMAND"
}

virsh_qemu_agent_command() {
    local VM COMMAND
    local RETURN
    COMMAND="$1"

    VR=$(virsh qemu-agent-command "$QEMU_VM" "$COMMAND")

    RETURN=$?
    if [[ $RETURN -ne 0 ]]; then
        return $RETURN
    fi

    local ERROR=$(jq -r '.error.desc // empty' <<< "$VR")
    if [[ -n "$ERROR" ]]; then
        echo "$ERROR" >&2
        return 1
    fi

    VIRSH_RETURN=$(jq -cM .return <<< "$VR")
    return $RETURN
}

proxy_cmd() {
    # check we are synced
    sync_agent
    [[ $? -eq 0 ]] || (echo "ERROR: cannot continue, out of sync" >&2 && return 1)

    "$1" "${COMMAND_ARGS[@]}"
}



sync_agent() {
    id=$RANDOM
    json_id=$(json --argjson pid "$id" '{"id": $pid}')
    virsh_qemu_agent_command  "$(json \
        --arg execute "guest-sync" \
        --argjson args "$json_id" \
        '{"execute": $execute, "arguments": $args}' \
        )"
    [[ $VIRSH_RETURN = $id ]] || (echo "guest-sync mismatch" >&2 && return 1)
}

cmd_info() {
    virsh_qemu_agent_command "$(json --arg execute "guest-info" '{"execute": $execute, "arguments": {}}')"
    jq -er .version <<< "$VIRSH_RETURN"
}

cmd_readfile() {
    local file=$1
    json_open_par=$(json --arg mode 'r' --arg path "$file" '{"path": $path, "mode": $mode}')
    virsh_qemu_agent_command "$(json \
        --arg execute "guest-file-open" \
        --argjson args "$json_open_par" \
        '{"execute": $execute, "arguments": $args}' \
        )"
    if [[ $? -ne 0 ]]; then
        echo "ERROR: could not open file: $file" >&2 && return 1
    fi
    FD=$VIRSH_RETURN

    json_read_par=$(json --argjson handle "$FD" '{"handle": $handle}')
    virsh_qemu_agent_command "$(json \
        --arg execute "guest-file-read" \
        --argjson args "$json_read_par" \
        '{"execute": $execute, "arguments": $args}' \
        )"
    if [[ $? -ne 0 ]]; then
        echo "ERROR: could not read file: $file" >&2 && return 1
    fi
    content=$(jq -cM '."buf-b64"' <<< "$VIRSH_RETURN" | xargs echo | base64 -d)

    virsh_qemu_agent_command "$(json \
         --arg execute "guest-file-close" \
         --argjson args "$json_read_par" \
         '{"execute": $execute, "arguments": $args}' \
         )"
    if [[ $? -ne 0 ]]; then
        echo "ERROR: could not close file: $file" >&2 && return 1
    fi

    echo "$content"
    return 0
}

cmd_exec() {
	local OPT_WAIT=false
	local OPT_INPUT=false
	local OPT_OUTPUT=false
	local OPT_ENV=()

	OPTIND=
	while getopts ":e:wio" opt; do
		case $opt in
			e)
				OPT_ENV+=("$OPTARG")
				;;
			w)
				OPT_WAIT=true
				;;
			i)
				OPT_INPUT=true
				;;
			o)
				OPT_OUTPUT=true
				;;
			\?)
				echo "Invalid option -$OPTARG" >&2
				usage >&2
				exit 1
				;;
			:)
				echo "Option -$OPTARG requires an argument" >&2
				usage >&2
				exit 1
				;;
		esac
	done

	shift $((OPTIND-1))

	if [[ $# -lt 1 ]]; then
		usage >&2
		exit 1
	fi

	local CMD="$1"
	shift
	local OPT_ARG=("$@")

	local JSON_ENV JSON_ARG PID STATUS EXIT_CODE
	JSON_ENV=$(json_array ${OPT_ENV[@]+"${OPT_ENV[@]}"})
	JSON_ARG=$(json_array ${OPT_ARG[@]+"${OPT_ARG[@]}"})

    json_exec_command="$(json \
        --arg path "$CMD" \
        --arg input "$([[ $OPT_INPUT == false ]] || base64)" \
        --argjson arg "$JSON_ARG" \
        --argjson env "$JSON_ENV" \
        --argjson capture "$OPT_OUTPUT" \
        '{"path": $path, "arg": $arg, "env": $env, "input-data": $input, "capture-output": $capture}' \
    )"
    virsh_qemu_agent_command "$(json \
       --arg execute "guest-exec" \
       --argjson args "$json_exec_command" \
       '{"execute": $execute, "arguments": $args}' \
    )"
	PID="$(jq -re .pid <<< $VIRSH_RETURN)"

	if [[ $OPT_WAIT = true || $OPT_OUTPUT == true ]]; then
		while true; do
            json_exec_status="$(json --argjson pid "$PID" '{"pid": $pid}')"
            virsh_qemu_agent_command "$(json \
                    --arg execute "guest-exec-status" \
                    --argjson args "$json_exec_status" \
                    '{"execute": $execute, "arguments": $args}' \
                    )"
			STATUS="$VIRSH_RETURN"
			if [[ "$(jq -er .exited <<< "$STATUS")" == false ]]; then
				sleep 0.1
			else
				EXIT_CODE=$(jq -er .exitcode <<< "$STATUS")
				if [[ $OPT_OUTPUT == true ]]; then
					jq -r '."out-data" // empty' <<< "$STATUS" | base64 -d
					jq -r '."err-data" // empty' <<< "$STATUS" | base64 -d >&2
					# TODO: check .out-truncated, .err-truncated
				fi
				return $EXIT_CODE
			fi
		done
	else
		echo "$PID"
	fi
}

cmd_shutdown() {
    local OPT_REBOOT=false
    local OPT_HALT=false

    OPTIND=
    while getopts ":rh" opt; do
        case $opt in
            r)
                OPT_REBOOT=true
                ;;
            h)
                OPT_HALT=true
                ;;
            \?)
                echo "Invalid option -$OPTARG" >&2
                usage >&2
                exit 1
                ;;
            :)
                echo "Option -$OPTARG requires an argument" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    shift $((OPTIND-1))

    json_shut_par=$(json \
      --arg mode "$([[ $OPT_REBOOT == true ]] && echo reboot || ([[ $OPT_HALT == true ]] && echo halt) || echo powerdown)" '{"mode": $mode}'
    )
    virsh_qemu_agent_command "$(json \
        --arg execute "guest-shutdown" \
        --argjson args "$json_shut_par" \
        '{"execute": $execute, "arguments": $args}' \
        )"
}


json() {
        jq -ncM "$@"
}

json_array() {
        for arg in "$@"; do
                json --arg arg "$arg" '$arg'
        done | jq -cMs .
}

json_dict() {
        local SEPARATOR="="
        for arg in "$@"; do
            local KEY=$(cut -d "$SEPARATOR" -f1 <<< $arg)
            local VALUE=$(cut -d "$SEPARATOR" -f2- <<< $arg)

            json --arg value "$VALUE" '{"'$KEY'": $value}'
        done | jq -cMs 'add // {}'
}

usage() {
        echo "$0 [options] COMMAND"
        echo "  -m VM_NAME"
        echo "Commands"
        echo "  info"
        echo "    Displays information about the guest, and can be used to check that the guest agent is running"
        echo "  readfile FILENAME"
        echo "    Read guest file to the screen"
        echo "  exec [options] PATH [ARGUMENTS..]"
        echo "    Executes a process inside the guest"
        echo "    -e ENV=value: set environment variable(s)"
        echo "    -w: wait for process to terminate"
        echo "    -i: send stdin"
        echo "    -o: capture stdout"
        echo "  shutdown"
        echo "    Tells the guest to initiate a system shutdown"
        echo "    -h: halt immediately"
        echo "    -r: reboot"
}


main "$@"
