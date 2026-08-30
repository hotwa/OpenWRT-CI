#!/bin/sh
# Non-blocking SSH login check for the agent CLIs and their updates (24h cache)
[ -t 1 ] || return 0
[ "$USER" = "root" ] || return 0

CACHE_FILE="/tmp/.agent_update_cache"
NOW=$(date +%s 2>/dev/null || echo 0)
CACHE_TTL=86400

print_agent_status() {
	local node_v python_v cmdc_v pi_v
	node_v="$(node -v 2>/dev/null || echo "not installed")"
	python_v="$(python3 --version 2>/dev/null || echo "not ready")"
	cmdc_v="$(cmdc --version 2>/dev/null || echo "not installed")"
	pi_v="$(pi --version 2>/dev/null || echo "not installed")"

	printf "\n\033[1;36m┌──────────────────────────────────────────────────────────────┐\033[0m\n"
	printf "\033[1;36m│\033[0m \033[1;32m🤖 OpenWrt AI Agent CLI Status (Multica / Pi / CommandCode)\033[0m  \033[1;36m│\033[0m\n"
	printf "\033[1;36m│\033[0m  • Node.js:  %-48s \033[1;36m│\033[0m\n" "$node_v"
	printf "\033[1;36m│\033[0m  • Python:   %-48s \033[1;36m│\033[0m\n" "$python_v"
	printf "\033[1;36m│\033[0m  • CommandCode: %-44s \033[1;36m│\033[0m\n" "$cmdc_v"
	printf "\033[1;36m│\033[0m  • Pi CLI:   %-48s \033[1;36m│\033[0m\n" "$pi_v"
	printf "\033[1;36m│\033[0m                                                              \033[1;36m│\033[0m\n"
	printf "\033[1;36m│\033[0m  💡 Signed stack upgrade: \033[1;33magent-runtime upgrade\033[0m             \033[1;36m│\033[0m\n"
	printf "\033[1;36m│\033[0m  💡 Verify / rollback: \033[1;33magent-runtime verify | rollback\033[0m      \033[1;36m│\033[0m\n"
	printf "\033[1;36m└──────────────────────────────────────────────────────────────┘\033[0m\n\n"
}

if [ -f "$CACHE_FILE" ]; then
	LAST_CHECK=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
	if [ $((NOW - LAST_CHECK)) -lt "$CACHE_TTL" ]; then
		print_agent_status
		return 0
	fi
fi

touch "$CACHE_FILE" 2>/dev/null || true
print_agent_status
