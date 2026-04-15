#!/usr/bin/env bash
set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/home/VM/tinyvm}"
CREATE_SYMLINK="${CREATE_SYMLINK:-1}"
CREATE_DESKTOP_ENTRY="${CREATE_DESKTOP_ENTRY:-1}"
SYMLINK_PATH="${SYMLINK_PATH:-/usr/local/bin/tinyvm}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-0}"

BIN_DIR="${INSTALL_ROOT}/bin"
VM_DIR="${INSTALL_ROOT}/vms"
CACHE_DIR="${INSTALL_ROOT}/cache"
CONFIG_DIR="${INSTALL_ROOT}/config"
BACKUP_DIR="${INSTALL_ROOT}/backups"
DESKTOP_DIR="${HOME}/.local/share/applications"
VERSION_FILE="${INSTALL_ROOT}/VERSION"

APP_VERSION="2.1.0"

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }

require_basic_tools() {
  local missing=0
  for cmd in bash find grep sed cut sort wc dirname basename mkdir chmod cat cp mv rm date uname readlink; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "Missing required basic tool: $cmd"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || exit 1
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
    return
  fi
  echo "unknown"
}

install_dependencies_if_requested() {
  local pm
  pm="$(detect_pkg_manager)"

  if [[ "$AUTO_INSTALL_DEPS" != "1" ]]; then
    info "AUTO_INSTALL_DEPS=0, skipping package installation."
    return
  fi

  if [[ "$pm" != "apt" ]]; then
    warn "Auto dependency install currently supports apt-based hosts only."
    return
  fi

  info "Installing Tiny VM Desktop runtime dependencies..."

  sudo apt-get update
  sudo apt-get install -y \
    qemu-system-x86 \
    qemu-utils \
    ovmf \
    swtpm \
    virt-viewer \
    spice-client-gtk \
    spice-vdagent \
    curl \
    wget \
    nano
}

check_runtime_tools() {
  info "Checking runtime tools..."
  for cmd in quickemu quickget qemu-img remote-viewer; do
    if command -v "$cmd" >/dev/null 2>&1; then
      info "Found: $cmd"
    else
      warn "Not found in PATH: $cmd"
    fi
  done
}

backup_existing_install() {
  if [[ -d "$INSTALL_ROOT" ]]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    if [[ -d "$BIN_DIR" || -d "$CONFIG_DIR" ]]; then
      local target="${BACKUP_DIR}/${stamp}"
      mkdir -p "$target"
      [[ -d "$BIN_DIR" ]] && cp -a "$BIN_DIR" "$target/bin"
      [[ -d "$CONFIG_DIR" ]] && cp -a "$CONFIG_DIR" "$target/config"
      info "Backed up existing bin/config to: $target"
    fi
  fi
}

make_dirs() {
  mkdir -p "$BIN_DIR" "$VM_DIR" "$CACHE_DIR" "$CONFIG_DIR" "$BACKUP_DIR"
}

write_version() {
  printf '%s\n' "$APP_VERSION" > "$VERSION_FILE"
}

write_shared_config() {
  cat > "${CONFIG_DIR}/tinyvm.conf" <<EOF
#!/usr/bin/env bash

TINYVM_ROOT="${INSTALL_ROOT}"
VM_ROOT="\${TINYVM_ROOT}/vms"
CACHE_DIR="\${TINYVM_ROOT}/cache"
BIN_DIR="\${TINYVM_ROOT}/bin"
CONFIG_DIR="\${TINYVM_ROOT}/config"

VM_INDEX_FILE="\${CACHE_DIR}/vm-index.txt"

DEFAULT_LAUNCH_MODE="safe"

SAFE_DISPLAY_MODE="sdl"
SPICE_DISPLAY_MODE="spice"

DEFAULT_WIDTH="1280"
DEFAULT_HEIGHT="800"

RESCUE_WIDTH="1024"
RESCUE_HEIGHT="768"

EDITOR_CMD="\${EDITOR:-nano}"

QUICKEMU_BIN="\${QUICKEMU_BIN:-quickemu}"
QUICKGET_BIN="\${QUICKGET_BIN:-quickget}"

DEBUG="\${DEBUG:-0}"
EOF
}

write_common_lib() {
  cat > "${BIN_DIR}/tinyvm-lib.sh" <<'EOF'
#!/usr/bin/env bash

get_script_realpath() {
  local source="${BASH_SOURCE[0]}"
  while [ -h "$source" ]; do
    local dir
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  printf '%s\n' "$(cd -P "$(dirname "$source")" && pwd)/$(basename "$source")"
}

get_base_dir() {
  local script_path
  script_path="$(get_script_realpath)"
  local script_dir
  script_dir="$(dirname "$script_path")"
  printf '%s\n' "$(cd "$script_dir/.." && pwd)"
}

set_or_add_conf_value() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
  else
    printf '%s="%s"\n' "$key" "$value" >> "$file"
  fi
}

