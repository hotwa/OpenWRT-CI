#!/usr/bin/env bash
# tests/test_container_mirror.sh
#
# Container mirror connectivity smoke test (build-time).
#
# History: docker.1panel.live began returning 403 to anonymous manifest
# requests on 2026-09-08 (observed on RE-CS-07/RE-SS-01 after ebd46aa flash).
# Anonymous manifest reachability also varies by egress IP/User-Agent, so this
# test probes a candidate list and passes if ANY mirror serves an anonymous
# manifest 200. The winning mirror name is printed so callers can wire it into
# device scripts (e.g. check-post-flash.sh container smoke test).
#
# Wire into CI with `WRT_SKIP_MIRROR_TEST` to bypass in restricted runners.
set -euo pipefail

CANDIDATES=(docker.xuanyuan.me docker.1panel.live docker.m.daocloud.io docker.1ms.run)
[ -n "${WRT_SKIP_MIRROR_TEST:-}" ] && { echo "mirror test skipped (WRT_SKIP_MIRROR_TEST)"; exit 0; }

ok=""
for mirror in "${CANDIDATES[@]}"; do
	code="$(curl -sS --max-time 15 -o /dev/null \
		-w '%{http_code}' \
		-H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
		"https://$mirror/v2/library/hello-world/manifests/latest" 2>&1 || true)"
	echo "  $mirror manifest http=$code"
	if [ "$code" = "200" ]; then
		ok="$mirror"
		break
	fi
done

if [ -n "$ok" ]; then
	echo "mirror OK: $ok"
else
	echo "no candidate mirror serves anonymous manifest 200" >&2
	exit 1
fi
