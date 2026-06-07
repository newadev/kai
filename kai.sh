#!/usr/bin/env bash
# kai.sh — Komari Agent Installer (Hardened, dedicated system user)
# Supports: Ubuntu, Debian, CentOS, AlmaLinux, Rocky, Fedora, Alpine Linux
# Requires: root (sudo) for setup; agent runs as unprivileged 'komari' user

# ─── Bootstrap: if running under non-bash shell (e.g. Alpine ash), install bash
#     and re-exec. This block must be valid POSIX sh.
if [ -z "$BASH_VERSION" ]; then
	if command -v bash >/dev/null 2>&1; then
		exec bash "$0" "$@"
	fi
	# No bash available — try to install it
	if [ -f /etc/alpine-release ] && command -v apk >/dev/null 2>&1; then
		echo "[INFO] bash not found, installing via apk..."
		apk add --quiet bash || { echo "[ERROR] Failed to install bash" >&2; exit 1; }
		exec bash "$0" "$@"
	fi
	echo "[ERROR] bash is required but not found. Install bash first." >&2
	exit 1
fi

set -euo pipefail
umask 077

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SERVICE_USER="komari"
readonly SERVICE_GROUP="komari"
readonly INSTALL_DIR="/opt/komari-agent"
readonly BIN_PATH="${INSTALL_DIR}/bin/komari-agent"
readonly CONFIG_PATH="${INSTALL_DIR}/config.json"
readonly LOG_DIR="${INSTALL_DIR}/logs"
readonly RUN_DIR="${INSTALL_DIR}/run"
readonly SERVICE_NAME="komari-agent"
readonly SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
readonly OPENRC_INIT="/etc/init.d/${SERVICE_NAME}"
readonly CRON_MARKER="${INSTALL_DIR}/.cron_installed"
readonly USER_MARKER="${INSTALL_DIR}/.kai_user_created"
readonly GROUP_MARKER="${INSTALL_DIR}/.kai_group_created"

readonly AGENT_VERSION="${KAI_AGENT_VERSION:-latest}"
readonly AGENT_SHA256="${KAI_AGENT_SHA256:-}"
readonly AGENT_SHA256_AMD64="${KAI_AGENT_SHA256_AMD64:-}"
readonly AGENT_SHA256_ARM64="${KAI_AGENT_SHA256_ARM64:-}"
readonly REQUIRE_BINARY_SHA256="${KAI_REQUIRE_BINARY_SHA256:-0}"

readonly DEFAULT_CONFIG='{
  "endpoint": "",
  "token": "",
  "auto_discovery_key": "",
  "disable_web_ssh": true,
  "disable_auto_update": false,
  "interval": 5,
  "ignore_unsafe_cert": false,
  "max_retries": 5,
  "reconnect_interval": 10,
  "info_report_interval": 15,
  "include_nics": "",
  "exclude_nics": "",
  "include_mountpoints": "",
  "month_rotate": 1,
  "cf_access_client_id": "",
  "cf_access_client_secret": "",
  "memory_include_cache": true,
  "memory_report_raw_used": false,
  "custom_dns": "",
  "enable_gpu": false,
  "custom_ipv4": "",
  "custom_ipv6": "",
  "get_ip_addr_from_nic": false,
  "host_proc": "",
  "protocol_version": 2,
  "disable_compression": false
}'

die()      { echo "[ERROR] $1" >&2; exit 1; }
log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_ok()   { echo "[OK] $1"; }


CFG_SOURCE=""
CFG_SOURCE_TYPE=""
CFG_URL_FOR_AUTO=""
OPT_AUTO_DISCOVERY=""
OPT_TOKEN=""
OPT_ENDPOINT=""
AUTO_MODE=""
DEBUG_MODE=0
UNINSTALL_ONLY=0
SHOW_LOGS=0
SERVICE_USER_CREATED=0
SERVICE_GROUP_CREATED=0

usage() {
	cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Options:
  -c <path|url>     Config file (local path or remote URL)
  -a <key>          Set auto_discovery_key (alphanumeric, <=64 chars)
  -t <token>        Set token (alphanumeric, <=64 chars)
  -e <url>          Set endpoint URL (http/https; reachability is warned)
  -log              Show service status and tail last 50 log lines
  --auto [min|d]    Enable auto config sync (default: 10 min); 'd' to disable
  --debug           Enable verbose trace output
  -u, --uninstall   Stop service and remove files; remove only KAI-created user

Installation requires one of:
  1. -c <config>
  2. -a <key> -e <url>
  3. -t <token> -e <url>

Examples:
  sudo bash ${SCRIPT_NAME} -c ./config.json
  sudo bash ${SCRIPT_NAME} -a DISCOVERY_KEY -e https://panel.example.com
  sudo bash ${SCRIPT_NAME} -t TOKEN -e https://panel.example.com
  sudo bash ${SCRIPT_NAME} -c https://example.com/config.json --auto 10
  sudo KAI_AGENT_VERSION=v1.2.3 KAI_AGENT_SHA256=<sha256> bash ${SCRIPT_NAME} -c ./config.json
  sudo bash ${SCRIPT_NAME} -log
  sudo bash ${SCRIPT_NAME} -u
EOF
}

require_root() {
	[[ ${EUID} -eq 0 ]] || die "This script must be run as root (use sudo)"
}

is_systemd() {
	[[ -d /run/systemd/system ]] && return 0
	local pid1
	pid1=$(ps -p 1 -o comm= 2>/dev/null || true)
	[[ ${pid1} == systemd ]]
}