get_conf_value() {
  local key="$1"
  local file="$2"
  local value
  value="$(grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- || true)"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "$value"
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}
EOF
}

write_scan_script() {
  cat > "${BIN_DIR}/tinyvm-scan-vms.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/config/tinyvm.conf"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

mkdir -p "$CACHE_DIR"

extract_value() {
  local key="$1"
  local file="$2"
  local value
  value="$(grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- || true)"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "$value"
}

detect_disk_file() {
  local dir="$1"
  local disk
  disk="$(find "$dir" -maxdepth 1 -type f \( -name "*.qcow2" -o -name "*.img" -o -name "*.raw" -o -name "*.vmdk" \) | head -n1 || true)"
  printf '%s' "$disk"
}

detect_os_type() {
  local conf="$1"
  local os="unknown"
  local guest_os lower name

  guest_os="$(extract_value "guest_os" "$conf")"
  if [[ -n "$guest_os" ]]; then
    printf '%s' "$guest_os"
    return 0
  fi

  name="$(basename "$conf" .conf)"
  lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower" == *windows* ]]; then
    os="windows"
  elif [[ "$lower" == *macos* ]] || [[ "$lower" == *osx* ]] || [[ "$lower" == *ventura* ]] || [[ "$lower" == *sonoma* ]] || [[ "$lower" == *sequoia* ]] || [[ "$lower" == *monterey* ]] || [[ "$lower" == *big-sur* ]] || [[ "$lower" == *catalina* ]] || [[ "$lower" == *mojave* ]]; then
    os="macos"
  elif [[ "$lower" == *ubuntu* ]] || [[ "$lower" == *debian* ]] || [[ "$lower" == *arch* ]] || [[ "$lower" == *alpine* ]] || [[ "$lower" == *kali* ]] || [[ "$lower" == *lubuntu* ]]; then
    os="linux"
  fi

  printf '%s' "$os"
}

main() {
  : > "$VM_INDEX_FILE"

  while IFS= read -r -d '' conf; do
    vm_dir="$(dirname "$conf")"
    vm_name="$(basename "$conf" .conf)"
    os_type="$(detect_os_type "$conf")"
    ram="$(extract_value "ram" "$conf")"
    cpu="$(extract_value "cpu_cores" "$conf")"
    disk="$(detect_disk_file "$vm_dir")"
    launch_mode="$(extract_value "tinyvm_launch_mode" "$conf")"

    [[ -z "$ram" ]] && ram="unknown"
    [[ -z "$cpu" ]] && cpu="unknown"
    [[ -z "$disk" ]] && disk="none"
    [[ -z "$launch_mode" ]] && launch_mode="safe"

    printf '%s|%s|%s|%s|%s|%s|%s\n' \
      "$vm_name" \
      "$os_type" \
      "$ram" \
      "$cpu" \
      "$disk" \
      "$conf" \
      "$launch_mode" >> "$VM_INDEX_FILE"
  done < <(find "$VM_ROOT" -type f -name "*.conf" -print0 | sort -z)

  count="$(wc -l < "$VM_INDEX_FILE" 2>/dev/null || echo 0)"
  echo "Scan complete. Found ${count} VM(s)."
  echo "Index written to: $VM_INDEX_FILE"
}

main "$@"
EOF
}

write_patch_existing_script() {
  cat > "${BIN_DIR}/tinyvm-patch-existing-vms.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/config/tinyvm.conf"
LIB_FILE="${BASE_DIR}/bin/tinyvm-lib.sh"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
# shellcheck source=/dev/null
source "$LIB_FILE"

main() {
  local count=0
  while IFS= read -r -d '' conf; do
    set_or_add_conf_value "width" "$DEFAULT_WIDTH" "$conf"
    set_or_add_conf_value "height" "$DEFAULT_HEIGHT" "$conf"

    if [[ -z "$(get_conf_value "tinyvm_launch_mode" "$conf")" ]]; then
      set_or_add_conf_value "tinyvm_launch_mode" "$DEFAULT_LAUNCH_MODE" "$conf"
    fi

    if [[ -z "$(get_conf_value "guest_os" "$conf")" ]]; then
      name="$(basename "$conf" .conf | tr '[:upper:]' '[:lower:]')"
      if [[ "$name" == *macos* ]] || [[ "$name" == *mojave* ]] || [[ "$name" == *catalina* ]] || [[ "$name" == *big-sur* ]] || [[ "$name" == *monterey* ]] || [[ "$name" == *ventura* ]] || [[ "$name" == *sonoma* ]] || [[ "$name" == *sequoia* ]]; then
        set_or_add_conf_value "guest_os" "macos" "$conf"
      fi
    fi

    count=$((count + 1))
  done < <(find "$VM_ROOT" -type f -name "*.conf" -print0)

  echo "Patched ${count} VM config(s)."
  "${BIN_DIR}/tinyvm-scan-vms.sh" >/dev/null || true
}
main "$@"
EOF
}

