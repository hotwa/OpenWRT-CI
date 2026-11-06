#!/usr/bin/env bash
# ============================================================
# ConfigureWgSiteToSite.sh — private WG seed; DDNS is disabled for mesh builds.
# Usage: ConfigureWgSiteToSite.sh <wrt/files> <server|client>
# Required env: WG_PRIV_KEY / WG_PEER_PUB. Optional DDNS_HOST is only an
# administrator-supplied initial client endpoint; it is never refreshed by the daemon.
# DDNSGO provider credentials are intentionally ignored and never staged.
# ============================================================
set -euo pipefail

FILES_DIR="${1:?usage: ConfigureWgSiteToSite.sh <files_dir> <ROLE>}"
ROLE="${2:?usage: ConfigureWgSiteToSite.sh <files_dir> <ROLE>}"
case "$ROLE" in server|client) ;; *) echo "ROLE 必须为 server|client"; exit 1 ;; esac

mkdir -p "$FILES_DIR/etc/wg-site"

# ============================================================
# 已知上游 feeds 回归修复（编译期处理，不进入固件内容）：
# ImmortalWRT packages 的 miniupnpd 补丁已过时——miniupnp 上游 2.3.11
# tarball（2026 重发）已合入等价修复，保留这些 patch 会在 package/compile
# 阶段重复打补丁 → Hunk FAILED → 编译必失败
# （"miniupnpd failed to build (build variant: nftables)"）。
# 已逐项本地实证（tarball hash 91994b12... 校验通过 + 源码 grep + git apply）：
#  020-descr-filter-fix.patch  → upnppermissions.c/h 已含 iseol/get_sep/get_range/
#                                get_addr_or_mask 与 const char * 声明（已冗余，删无损）
#  030-allow-private-fix.patch → upnpsoap.c:421 已是 if (GETFLAG(ALLOWPRIVATEIPV4MASK))
#                                （修复已合入，仅行号漂移 370→421 导致 hunk 失败，删无损）
#  040-improve-logging.patch   → 上下文漂移打不上；源码未含其改进（日志仍为上游默认），
#                                删除仅损失"更详细启动日志"这一非必要改进（功能无影响）
#  900-format-xml-...patch     → 上下文漂移打不上；源码未含 \r\n 格式，
#                                删除仅影响极少数 UPnP 客户端（如 Server-U）的
#                                SOAP/desc XML 格式兼容，UPnP 功能本身不受影响
# 删除过时 patch：编译可继续。若未来 ImmortalWRT 更新这些 patch 使其重新匹配，
# 本段自动失效（文件不存在）。
WRT_ROOT="$(cd "$FILES_DIR/.." && pwd)"
for stale_patch in 020-descr-filter-fix.patch 030-allow-private-fix.patch \
                   040-improve-logging.patch \
                   900-miniupnpd-format-xml-to-make-some-app-happy.patch; do
    if [ -f "$WRT_ROOT/feeds/packages/net/miniupnpd/patches/$stale_patch" ]; then
        rm -f "$WRT_ROOT/feeds/packages/net/miniupnpd/patches/$stale_patch"
        echo "[wg-site] 已移除过时 feeds patch: miniupnpd $stale_patch"
    fi
done
# ============================================================

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/wg_site_config.py" "$FILES_DIR" "$ROLE"
python3 "$SCRIPT_DIR/stage_ddns_go_service.py" "$FILES_DIR"
# No faketcp firewall exceptions when the unvalidated TCP carrier is disabled.
[ "${U2R_ENABLE:-0}" != 0 ] || rm -f "$FILES_DIR/etc/nftables.d/10-wg-site.nft"
