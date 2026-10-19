#!/usr/bin/env bash
# ============================================================
# ConfigureWgSiteToSite.sh — CI 编译期注入 WG site-to-site 站点配置 + ddns-go 完整配置
# 用法: ConfigureWgSiteToSite.sh <wrt/files目录> <ROLE:server|client>
# 环境变量（由 GitHub Actions secrets / job env 提供）：
#   WG_PRIV_KEY / WG_PEER_PUB / DDNS_HOST / DDNS_FALLBACK_IP
#   U2R_ENABLE(0|1) / U2R_KEY / WG_LISTEN_PORT / TUN_PREFIX
#   DDNSGO_AK / DDNSGO_SK / DDNSGO_DOMAIN（阿里云 AccessKey + 本机上报域名）
#   DDNSGO_IPV4_URL（可选，获取公网 IP 的接口，默认国内源）
# 域名约定：ss0112.jmsu.top（SS-01 WAN）/ cs0211.jmsu.top（CS-02 WAN）
#   DDNS_HOST = WG endpoint 用（client 填对端域名 ss0112.jmsu.top）
#   DDNSGO_DOMAIN = ddns-go 本机上报的域名（SS-01 填 ss0112，CS-02 填 cs0211）
# 说明：WG 私钥与阿里云 AK/SK 不进 Git；由仓库 secrets 注入。刷机通电即用，无需任何配置。
#   ddns-go 配置文件格式已按 jeessy2/ddns-go v6 源码确认（config/config.go）：
#   DnsConfig.Ipv4.Domains / DNS{Name,ID,Secret}；provider 名 "alidns"。
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

cat > "$FILES_DIR/etc/wg-site/site.conf" <<EOF
# 由 ConfigureWgSiteToSite.sh 生成（CI secrets 注入）；刷机首启由 99-wg-site-init 读取
ROLE=$ROLE
WG_PRIV_KEY=${WG_PRIV_KEY:-__GENERATE__}
WG_PEER_PUB=${WG_PEER_PUB:-}
WG_LISTEN_PORT=${WG_LISTEN_PORT:-51820}
TUN_PREFIX=${TUN_PREFIX:-10.99.0}
DDNS_HOST=${DDNS_HOST:-}
DDNS_FALLBACK_IP=${DDNS_FALLBACK_IP:-}
U2R_ENABLE=${U2R_ENABLE:-0}
U2R_PORT=${U2R_PORT:-28900}
U2R_KEY=${U2R_KEY:-udp2rawtestkey}
EOF
echo "[wg-site] site.conf 已写入 role=$ROLE"

# ddns-go 基础启用（uci 只控制启动参数；provider 明细在 yaml 文件）
mkdir -p "$FILES_DIR/etc/config"
cat > "$FILES_DIR/etc/config/ddns-go" <<'EOF'
config ddns-go 'config'
	option enabled '1'
	option logger '1'
	option port '9876'
	option time '300'
	option ctimes '5'
	option skipverify '0'
	option delay '0'
	option dns '223.5.5.5'
EOF
echo "[wg-site] ddns-go uci 基础配置已写入"

# ddns-go provider 完整配置（v6 yaml；刷机通电即用，无需 WebUI）
# 注入阿里云 AK/SK + 本机上报域名；未提供 AK/SK 时生成空 dnsconf（ddns-go 正常启动）
if [ -n "${DDNSGO_AK:-}" ] && [ -n "${DDNSGO_SK:-}" ]; then
    DDNSGO_DOMAIN="${DDNSGO_DOMAIN:-}"
    if [ -z "$DDNSGO_DOMAIN" ]; then
        echo "[wg-site] 警告: 提供了 AK/SK 但缺少 DDNSGO_DOMAIN，跳过 ddns-go yaml 注入" >&2
    else
        IPV4_URL="${DDNSGO_IPV4_URL:-https://4.ipw.cn,https://api.ipify.org}"
        mkdir -p "$FILES_DIR/etc/ddns-go"
        cat > "$FILES_DIR/etc/ddns-go/ddns-go-config.yaml" <<YAMLEOF
dnsconf:
  - name: "aliyun-wg-site"
    ipv4:
      enable: true
      gettype: "url"
      url: "${IPV4_URL}"
      netinterface: ""
      cmd: ""
      domains:
        - "${DDNSGO_DOMAIN}"
    ipv6:
      enable: false
      gettype: ""
      url: ""
      netinterface: ""
      cmd: ""
      ipv6reg: ""
      domains: []
    dns:
      name: "alidns"
      id: "${DDNSGO_AK}"
      secret: "${DDNSGO_SK}"
      extparam: ""
    ttl: "600"
    httpinterface: ""
webhook:
  webhookurl: ""
  webhookrequestbody: ""
  webhookheaders: ""
notallowwanaccess: true
lang: ""
YAMLEOF
        chmod 600 "$FILES_DIR/etc/ddns-go/ddns-go-config.yaml"
        echo "[wg-site] ddns-go yaml 已注入（provider=alidns, domain=$DDNSGO_DOMAIN）"
    fi
fi

echo "[wg-site] 完成。请确保仓库 git 记录以下文件为可执行："
echo "  files/etc/uci-defaults/99-wg-site-init  files/etc/init.d/wg-path-daemon  files/etc/init.d/wg-udp2raw-server"
exit 0