write_launch_script() {
  cat > "${BIN_DIR}/tinyvm-launch-existing.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/config/tinyvm.conf"
LIB_FILE="${BASE_DIR}/bin/tinyvm-lib.sh"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
# shellcheck source=/dev/null
source "$LIB_FILE"

scan_if_needed() {
  if [[ ! -f "$VM_INDEX_FILE" ]]; then
    "${BIN_DIR}/tinyvm-scan-vms.sh"
  fi
}

list_vms() {
  local i=1
  while IFS='|' read -r vm_name os_type ram cpu disk conf_path launch_mode; do
    [[ -z "$vm_name" ]] && continue
    printf '%2d) %-24s | OS: %-10s | RAM: %-8s | CPU: %-4s | MODE: %-6s\n' "$i" "$vm_name" "$os_type" "$ram" "$cpu" "$launch_mode"
    i=$((i + 1))
  done < "$VM_INDEX_FILE"
}

pick_vm() {
  scan_if_needed

  if [[ ! -s "$VM_INDEX_FILE" ]]; then
    echo "No VMs found."
    exit 0
  fi

  echo
  echo "Available VMs:"
  list_vms
  echo

  read -rp "Enter VM number: " selection
  [[ "$selection" =~ ^[0-9]+$ ]] || { echo "Invalid selection."; exit 1; }

  line="$(sed -n "${selection}p" "$VM_INDEX_FILE")"
  [[ -n "$line" ]] || { echo "No VM matches that selection."; exit 1; }

  IFS='|' read -r vm_name os_type ram cpu disk conf_path launch_mode <<< "$line"
}

launch_safe() {
  local conf_path="$1"
  local width height
  width="$(get_conf_value "width" "$conf_path")"
  height="$(get_conf_value "height" "$conf_path")"
  [[ -z "$width" ]] && width="$DEFAULT_WIDTH"
  [[ -z "$height" ]] && height="$DEFAULT_HEIGHT"

  echo
  echo "Launching SAFE mode"
  echo "Display: $SAFE_DISPLAY_MODE"
  echo "Window:  ${width}x${height}"
  echo

  exec "$QUICKEMU_BIN" \
    --vm "$conf_path" \
    --display "$SAFE_DISPLAY_MODE" \
    --width "$width" \
    --height "$height"
}

launch_spice() {
  local conf_path="$1"
  local width height
  width="$(get_conf_value "width" "$conf_path")"
  height="$(get_conf_value "height" "$conf_path")"
  [[ -z "$width" ]] && width="$DEFAULT_WIDTH"
  [[ -z "$height" ]] && height="$DEFAULT_HEIGHT"

  if ! command -v remote-viewer >/dev/null 2>&1; then
    echo "ERROR: remote-viewer not found."
    echo "Install virt-viewer to use SPICE mode."
    exit 1
  fi

  echo
  echo "Launching SPICE mode"
  echo "Display: $SPICE_DISPLAY_MODE"
  echo "Window:  ${width}x${height}"
  echo

  exec "$QUICKEMU_BIN" \
    --vm "$conf_path" \
    --display "$SPICE_DISPLAY_MODE" \
    --width "$width" \
    --height "$height"
}

launch_rescue() {
  local conf_path="$1"

  echo
  echo "Launching RESCUE mode"
  echo "Display: $SAFE_DISPLAY_MODE"
  echo "Window:  ${RESCUE_WIDTH}x${RESCUE_HEIGHT}"
  echo "Purpose: force a small safe window"
  echo

  exec "$QUICKEMU_BIN" \
    --vm "$conf_path" \
    --display "$SAFE_DISPLAY_MODE" \
    --width "$RESCUE_WIDTH" \
    --height "$RESCUE_HEIGHT"
}

main() {
  command -v "$QUICKEMU_BIN" >/dev/null 2>&1 || { echo "ERROR: quickemu not found."; exit 1; }

  pick_vm

  echo
  echo "Launch options:"
  echo "1) Use VM saved mode (${launch_mode:-safe})"
  echo "2) Force SAFE mode"
  echo "3) Force SPICE mode"
  echo "4) RESCUE mode (small safe SDL window)"
  echo

  read -rp "Choose launch mode: " mode_choice

  case "$mode_choice" in
    1)
      case "${launch_mode:-safe}" in
        spice) launch_spice "$conf_path" ;;
        *) launch_safe "$conf_path" ;;
      esac
      ;;
    2) launch_safe "$conf_path" ;;
    3) launch_spice "$conf_path" ;;
    4) launch_rescue "$conf_path" ;;
    *) echo "Invalid option."; exit 1 ;;
  esac
}

