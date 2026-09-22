#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$ROOT_DIR/Scripts/generate_samba_credentials.sh"
DEFAULT_USER="$ROOT_DIR/files/etc/uci-defaults/96-samba-default-user"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
ENV_INIT="$ROOT_DIR/Scripts/ci_init_environment.sh"

bash -n "$GENERATOR"
sh -n "$DEFAULT_USER"
grep -Eq 'aptx_retry install .* samba( | \\)$' "$ENV_INIT"
grep -Fq 'SAMBA_DEFAULT_USER:-smb' "$GENERATOR"
grep -Fq 'SAMBA_DEFAULT_PASSWORD:-}' "$GENERATOR"
grep -Fq 'SAMBA_MACHINE_SID:-S-1-5-21-' "$GENERATOR"
grep -Fq -- '--with-privatedir=/etc/samba' "$GENERATOR"
grep -Fq 'passdb backend = tdbsam' "$GENERATOR"
grep -Fq 'passdb.tdb secrets.tdb' "$GENERATOR"
grep -Fq 'pdbedit -s "$config" -L "$SAMBA_USER"' "$GENERATOR"
grep -Fq 'Scripts/generate_samba_credentials.sh" "$GITHUB_WORKSPACE/wrt"' "$CORE"
grep -Fq 'SAMBA_DEFAULT_PASSWORD:' "$CORE"
grep -Fq '96-samba-default-user' "$CORE"
grep -Fq '"./Config/$WRT_CONFIG.txt" ./Config/GENERAL.txt' "$CORE"
grep -Fq 'samba-default-credential' "$ROOT_DIR/Scripts/PrivateFirmwareGuard.sh"
grep -Fq 'ROM_DIR="${SAMBA_ROM_DIR:-/rom/etc/samba}"' "$DEFAULT_USER"
grep -Fq 'existing legacy smbpasswd database detected' "$DEFAULT_USER"
grep -Fq 'existing custom passdb.tdb detected' "$DEFAULT_USER"
grep -Fq "stat -c '%a:%u:%g'" "$DEFAULT_USER"

if grep -Eq 'SAMBA_DEFAULT_PASSWORD:-[^}]+' "$GENERATOR"; then
	echo "Samba password must not have a source-code default" >&2
	exit 1
fi

root_command=()
can_run_root=1
if [ "$(id -u)" -ne 0 ]; then
	if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
		root_command=(sudo -n)
	else
		can_run_root=0
	fi
fi

run_root() {
	"${root_command[@]}" "$@"
}

if [ "$can_run_root" -eq 1 ]; then
	(
		runtime_fixture="$(mktemp -d)"
		trap 'run_root rm -rf "$runtime_fixture"' EXIT

		new_runtime_case() {
			case_dir="$runtime_fixture/$1"
			mkdir -p "$case_dir/live" "$case_dir/rom"
			printf '%s\n' 'root:x:0:0:root:/root:/bin/ash' >"$case_dir/passwd"
			printf '%s\n' 'firmware-passdb-fixture' >"$case_dir/rom/passdb.tdb"
			printf '%s\n' 'firmware-secrets-fixture' >"$case_dir/rom/secrets.tdb"
			cat >"$case_dir/smb.conf" <<'EOF'
[global]
security = user
server role = standalone server
passdb backend = tdbsam
private dir = /etc/samba
EOF
			cp "$case_dir/smb.conf" "$case_dir/rom/smb.conf.template"
			cp "$case_dir/smb.conf" "$case_dir/live/smb.conf.template"
			ln -s /var/etc/smb.conf "$case_dir/live/smb.conf"
			: >"$case_dir/samba4"
			printf '%s\n' "$case_dir"
		}

		run_runtime_case() {
			case_dir="$1"
			mv_command="${2:-mv}"
			fail_rollback="${3:-0}"
			testparm_command="${4:-testparm}"
			run_root env \
				SAMBA_PASSWD_FILE="$case_dir/passwd" \
				SAMBA_LIVE_DIR="$case_dir/live" \
				SAMBA_ROM_DIR="$case_dir/rom" \
				SAMBA_CONFIG_FILE="$case_dir/smb.conf" \
				SAMBA_UCI_CONFIG="$case_dir/samba4" \
				SAMBA_AD_DAEMON="$case_dir/no-ad-daemon" \
				SAMBA_LOGGER=: \
				SAMBA_MV_COMMAND="$mv_command" \
				SAMBA_TEST_FAIL_ROLLBACK="$fail_rollback" \
				SAMBA_TESTPARM="$testparm_command" \
				sh "$DEFAULT_USER"
		}

		run_stock_case() {
			case_dir="$1"
			run_root env \
				SAMBA_PASSWD_FILE="$case_dir/passwd" \
				SAMBA_LIVE_DIR="$case_dir/live" \
				SAMBA_ROM_DIR="$case_dir/rom" \
				SAMBA_UCI_CONFIG="$case_dir/samba4" \
				SAMBA_AD_DAEMON="$case_dir/no-ad-daemon" \
				SAMBA_LOGGER=: \
				sh "$DEFAULT_USER"
		}

		make_failing_mv() {
			wrapper="$1"
			cat >"$wrapper" <<'EOF'
#!/bin/sh
source_file="$2"
case "$source_file" in
	*/passdb.tdb.new) exit 1 ;;
	*/secrets.tdb.original.restore)
		[ "${SAMBA_TEST_FAIL_ROLLBACK:-0}" -eq 1 ] && exit 1
		;;