is_alpine() { [[ -f /etc/alpine-release ]]; }

install_packages() {
	local cmds=("$@") missing=()
	for c in "${cmds[@]}"; do
		command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
	done
	[[ ${#missing[@]} -eq 0 ]] && return 0

	local pm=""
	for try in apt-get apt dnf yum apk; do
		command -v "${try}" >/dev/null 2>&1 && { pm="${try}"; break; }
	done
	[[ -n ${pm} ]] || die "No supported package manager. Install ${missing[*]} manually."

	# Map command → package name
	local pkgs=()
	for cmd in "${missing[@]}"; do
		case ${cmd} in
			crontab)
				case ${pm} in
					apt-get|apt) pkgs+=("cron") ;;
					dnf|yum)     pkgs+=("cronie") ;;
					apk)         pkgs+=("dcron") ;;
				esac ;;
			*) pkgs+=("${cmd}") ;;
		esac
	done

	# Deduplicate
	local unique=()
	declare -A _seen=()
	for p in "${pkgs[@]}"; do
		[[ -z ${_seen[${p}]+x} ]] && { unique+=("${p}"); _seen[${p}]=1; }
	done

	log_info "Installing: ${unique[*]} (via ${pm})"
	case ${pm} in
		apt-get) apt-get update -qq && apt-get install -y -qq "${unique[@]}" ;;
		apt)     apt update -qq && apt install -y -qq "${unique[@]}" ;;
		dnf)     dnf install -y -q "${unique[@]}" ;;
		yum)     yum install -y -q "${unique[@]}" ;;
		apk)     apk add --quiet "${unique[@]}" ;;
	esac || die "Failed to install: ${unique[*]}"
}