main "$@"
EOF
}

write_set_mode_script() {
  cat > "${BIN_DIR}/tinyvm-set-launch-mode.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/config/tinyvm.conf"
LIB_FILE="${BASE_DIR}/bin/tinyvm-lib.sh"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
# shellcheck source=/dev/null
source "$LIB_FILE"

scan_if_needed() {
  if [[ ! -f "$VM_INDEX_FILE" ]]; then
    "${BIN_DIR}/tinyvm-scan-vms.sh"
  fi
}

list_vms() {
  local i=1
  while IFS='|' read -r vm_name os_type ram cpu disk conf_path launch_mode; do
    [[ -z "$vm_name" ]] && continue
    printf '%2d) %-24s | OS: %-10s | MODE: %-6s\n' "$i" "$vm_name" "$os_type" "$launch_mode"
    i=$((i + 1))
  done < "$VM_INDEX_FILE"
}

main() {
  scan_if_needed
  [[ -s "$VM_INDEX_FILE" ]] || { echo "No VMs found."; exit 0; }

  echo
  echo "Available VMs:"
  list_vms
  echo

  read -rp "Enter VM number: " selection
  [[ "$selection" =~ ^[0-9]+$ ]] || { echo "Invalid selection."; exit 1; }

  line="$(sed -n "${selection}p" "$VM_INDEX_FILE")"
  [[ -n "$line" ]] || { echo "No VM matches that selection."; exit 1; }

  IFS='|' read -r vm_name os_type ram cpu disk conf_path launch_mode <<< "$line"

  echo
  echo "Set launch mode for: $vm_name"
  echo "1) safe"
  echo "2) spice"
  echo

  read -rp "Choose mode: " mode
  case "$mode" in
    1) set_or_add_conf_value "tinyvm_launch_mode" "safe" "$conf_path" ;;
    2) set_or_add_conf_value "tinyvm_launch_mode" "spice" "$conf_path" ;;
    *) echo "Invalid option."; exit 1 ;;
  esac

  "${BIN_DIR}/tinyvm-scan-vms.sh" >/dev/null || true
  echo "Launch mode updated."
}
main "$@"
EOF
}

write_delete_script() {
  cat > "${BIN_DIR}/tinyvm-delete-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/config/tinyvm.conf"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

scan_if_needed() {
  [[ -f "$VM_INDEX_FILE" ]] || "${BIN_DIR}/tinyvm-scan-vms.sh"
}

list_vms() {
  local i=1
  while IFS='|' read -r vm_name os_type ram cpu disk conf_path launch_mode; do
    [[ -z "$vm_name" ]] && continue
    printf '%2d) %-24s | OS: %-10s | MODE: %-6s\n' "$i" "$vm_name" "$os_type" "$launch_mode"
    i=$((i + 1))
  done < "$VM_INDEX_FILE"
}

main() {
  scan_if_needed
  [[ -s "$VM_INDEX_FILE" ]] || { echo "No VMs found."; exit 0; }

  echo
  echo "Available VMs:"
  list_vms
  echo

  read -rp "Enter VM number to delete: " selection
  [[ "$selection" =~ ^[0-9]+$ ]] || { echo "Invalid selection."; exit 1; }

  line="$(sed -n "${selection}p" "$VM_INDEX_FILE")"
  [[ -n "$line" ]] || { echo "No VM matches that selection."; exit 1; }

  IFS='|' read -r vm_name os_type ram cpu disk conf_path launch_mode <<< "$line"
  vm_dir="$(dirname "$conf_path")"

  echo
  echo "Delete permanently:"
  echo "Name: $vm_name"
  echo "Path: $vm_dir"
  echo

  read -rp "Type DELETE to confirm: " confirm
  [[ "$confirm" == "DELETE" ]] || { echo "Cancelled."; exit 0; }

  rm -rf -- "$vm_dir"
  "${BIN_DIR}/tinyvm-scan-vms.sh" >/dev/null || true
  echo "Deleted."
}
main "$@"
EOF
}

