#!/usr/bin/env python3
"""Read-only CPE status and offline API publication planning; never deploys."""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


class Invalid(ValueError):
    pass


def need(condition, message):
    if not condition:
        raise Invalid(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, "JSON 不允许重复字段")
        result[key] = value
    return result


def load_json(path):
    p = Path(path).expanduser()
    need(p.is_file() and p.stat().st_size <= 65536, "JSON 必须是至多 64 KiB 的普通文件")
    try:
        return json.loads(p.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError):
        raise Invalid("JSON 编码或格式无效") from None


def fields(obj, required, optional=(), label="对象"):
    need(isinstance(obj, dict), label + " 必须是对象")
    need(set(required) <= obj.keys(), label + " 缺少必填字段")
    need(obj.keys() <= set(required) | set(optional), label + " 包含不支持的字段；秘密应使用引用")


def integer(value, low, high, label):
    need(type(value) is int and low <= value <= high, label + " 超出支持范围")


def hostname(value, label="hostname"):
    need(isinstance(value, str) and value == value.lower() and len(value) <= 253, label + " 必须是小写精确域名")
    labels = value.split(".")
    need(len(labels) >= 2 and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", s) for s in labels), label + " 必须是精确 DNS 域名，不支持通配符")
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return value
    raise Invalid(label + " 不能使用 IP 地址")


def host(value):
    need(isinstance(value, str) and len(value) <= 253 and not value.startswith("-") and "%" not in value, "SSH host 无效")
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        return hostname(value, "SSH host")


def local_path(value, label):
    need(isinstance(value, str) and value and not any(c in value for c in "\n\r\x00"), label + " 无效")
    p = Path(value).expanduser()
    need(p.is_absolute(), label + " 必须是 Linux 绝对路径或 ~/ 路径")
    return str(p)


def key_ref(value):
    need(isinstance(value, str), "auth.key_ref 必须是本机引用")
    if value.startswith("env:"):
        need(re.fullmatch(r"[A-Z][A-Z0-9_]{0,127}", value[4:]) is not None, "env key 引用无效")
    elif value.startswith("file:"):
        local_path(value[5:], "file key 引用")
    else:
        raise Invalid("auth.key_ref 仅支持 env:变量名 或 file:绝对路径；不能填写实际 key")


def api_path(value, pattern=False):
    need(isinstance(value, str) and len(value) <= 256, "API path 无效")
    base = value[:-2] if pattern and value.endswith("/*") else value
    need(re.fullmatch(r"/[A-Za-z0-9._~:/-]+", base) is not None and base != "/", "API path 必须是显式子路径，可仅在末尾使用 /*")
    need("//" not in base and all(s not in (".", "..") for s in base.split("/")), "API path 不能含歧义或目录跳转")
    return value


def validate_service(s):
    fields(s, ("version", "enabled", "name", "public", "upstream", "auth", "streaming", "limits"), label="service")
    need(type(s["version"]) is int and s["version"] == 1, "service version 仅支持 1")
    need(type(s["enabled"]) is bool, "enabled 必须是布尔值")
    need(isinstance(s["name"], str) and re.fullmatch(r"[a-z][a-z0-9-]{0,47}", s["name"]), "name 无效")
    p = s["public"]
    fields(p, ("hostname", "routes", "cache"), label="public")
    hostname(p["hostname"])
    need(p["cache"] is False, "推理 API cache 必须关闭")
    routes = p["routes"]
    need(isinstance(routes, list) and 0 < len(routes) <= 32, "public.routes 必须是 1 至 32 个显式 method/path 配对")
    pairs = set()
    for route in routes:
        fields(route, ("method", "path"), label="route")
        need(isinstance(route["method"], str) and route["method"] in {"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"}, "route.method 必须是显式 HTTP 方法")
        api_path(route["path"], pattern=True)
        pair = (route["method"], route["path"])
        need(pair not in pairs, "public.routes 不能重复 method/path 配对")
        pairs.add(pair)
    u = s["upstream"]
    fields(u, ("address", "port", "scheme", "base_path"), label="upstream")
    need(isinstance(u["address"], str) and "%" not in u["address"], "upstream.address 不支持 scoped IPv6 或非字符串")
    try:
        address = ipaddress.ip_address(u["address"])
    except (ValueError, TypeError):
        raise Invalid("upstream.address 必须是明确批准的私网 IP，不解析主机名") from None
    private = (address.version == 4 and any(address in ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))) or (address.version == 6 and address in ipaddress.ip_network("fc00::/7"))
    need(private, "upstream.address 必须位于 RFC1918 或 ULA；其他拓扑需要显式设计")
    integer(u["port"], 1, 65535, "upstream.port")
    need(u["scheme"] in ("http", "https"), "upstream.scheme 仅支持 http/https")
    base = api_path(u["base_path"])
    need(not base.endswith("/"), "upstream.base_path 不能以 / 结尾")
    need(all(r["path"] == base or r["path"].startswith(base + "/") for r in routes), "公开路径必须位于所声明的 base_path；当前规划不重写路径")
    a = s["auth"]
    fields(a, ("mode", "key_ref"), label="auth")
    need(a["mode"] == "upstream-bearer", "当前 API 规划要求上游 Bearer 鉴权")
    key_ref(a["key_ref"])
    st = s["streaming"]
    fields(st, ("enabled", "keepalive_seconds", "first_token_timeout_seconds", "origin_read_timeout_seconds"), label="streaming")
    need(type(st["enabled"]) is bool, "streaming.enabled 必须是布尔值")
    integer(st["keepalive_seconds"], 1, 29, "streaming.keepalive_seconds")
    integer(st["first_token_timeout_seconds"], 1, 300, "streaming.first_token_timeout_seconds")
    integer(st["origin_read_timeout_seconds"], 1, 300, "streaming.origin_read_timeout_seconds")
    need(st["first_token_timeout_seconds"] <= st["origin_read_timeout_seconds"], "首 token 超时不能超过所规划的源站读取超时")
    lim = s["limits"]
    fields(lim, ("requests_per_minute", "concurrency", "max_body_bytes"), label="limits")
    integer(lim["requests_per_minute"], 1, 1000000, "limits.requests_per_minute")
    integer(lim["concurrency"], 1, 100000, "limits.concurrency")
    integer(lim["max_body_bytes"], 1, 500 * 1024 * 1024, "limits.max_body_bytes")
    return s


