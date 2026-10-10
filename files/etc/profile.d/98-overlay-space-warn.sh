# SSH login warning when the f2fs root overlay is running low.
# The rootfs_data partition is small (~656 MB). When it fills up, mount_root
# falls back to a RAM overlay and ALL UCI config (PPPoE, nikki, wifi) is lost
# on reboot. This banner gives the operator a chance to clean up before that
# happens.
if [ -t 1 ] && [ "$(id -u 2>/dev/null)" = 0 ]; then
	_ov_avail_kb="$(df -Pk /overlay 2>/dev/null | awk 'NR==2{print $4}')"
	_ov_pct="$(df -Pk /overlay 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
	if [ -n "$_ov_avail_kb" ] && [ "$_ov_avail_kb" -lt 204800 ] 2>/dev/null; then
		printf '\n\033[1;33mWARNING: /overlay is %s%% full (%s KB free).\033[0m\n' \
			"${_ov_pct:-?}" "${_ov_avail_kb:-?}"
		printf '\033[1;33mIf it reaches 100%%, mount_root falls back to RAM and ALL config (PPPoE, nikki, wifi) is lost on reboot.\033[0m\n'
		printf '\033[1;33mCheck: du -sh /overlay/upper/*  |  Clean: rm -rf /overlay/upper/data/*\033[0m\n\n'
	elif [ -n "$_ov_pct" ] && [ "$_ov_pct" -ge 90 ] 2>/dev/null; then
		printf '\n\033[1;33mWARNING: /overlay is %s%% full. Clean up before it reaches 100%%.\033[0m\n\n' "$_ov_pct"
	fi
	unset _ov_avail_kb _ov_pct
fi