write_edit_script() {
  cat > "${BIN_DIR}/tinyvm-edit-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/config/tinyvm.conf"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

scan_if_needed() {
  [[ -f "$VM_INDEX_FILE" ]] || "${BIN_DIR}/tinyvm-scan-vms.sh"
}

list_vms() {
  local i=1
  while IFS='|' read -r vm_name os_type ram cpu disk conf_path launch_mode; do
    [[ -z "$vm_name" ]] && continue
    printf '%2d) %-24s | OS: %-10s | MODE: %-6s\n' "$i" "$vm_name" "$os_type" "$launch_mode"
    i=$((i + 1))
  done < "$VM_INDEX_FILE"
}

main() {
  scan_if_needed
  [[ -s "$VM_INDEX_FILE" ]] || { echo "No VMs found."; exit 0; }

  echo
  echo "Available VMs:"
  list_vms
  echo

  read -rp "Enter VM number to edit: " selection
  [[ "$selection" =~ ^[0-9]+$ ]] || { echo "Invalid selection."; exit 1; }

  line="$(sed -n "${selection}p" "$VM_INDEX_FILE")"
  [[ -n "$line" ]] || { echo "No VM matches that selection."; exit 1; }

  IFS='|' read -r vm_name os_type ram cpu disk conf_path launch_mode <<< "$line"

  echo
  echo "Editing: $conf_path"
  echo
  echo 'Common values:'
  echo '  ram="8192"'
  echo '  cpu_cores="4"'
  echo '  width="1280"'
  echo '  height="800"'
  echo '  tinyvm_launch_mode="safe"'
  echo '  tinyvm_launch_mode="spice"'
  echo

  "$EDITOR_CMD" "$conf_path"
  "${BIN_DIR}/tinyvm-scan-vms.sh" >/dev/null || true
}
main "$@"
EOF
}

write_quick_wizard() {
  cat > "${BIN_DIR}/tinyvm-quick-wizard.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/config/tinyvm.conf"
LIB_FILE="${BASE_DIR}/bin/tinyvm-lib.sh"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
# shellcheck source=/dev/null
source "$LIB_FILE"

require_bin() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: Required command not found: $bin"; exit 1; }
}

pick_preset() {
  cat <<'EOF2'
1) Windows 10
2) Windows 11
3) macOS Mojave
4) macOS Catalina
5) macOS Big Sur
6) macOS Monterey
7) macOS Ventura
8) macOS Sonoma
9) macOS Sequoia
10) Ubuntu
11) Debian
12) Lubuntu
13) Alpine
14) Kali
15) Arch
16) Custom quickget arguments
EOF2
}

resolve_quickget_args() {
  local choice="$1"
  case "$choice" in
    1)  echo "windows 10" ;;
    2)  echo "windows 11" ;;
    3)  echo "macos mojave" ;;
    4)  echo "macos catalina" ;;
    5)  echo "macos big-sur" ;;
    6)  echo "macos monterey" ;;
    7)  echo "macos ventura" ;;
    8)  echo "macos sonoma" ;;
    9)  echo "macos sequoia" ;;
    10) echo "ubuntu" ;;
    11) echo "debian" ;;
    12) echo "lubuntu" ;;
    13) echo "alpine" ;;
    14) echo "kali" ;;
    15) echo "arch" ;;
    16) return 1 ;;
    *) return 2 ;;
  esac
}

is_macos_args() {
  local args="$1"
  [[ "$args" == macos* ]]
}