validate_alnum() {
	local v=$1
	[[ ${#v} -le 64 && ${v} =~ ^[0-9A-Za-z]+$ ]]
}

validate_http_url() {
	local url=$1
	[[ ${url} =~ ^https?://[^[:space:]]+$ ]]
}

trim_value() {
	local v=$1
	v="${v#"${v%%[![:space:]]*}"}"
	v="${v%"${v##*[![:space:]]}"}"
	printf '%s' "${v}"
}

check_url_reachable() {
	local url=$1
	curl -fsS --max-time 10 -o /dev/null "${url}" 2>/dev/null
}

normalize_endpoint() {
	local raw=$1
	raw="${raw#"${raw%%[![:space:]]*}"}"
	raw="${raw%"${raw##*[![:space:]]}"}"
	[[ -z ${raw} ]] && return
	if [[ ${raw,,} =~ ^https?:// ]]; then
		printf '%s' "${raw}"
	else
		raw="${raw#//}"
		printf 'https://%s' "${raw}"
	fi
}

validate_json_file() {
	local f=$1
	if command -v jq >/dev/null 2>&1; then
		jq empty "${f}" 2>/dev/null || die "Invalid JSON: ${f}"
	elif command -v python3 >/dev/null 2>&1; then
		python3 -m json.tool "${f}" >/dev/null 2>&1 || die "Invalid JSON: ${f}"
	else
		log_warn "Cannot validate JSON (no jq or python3)"
	fi
}

validate_config_file() {
	local f=$1
	validate_json_file "${f}"
	validate_config_credentials "${f}"
}

json_read() {
	local file=$1 key=$2
	if command -v jq >/dev/null 2>&1; then
		jq -r --arg k "${key}" '.[$k] // ""' "${file}"
	else
		python3 -c "
import json,sys
file, key = sys.argv[1:3]
with open(file) as f: d=json.load(f)
v=d.get(key,'')
print(v if isinstance(v,str) else '')" "${file}" "${key}" 2>/dev/null || echo ""
	fi
}

json_set() {
	local file=$1 key=$2 value=$3
	if command -v jq >/dev/null 2>&1; then
		local tmp
		tmp=$(mktemp "${file}.tmp.XXXXXX")
		if jq --arg v "${value}" ".${key} = \$v" "${file}" >"${tmp}"; then
			mv "${tmp}" "${file}"
		else
			rm -f "${tmp}"
			die "Failed to update JSON key: ${key}"
		fi
	else
		local tmp
		tmp=$(mktemp "${file}.tmp.XXXXXX")
		if python3 -c "
import json,sys
file, tmp, key, val = sys.argv[1:5]
with open(file) as f: d=json.load(f)
d[key]=val
with open(tmp,'w') as f: json.dump(d,f,ensure_ascii=False,indent=2)
" "${file}" "${tmp}" "${key}" "${value}"; then
			mv "${tmp}" "${file}"
		else
			rm -f "${tmp}"
			die "Failed to update JSON key: ${key}"
		fi
	fi
}

looks_like_domain_path() {
	local v=$1
	[[ ${v} == .* || ${v} == ../* || ${v} == ~/* || ${v} == /* ]] && return 1
	[[ ${v} != */* ]] && return 1
	local prefix=${v%%/*}
	[[ ${prefix} == *.* ]]
}

resolve_cfg_source() {
	local src=$1
	[[ -z ${src} ]] && return

	if [[ ${src} =~ ^https?:// ]]; then
		validate_http_url "${src}" || die "-c URL invalid: ${src}"
		check_url_reachable "${src}" || die "-c URL unreachable: ${src}"
		CFG_URL_FOR_AUTO="${src}"
		CFG_SOURCE_TYPE="remote"
		return
	fi

	if [[ -f ${src} ]]; then
		CFG_SOURCE_TYPE="local"
		return
	fi

	# Try as bare domain/path
	if looks_like_domain_path "${src}" || [[ ${src} != */* && ${src} != .* ]]; then
		for proto in https http; do
			local candidate="${proto}://${src}"
			if check_url_reachable "${candidate}"; then
				CFG_SOURCE="${candidate}"
				CFG_URL_FOR_AUTO="${candidate}"
				CFG_SOURCE_TYPE="remote"
				return
			fi
		done
	fi

	die "-c value not found locally and unreachable via http(s): ${src}"
}

fetch_config() {
	local src=$1 dest=$2
	if [[ -z ${src} ]]; then
		printf '%s\n' "${DEFAULT_CONFIG}" >"${dest}"
	elif [[ -f ${src} ]]; then
		cp "${src}" "${dest}"
	else
		curl -fsSL "${src}" -o "${dest}" || die "Failed to download config: ${src}"
	fi
}

validate_config_credentials() {
	local file=$1
	local endpoint auto_key token
	endpoint=$(json_read "${file}" "endpoint")
	auto_key=$(json_read "${file}" "auto_discovery_key")
	token=$(json_read "${file}" "token")

	# Trim whitespace
	endpoint="${endpoint#"${endpoint%%[![:space:]]*}"}"
	auto_key="${auto_key#"${auto_key%%[![:space:]]*}"}"
	token="${token#"${token%%[![:space:]]*}"}"

	[[ -n ${endpoint} ]] || die "Config must contain endpoint (http(s)://...)"
	[[ ${endpoint} =~ ^https?:// ]] || die "Config endpoint invalid (need http(s)://...)"

	local ok=0
	if [[ -n ${auto_key} ]]; then
		validate_alnum "${auto_key}" || die "Config auto_discovery_key must be alphanumeric <=64"
		ok=1
	fi
	if [[ -n ${token} ]]; then
		validate_alnum "${token}" || die "Config token must be alphanumeric <=64"
		ok=1
	fi
	(( ok )) || die "Config must provide a valid auto_discovery_key or token"
}

create_service_group() {
	group_exists "${SERVICE_GROUP}" && return 0
	log_info "Creating system group: ${SERVICE_GROUP}"
	if command -v groupadd >/dev/null 2>&1; then
		groupadd --system "${SERVICE_GROUP}"
	elif command -v addgroup >/dev/null 2>&1; then
		addgroup -S "${SERVICE_GROUP}"
	else
		die "Cannot create system group (no groupadd or addgroup)"
	fi
	SERVICE_GROUP_CREATED=1
}

group_exists() {
	local group=$1
	if command -v getent >/dev/null 2>&1; then
		getent group "${group}" >/dev/null 2>&1
	else
		grep -q "^${group}:" /etc/group 2>/dev/null
	fi
}

nologin_shell() {
	if [[ -x /usr/sbin/nologin ]]; then
		printf '%s' "/usr/sbin/nologin"
	elif [[ -x /sbin/nologin ]]; then
		printf '%s' "/sbin/nologin"
	else
		printf '%s' "/bin/false"
	fi
}

create_service_user() {
	create_service_group
	if id "${SERVICE_USER}" &>/dev/null; then
		log_info "User '${SERVICE_USER}' already exists; it will not be removed by uninstall"
		return
	fi
	log_info "Creating system user: ${SERVICE_USER}"
	if command -v useradd >/dev/null 2>&1; then
		useradd --system --no-create-home --home-dir "${INSTALL_DIR}" \
			--gid "${SERVICE_GROUP}" --shell "$(nologin_shell)" "${SERVICE_USER}"
	elif command -v adduser >/dev/null 2>&1; then
		adduser -S -D -H -h "${INSTALL_DIR}" -s "$(nologin_shell)" \
			-G "${SERVICE_GROUP}" "${SERVICE_USER}"
	else
		die "Cannot create system user (no useradd or adduser)"
	fi
	SERVICE_USER_CREATED=1
	log_ok "User '${SERVICE_USER}' created (nologin)"
}

remove_service_user() {
	if id "${SERVICE_USER}" &>/dev/null; then
		if [[ -f ${USER_MARKER} ]]; then
			log_info "Removing user: ${SERVICE_USER}"
			if command -v userdel >/dev/null 2>&1; then
				userdel "${SERVICE_USER}" 2>/dev/null || true
			elif command -v deluser >/dev/null 2>&1; then
				deluser "${SERVICE_USER}" 2>/dev/null || true
			fi
		else
			log_info "Keeping pre-existing user: ${SERVICE_USER}"
		fi
	fi
	if [[ -f ${GROUP_MARKER} ]] && group_exists "${SERVICE_GROUP}"; then
		log_info "Removing group: ${SERVICE_GROUP}"
		if command -v groupdel >/dev/null 2>&1; then
			groupdel "${SERVICE_GROUP}" 2>/dev/null || true
		elif command -v delgroup >/dev/null 2>&1; then
			delgroup "${SERVICE_GROUP}" 2>/dev/null || true
		fi
	fi
}

ensure_dirs() {
	mkdir -p "${INSTALL_DIR}/bin" "${LOG_DIR}" "${RUN_DIR}"
	# logs/ and base dir: service user writable (logs, config auto-sync)
	chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${INSTALL_DIR}"
	chmod 750 "${INSTALL_DIR}" "${INSTALL_DIR}/bin" "${LOG_DIR}" "${RUN_DIR}"
	# bin/ and run/: root-owned, service user read+exec only (defense-in-depth)
	chown root:"${SERVICE_GROUP}" "${INSTALL_DIR}/bin" "${RUN_DIR}"
	if (( SERVICE_USER_CREATED )); then
		touch "${USER_MARKER}"
		chown root:"${SERVICE_GROUP}" "${USER_MARKER}"
		chmod 640 "${USER_MARKER}"
	fi
	if (( SERVICE_GROUP_CREATED )); then
		touch "${GROUP_MARKER}"
		chown root:"${SERVICE_GROUP}" "${GROUP_MARKER}"
		chmod 640 "${GROUP_MARKER}"
	fi
	# Agent writes auto-discovery.json next to binary (hardcoded in Go source).
	# Symlink redirects writes from root-owned bin/ to komari-writable base dir.
	ln -sf "${INSTALL_DIR}/auto-discovery.json" "${INSTALL_DIR}/bin/auto-discovery.json"
}

current_arch() {
	case "$(uname -m)" in
		x86_64|amd64)  printf '%s' "amd64" ;;
		aarch64|arm64) printf '%s' "arm64" ;;
		*) die "Unsupported architecture: $(uname -m)" ;;
	esac
}

current_arch_url() {
	local arch path
	arch=$(current_arch)
	if [[ ${AGENT_VERSION} == "latest" ]]; then
		path="latest/download"
	else
		path="download/${AGENT_VERSION}"
	fi
	printf 'https://github.com/komari-monitor/komari-agent/releases/%s/komari-agent-linux-%s' \
		"${path}" "${arch}"
}

current_arch_sha256() {
	local arch
	arch=$(current_arch)
	if [[ -n ${AGENT_SHA256} ]]; then
		printf '%s' "${AGENT_SHA256}"
	elif [[ ${arch} == "amd64" ]]; then
		printf '%s' "${AGENT_SHA256_AMD64}"
	else
		printf '%s' "${AGENT_SHA256_ARM64}"
	fi
}

download_binary() {
	local url tmp magic sha
	url=$(current_arch_url)
	sha=$(current_arch_sha256)
	tmp="${BIN_PATH}.tmp"
	log_info "Downloading komari-agent from ${url}"
	rm -f "${tmp}"
	curl -fsSL "${url}" -o "${tmp}" || { rm -f "${tmp}"; die "Download failed"; }
	if [[ -n ${sha} ]]; then
		[[ ${sha} =~ ^[0-9A-Fa-f]{64}$ ]] || { rm -f "${tmp}"; die "Invalid SHA256 value"; }
		printf '%s  %s\n' "${sha}" "${tmp}" | sha256sum -c - >/dev/null || {
			rm -f "${tmp}"
			die "SHA256 verification failed"
		}
	elif [[ ${REQUIRE_BINARY_SHA256} == "1" ]]; then
		rm -f "${tmp}"
		die "KAI_REQUIRE_BINARY_SHA256=1 but no SHA256 was provided"
	else
		log_warn "No SHA256 provided; only ELF header will be checked"
	fi
	magic=$(dd if="${tmp}" bs=4 count=1 2>/dev/null | od -An -t x1 | tr -d ' \n')
	[[ ${magic} == "7f454c46" ]] || { rm -f "${tmp}"; die "Not a valid ELF binary (download corrupted?)"; }
	chmod 750 "${tmp}"
	chown root:"${SERVICE_GROUP}" "${tmp}"
	mv "${tmp}" "${BIN_PATH}"
	log_ok "Binary: ${BIN_PATH}"
}

generate_wrapper() {
	cat >"${RUN_DIR}/komari-wrapper.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/komari-agent"
BIN_PATH="${INSTALL_DIR}/bin/komari-agent"
CONFIG_PATH="${INSTALL_DIR}/config.json"
LOG_DIR="${INSTALL_DIR}/logs"
RUN_DIR="${INSTALL_DIR}/run"
AUTO_CONF="${RUN_DIR}/auto-update.conf"
AGENT_LOG="${LOG_DIR}/komari-agent.log"

mkdir -p "${LOG_DIR}"

agent_pid=0

trim_value() {
	local v=$1
	v="${v#"${v%%[![:space:]]*}"}"
	v="${v%"${v##*[![:space:]]}"}"
	printf '%s' "${v}"
}

validate_alnum() {
	local v=$1
	[[ ${#v} -le 64 && ${v} =~ ^[0-9A-Za-z]+$ ]]
}

validate_http_url() {
	local url=$1
	[[ ${url} =~ ^https?://[^[:space:]]+$ ]]
}

cleanup() {
	if (( agent_pid > 0 )); then
		kill "${agent_pid}" 2>/dev/null || true
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			if ! kill -0 "${agent_pid}" 2>/dev/null; then
				wait "${agent_pid}" 2>/dev/null || true
				agent_pid=0
				return 0
			fi
			sleep 1
		done
		kill -KILL "${agent_pid}" 2>/dev/null || true
		wait "${agent_pid}" 2>/dev/null || true
		agent_pid=0
	fi
}
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT

read_auto_conf() {
	AUTO_ENABLED=0; AUTO_INTERVAL=10; AUTO_URL=""
	if [[ -f ${AUTO_CONF} ]]; then
		local key value
		while IFS='=' read -r key value || [[ -n ${key} ]]; do
			key=$(trim_value "${key}")
			value=$(trim_value "${value}")
			case ${key} in
				AUTO_ENABLED)
					[[ ${value} =~ ^[01]$ ]] && AUTO_ENABLED=${value}
					;;
				AUTO_INTERVAL)
					[[ ${value} =~ ^[0-9]+$ && ${value} -gt 0 ]] && AUTO_INTERVAL=${value}
					;;
				AUTO_URL)
					validate_http_url "${value}" && AUTO_URL=${value}
					;;
			esac
		done <"${AUTO_CONF}"
	fi
	[[ ${AUTO_INTERVAL} =~ ^[0-9]+$ && ${AUTO_INTERVAL} -gt 0 ]] || AUTO_INTERVAL=10
}

validate_config_file() {
	local file=$1 endpoint auto_key token ok=0
	command -v jq >/dev/null 2>&1 || return 1
	jq empty "${file}" >/dev/null 2>&1 || return 1

	endpoint=$(jq -r 'if (.endpoint | type) == "string" then .endpoint else "" end' "${file}" 2>/dev/null)
	auto_key=$(jq -r 'if (.auto_discovery_key | type) == "string" then .auto_discovery_key else "" end' "${file}" 2>/dev/null)
	token=$(jq -r 'if (.token | type) == "string" then .token else "" end' "${file}" 2>/dev/null)

	endpoint=$(trim_value "${endpoint}")
	auto_key=$(trim_value "${auto_key}")
	token=$(trim_value "${token}")

	validate_http_url "${endpoint}" || return 1
	if [[ -n ${auto_key} ]]; then
		validate_alnum "${auto_key}" || return 1
		ok=1
	fi
	if [[ -n ${token} ]]; then
		validate_alnum "${token}" || return 1
		ok=1
	fi
	(( ok ))
}

do_config_update() {
	read_auto_conf
	[[ ${AUTO_ENABLED} -eq 1 && -n ${AUTO_URL} ]] || return 0
	local tmp; tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
	if ! curl -fsSL "${AUTO_URL}" -o "${tmp}" 2>/dev/null; then
		rm -f "${tmp}"; return 0
	fi
	if ! validate_config_file "${tmp}"; then
		rm -f "${tmp}"; return 0
	fi
	if [[ ! -f ${CONFIG_PATH} ]]; then
		mv "${tmp}" "${CONFIG_PATH}"; return 0
	fi
	local cur_hash new_hash
	cur_hash=$(sha256sum "${CONFIG_PATH}" | awk '{print $1}')
	new_hash=$(sha256sum "${tmp}" | awk '{print $1}')
	if [[ ${cur_hash} != "${new_hash}" ]]; then
		mv "${tmp}" "${CONFIG_PATH}"
	else
		rm -f "${tmp}"
	fi
}

# After successful auto-discovery registration, the agent writes
# auto-discovery.json with {uuid, token}. Promote that token into
# config.json and clear auto_discovery_key so the agent never re-registers.
promote_auto_discovery() {
	local ad_json="${INSTALL_DIR}/auto-discovery.json"
	[[ -f ${ad_json} ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	[[ -f ${CONFIG_PATH} ]] || return 0

	local ad_token current_key
	ad_token=$(jq -r '.token // ""' "${ad_json}" 2>/dev/null)
	[[ -n ${ad_token} ]] || return 0

	current_key=$(jq -r '.auto_discovery_key // ""' "${CONFIG_PATH}" 2>/dev/null)
	[[ -n ${current_key} ]] || return 0  # already promoted or using -t

	local tmp; tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
	if jq --arg t "${ad_token}" '.token = $t | .auto_discovery_key = ""' \
		"${CONFIG_PATH}" >"${tmp}" 2>/dev/null && validate_config_file "${tmp}"; then
		mv "${tmp}" "${CONFIG_PATH}"
		rm -f "${ad_json}"
	else
		rm -f "${tmp}"
	fi
}

last_update=0
last_hash=""
[[ -f ${CONFIG_PATH} ]] && last_hash=$(sha256sum "${CONFIG_PATH}" | awk '{print $1}')

# Crash-loop backoff: if agent exits too fast, delay restarts exponentially
crash_count=0
last_start=0

while true; do
	read_auto_conf
	now=$(date +%s)
	interval=$(( AUTO_INTERVAL * 60 ))
	(( interval > 0 )) || interval=600

	# Periodic config sync
	if [[ ${AUTO_ENABLED} -eq 1 ]] && (( now - last_update >= interval )); then
		do_config_update || true
		last_update=${now}
	fi

	# Promote auto-discovery token → config.json (one-time migration)
	promote_auto_discovery || true

	# Detect config change → restart agent
	if [[ -f ${CONFIG_PATH} ]]; then
		cur_hash=$(sha256sum "${CONFIG_PATH}" | awk '{print $1}')
		if [[ ${cur_hash} != "${last_hash}" ]]; then
			last_hash=${cur_hash}
			cleanup
			crash_count=0
		fi
	fi

	# Log rotation (>2MB → archive + truncate)
	if [[ -f ${AGENT_LOG} ]]; then
		log_bytes=$(wc -c < "${AGENT_LOG}" 2>/dev/null || echo 0)
		if (( log_bytes > 2097152 )); then
			cp "${AGENT_LOG}" "${AGENT_LOG}.1" 2>/dev/null || true
			: > "${AGENT_LOG}"
		fi
	fi

	# Start or maintain agent process
	if (( agent_pid == 0 )); then
		# Crash-loop backoff: 5s, 10s, 20s, 40s, ... up to 300s (5 min)
		if (( crash_count > 0 )); then
			backoff=$(( 5 * (1 << (crash_count > 6 ? 6 : crash_count)) ))
			(( backoff > 300 )) && backoff=300
			elapsed=$(( $(date +%s) - last_start ))
			if (( elapsed < backoff )); then
				sleep 5; continue
			fi
		fi
		if [[ -x ${BIN_PATH} && -f ${CONFIG_PATH} ]]; then
			last_start=$(date +%s)
			"${BIN_PATH}" --config "${CONFIG_PATH}" >>"${AGENT_LOG}" 2>&1 &
			agent_pid=$!
		else
			sleep 5; continue
		fi
	elif ! kill -0 "${agent_pid}" 2>/dev/null; then
		wait "${agent_pid}" 2>/dev/null || true
		agent_pid=0
		runtime=$(( $(date +%s) - last_start ))
		if (( runtime < 10 )); then
			(( crash_count++ ))
		else
			crash_count=0
		fi
	fi

	sleep 5
done
WRAPPER
	chown root:"${SERVICE_GROUP}" "${RUN_DIR}/komari-wrapper.sh"
	chmod 750 "${RUN_DIR}/komari-wrapper.sh"
}

write_auto_conf() {
	local enabled=$1 interval=$2 url=$3
	[[ ${enabled} =~ ^[01]$ ]] || die "Invalid auto enabled value"
	[[ ${interval} =~ ^[0-9]+$ && ${interval} -gt 0 ]] || die "Invalid auto interval"
	[[ -z ${url} || ${url} =~ ^https?://[^[:space:]]+$ ]] || die "Invalid auto URL"
	{
		printf 'AUTO_ENABLED=%s\n' "${enabled}"
		printf 'AUTO_INTERVAL=%s\n' "${interval}"
		printf 'AUTO_URL=%s\n' "${url}"
	} >"${RUN_DIR}/auto-update.conf"
	chown root:"${SERVICE_GROUP}" "${RUN_DIR}/auto-update.conf"
	chmod 640 "${RUN_DIR}/auto-update.conf"
}

setup_systemd() {
	cat >"${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=Komari Agent (hardened)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
ExecStart=${RUN_DIR}/komari-wrapper.sh
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
MemoryDenyWriteExecute=yes
LockPersonality=yes
RestrictRealtime=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
ReadWritePaths=${INSTALL_DIR}
CapabilityBoundingSet=CAP_NET_RAW
AmbientCapabilities=CAP_NET_RAW
SystemCallFilter=@system-service
SystemCallArchitectures=native
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	if systemctl enable --now "${SERVICE_NAME}"; then
		log_ok "systemd service active (hardened sandbox)"
	else
		log_warn "Failed to enable systemd service"
	fi
}

setup_openrc() {
	cat >"${OPENRC_INIT}" <<'INITEOF'
#!/sbin/openrc-run

name="komari-agent"
description="Komari Agent (hardened)"

command="/opt/komari-agent/run/komari-wrapper.sh"
command_user="komari:komari"
command_background=true
pidfile="/opt/komari-agent/run/${name}.pid"
output_log="/opt/komari-agent/logs/komari-agent.log"
error_log="/opt/komari-agent/logs/komari-agent.log"

depend() {
	need net
	after firewall
}
INITEOF
	chmod 755 "${OPENRC_INIT}"

	rc-update add "${SERVICE_NAME}" default 2>/dev/null || true
	rc-service "${SERVICE_NAME}" start 2>/dev/null || log_warn "Failed to start OpenRC service"
	log_ok "OpenRC service installed"
}

setup_alpine_cron() {
	local interval=10
	if [[ -f ${RUN_DIR}/auto-update.conf ]]; then
		local key value auto_interval=10
		while IFS='=' read -r key value || [[ -n ${key} ]]; do
			key=$(trim_value "${key}")
			value=$(trim_value "${value}")
			[[ ${key} == "AUTO_INTERVAL" && ${value} =~ ^[0-9]+$ && ${value} -gt 0 ]] && auto_interval=${value}
		done <"${RUN_DIR}/auto-update.conf"
		interval=${auto_interval}
	fi
	(( interval > 59 )) && interval=59

	cat >"${RUN_DIR}/cron-update.sh" <<'CRON'
#!/usr/bin/env bash
set -euo pipefail
RUN_DIR="/opt/komari-agent/run"
AUTO_CONF="${RUN_DIR}/auto-update.conf"
CONFIG_PATH="/opt/komari-agent/config.json"
AUTO_ENABLED=0; AUTO_URL=""

trim_value() {
	local v=$1
	v="${v#"${v%%[![:space:]]*}"}"
	v="${v%"${v##*[![:space:]]}"}"
	printf '%s' "${v}"
}

validate_alnum() {
	local v=$1
	[[ ${#v} -le 64 && ${v} =~ ^[0-9A-Za-z]+$ ]]
}

validate_http_url() {
	local url=$1
	[[ ${url} =~ ^https?://[^[:space:]]+$ ]]
}

read_auto_conf() {
	if [[ -f ${AUTO_CONF} ]]; then
		local key value
		while IFS='=' read -r key value || [[ -n ${key} ]]; do
			key=$(trim_value "${key}")
			value=$(trim_value "${value}")
			case ${key} in
				AUTO_ENABLED)
					[[ ${value} =~ ^[01]$ ]] && AUTO_ENABLED=${value}
					;;
				AUTO_URL)
					validate_http_url "${value}" && AUTO_URL=${value}
					;;
			esac
		done <"${AUTO_CONF}"
	fi
}

validate_config_file() {
	local file=$1 endpoint auto_key token ok=0
	command -v jq >/dev/null 2>&1 || return 1
	jq empty "${file}" >/dev/null 2>&1 || return 1

	endpoint=$(jq -r 'if (.endpoint | type) == "string" then .endpoint else "" end' "${file}" 2>/dev/null)
	auto_key=$(jq -r 'if (.auto_discovery_key | type) == "string" then .auto_discovery_key else "" end' "${file}" 2>/dev/null)
	token=$(jq -r 'if (.token | type) == "string" then .token else "" end' "${file}" 2>/dev/null)

	endpoint=$(trim_value "${endpoint}")
	auto_key=$(trim_value "${auto_key}")
	token=$(trim_value "${token}")

	validate_http_url "${endpoint}" || return 1
	if [[ -n ${auto_key} ]]; then
		validate_alnum "${auto_key}" || return 1
		ok=1
	fi
	if [[ -n ${token} ]]; then
		validate_alnum "${token}" || return 1
		ok=1
	fi
	(( ok ))
}

read_auto_conf
[[ ${AUTO_ENABLED} -eq 1 && -n ${AUTO_URL} ]] || exit 0
TMP=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
curl -fsSL "${AUTO_URL}" -o "${TMP}" 2>/dev/null || { rm -f "${TMP}"; exit 0; }
validate_config_file "${TMP}" || { rm -f "${TMP}"; exit 0; }
if [[ ! -f ${CONFIG_PATH} ]]; then mv "${TMP}" "${CONFIG_PATH}"; exit 0; fi
cur=$(sha256sum "${CONFIG_PATH}" | awk '{print $1}')
new=$(sha256sum "${TMP}" | awk '{print $1}')
if [[ ${cur} != "${new}" ]]; then
	mv "${TMP}" "${CONFIG_PATH}"
else
	rm -f "${TMP}"
fi
CRON
	chown root:"${SERVICE_GROUP}" "${RUN_DIR}/cron-update.sh"
	chmod 750 "${RUN_DIR}/cron-update.sh"

	local cron_file; cron_file=$(mktemp)
	crontab -u "${SERVICE_USER}" -l >"${cron_file}" 2>/dev/null || true
	sed -i "\#${RUN_DIR}/cron-update.sh#d" "${cron_file}"
	printf '*/%s * * * * %s\n' "${interval}" "${RUN_DIR}/cron-update.sh" >>"${cron_file}"
	crontab -u "${SERVICE_USER}" "${cron_file}" 2>/dev/null || \
		log_warn "Failed to install crontab for ${SERVICE_USER}"
	rm -f "${cron_file}"
	touch "${CRON_MARKER}"
	log_ok "Cron config-sync installed (every ${interval} min)"
}

enable_crond_alpine() {
	if is_alpine; then
		rc-service crond start 2>/dev/null || true
		rc-update add crond 2>/dev/null || true
	fi
}

show_logs() {
	if is_systemd && command -v systemctl >/dev/null 2>&1; then
		systemctl status "${SERVICE_NAME}" --no-pager 2>/dev/null || true
		journalctl -u "${SERVICE_NAME}" -n 50 -f
	elif [[ -f ${LOG_DIR}/komari-agent.log ]]; then
		if is_alpine && command -v rc-service >/dev/null 2>&1; then
			rc-service "${SERVICE_NAME}" status 2>/dev/null || true
		fi
		tail -n 50 -f "${LOG_DIR}/komari-agent.log"
	else
		die "No log found at ${LOG_DIR}/komari-agent.log"
	fi
}

uninstall_all() {
	require_root
	log_info "Uninstalling komari-agent..."

	# systemd
	if is_systemd; then
		systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
		systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
		rm -f "${SYSTEMD_UNIT}"
		systemctl daemon-reload 2>/dev/null || true
	fi

	# OpenRC
	if is_alpine; then
		rc-service "${SERVICE_NAME}" stop 2>/dev/null || true
		rc-update del "${SERVICE_NAME}" 2>/dev/null || true
		rm -f "${OPENRC_INIT}"
	fi

	# Crontab
	if [[ -f ${CRON_MARKER} ]] && id "${SERVICE_USER}" &>/dev/null; then
		local cron_file
		cron_file=$(mktemp)
		crontab -u "${SERVICE_USER}" -l >"${cron_file}" 2>/dev/null || true
		sed -i "\#${RUN_DIR}/cron-update.sh#d" "${cron_file}"
		crontab -u "${SERVICE_USER}" "${cron_file}" 2>/dev/null || true
		rm -f "${cron_file}"
	fi

	# Kill remaining processes
	if id "${SERVICE_USER}" &>/dev/null; then
		if [[ -f ${USER_MARKER} ]]; then
			pkill -u "${SERVICE_USER}" 2>/dev/null || true
			sleep 1
			pkill -9 -u "${SERVICE_USER}" 2>/dev/null || true
		else
			log_info "Skipping broad process kill for pre-existing user: ${SERVICE_USER}"
		fi
	fi

	remove_service_user
	rm -rf "${INSTALL_DIR}"
	log_ok "komari-agent fully uninstalled"
}

is_installed() { [[ -x ${BIN_PATH} ]]; }

parse_args() {
	while [[ $# -gt 0 ]]; do
		case $1 in
			-c)  [[ $# -ge 2 ]] || die "-c requires a value"; CFG_SOURCE=$2; shift 2 ;;
			-a)  [[ $# -ge 2 ]] || die "-a requires a value"; OPT_AUTO_DISCOVERY=$2; shift 2 ;;
			-t)  [[ $# -ge 2 ]] || die "-t requires a value"; OPT_TOKEN=$2; shift 2 ;;
			-e)  [[ $# -ge 2 ]] || die "-e requires a value"; OPT_ENDPOINT=$2; shift 2 ;;
			-log) SHOW_LOGS=1; shift ;;
			--auto)
				if [[ $# -ge 2 && $2 != -* ]]; then
					AUTO_MODE=$2; shift 2
				else
					AUTO_MODE=10; shift
				fi ;;
			--debug) DEBUG_MODE=1; shift ;;
			-u|--uninstall) UNINSTALL_ONLY=1; shift ;;
			-h|--help) usage; exit 0 ;;
			*) die "Unknown option: $1" ;;
		esac
	done
}

main() {
	parse_args "$@"

	(( DEBUG_MODE )) && set -x

	if (( UNINSTALL_ONLY )); then uninstall_all; exit 0; fi
	if (( SHOW_LOGS ));      then show_logs;     exit 0; fi

	require_root
	install_packages curl
	command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found (install coreutils)"
	command -v jq >/dev/null 2>&1 || install_packages jq
	if is_alpine && ! is_systemd; then
		install_packages bash crontab
		enable_crond_alpine
	fi

	local valid=0

	if [[ -n ${CFG_SOURCE} ]]; then
		resolve_cfg_source "${CFG_SOURCE}"
		valid=1
	fi

	[[ -n ${OPT_ENDPOINT} ]] && OPT_ENDPOINT=$(normalize_endpoint "${OPT_ENDPOINT}")

	if [[ -n ${OPT_AUTO_DISCOVERY} || -n ${OPT_TOKEN} ]]; then
		[[ -n ${OPT_ENDPOINT} ]] || die "-e is required with -a or -t"
		validate_http_url "${OPT_ENDPOINT}" || die "Endpoint invalid: ${OPT_ENDPOINT}"
		check_url_reachable "${OPT_ENDPOINT}" || log_warn "Endpoint was not reachable during preflight: ${OPT_ENDPOINT}"
	fi
	if [[ -n ${OPT_AUTO_DISCOVERY} ]]; then
		validate_alnum "${OPT_AUTO_DISCOVERY}" || die "-a must be alphanumeric <=64 chars"
		valid=1
	fi
	if [[ -n ${OPT_TOKEN} ]]; then
		validate_alnum "${OPT_TOKEN}" || die "-t must be alphanumeric <=64 chars"
		valid=1
	fi

	(( valid )) || die "Requires: -c, or (-a -e), or (-t -e). Use -h for help."

	if is_installed; then
		log_warn "Already installed at ${INSTALL_DIR}"
		log_info "Use -u to uninstall, -log to view logs"
		exit 0
	fi

	create_service_user
	ensure_dirs

	fetch_config "${CFG_SOURCE}" "${CONFIG_PATH}"
	[[ ${CFG_SOURCE_TYPE} == "local" ]] && validate_json_file "${CONFIG_PATH}"

	[[ -n ${OPT_AUTO_DISCOVERY} ]] && json_set "${CONFIG_PATH}" "auto_discovery_key" "${OPT_AUTO_DISCOVERY}"
	[[ -n ${OPT_TOKEN} ]]          && json_set "${CONFIG_PATH}" "token" "${OPT_TOKEN}"
	[[ -n ${OPT_ENDPOINT} ]]       && json_set "${CONFIG_PATH}" "endpoint" "${OPT_ENDPOINT}"

	validate_config_file "${CONFIG_PATH}"
	chown "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_PATH}"
	chmod 600 "${CONFIG_PATH}"

	download_binary
	generate_wrapper

	local auto_enabled=0 auto_interval=10 auto_url="${CFG_URL_FOR_AUTO}"

	if [[ -n ${AUTO_MODE} ]]; then
		local mode=${AUTO_MODE,,}
		if [[ ${mode} == "d" ]]; then
			auto_enabled=0
		elif [[ ${mode} =~ ^[0-9]+$ ]]; then
			(( mode > 0 )) || die "--auto value must be > 0"
			auto_enabled=1
			auto_interval=${mode}
			[[ -n ${auto_url} ]] || die "--auto requires a remote URL via -c"
		else
			die "Invalid --auto value: ${AUTO_MODE}"
		fi
	fi

	write_auto_conf "${auto_enabled}" "${auto_interval}" "${auto_url}"

	if is_systemd; then
		setup_systemd
	elif is_alpine; then
		setup_openrc
		(( auto_enabled )) && setup_alpine_cron
	else
		die "No supported init system (need systemd or OpenRC)"
	fi

	echo ""
	log_ok "komari-agent installed"
	log_info "  User:    ${SERVICE_USER} (nologin, no home)"
	log_info "  Dir:     ${INSTALL_DIR}"
	log_info "  Config:  ${CONFIG_PATH} (mode 600)"
	log_info "  Binary:  ${BIN_PATH} (mode 750)"
	if (( auto_enabled )); then
		log_info "  Sync:    every ${auto_interval} min from ${auto_url}"
	else
		log_info "  Sync:    disabled"
	fi
	log_info "  Logs:    sudo bash ${SCRIPT_NAME} -log"
	log_info "  Remove:  sudo bash ${SCRIPT_NAME} -u"
}

main "$@"