esac
exec /bin/mv "$@"
EOF
			chmod 0755 "$wrapper"
		}

		make_partially_failing_testparm() {
			wrapper="$1"
			cat >"$wrapper" <<'EOF'
#!/bin/sh
parameter=''
for argument in "$@"; do
	case "$argument" in
		--parameter-name=*) parameter="${argument#--parameter-name=}" ;;
	esac
done
case "$parameter" in
	'config backend') printf '%s\n' file ;;
	'passdb backend') printf '%s\n' tdbsam ;;
	'private dir') printf '%s\n' /etc/samba ;;
	security) printf '%s\n' USER ;;
	'server role') printf '%s\n' 'standalone server' ;;
	realm) printf '\n' ;;
	'domain logons') printf '%s\n' No ;;
esac
exit 1
EOF
			chmod 0755 "$wrapper"
		}

		# A legacy sysupgrade exposes the new ROM passdb through overlayfs while
		# retaining an old secrets.tdb and an empty smbpasswd user database.
		live_case="$(new_runtime_case live-upgrade)"
		cp "$live_case/rom/passdb.tdb" "$live_case/live/passdb.tdb"
		printf '%s\n' 'legacy-machine-secrets' >"$live_case/live/secrets.tdb"
		: >"$live_case/live/smbpasswd"
		run_runtime_case "$live_case" 2>"$live_case/run.log"
		run_root cmp -s "$live_case/live/passdb.tdb" "$live_case/rom/passdb.tdb"
		run_root cmp -s "$live_case/live/secrets.tdb" "$live_case/rom/secrets.tdb"
		[ "$(run_root stat -c '%a:%u:%g' "$live_case/live/passdb.tdb")" = '600:0:0' ]
		[ "$(run_root stat -c '%a:%u:%g' "$live_case/live/secrets.tdb")" = '600:0:0' ]
		grep -Eq '^smb:x:1000:65534:' "$live_case/passwd"
		live_recovery_stage="$(find "$live_case/live" -maxdepth 1 -type d -name '.firmware-samba-pair.*' -print -quit)"
		[ -n "$live_recovery_stage" ]
		[ "$(run_root stat -c '%a' "$live_recovery_stage")" = 700 ]
		run_root grep -Fxq 'legacy-machine-secrets' "$live_recovery_stage/secrets.tdb.original"
		grep -Fq "retained pre-migration recovery material at $live_recovery_stage" "$live_case/run.log"

		# Exercise the production stock symlink/template path, not only the
		# explicit config injection used by the remaining unit fixtures.
		stock_case="$(new_runtime_case stock-template-upgrade)"
		cp "$stock_case/rom/passdb.tdb" "$stock_case/live/passdb.tdb"
		printf '%s\n' 'stock-legacy-secrets' >"$stock_case/live/secrets.tdb"
		: >"$stock_case/live/smbpasswd"
		run_stock_case "$stock_case" 2>"$stock_case/run.log"
		run_root cmp -s "$stock_case/live/passdb.tdb" "$stock_case/rom/passdb.tdb"
		run_root cmp -s "$stock_case/live/secrets.tdb" "$stock_case/rom/secrets.tdb"
		grep -q '^smb:' "$stock_case/passwd"

		# The same safe path also applies when no passdb is visible at all.
		missing_passdb_case="$(new_runtime_case no-live-passdb)"
		run_runtime_case "$missing_passdb_case" 2>"$missing_passdb_case/run.log"
		run_root cmp -s "$missing_passdb_case/live/passdb.tdb" "$missing_passdb_case/rom/passdb.tdb"
		run_root cmp -s "$missing_passdb_case/live/secrets.tdb" "$missing_passdb_case/rom/secrets.tdb"

		# A second run must not replace or rewrite an already matching pair.
		passdb_inode="$(run_root stat -c '%i' "$live_case/live/passdb.tdb")"
		secrets_inode="$(run_root stat -c '%i' "$live_case/live/secrets.tdb")"
		run_runtime_case "$live_case" 2>>"$live_case/run.log"
		[ "$(run_root stat -c '%i' "$live_case/live/passdb.tdb")" = "$passdb_inode" ]
		[ "$(run_root stat -c '%i' "$live_case/live/secrets.tdb")" = "$secrets_inode" ]

		# If the second publish fails but rollback succeeds, old secrets are
		# restored and no sensitive staging material is left behind.
		failing_mv="$runtime_fixture/failing-mv"
		make_failing_mv "$failing_mv"
		rollback_case="$(new_runtime_case publish-failure-rollback-ok)"
		cp "$rollback_case/rom/passdb.tdb" "$rollback_case/live/passdb.tdb"
		printf '%s\n' 'legacy-machine-secrets' >"$rollback_case/live/secrets.tdb"
		: >"$rollback_case/live/smbpasswd"
		if run_runtime_case "$rollback_case" "$failing_mv" 0 2>"$rollback_case/run.log"; then
			echo "second Samba database publish failure must request a retry" >&2
			exit 1
		fi
		run_root cmp -s "$rollback_case/live/passdb.tdb" "$rollback_case/rom/passdb.tdb"
		grep -Fxq 'legacy-machine-secrets' "$rollback_case/live/secrets.tdb"
		[ -z "$(find "$rollback_case/live" -maxdepth 1 -type d -name '.firmware-samba-pair.*' -print -quit)" ]

		# If that rollback also fails, retain the 0700 directory and both
		# originals so an operator still has recovery material.
		retained_case="$(new_runtime_case publish-and-rollback-failure)"
		cp "$retained_case/rom/passdb.tdb" "$retained_case/live/passdb.tdb"
		printf '%s\n' 'legacy-machine-secrets' >"$retained_case/live/secrets.tdb"
		: >"$retained_case/live/smbpasswd"
		if run_runtime_case "$retained_case" "$failing_mv" 1 2>"$retained_case/run.log"; then
			echo "failed Samba rollback must request a retry" >&2
			exit 1
		fi
		retained_stage="$(find "$retained_case/live" -maxdepth 1 -type d -name '.firmware-samba-pair.*' -print -quit)"
		[ -n "$retained_stage" ]
		[ "$(run_root stat -c '%a' "$retained_stage")" = 700 ]
		run_root test -f "$retained_stage/passdb.tdb.original"
		run_root test -f "$retained_stage/secrets.tdb.original"
		[ "$(run_root stat -c '%a' "$retained_stage/passdb.tdb.original")" = 600 ]
		[ "$(run_root stat -c '%a' "$retained_stage/secrets.tdb.original")" = 600 ]
		grep -Fq "rollback incomplete; retained recovery material at $retained_stage" "$retained_case/run.log"

		# A legacy user database under the new tdbsam backend is preserved but
		# requests manual migration instead of pretending those users still work.
		legacy_case="$(new_runtime_case legacy-users)"
		printf '%s\n' 'configured-legacy-user' >"$legacy_case/live/smbpasswd"
		printf '%s\n' 'legacy-machine-secrets' >"$legacy_case/live/secrets.tdb"
		run_runtime_case "$legacy_case" 2>"$legacy_case/run.log"
		[ ! -e "$legacy_case/live/passdb.tdb" ]
		grep -Fxq 'legacy-machine-secrets' "$legacy_case/live/secrets.tdb"
		! grep -q '^smb:' "$legacy_case/passwd"
		grep -Fq 'effective backend is tdbsam' "$legacy_case/run.log"

		# If the effective backend really remains standalone smbpasswd, preserving
		# the legacy database is a completed, safe policy skip.
		legacy_backend_case="$(new_runtime_case legacy-smbpasswd-backend)"
		sed -i 's/passdb backend = tdbsam/passdb backend = smbpasswd/' "$legacy_backend_case/smb.conf"
		printf '%s\n' 'configured-legacy-user' >"$legacy_backend_case/live/smbpasswd"
		printf '%s\n' 'legacy-machine-secrets' >"$legacy_backend_case/live/secrets.tdb"
		run_runtime_case "$legacy_backend_case" 2>"$legacy_backend_case/run.log"
		grep -Fxq 'configured-legacy-user' "$legacy_backend_case/live/smbpasswd"
		grep -Fxq 'legacy-machine-secrets' "$legacy_backend_case/live/secrets.tdb"
		! grep -q '^smb:' "$legacy_backend_case/passwd"
		grep -Fq 'effective standalone backend remains smbpasswd' "$legacy_backend_case/run.log"

		# Never replace an existing tdbsam user database that differs from ROM.
		custom_case="$(new_runtime_case custom-passdb)"
		: >"$custom_case/live/smbpasswd"
		printf '%s\n' 'administrator-passdb' >"$custom_case/live/passdb.tdb"
		printf '%s\n' 'administrator-secrets' >"$custom_case/live/secrets.tdb"
		if ! run_runtime_case "$custom_case" 2>"$custom_case/run.log"; then
			echo "custom passdb.tdb must be a successful policy skip" >&2
			exit 1
		fi
		grep -Fxq 'administrator-passdb' "$custom_case/live/passdb.tdb"
		grep -Fxq 'administrator-secrets' "$custom_case/live/secrets.tdb"
		! grep -q '^smb:' "$custom_case/passwd"
		grep -Fq 'existing custom passdb.tdb detected' "$custom_case/run.log"

		# A custom backend is not eligible for firmware database replacement.
		custom_backend_case="$(new_runtime_case custom-backend)"
		sed -i 's/passdb backend = tdbsam/passdb backend = ldapsam/' "$custom_backend_case/smb.conf"
		printf '%s\n' 'custom-backend-secrets' >"$custom_backend_case/live/secrets.tdb"
		run_runtime_case "$custom_backend_case" 2>"$custom_backend_case/run.log"
		[ ! -e "$custom_backend_case/live/passdb.tdb" ]
		grep -Fxq 'custom-backend-secrets' "$custom_backend_case/live/secrets.tdb"
		! grep -q '^smb:' "$custom_backend_case/passwd"
		grep -Fq 'custom Samba passdb backend detected' "$custom_backend_case/run.log"

		# Domain/member configuration may use secrets.tdb for trust state and must
		# never be overwritten by the standalone firmware pair.
		domain_case="$(new_runtime_case domain-member)"
		sed -i 's/security = user/security = ads/; s/server role = standalone server/server role = member server/' "$domain_case/smb.conf"
		printf '%s\n' 'realm = EXAMPLE.TEST' 'workgroup = EXAMPLE' >>"$domain_case/smb.conf"
		printf '%s\n' 'domain-trust-secrets' >"$domain_case/live/secrets.tdb"
		run_runtime_case "$domain_case" 2>"$domain_case/run.log"
		[ ! -e "$domain_case/live/passdb.tdb" ]
		grep -Fxq 'domain-trust-secrets' "$domain_case/live/secrets.tdb"
		! grep -q '^smb:' "$domain_case/passwd"
		grep -Fq 'domain/member/DC Samba role or security detected' "$domain_case/run.log"

		role_case="$(new_runtime_case member-role)"
		sed -i 's/server role = standalone server/server role = member server/' "$role_case/smb.conf"
		printf '%s\n' 'member-role-secrets' >"$role_case/live/secrets.tdb"
		run_runtime_case "$role_case" 2>"$role_case/run.log"
		grep -Fxq 'member-role-secrets' "$role_case/live/secrets.tdb"
		! grep -q '^smb:' "$role_case/passwd"
		grep -Fq 'domain/member/DC Samba role or security detected' "$role_case/run.log"

		registry_case="$(new_runtime_case registry-config-backend)"
		printf '%s\n' 'config backend = registry' >>"$registry_case/smb.conf"
		printf '%s\n' 'registry-backend-secrets' >"$registry_case/live/secrets.tdb"
		run_runtime_case "$registry_case" 2>"$registry_case/run.log"
		grep -Fxq 'registry-backend-secrets' "$registry_case/live/secrets.tdb"
		! grep -q '^smb:' "$registry_case/passwd"
		grep -Fq 'custom Samba config backend or private directory detected' "$registry_case/run.log"

		private_dir_case="$(new_runtime_case custom-private-dir)"
		sed -i 's|private dir = /etc/samba|private dir = /srv/custom-samba|' "$private_dir_case/smb.conf"
		printf '%s\n' 'custom-private-secrets' >"$private_dir_case/live/secrets.tdb"
		run_runtime_case "$private_dir_case" 2>"$private_dir_case/run.log"
		grep -Fxq 'custom-private-secrets' "$private_dir_case/live/secrets.tdb"
		! grep -q '^smb:' "$private_dir_case/passwd"
		grep -Fq 'custom Samba config backend or private directory detected' "$private_dir_case/run.log"

		domain_logons_case="$(new_runtime_case domain-logons-true)"
		printf '%s\n' 'domain   logons = true' >>"$domain_logons_case/smb.conf"
		printf '%s\n' 'domain-logons-secrets' >"$domain_logons_case/live/secrets.tdb"
		run_runtime_case "$domain_logons_case" 2>"$domain_logons_case/run.log"
		grep -Fxq 'domain-logons-secrets' "$domain_logons_case/live/secrets.tdb"
		! grep -q '^smb:' "$domain_logons_case/passwd"
		grep -Fq 'domain/member/DC Samba role or security detected' "$domain_logons_case/run.log"

		config_file_case="$(new_runtime_case config-file-redirect)"
		printf '%s\n' 'config file = /etc/samba/domain.conf' >>"$config_file_case/smb.conf"
		printf '%s\n' 'redirected-config-secrets' >"$config_file_case/live/secrets.tdb"
		run_runtime_case "$config_file_case" 2>"$config_file_case/run.log"
		grep -Fxq 'redirected-config-secrets' "$config_file_case/live/secrets.tdb"
		! grep -q '^smb:' "$config_file_case/passwd"
		grep -Fq 'config-file redirect' "$config_file_case/run.log"

		# A malformed configuration can make testparm emit partial parameter
		# output before returning failure.  Validate the complete configuration
		# first so a pipeline's final awk status cannot hide that rejection.
		failing_testparm="$runtime_fixture/partially-failing-testparm"
		make_partially_failing_testparm "$failing_testparm"
		parse_failure_case="$(new_runtime_case testparm-parse-failure)"
		printf '%s\n' 'parse-failure-secrets' >"$parse_failure_case/live/secrets.tdb"
		if run_runtime_case "$parse_failure_case" mv 0 "$failing_testparm" 2>"$parse_failure_case/run.log"; then
			echo "testparm parse failure must request a later-boot retry" >&2
			exit 1
		fi
		[ ! -e "$parse_failure_case/live/passdb.tdb" ]
		grep -Fxq 'parse-failure-secrets' "$parse_failure_case/live/secrets.tdb"
		! grep -q '^smb:' "$parse_failure_case/passwd"
		grep -Fq 'testparm rejected the active Samba configuration' "$parse_failure_case/run.log"

		# Production config resolution must reject every administrator-owned path
		# before touching databases or adding the firmware smb Unix account.
		custom_link_case="$(new_runtime_case custom-config-symlink)"
		rm -f "$custom_link_case/live/smb.conf"
		cp "$custom_link_case/smb.conf" "$custom_link_case/domain.conf"
		ln -s "$custom_link_case/domain.conf" "$custom_link_case/live/smb.conf"
		printf '%s\n' 'custom-link-secrets' >"$custom_link_case/live/secrets.tdb"
		run_stock_case "$custom_link_case" 2>"$custom_link_case/run.log"
		grep -Fxq 'custom-link-secrets' "$custom_link_case/live/secrets.tdb"
		! grep -q '^smb:' "$custom_link_case/passwd"
		grep -Fq 'non-stock Samba config symlink detected' "$custom_link_case/run.log"

		regular_config_case="$(new_runtime_case regular-custom-config)"
		rm -f "$regular_config_case/live/smb.conf"
		cp "$regular_config_case/smb.conf" "$regular_config_case/live/smb.conf"
		printf '%s\n' 'regular-config-secrets' >"$regular_config_case/live/secrets.tdb"
		run_stock_case "$regular_config_case" 2>"$regular_config_case/run.log"
		grep -Fxq 'regular-config-secrets' "$regular_config_case/live/secrets.tdb"
		! grep -q '^smb:' "$regular_config_case/passwd"
		grep -Fq 'custom regular smb.conf' "$regular_config_case/run.log"

		modified_template_case="$(new_runtime_case modified-template)"
		sed -i 's/passdb backend = tdbsam/passdb backend = smbpasswd/' "$modified_template_case/live/smb.conf.template"
		printf '%s\n' 'modified-template-secrets' >"$modified_template_case/live/secrets.tdb"
		run_stock_case "$modified_template_case" 2>"$modified_template_case/run.log"
		grep -Fxq 'modified-template-secrets' "$modified_template_case/live/secrets.tdb"
		! grep -q '^smb:' "$modified_template_case/passwd"
		grep -Fq 'template differs from ROM' "$modified_template_case/run.log"

		quoted_uci_case="$(new_runtime_case quoted-uci-override)"
		printf '%s\n' "config samba 'main'" "option 'smb_options' 'security = ads'" >"$quoted_uci_case/samba4"
		printf '%s\n' 'quoted-uci-secrets' >"$quoted_uci_case/live/secrets.tdb"
		run_stock_case "$quoted_uci_case" 2>"$quoted_uci_case/run.log"
		grep -Fxq 'quoted-uci-secrets' "$quoted_uci_case/live/secrets.tdb"
		! grep -q '^smb:' "$quoted_uci_case/passwd"
		grep -Fq 'custom UCI Samba global options' "$quoted_uci_case/run.log"

		# First boot must not follow or replace administrator-managed links.
		symlink_case="$(new_runtime_case symlink-protection)"
		cp "$symlink_case/rom/passdb.tdb" "$symlink_case/live/passdb.tdb"
		: >"$symlink_case/live/smbpasswd"
		printf '%s\n' 'linked-administrator-secrets' >"$symlink_case/linked-secrets.tdb"
		ln -s "$symlink_case/linked-secrets.tdb" "$symlink_case/live/secrets.tdb"
		if ! run_runtime_case "$symlink_case" 2>"$symlink_case/run.log"; then
			echo "administrator symlinks must be a successful policy skip" >&2
			exit 1
		fi
		[ -L "$symlink_case/live/secrets.tdb" ]
		grep -Fxq 'linked-administrator-secrets' "$symlink_case/linked-secrets.tdb"
		grep -Fq 'symlink detected in the live Samba database path' "$symlink_case/run.log"

		# An incomplete ROM pair is a fail-open no-op and must not install half.
		missing_case="$(new_runtime_case missing-rom-pair)"
		rm -f "$missing_case/rom/secrets.tdb"
		printf '%s\n' 'legacy-machine-secrets' >"$missing_case/live/secrets.tdb"
		if run_runtime_case "$missing_case" 2>"$missing_case/run.log"; then
			echo "incomplete firmware pair must request a later-boot retry" >&2
			exit 1
		fi
		[ ! -e "$missing_case/live/passdb.tdb" ]
		grep -Fxq 'legacy-machine-secrets' "$missing_case/live/secrets.tdb"
		grep -Fq 'firmware passdb.tdb/secrets.tdb pair is incomplete' "$missing_case/run.log"
		printf '%s\n' 'firmware-secrets-fixture' >"$missing_case/rom/secrets.tdb"
		run_runtime_case "$missing_case" 2>>"$missing_case/run.log"
		run_root cmp -s "$missing_case/live/passdb.tdb" "$missing_case/rom/passdb.tdb"
		run_root cmp -s "$missing_case/live/secrets.tdb" "$missing_case/rom/secrets.tdb"
	)