main() {
  require_bin "$QUICKGET_BIN"

  mkdir -p "$VM_ROOT"

  echo
  echo "Tiny VM Desktop - Quick Wizard"
  echo "=============================="
  echo
  pick_preset
  echo

  read -rp "Choose OS preset: " preset_choice

  quickget_args=""
  if quickget_args="$(resolve_quickget_args "$preset_choice")"; then
    :
  else
    status=$?
    if [[ $status -eq 1 ]]; then
      read -rp "Enter custom quickget arguments (example: windows 10): " quickget_args
    else
      echo "Invalid selection."
      exit 1
    fi
  fi

  read -rp "Enter VM name: " vm_name
  vm_name="$(slugify "$vm_name")"
  [[ -n "$vm_name" ]] || { echo "VM name cannot be empty."; exit 1; }

  read -rp "RAM in MB (example 4096): " ram
  read -rp "CPU cores (example 4): " cpu
  read -rp "Disk size in GB (example 64): " disk
  read -rp "Default launch mode [safe/spice] (default safe): " vm_mode

  [[ -z "$ram" ]] && ram="4096"
  [[ -z "$cpu" ]] && cpu="2"
  [[ -z "$disk" ]] && disk="64"
  [[ -z "$vm_mode" ]] && vm_mode="safe"

  case "$vm_mode" in
    safe|spice) ;;
    *) echo "Invalid launch mode."; exit 1 ;;
  esac

  vm_dir="${VM_ROOT}/${vm_name}"
  [[ ! -e "$vm_dir" ]] || { echo "ERROR: VM directory already exists: $vm_dir"; exit 1; }

  mkdir -p "$vm_dir"
  cd "$vm_dir"

  echo
  echo "Running: $QUICKGET_BIN $quickget_args"
  echo "Target:  $vm_dir"
  echo

  # shellcheck disable=SC2086
  "$QUICKGET_BIN" $quickget_args

  conf_file="$(find "$vm_dir" -maxdepth 1 -type f -name "*.conf" | head -n1 || true)"
  [[ -n "$conf_file" ]] || { echo "ERROR: quickget did not produce a .conf file in $vm_dir"; exit 1; }

  desired_conf="${vm_dir}/${vm_name}.conf"
  if [[ "$(basename "$conf_file")" != "${vm_name}.conf" ]]; then
    mv "$conf_file" "$desired_conf"
    conf_file="$desired_conf"
  fi

  disk_file="$(find "$vm_dir" -maxdepth 1 -type f -name "*.qcow2" | head -n1 || true)"
  if [[ -n "$disk_file" && "$(basename "$disk_file")" != "${vm_name}.qcow2" ]]; then
    mv "$disk_file" "${vm_dir}/${vm_name}.qcow2"
  fi

  set_or_add_conf_value "ram" "$ram" "$conf_file"
  set_or_add_conf_value "cpu_cores" "$cpu" "$conf_file"
  set_or_add_conf_value "width" "$DEFAULT_WIDTH" "$conf_file"
  set_or_add_conf_value "height" "$DEFAULT_HEIGHT" "$conf_file"
  set_or_add_conf_value "tinyvm_launch_mode" "$vm_mode" "$conf_file"

  if is_macos_args "$quickget_args"; then
    set_or_add_conf_value "guest_os" "macos" "$conf_file"
  fi

  {
    echo
    echo "# Tiny VM Desktop metadata"
    echo "# requested_disk=${disk}G"
    echo "# default_launch_mode=${vm_mode}"
  } >> "$conf_file"

  echo
  echo "VM created."
  echo "Config: $conf_file"
  echo "Window: ${DEFAULT_WIDTH}x${DEFAULT_HEIGHT}"
  echo "Mode:   $vm_mode"
  echo

  "${BIN_DIR}/tinyvm-scan-vms.sh" >/dev/null || true
}
main "$@"
EOF
}

write_manual_wizard() {
  cat > "${BIN_DIR}/tinyvm-manual-wizard.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/config/tinyvm.conf"
LIB_FILE="${BASE_DIR}/bin/tinyvm-lib.sh"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
# shellcheck source=/dev/null
source "$LIB_FILE"

require_bin() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: Required command not found: $bin"; exit 1; }
}

main() {
  require_bin qemu-img
  mkdir -p "$VM_ROOT"

  echo
  echo "Tiny VM Desktop - Manual / Legacy Wizard"
  echo "========================================"
  echo

  read -rp "Enter VM name: " vm_name
  vm_name="$(slugify "$vm_name")"
  [[ -n "$vm_name" ]] || { echo "VM name cannot be empty."; exit 1; }

  echo
  echo "Guest OS options:"
  echo "1) windows"
  echo "2) macos"
  echo "3) linux"
  echo

  read -rp "Choose guest OS type: " os_choice
  case "$os_choice" in
    1) guest_os="windows" ;;
    2) guest_os="macos" ;;
    3) guest_os="linux" ;;
    *) echo "Invalid choice."; exit 1 ;;
  esac

  read -rp "Full path to ISO (or recovery image if appropriate): " iso_path
  [[ -f "$iso_path" ]] || { echo "ERROR: File not found: $iso_path"; exit 1; }

  read -rp "RAM in MB (example 4096): " ram
  read -rp "CPU cores (example 4): " cpu
  read -rp "Disk size in GB (example 64): " disk
  read -rp "Default launch mode [safe/spice] (default safe): " vm_mode

  [[ -z "$ram" ]] && ram="4096"
  [[ -z "$cpu" ]] && cpu="2"
  [[ -z "$disk" ]] && disk="64"
  [[ -z "$vm_mode" ]] && vm_mode="safe"

  case "$vm_mode" in
    safe|spice) ;;
    *) echo "Invalid launch mode."; exit 1 ;;
  esac

  vm_dir="${VM_ROOT}/${vm_name}"
  mkdir -p "$vm_dir"

  iso_name="$(basename "$iso_path")"
  target_iso="${vm_dir}/${iso_name}"
  [[ "$iso_path" == "$target_iso" ]] || cp -n "$iso_path" "$target_iso"

  disk_file="${vm_dir}/${vm_name}.qcow2"
  conf_file="${vm_dir}/${vm_name}.conf"

  [[ -f "$disk_file" ]] || qemu-img create -f qcow2 "$disk_file" "${disk}G" >/dev/null

  cat > "$conf_file" <<CONFIG