def validate_profile(p):
    fields(p, ("version", "ssh", "repositories", "public_context"), ("credential_refs",), "profile")
    need(type(p["version"]) is int and p["version"] == 1, "profile version 仅支持 1")
    s = p["ssh"]
    fields(s, ("host", "user", "identity_file", "known_hosts_file"), ("jump", "port"), "ssh")
    host(s["host"])
    need(isinstance(s["user"], str) and re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", s["user"]), "SSH user 无效")
    local_path(s["identity_file"], "identity_file")
    local_path(s["known_hosts_file"], "known_hosts_file")
    integer(s.get("port", 22), 1, 65535, "ssh.port")
    if "jump" in s:
        j = s["jump"]
        fields(j, ("host", "user", "known_hosts_file"), ("port",), "jump")
        host(j["host"])
        need(isinstance(j["user"], str) and re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", j["user"]), "jump user 无效")
        local_path(j["known_hosts_file"], "jump known_hosts_file")
        integer(j.get("port", 22), 1, 65535, "jump.port")
    fields(p["repositories"], ("firmware", "backup"), label="repositories")
    for v in p["repositories"].values():
        local_path(v, "repository")
    c = p["public_context"]
    fields(c, ("esa_zone", "origin_hostname", "origin_port", "current_udx_hostname"), label="public_context")
    for k in ("esa_zone", "origin_hostname", "current_udx_hostname"):
        hostname(c[k], k)
    integer(c["origin_port"], 1, 65535, "origin_port")
    if "credential_refs" in p:
        refs = p["credential_refs"]
        need(isinstance(refs, dict) and all(isinstance(k, str) and re.fullmatch(r"[a-z][a-z0-9_-]{0,47}", k) for k in refs), "credential_refs 字段名无效")
        for v in refs.values():
            need(isinstance(v, str) and len(v) <= 1024, "credential_refs 必须是引用，不能存秘密")
            if v.startswith("repository:"):
                need(v[11:] in p["repositories"], "repository 凭据引用无效")
            elif v.startswith("remote:"):
                local_path(v[7:], "remote 凭据引用")
            else:
                key_ref(v)
    return p


REMOTE_STATUS = r'''set -f
kv() { value=$(printf '%s' "$2" | tr '\r\n\t' ' ' | cut -c1-200); printf '%s\t%s\n' "$1" "$value"; }
jkv() { kv "$1" "$(jsonfilter -i "$2" -e "$3" 2>/dev/null)"; }
kv schema cpe5g-read-only-v1
kv hostname "$(uci -q get system.@system[0].hostname)"
kv kernel "$(uname -r)"
board=$(ubus -S call system board 2>/dev/null)
kv release "$(printf '%s' "$board" | jsonfilter -e '@.release.version' 2>/dev/null)"
kv model "$(printf '%s' "$board" | jsonfilter -e '@.model' 2>/dev/null)"
kv wan_protocol "$(uci -q get network.wan.proto)"
kv wan_ipv6_option "$(uci -q get network.wan.ipv6)"
kv wan6_section "$(uci -q get network.wan6)"
kv wan6_disabled "$(uci -q get network.wan6.disabled)"
kv wan6_auto "$(uci -q get network.wan6.auto)"
kv cpe6_section "$(uci -q get network.cpe6)"
wan=$(ubus -S call network.interface.wan status 2>/dev/null)
kv wan_up "$(printf '%s' "$wan" | jsonfilter -e '@.up' 2>/dev/null)"
kv wan_device "$(printf '%s' "$wan" | jsonfilter -e '@.l3_device' 2>/dev/null)"
if command -v mwan3 >/dev/null 2>&1; then
  mwan3 interfaces 2>/dev/null | sed -n '/^[[:space:]]*interface \(wan\|5G\) is /p' | while IFS= read -r line; do kv mwan_interface "$line"; done
fi
s=/var/run/cpe5g-ipv6/status.json
jkv sim_phase "$s" '@.phase'
jkv sim_detail "$s" '@.detail'
jkv sim_address "$s" '@.address'
jkv sim_public_origin_open "$s" '@.public_origin_open'
jkv sim_updated "$s" '@.updated'
jkv quota_enabled "$s" '@.quota.enabled'
jkv quota_limit "$s" '@.quota.limit'
jkv quota_used "$s" '@.quota.used'
jkv quota_blocked "$s" '@.quota.blocked'
jkv quota_source "$s" '@.quota.source'
jkv quota_vendor_used "$s" '@.quota.vendor_used'
r=/var/run/cpe5g-lucky/public-ready.json
jkv origin_ready "$r" '@.ready'
jkv origin_hostname "$r" '@.hostname'
jkv origin_port "$r" '@.port'
jkv origin_source_policy "$r" '@.source_policy'
jkv origin_updated "$r" '@.updated'
jkv origin_mtls_verified "$r" '@.mtls_verified'
jkv origin_header_verified "$r" '@.origin_header_verified'
'''

# Validate only whitelisted image fields; a local version alias is not proof of a pin.
REMOTE_IMAGE_PROJECTION = r'''api_image_projection() {
 row=$1
 old_ifs=$IFS; IFS='|'; set -- $row; IFS=$old_ifs
 platform=${1:-}; if [ "$#" -gt 0 ]; then shift; fi
 verified=''
 if [ -n "$platform" ]; then
  verified=false
  if [ "$platform" = 'linux/arm64' ]; then
   for ref in "$@"; do
    case "$ref" in
     docker.io/eceasy/cli-proxy-api@sha256:913f5db831ef5919ff63edb5f818df7dd8c821a18d36a92145449a8d8a1b787d|eceasy/cli-proxy-api@sha256:913f5db831ef5919ff63edb5f818df7dd8c821a18d36a92145449a8d8a1b787d) verified=true ;;
    esac
   done
  fi
 fi
 kv api_image_platform "$platform"
 kv api_image_manifest_verified "$verified"
}
'''

# Fixed local resources only: never config, credentials, OAuth state or logs.
REMOTE_API_STATUS = REMOTE_STATUS + REMOTE_IMAGE_PROJECTION + r'''kv api_service_enabled "$(uci -q get cpe_api.main.enabled)"
kv api_init_enabled "$(if [ -x /etc/init.d/cpe-api ]; then /etc/init.d/cpe-api enabled >/dev/null 2>&1 && printf true || printf false; fi)"
kv api_disabled_marker "$(if [ -e /data/compose/cpe-api/disabled ]; then printf true; else printf false; fi)"
kv api_containerd_socket "$(if [ -S /run/containerd/containerd.sock ]; then printf true; else printf false; fi)"
kv api_nerdctl_present "$(if [ -x /usr/bin/nerdctl ]; then printf true; else printf false; fi)"
if [ -x /usr/bin/nerdctl ]; then
 kv api_nerdctl_version "$(timeout 3 /usr/bin/nerdctl --version 2>/dev/null)"
 if [ -S /run/containerd/containerd.sock ]; then
  row=$(timeout 5 /usr/bin/nerdctl --address /run/containerd/containerd.sock --namespace default image inspect --format '{{.Os}}/{{.Architecture}}|{{range .RepoDigests}}{{.}}|{{end}}' docker.io/eceasy/cli-proxy-api:v8.0.13 2>/dev/null)
  api_image_projection "$row"
  row=$(timeout 5 /usr/bin/nerdctl --address /run/containerd/containerd.sock --namespace default inspect --format '{{.State.Status}}|{{.State.Running}}|{{.HostConfig.Memory}}|{{.HostConfig.CpuQuota}}|{{.HostConfig.CpuPeriod}}|{{.HostConfig.PidsLimit}}' cpe-api 2>/dev/null)
  kv api_container_fields "$row"
  # nerdctl stats reports zero cgroups on this device. Read only this container's
  # kernel cgroup-v2 counters, located through its verified numeric PID.
  pid=$(timeout 5 /usr/bin/nerdctl --address /run/containerd/containerd.sock --namespace default inspect --format '{{.State.Pid}}' cpe-api 2>/dev/null)
  case "$pid" in ''|0|*[!0-9]*) ;; *)
   cg=$(sed -n 's/^0:://p' "/proc/$pid/cgroup" 2>/dev/null)
   case "$cg" in /*)
    case "$cg" in *..*|*' '*|*'	'*) ;; *)
     kv api_resource_source cgroup-v2
     kv api_memory_current "$(cat "/sys/fs/cgroup$cg/memory.current" 2>/dev/null)"
     kv api_memory_max "$(cat "/sys/fs/cgroup$cg/memory.max" 2>/dev/null)"
     kv api_pids "$(cat "/sys/fs/cgroup$cg/pids.current" 2>/dev/null)"
     kv api_cpu_usage_usec "$(awk '/^usage_usec / {print $2}' "/sys/fs/cgroup$cg/cpu.stat" 2>/dev/null)"
    ;; esac
   ;; esac
  ;; esac
 fi
fi
r=/var/run/cpe5g-lucky/api-ready.json
jkv api_ready "$r" '@.ready'
jkv api_approved_host "$r" '@.approved_host'
jkv api_shared_gate "$r" '@.shared_gate'
jkv api_updated "$r" '@.updated'
'''


def ssh_argv(profile):
    s = profile["ssh"]
    key = local_path(s["identity_file"], "identity_file")
    known = local_path(s["known_hosts_file"], "known_hosts_file")
    for path in (key, known):
        need(Path(path).is_file(), "维护密钥或已验证 known_hosts 文件缺失")
    common = ["ssh", "-F", "/dev/null", "-i", key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes", "-o", "GlobalKnownHostsFile=/dev/null"]
    argv = common + ["-o", "UserKnownHostsFile=" + shlex.quote(known), "-p", str(s.get("port", 22))]
    if "jump" in s:
        j = s["jump"]
        jknown = local_path(j["known_hosts_file"], "jump known_hosts_file")
        need(Path(jknown).is_file(), "跳板已验证 known_hosts 文件缺失")
        proxy = common + ["-o", "UserKnownHostsFile=" + shlex.quote(jknown), "-p", str(j.get("port", 22)), "-W", "%h:%p", j["user"] + "@" + j["host"]]
        argv += ["-o", "ProxyCommand=" + shlex.join(proxy)]
    return argv + [s["user"] + "@" + s["host"], "sh", "-s"]


def container_projection(row):
    if not row:
        return {}
    parts = row.split("|")
    if len(parts) not in (6, 9):
        return {}
    fields = parts[-6:]
    if len(parts) == 9 and parts[:3] != fields[:3]:
        return {}
    if fields[0] not in ("created", "running", "paused", "restarting", "removing", "exited", "dead") or fields[1] not in ("true", "false"):
        return {}
    if any(re.fullmatch(r"[0-9]{1,20}", value) is None for value in fields[2:]):
        return {}
    return dict(zip(("api_container_state", "api_container_running", "api_memory_limit", "api_cpu_quota", "api_cpu_period", "api_pids_limit"), fields))


def status_projection(raw, include_api=False):
    values = {}
    interfaces = {}
    for line in raw.splitlines():
        k, sep, v = line.partition("\t")
        if not sep:
            continue
        if k == "mwan_interface":
            m = re.match(r"\s*interface (wan|5G) is (online|offline|unknown|disabled)\b", v)
            if m:
                interfaces[m.group(1)] = m.group(2)
        elif len(v) <= 200:
            values[k] = v or None

    need(values.get("schema") == "cpe5g-read-only-v1", "远端未返回预期的只读状态结构")
    if include_api and "api_container_fields" in values:
        values.update(container_projection(values["api_container_fields"]))

    def text(key):
        return values.get(key)

    def boolean(key):
        return {"true": True, "false": False, "1": True, "0": False}.get(values.get(key))

    def number(key):
        value = values.get(key)
        return int(value) if value and re.fullmatch(r"[0-9]{1,20}", value) else None

    result = {
        "mode": "read-only",
        "system": {k: text(k) for k in ("hostname", "kernel", "release", "model")},
        "wan": {"protocol": text("wan_protocol"), "up": boolean("wan_up"), "device": text("wan_device"), "ipv6_option": text("wan_ipv6_option"), "wan6_present": text("wan6_section") is not None, "wan6_disabled": boolean("wan6_disabled"), "wan6_auto": boolean("wan6_auto"), "cpe6_present": text("cpe6_section") is not None},
        "mwan3_interfaces": interfaces,
        "sim": {"phase": text("sim_phase"), "detail": text("sim_detail"), "address": text("sim_address"), "public_origin_open": boolean("sim_public_origin_open"), "updated_ms": number("sim_updated"), "quota": {"enabled": boolean("quota_enabled"), "limit_bytes": number("quota_limit"), "used_bytes": number("quota_used"), "blocked": boolean("quota_blocked"), "source": "emmc-cellular-counters" if text("quota_source") == "emmc-cellular-counters" else None, "vendor_used_bytes": number("quota_vendor_used")}},
        "udx_origin": {"ready": boolean("origin_ready"), "hostname": text("origin_hostname"), "port": number("origin_port"), "source_policy": text("origin_source_policy"), "updated_ms": number("origin_updated"), "mtls_verified": boolean("origin_mtls_verified"), "origin_header_verified": boolean("origin_header_verified")},
        "api_publication": {"not_verified": True, "note": "现有 readiness 仅针对 UDX；status 不验证或部署新的 API"},
    }

    if include_api:
        # Readiness proves local route/auth rejection checks only, not OAuth or public inference.
        result["api"] = {
            "service_enabled": boolean("api_service_enabled"),
            "init_enabled": boolean("api_init_enabled"),
            "disabled_marker": boolean("api_disabled_marker"),
            "runtime": {"binary_present": boolean("api_nerdctl_present"), "version": text("api_nerdctl_version"), "socket_present": boolean("api_containerd_socket")},
            "image": {"pinned_version": "8.0.13", "local_alias": "docker.io/eceasy/cli-proxy-api:v8.0.13", "local_platform": text("api_image_platform"), "manifest_verified": boolean("api_image_manifest_verified")},
            "container": {"state": text("api_container_state"), "running": boolean("api_container_running")},
            "limits": {"memory_bytes": number("api_memory_limit"), "cpu_quota": number("api_cpu_quota"), "cpu_period": number("api_cpu_period"), "pids": number("api_pids_limit")},
            "resources": {"source": text("api_resource_source"), "cpu_usage_usec": number("api_cpu_usage_usec"), "memory_current_bytes": number("api_memory_current"), "memory_max_bytes": number("api_memory_max"), "pids": number("api_pids")},
            "origin": {"ready": boolean("api_ready"), "approved_host": text("api_approved_host"), "shared_gate": text("api_shared_gate"), "updated_ms": number("api_updated")},
            "public_inference_verified": False,
        }
        result["api_publication"]["note"] = "api-ready 为独立本地检查结果，但依赖 UDX 共享 gate；不证明公网调用或可用模型"
    return result


def read_status(profile, include_api=False):
    try:
        result = subprocess.run(ssh_argv(profile), input=REMOTE_API_STATUS if include_api else REMOTE_STATUS, text=True, capture_output=True, timeout=35, check=False)
    except subprocess.TimeoutExpired:
        raise Invalid("只读 SSH 状态检查超时；未写设备") from None
    need(result.returncode == 0, "只读 SSH 失败：检查现有密钥、主机指纹、跳板和连通性；不回显远端原始输出")
    need(len(result.stdout) <= 16384, "远端状态输出异常，已拒绝显示")
    return status_projection(result.stdout, include_api=include_api)


def service_plan(service, profile):
    c = profile["public_context"]
    name = service["public"]["hostname"]
    need(name not in (c["current_udx_hostname"], c["origin_hostname"], c["esa_zone"]), "API Host 与现有 UDX、源站或站点 apex 冲突")
    in_zone = name.endswith("." + c["esa_zone"])
    u = service["upstream"]
    address = "[" + u["address"] + "]" if ":" in u["address"] else u["address"]
    return {
        "mode": "planning-only",
        "deployment_supported_by_this_cli": False,
        "device_or_cloud_modified": False,
        "enabled_in_spec": service["enabled"],
        "service": service["name"],
        "client_base_url": "https://" + name + u["base_path"],
        "upstream_base_url": u["scheme"] + "://" + address + ":" + str(u["port"]) + u["base_path"],
        "origin": {"hostname": c["origin_hostname"], "port": c["origin_port"], "reuse_existing_esa_zone": in_zone, "requires_other_site_assessment": not in_zone},
        "access": service["public"],
        "application_auth": service["auth"],
        "streaming": service["streaming"],
        "limits": service["limits"],
        "required_before_publication": [
            "核对用户批准的端点与 Host；示例 enabled=false 不构成发布授权",
            "核对已实现的固定 CPE API registry 与目标固件；其他端点仍需按批准范围设计",
            "保留 UDX v1；隔离 API 健康结果并处理共享 readiness/nft gate",
            "落实私有 CI 文件白名单、validator、加密注入、保留配置恢复与迁移",
            "配置新 Host 的 ESA HTTPS/mTLS/header、HTTPS 跳转、无普通/POST 缓存与 API 规则",
            "在上游网关核实 Bearer 鉴权、模型/预算/并发与版本对应的 SSE keepalive",
            "少量真实公网请求验收 JSON、SSE、长流、取消、拒绝与 Host 隔离",
        ],
        "note": "此 JSON 是离线规划；固定 CPA 注册格式不同，不直接安装；代码实现不等于实机部署",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    default_profile = os.environ.get("CPE_5G_PROFILE", "~/.config/cpe-5g/profile.json")
    status = sub.add_parser("status", help="只读 SSH 白名单状态")
    status.add_argument("--profile", default=default_profile)
    api_status = sub.add_parser("api-status", help="只读 SSH：固定 CPE API 运行时、容器资源及独立 readiness")
    api_status.add_argument("--profile", default=default_profile)
    validate = sub.add_parser("validate", help="离线校验 API 规划规格，不部署")
    validate.add_argument("--service", required=True)
    plan = sub.add_parser("plan", help="离线生成部署计划，不连接设备或云")
    plan.add_argument("--profile", default=default_profile)
    plan.add_argument("--service", required=True)
    args = parser.parse_args()
    try:
        if args.command in ("status", "api-status"):
            result = read_status(validate_profile(load_json(args.profile)), include_api=args.command == "api-status")
        else:
            service = validate_service(load_json(args.service))
            result = {"valid": True, "name": service["name"], "enabled_in_spec": service["enabled"], "deployed": False} if args.command == "validate" else service_plan(service, validate_profile(load_json(args.profile)))
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (Invalid, OSError, TypeError, ValueError):
        exc = sys.exc_info()[1]
        message = str(exc) if isinstance(exc, Invalid) else "输入或本机环境无效；未执行部署"
        print(json.dumps({"error": message, "device_or_cloud_modified": False}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
