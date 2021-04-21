#!/usr/bin/env bash

port_test () {
	NAME=$1
	PORT=$2
	PID=$(lsof -P -i:${PORT} | tail -1 | awk '{print $2}')
	STATUS=$([[ -z "$PID" ]] && echo "NOT RUNNING" || echo "RUNNING")
	echo "$NAME (port $PORT) status - $STATUS"
	if [[ -n "$PID" ]]; then
		lsof -P -i:$PORT
		pstree -p ${PID}
		echo ""
	fi
}

port_test webapp 8080
port_test datastore-translator 8001
port_test nginx 8081