guest_os="${guest_os}"
disk_img="${disk_file}"
iso="${target_iso}"
ram="${ram}"
cpu_cores="${cpu}"
width="${DEFAULT_WIDTH}"
height="${DEFAULT_HEIGHT}"
display_device="virtio-vga"
boot="legacy"
tinyvm_launch_mode="${vm_mode}"
CONFIG

  echo
  echo "Manual VM created."
  echo "Config: $conf_file"
  echo

  "${BIN_DIR}/tinyvm-scan-vms.sh" >/dev/null || true
}
main "$@"
EOF
}

write_manager_script() {
  cat > "${BIN_DIR}/tinyvm-manager.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/config/tinyvm.conf"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

pause() {
  echo
  read -rp "Press Enter to continue..." _
}

show_header() {
  clear 2>/dev/null || true
  echo "Tiny VM Desktop"
  echo "==============="
  echo "VM Root:        $VM_ROOT"
  echo "Default mode:   $DEFAULT_LAUNCH_MODE"
  echo "Safe mode:      $SAFE_DISPLAY_MODE"
  echo "SPICE mode:     $SPICE_DISPLAY_MODE"
  echo "Rescue window:  ${RESCUE_WIDTH}x${RESCUE_HEIGHT}"
  echo
}

show_vm_summary() {
  if [[ ! -f "$VM_INDEX_FILE" ]]; then
    "${BIN_DIR}/tinyvm-scan-vms.sh" >/dev/null 2>&1 || true
  fi

  local count=0
  if [[ -f "$VM_INDEX_FILE" ]]; then
    count="$(wc -l < "$VM_INDEX_FILE" 2>/dev/null || echo 0)"
  fi

  echo "Detected VMs: $count"
  echo
}

view_vm_list() {
  if [[ ! -f "$VM_INDEX_FILE" ]]; then
    "${BIN_DIR}/tinyvm-scan-vms.sh" >/dev/null
  fi

  if [[ ! -s "$VM_INDEX_FILE" ]]; then
    echo "No VMs found."
    return
  fi

  printf '%-4s %-24s %-12s %-10s %-8s %-7s %s\n' "No." "Name" "OS" "RAM" "CPU" "MODE" "Config"
  echo "----------------------------------------------------------------------------------------------------------------"
  local i=1
  while IFS='|' read -r vm_name os_type ram cpu disk conf_path launch_mode; do
    [[ -z "$vm_name" ]] && continue
    printf '%-4s %-24s %-12s %-10s %-8s %-7s %s\n' "$i" "$vm_name" "$os_type" "$ram" "$cpu" "$launch_mode" "$conf_path"
    i=$((i + 1))
  done < "$VM_INDEX_FILE"
}

main_loop() {
  while true; do
    show_header
    show_vm_summary
    echo "1) Create VM"
    echo "2) Launch VM"
    echo "3) Edit VM"
    echo "4) Delete VM"
    echo "5) Set VM Launch Mode"
    echo "6) Patch Existing VMs"
    echo "7) Scan / Refresh VM List"
    echo "8) View VM List"
    echo "9) Exit"
    echo

    read -rp "Choose an option: " choice

    case "$choice" in
      1)
        show_header
        echo "1) Quick Wizard"
        echo "2) Manual / Legacy Wizard"
        echo "3) Back"
        echo
        read -rp "Choose create mode: " create_choice
        case "$create_choice" in
          1) "${BIN_DIR}/tinyvm-quick-wizard.sh"; pause ;;
          2) "${BIN_DIR}/tinyvm-manual-wizard.sh"; pause ;;
          3) ;;
          *) echo "Invalid option."; pause ;;
        esac
        ;;
      2) "${BIN_DIR}/tinyvm-launch-existing.sh" ;;
      3) "${BIN_DIR}/tinyvm-edit-vm.sh"; pause ;;
      4) "${BIN_DIR}/tinyvm-delete-vm.sh"; pause ;;
      5) "${BIN_DIR}/tinyvm-set-launch-mode.sh"; pause ;;
      6) "${BIN_DIR}/tinyvm-patch-existing-vms.sh"; pause ;;
      7) "${BIN_DIR}/tinyvm-scan-vms.sh"; pause ;;
      8) show_header; view_vm_list; pause ;;
      9) echo "Goodbye."; exit 0 ;;
      *) echo "Invalid option."; pause ;;
    esac
  done
}