else
	echo "SKIP: Samba live-upgrade fixtures require root or passwordless sudo" >&2
fi

if command -v smbpasswd >/dev/null 2>&1 && command -v pdbedit >/dev/null 2>&1 &&
	command -v net >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
	fixture="$(mktemp -d)"
	test_user_created=0
	cleanup_fixture() {
		[ "$test_user_created" -eq 0 ] || sudo userdel smb >/dev/null 2>&1 || true
		sudo rm -rf "$fixture"
	}
	trap cleanup_fixture EXIT
	mkdir -p "$fixture/feeds/packages/net/samba4/files"
	printf '%s\n' 'passdb backend = smbpasswd' >"$fixture/feeds/packages/net/samba4/files/smb.conf.template"
	printf '%s\n' 'CONFIGURE_ARGS += --with-privatedir=/etc/samba' >"$fixture/feeds/packages/net/samba4/Makefile"
	sudo -E env SAMBA_DEFAULT_PASSWORD='BuildTestOnly.1' bash "$GENERATOR" "$fixture"
	if ! getent passwd smb >/dev/null; then
		sudo useradd --system --no-create-home --home-dir /var --shell /usr/sbin/nologin smb
		test_user_created=1
	fi
	grep -Fxq 'passdb backend = tdbsam' "$fixture/feeds/packages/net/samba4/files/smb.conf.template"
	[ "$(sudo stat -c '%a' "$fixture/files/etc/samba/passdb.tdb")" = 600 ]
	[ "$(sudo stat -c '%a' "$fixture/files/etc/samba/secrets.tdb")" = 600 ]
	# Mirror package/install as the non-root CI runner: mode-only assertions
	# miss root-owned 0600 files that sudo can inspect but make cannot copy.
	mkdir -p "$fixture/image-root"
	cp -fpR "$fixture/files/." "$fixture/image-root/"
	for database in passdb.tdb secrets.tdb; do
		# The generator runs through sudo so the staged firmware databases must
		# remain root-owned even when this guard itself runs as GitHub's runner.
		[ "$(stat -c '%u:%g' "$fixture/files/etc/samba/$database")" = '0:0' ]
		[ "$(stat -c '%a' "$fixture/image-root/etc/samba/$database")" = 600 ]
		cmp -s "$fixture/files/etc/samba/$database" "$fixture/image-root/etc/samba/$database"
	done
	cat >"$fixture/runtime-smb.conf" <<EOF
[global]
netbios name = OPENWRT
workgroup = WORKGROUP
security = user
passdb backend = tdbsam
private dir = $fixture/files/etc/samba
state directory = $fixture/state
lock directory = $fixture/lock
pid directory = $fixture/run
ncalrpc dir = $fixture/ncalrpc
EOF
	mkdir -p "$fixture/state" "$fixture/lock" "$fixture/run" "$fixture/ncalrpc"
	sudo pdbedit -s "$fixture/runtime-smb.conf" -L smb | grep -Eq '^smb:'
	machine_sid="$(sudo net -s "$fixture/runtime-smb.conf" getlocalsid | sed -n 's/^SID for domain .* is: //p')"
	user_sid="$(sudo pdbedit -s "$fixture/runtime-smb.conf" -Lv smb | sed -n 's/^User SID:[[:space:]]*//p')"
	[ "$machine_sid" = 'S-1-5-21-3852847346-2771498014-1104378472' ]
	case "$user_sid" in
		"$machine_sid"-*) ;;
		*)
			echo "Samba passdb user SID does not match the generated machine SID" >&2
			exit 1
			;;
	esac
fi
echo "Samba build-time credential guards passed"
