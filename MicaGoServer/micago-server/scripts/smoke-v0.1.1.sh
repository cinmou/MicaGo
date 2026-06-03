#!/bin/sh

set -eu

base_url="http://127.0.0.1:3000"
timestamp="$(date '+%Y%m%d-%H%M%S')"
out_dir="tmp/smoke-v0.1.1/$timestamp"

mkdir -p "$out_dir"

run_json() {
	name="$1"
	path="$2"
	file="$out_dir/$name.txt"

	printf '\n== %s ==\n' "$name"
	curl -sS "$base_url$path" | tee "$file"
	printf '\n'
}

run_error() {
	name="$1"
	path="$2"
	file="$out_dir/$name.txt"

	printf '\n== %s ==\n' "$name"
	curl -i -sS "$base_url$path" | tee "$file"
	printf '\n'
}

run_json "A-health" "/api/health"
run_json "B-chats-default" "/api/chats?limit=10"
run_json "C-chats-all" "/api/chats?service=all&limit=10"
run_json "D-chats-sms" "/api/chats?service=SMS&limit=10"
run_json "E-chats-rcs" "/api/chats?service=RCS&limit=10"
run_json "F-messages-default" "/api/messages/recent?limit=10"
run_json "G-messages-all" "/api/messages/recent?service=all&limit=10"
run_json "H-messages-all-include-empty" "/api/messages/recent?service=all&includeEmpty=true&limit=10"
run_error "I-chats-invalid-service" "/api/chats?service=WhatsApp"
run_error "J-messages-invalid-include-empty" "/api/messages/recent?includeEmpty=maybe"
run_error "K-messages-limit-zero" "/api/messages/recent?limit=0"
run_error "L-messages-limit-too-high" "/api/messages/recent?limit=501"
run_error "M-messages-negative-offset" "/api/messages/recent?offset=-1"
run_error "N-chat-messages-unknown-guid" "/api/chats/not-a-real-guid/messages"

printf '\nSaved responses under %s\n' "$out_dir"