main_loop "$@"
EOF
}

write_uninstall_script() {
  cat > "${BIN_DIR}/tinyvm-uninstall.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "This will remove the Tiny VM Desktop program files from:"
echo "  ${INSTALL_ROOT}"
echo
read -rp "Type REMOVE to continue: " confirm
[[ "\$confirm" == "REMOVE" ]] || { echo "Cancelled."; exit 0; }

rm -rf -- "${INSTALL_ROOT}"
echo "Removed: ${INSTALL_ROOT}"
EOF
}

set_permissions() {
  chmod +x \
    "${CONFIG_DIR}/tinyvm.conf" \
    "${BIN_DIR}/tinyvm-lib.sh" \
    "${BIN_DIR}/tinyvm-scan-vms.sh" \
    "${BIN_DIR}/tinyvm-patch-existing-vms.sh" \
    "${BIN_DIR}/tinyvm-launch-existing.sh" \
    "${BIN_DIR}/tinyvm-set-launch-mode.sh" \
    "${BIN_DIR}/tinyvm-delete-vm.sh" \
    "${BIN_DIR}/tinyvm-edit-vm.sh" \
    "${BIN_DIR}/tinyvm-quick-wizard.sh" \
    "${BIN_DIR}/tinyvm-manual-wizard.sh" \
    "${BIN_DIR}/tinyvm-manager.sh" \
    "${BIN_DIR}/tinyvm-uninstall.sh"
}

create_symlink() {
  if [[ "$CREATE_SYMLINK" != "1" ]]; then
    info "Skipping symlink creation."
    return
  fi

  if [[ ! -w "$(dirname "$SYMLINK_PATH")" ]]; then
    warn "No write access to $(dirname "$SYMLINK_PATH"), skipping symlink."
    warn "Create later with: sudo ln -sf ${BIN_DIR}/tinyvm-manager.sh ${SYMLINK_PATH}"
    return
  fi

  ln -sf "${BIN_DIR}/tinyvm-manager.sh" "$SYMLINK_PATH"
  info "Created symlink: $SYMLINK_PATH -> ${BIN_DIR}/tinyvm-manager.sh"
}

create_desktop_entry() {
  if [[ "$CREATE_DESKTOP_ENTRY" != "1" ]]; then
    info "Skipping desktop entry."
    return
  fi

  mkdir -p "$DESKTOP_DIR"

  cat > "${DESKTOP_DIR}/tinyvm.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Tiny VM Desktop
Comment=Launch Tiny VM Desktop Manager
Exec=${BIN_DIR}/tinyvm-manager.sh
Terminal=true
Categories=System;Emulator;
Icon=utilities-terminal
EOF

  info "Desktop entry created: ${DESKTOP_DIR}/tinyvm.desktop"
}

final_message() {
  echo
  info "Tiny VM Desktop v${APP_VERSION} installed successfully."
  echo
  echo "Run:"
  echo "  ${BIN_DIR}/tinyvm-manager.sh"
  echo
  if [[ "$CREATE_SYMLINK" == "1" ]]; then
    echo "Or:"
    echo "  tinyvm"
    echo
  fi
  echo "Recommended first actions:"
  echo "  1) Patch Existing VMs"
  echo "  2) Set Mojave to safe"
  echo "  3) Launch Mojave in Rescue mode if needed"
  echo
}

main() {
  require_basic_tools
  install_dependencies_if_requested
  check_runtime_tools
  backup_existing_install
  make_dirs
  write_version
  write_shared_config
  write_common_lib
  write_scan_script
  write_patch_existing_script
  write_launch_script
  write_set_mode_script
  write_delete_script
  write_edit_script
  write_quick_wizard
  write_manual_wizard
  write_manager_script
  write_uninstall_script
  set_permissions
  create_symlink
  create_desktop_entry
  "${BIN_DIR}/tinyvm-patch-existing-vms.sh" >/dev/null 2>&1 || true
  "${BIN_DIR}/tinyvm-scan-vms.sh" >/dev/null 2>&1 || true
  final_message
}

main "$@"