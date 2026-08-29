#!/bin/sh
# Non-blocking SSH login check for the agent CLIs and their updates (24h cache)
[ -t 1 ] || return 0
[ "$USER" = "root" ] || return 0

CACHE_FILE="/tmp/.agent_update_cache"
NOW=$(date +%s 2>/dev/null || echo 0)
CACHE_TTL=86400

print_agent_status() {
	local node_v oc_v pi_v hm_v
	node_v="$(node -v 2>/dev/null || echo "not installed")"
	oc_v="$(opencode --version 2>/dev/null || echo "not installed")"
	pi_v="$(pi --version 2>/dev/null || echo "not installed")"
	hm_v="$(hermes --version 2>/dev/null || echo "provisioning: /data/hermes-runtime.log")"

	printf "\n\033[1;36m┌──────────────────────────────────────────────────────────────┐\033[0m\n"
	printf "\033[1;36m│\033[0m \033[1;32m🤖 OpenWrt AI Agent CLI Status (Multica / OpenCode / Pi)\033[0m     \033[1;36m│\033[0m\n"
	printf "\033[1;36m│\033[0m  • Node.js:  %-48s \033[1;36m│\033[0m\n" "$node_v"
	printf "\033[1;36m│\033[0m  • OpenCode: %-48s \033[1;36m│\033[0m\n" "$oc_v"
	printf "\033[1;36m│\033[0m  • Pi CLI:   %-48s \033[1;36m│\033[0m\n" "$pi_v"
	printf "\033[1;36m│\033[0m  • Hermes:   %-48s \033[1;36m│\033[0m\n" "$hm_v"
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
