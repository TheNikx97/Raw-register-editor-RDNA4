#!/bin/bash
# Standalone Raw Register Viewer / Editor for AMD RDNA4 VR (voltage regulator) i2c registers.

#Disclaimer: I release this tool for research and academic purposes
#If you use this tool and your GPU fails, do not claim warranty
#You use this tool at your own risk, I am not responsible for any damage

set -o pipefail

#############################################
# Paths / state files
#############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTERS_CONF="$SCRIPT_DIR/registers.conf"
LOG_FILE="$SCRIPT_DIR/register_editor.log"
EEPROM_COUNT_FILE="$SCRIPT_DIR/.eeprom_write_count"
LOCK_FILE="/tmp/raw_register_editor.lock"

EEPROM_WARN_THRESHOLD=50

#############################################
# Global constants
#############################################

# VR addresses
vr1="0x22"
vr2="0x24"

# VR pages
page0="0x00"
page1="0x01"
page2="0x02"

# Global variables
bus_number=""

I2C_DELAY=0.1
I2C_RETRIES=5

#############################################
# CLI args
#############################################

READ_ONLY=0
DUMP_FILE=""

print_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

  --read-only          Print the register table once and exit (no writes possible)
  --dump-file=PATH      Write a plain-text register dump to PATH and exit
  -h, --help            Show this help

With no options, starts the interactive raw register editor.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --read-only) READ_ONLY=1 ;;
    --dump-file=*) DUMP_FILE="${arg#--dump-file=}" ;;
    -h|--help) print_help; exit 0 ;;
    *)
      echo "Unknown option: $arg"
      print_help
      exit 1
      ;;
  esac
done

#############################################
# Logging
#############################################

log_action() {
  local msg="$1"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE"
}

#############################################
# Lock (prevent concurrent instances hammering the same i2c bus)
#############################################

acquire_lock() {
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    echo -e "\033[1;31mAnother instance appears to be running (lock: $LOCK_FILE). Exiting.\033[0m"
    exit 1
  fi
}

#############################################
# Cleanup trap: always leave VR page pointer at 0x00
#############################################

cleanup() {
  # Best-effort, ignore failures (bus_number may not be set yet if we bail out early)
  if [[ -n "$bus_number" ]]; then
    i2c_set_page "$bus_number" "$vr1" 0x00 >/dev/null 2>&1
    i2c_set_page "$bus_number" "$vr2" 0x00 >/dev/null 2>&1
  fi
}
trap cleanup EXIT INT TERM

#############################################
# Setup functions
#############################################

# Function to detect the operating system
detect_os() {
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Detected Linux OS"
  else
    echo -e "\033[1;31mUnsupported OS: $OSTYPE. Exiting.\033[0m"
    exit 1
  fi
}

# Function to check if i2c_dev module is loaded and load it if necessary
check_i2c_module() {
  if ! lsmod | grep -q i2c_dev; then
    sudo modprobe i2c_dev
    echo "Loaded i2c_dev module"
  else
    echo "i2c_dev module already loaded"
  fi
}

# Function to install i2c-tools, bc and flock (util-linux) based on the detected OS
install_i2c_tools() {
  if command -v apt-get &> /dev/null; then
    # Debian-based system (e.g., Ubuntu)
    if ! dpkg-query -W -f='${Status}' i2c-tools 2>/dev/null | grep -q "ok installed"; then
      sudo apt-get update
      sudo apt-get install -y i2c-tools bc util-linux
      echo "Installed i2c-tools, bc and util-linux"
    elif ! dpkg-query -W -f='${Status}' bc 2>/dev/null | grep -q "ok installed"; then
      sudo apt-get install -y bc
      echo "Installed bc"
    else
      echo "i2c-tools and bc are already installed."
    fi
  elif command -v pacman &> /dev/null; then
    # Arch Linux
    if ! pacman -Q i2c-tools &> /dev/null; then
      sudo pacman -Sy --noconfirm i2c-tools bc util-linux
      echo "Installed i2c-tools, bc and util-linux"
    elif ! pacman -Q bc &> /dev/null; then
      sudo pacman -S --noconfirm bc
      echo "Installed bc"
    else
      echo "i2c-tools and bc are already installed."
    fi
  elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
    # YUM-based system (e.g., CentOS, RHEL)
    package_manager="yum"
    if command -v dnf &> /dev/null; then
      package_manager="dnf"
    fi

    if ! rpm -q i2c-tools &> /dev/null; then
      sudo $package_manager install -y i2c-tools bc util-linux
      echo "Installed i2c-tools, bc and util-linux"
    elif ! rpm -q bc &> /dev/null; then
      sudo $package_manager install -y bc
      echo "Installed bc"
    else
      echo "i2c-tools and bc are already installed."
    fi
  else
    echo -e "\033[1;31mUnsupported package manager. Please install i2c-tools, bc and flock (util-linux) manually.\033[0m"
    exit 1
  fi

  if ! command -v flock &> /dev/null; then
    echo -e "\033[1;31mflock command not found. Please install util-linux.\033[0m"
    exit 1
  fi
}

find_i2c_bus() {
  # Get matching i2c lines (SMU 0 or bcm)
  mapfile -t matches < <(i2cdetect -l | grep -E "SMU 0|bcm")

  if [ ${#matches[@]} -eq 0 ]; then
    echo -e "\033[1;31mNo i2c bus with \"SMU 0\" or \"bcm\" found.\033[0m"
    exit 1
  fi

  # If only one match, select it automatically
  if [ ${#matches[@]} -eq 1 ]; then
    selected_line="${matches[0]}"
  else
    echo "Multiple matching i2c buses found:"
    echo

    # Show numbered menu
    for i in "${!matches[@]}"; do
      bus=$(echo "${matches[$i]}" | awk '{print $1}')
      desc=$(echo "${matches[$i]}" | cut -f3)
      printf "  [%d] %s (%s)\n" "$((i+1))" "$bus" "$desc"
    done

    echo
    while true; do
      read -rp "Select the i2c bus to use [1-${#matches[@]}]: " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#matches[@]} )); then
        selected_line="${matches[$((choice-1))]}"
        break
      fi
      echo "Invalid selection, try again."
    done
  fi

  # Extract bus number
  bus_number=$(echo "$selected_line" | awk '{print $1}' | cut -d '-' -f 2)

  # Determine why it matched
  if echo "$selected_line" | grep -q "SMU 0"; then
    I2C_BACKEND="SMU 0"
  else
    I2C_BACKEND="bcm"
  fi

  export I2C_BACKEND
  echo "Using i2c bus: i2c-$bus_number ($I2C_BACKEND)"
}

gpu_check() {
  local first_byte second_byte check_value

  # Helper function to read two bytes from a VR device
  read_vr_bytes() {
    local vr="$1"
    local check_value

    # Set and verify page 0 using robust path
    if ! i2c_set_page "$bus_number" "$vr" "$page0"; then
      echo -e "\033[1;31mError: Failed to set page 0x00 on VR device $vr.\033[0m"
      exit 1
    fi

    # Read register 0x9A (word)
    if ! check_value=$(i2c_read_register "$vr" "$page0" 0x9a w); then
      echo -e "\033[1;31mError: Failed to read register 0x9A from VR device $vr.\033[0m"
      exit 1
    fi

    # Normalize value
    check_value="${check_value#0x}"

    if [[ ${#check_value} -eq 4 ]]; then
      first_byte="${check_value:2:2}"
      second_byte="${check_value:0:2}"
    else
      echo -e "\033[1;31mError: Unexpected data format from VR device $vr: 0x$check_value\033[0m"
      exit 1
    fi
  }

  # --- Step 1: Detect GPU type on first VR device (vr1) ---
  read_vr_bytes "$vr1"

  if [ "$first_byte" == "57" ] || [ "$second_byte" == "57" ]; then
    echo "Detected RDNA3 GPU, this script doesn't support RDNA3"
    exit 1
  elif [ "$first_byte" == "68" ] || [ "$second_byte" == "68" ]; then
    echo "Detected RDNA4 GPU on first VR device ($vr1)"
  else
    echo -e "\033[1;31mUnsupported GPU type detected on $vr1. Found bytes: $first_byte, $second_byte.\033[0m"
    exit 1
  fi

  # --- Step 2: Validate RDNA4 GPU on both VR devices ---
  for vr in "$vr1" "$vr2"; do
    read_vr_bytes "$vr"

    if [ "$first_byte" != "68" ] && [ "$second_byte" != "68" ]; then
      echo -e "\033[1;31mError: The byte at VR device $vr for RDNA4 should be 68. Found bytes: $first_byte, $second_byte.\033[0m"
      exit 1
    fi
  done

  echo -e "\033[1;36m[✓ ]\033[0m GPU validated successfully!\n"
}

#############################################
# Low-level i2c helpers
#############################################

i2c_do() {
  local cmd="$1"
  shift
  local attempt out

  for ((attempt=1; attempt<=I2C_RETRIES; attempt++)); do
    if [[ "$cmd" == "set" ]]; then
      if i2cset -y "$@" >/dev/null 2>&1; then
        sleep "$I2C_DELAY"
        return 0
      fi
    else
      if out=$(i2cget -y "$@" 2>/dev/null); then
        echo "$out"
        return 0
      fi
    fi

    sleep "$I2C_DELAY"
  done

  return 1
}

i2c_write_verify() {
  local bus="$1"
  local addr="$2"
  local reg="$3"
  local val="$4"
  local width="$5"

  local attempt rb
  val="${val#0x}"

  for ((attempt=1; attempt<=I2C_RETRIES; attempt++)); do
    i2c_do set "$bus" "$addr" "$reg" "0x$val" "$width" || continue

    rb=$(i2c_do get "$bus" "$addr" "$reg" "$width") || continue
    rb="${rb#0x}"

    # Normalize both to integers
    val_int=$((16#$val))
    rb_int=$((16#${rb#0x}))

    if (( rb_int == val_int )); then
      return 0
    fi

  done
  return 1
}

i2c_set_page() {
  local bus="$1"
  local addr="$2"
  local page="$3"
  i2c_write_verify "$bus" "$addr" 0x00 "$page" b
}

i2c_write_register() {
  local addr="$1"
  local page="$2"
  local reg="$3"
  local val="$4"
  local width="${5:-w}"

  i2c_set_page "$bus_number" "$addr" "$page" || return 1
  i2c_write_verify "$bus_number" "$addr" "$reg" "$val" "$width" || return 1
  i2c_set_page "$bus_number" "$addr" 0x00 || return 1
}

i2c_read_register() {
  local addr="$1"
  local page="$2"
  local reg="$3"
  local val
  local width="${4:-w}"

  i2c_set_page "$bus_number" "$addr" "$page" || return 1
  val=$(i2c_do get "$bus_number" "$addr" "$reg" "$width") || return 1
  i2c_set_page "$bus_number" "$addr" 0x00 || return 1

  echo "$val"
}

# Permanently commits the current register values to the VR's EEPROM
save_to_eeprom() {
  local addr="$1"

  i2c_set_page "$bus_number" "$addr" 0x00 || return 1
  i2c_do set "$bus_number" "$addr" 0x15 || return 1
  i2c_do set "$bus_number" "$addr" 0x17 || return 1

  echo -e "Values permanently saved on $addr!"
}

#############################################
# mV conversion for range-checked fields
# (generic two's-complement decode based on a bitmask, offset*5mV per step,
# same convention as the original tool's VID/TRIM offset conversion)
#############################################

convert_masked_to_mv() {
  local raw="$1"
  local mask="$2"

  raw=$((16#${raw#0x}))
  mask=$((16#${mask#0x}))

  local val=$(( raw & mask ))
  local half=$(( (mask + 1) / 2 ))

  if (( val >= half )); then
    val=$(( val - (mask + 1) ))
  fi

  echo $(( val * 5 ))
}

#############################################
# Register table (externalized to registers.conf)
# Format per line (pipe-separated):
#   VR|PAGE|REG|LABEL|MASK|MIN_MV|MAX_MV
# MASK/MIN_MV/MAX_MV may be left empty for registers with no known safe range
# (backup/PG/CG1 registers) - they are only range-checked/converted when set.
#############################################

generate_default_registers_conf() {
  cat > "$REGISTERS_CONF" <<EOF
# VR|PAGE|REG|LABEL|MASK|MIN_MV|MAX_MV
# MASK/MIN_MV/MAX_MV are optional. When present, the register is treated as a
# signed offset field (two's complement over MASK, 5mV/step) and writes
# outside [MIN_MV,MAX_MV] require an explicit "override" to proceed.
$vr1|$page0|0x22|VR1/p0/TRIM|0x7F|-50|50
$vr1|$page0|0x23|VR1/p0/VID|0x1FF|-50|150
$vr1|$page0|0x4b|VR1/p0/BACKUP1|||
$vr1|$page1|0x10|VR1/p1/BACKUP3|||
$vr1|$page1|0x23|VR1/p1/VID(VDDCI)|0x1FF|-50|100
$vr1|$page1|0x4b|VR1/p1/BACKUP1|||
$vr1|$page1|0x4d|VR1/p1/BACKUP2|||
$vr1|$page2|0x06|VR1/p2/CG1|||
$vr1|$page2|0x08|VR1/p2/CG1_raw|||
$vr1|$page2|0x0c|VR1/p2/PG_hi|||
$vr1|$page2|0x0f|VR1/p2/PG|||
$vr2|$page0|0x23|VR2/p0/VID(SoC)|0x1FF|-50|100
$vr2|$page0|0x4b|VR2/p0/BACKUP1|||
$vr2|$page1|0x10|VR2/p1/BACKUP3|||
$vr2|$page1|0x23|VR2/p1/VID(VRAM)|0x1FF|-100|135
$vr2|$page1|0x4b|VR2/p1/BACKUP1|||
$vr2|$page1|0x4d|VR2/p1/BACKUP2|||
$vr2|$page2|0x0f|VR2/p2/PG|||
EOF
  echo "Created default register table: $REGISTERS_CONF"
}

REGISTER_TABLE=()

load_register_table() {
  if [[ ! -f "$REGISTERS_CONF" ]]; then
    generate_default_registers_conf
  fi

  REGISTER_TABLE=()
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    REGISTER_TABLE+=("$line")
  done < "$REGISTERS_CONF"

  if [ ${#REGISTER_TABLE[@]} -eq 0 ]; then
    echo -e "\033[1;31mNo registers loaded from $REGISTERS_CONF. Aborting.\033[0m"
    exit 1
  fi
}

parse_entry() {
  # Splits a REGISTER_TABLE entry into the parse_* globals
  local entry="$1"
  IFS='|' read -r parse_vr parse_page parse_reg parse_label parse_mask parse_min parse_max <<< "$entry"
}

#############################################
# Table display / dump
#############################################

# Prints the register table with index numbers and live values (to stdout, with colors)
show_register_table() {
  echo -e "\n\033[1;32m═════════════════════════════════════════════════════════════════\033[0m"
  echo -e "\033[1;32m   Raw Register Table (live read from GPU)\033[0m"
  echo -e "\033[1;32m═════════════════════════════════════════════════════════════════\033[0m"
  printf "  \033[1;37m%-4s %-6s %-6s %-6s  %-20s  %-8s %s\033[0m\n" \
         "#" "VR" "PAGE" "REG" "LABEL" "VALUE" "mV"
  echo -e "  ─────────────────────────────────────────────────────────────────"

  local i=0
  for entry in "${REGISTER_TABLE[@]}"; do
    parse_entry "$entry"
    local val mv_display=""
    val=$(i2c_read_register "$parse_vr" "$parse_page" "$parse_reg" wp 2>/dev/null) || val="ERR"

    if [[ -n "$parse_mask" && "$val" != "ERR" ]]; then
      mv_display="$(convert_masked_to_mv "$val" "$parse_mask") mV"
    fi

    printf "  \033[1;36m[%2d]\033[0m %-6s %-6s %-6s  %-20s  \033[1;33m%-8s\033[0m %s\n" \
           "$i" "$parse_vr" "$parse_page" "$parse_reg" "$parse_label" "$val" "$mv_display"
    (( i++ ))
  done
  echo -e "  ─────────────────────────────────────────────────────────────────"
}

# Plain-text dump (no ANSI colors) to a file, for --dump-file / scripting
dump_register_table_to_file() {
  local outfile="$1"

  {
    echo "RDNA4 VR raw register dump"
    echo "Timestamp: $(date)"
    echo "i2c bus: i2c-$bus_number ($I2C_BACKEND)"
    echo
    printf "%-4s %-6s %-6s %-6s %-20s %-8s %s\n" "#" "VR" "PAGE" "REG" "LABEL" "VALUE" "mV"

    local i=0
    for entry in "${REGISTER_TABLE[@]}"; do
      parse_entry "$entry"
      local val mv_display=""
      val=$(i2c_read_register "$parse_vr" "$parse_page" "$parse_reg" wp 2>/dev/null) || val="ERR"
      if [[ -n "$parse_mask" && "$val" != "ERR" ]]; then
        mv_display="$(convert_masked_to_mv "$val" "$parse_mask") mV"
      fi
      printf "%-4s %-6s %-6s %-6s %-20s %-8s %s\n" "$i" "$parse_vr" "$parse_page" "$parse_reg" "$parse_label" "$val" "$mv_display"
      (( i++ ))
    done
  } > "$outfile"

  echo "Dump written to $outfile"
}

#############################################
# EEPROM write-cycle counter
#############################################

get_eeprom_count() {
  if [[ -f "$EEPROM_COUNT_FILE" ]]; then
    cat "$EEPROM_COUNT_FILE"
  else
    echo 0
  fi
}

bump_eeprom_count() {
  local count
  count=$(get_eeprom_count)
  count=$(( count + 1 ))
  echo "$count" > "$EEPROM_COUNT_FILE"
  echo "$count"
}

# Permanently commits the current values to EEPROM on both VR devices
save_current_state_permanently() {
  local current_count
  current_count=$(get_eeprom_count)

  echo -e "\n\033[1;33m⚠  This will permanently write the CURRENT register state to EEPROM on both VR devices ($vr1, $vr2).\033[0m"
  echo -e "\033[1;33m   This survives reboots/power cycles and consumes one EEPROM write cycle per device.\033[0m"
  echo -e "\033[1;33m   EEPROM write cycles recorded so far by this tool: $current_count\033[0m"
  if (( current_count >= EEPROM_WARN_THRESHOLD )); then
    echo -e "\033[1;31m   You have already performed $current_count EEPROM commits. VR EEPROMs have a limited write endurance -\033[0m"
    echo -e "\033[1;31m   repeated commits increase the risk of wear. Only proceed if you specifically intend to.\033[0m"
  fi
  read -rp "Type 'yes' to confirm: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    log_action "EEPROM save aborted by user (count would have been $((current_count+1)))"
    sleep 1
    return
  fi

  if save_to_eeprom "$vr1" && save_to_eeprom "$vr2"; then
    local new_count
    new_count=$(bump_eeprom_count)
    log_action "EEPROM save OK on $vr1,$vr2 (cumulative count: $new_count)"
    echo -e "\033[1;36mCumulative EEPROM write count: $new_count\033[0m"
  else
    log_action "EEPROM save FAILED on $vr1 and/or $vr2"
    echo -e "\033[1;31mEEPROM save failed - check connection and try again.\033[0m"
  fi
  sleep 2
}

#############################################
# Interactive raw register editor loop
#############################################

raw_register_editor() {
  while true; do
    echo -e "\033[H\033[J"
    show_register_table

    echo -e "\n\033[1;33m[r]\033[0m Refresh table"
    echo -e "\033[1;35m[s]\033[0m Permanently save current state to EEPROM"
    echo -e "\033[1;31m[0]\033[0m Exit"
    echo -e "\nEnter register index to edit, [r] to refresh, [s] to save permanently, or [0] to exit:"
    read -rp "> " choice

    case "$choice" in
    0)
      echo -e "\033[H\033[J"
      break
      ;;
    r|R)
      continue
      ;;
    s|S)
      save_current_state_permanently
      continue
      ;;
    ''|*[!0-9]*)
      echo "Invalid input."
      sleep 1
      continue
      ;;
    esac

    local idx=$choice
    if (( idx < 0 || idx >= ${#REGISTER_TABLE[@]} )); then
      echo "Index out of range."
      sleep 1
      continue
    fi

    # Parse the chosen entry
    parse_entry "${REGISTER_TABLE[$idx]}"
    local sel_vr="$parse_vr" sel_page="$parse_page" sel_reg="$parse_reg" sel_label="$parse_label"
    local sel_mask="$parse_mask" sel_min="$parse_min" sel_max="$parse_max"

    # Read current value
    local cur_val
    cur_val=$(i2c_read_register "$sel_vr" "$sel_page" "$sel_reg" wp 2>/dev/null) || cur_val="ERR"

    echo -e "\n\033[1;37mSelected:\033[0m  VR=$sel_vr  page=$sel_page  reg=$sel_reg  label=$sel_label"
    echo -e "\033[1;37mCurrent value:\033[0m  \033[1;33m$cur_val\033[0m"
    if [[ -n "$sel_mask" && "$cur_val" != "ERR" ]]; then
      echo -e "\033[1;37mCurrent (decoded):\033[0m  \033[1;33m$(convert_masked_to_mv "$cur_val" "$sel_mask") mV\033[0m  (known-safe range: ${sel_min}..${sel_max} mV)"
    fi
    echo -e "\n⚠  Enter new value as 0xNNNN (16-bit hex word), or [Enter] to cancel:"
    read -rp "> " new_val

    if [[ -z "$new_val" ]]; then
      echo "Cancelled."
      sleep 1
      continue
    fi

    # Validate format: 0x followed by 1-4 hex digits
    if ! [[ "$new_val" =~ ^0[xX][0-9A-Fa-f]{1,4}$ ]]; then
      echo -e "\033[1;31mInvalid format. Use 0xNNNN (e.g. 0x1A23).\033[0m"
      sleep 2
      continue
    fi

    # Normalize to 4-digit uppercase
    local norm_val
    norm_val=$(printf "0x%04X" $(( new_val )) )

    # Range check (only for registers with a known-safe mV range defined)
    if [[ -n "$sel_mask" && -n "$sel_min" && -n "$sel_max" ]]; then
      local new_mv
      new_mv=$(convert_masked_to_mv "$norm_val" "$sel_mask")
      echo -e "\n\033[1;37mNew value decodes to:\033[0m \033[1;33m${new_mv} mV\033[0m  (known-safe range: ${sel_min}..${sel_max} mV)"

      if (( new_mv < sel_min || new_mv > sel_max )); then
        echo -e "\033[1;31m⚠  This is OUTSIDE the known-safe range for $sel_label.\033[0m"
        read -rp "Type 'override' to force this write anyway, or anything else to cancel: " ov
        if [[ "$ov" != "override" ]]; then
          echo "Cancelled."
          log_action "WRITE cancelled (out of range) vr=$sel_vr page=$sel_page reg=$sel_reg label=$sel_label old=$cur_val attempted=$norm_val (${new_mv}mV)"
          sleep 1
          continue
        fi
      else
        read -rp "Confirm? Type 'yes' to proceed: " confirm
        if [[ "$confirm" != "yes" ]]; then
          echo "Aborted."
          sleep 1
          continue
        fi
      fi
    else
      echo -e "\n\033[1;33mAbout to write $norm_val to $sel_label (VR=$sel_vr page=$sel_page reg=$sel_reg)\033[0m"
      echo -e "\033[1;33m(No known-safe range defined for this register - proceed carefully.)\033[0m"
      read -rp "Confirm? Type 'yes' to proceed: " confirm
      if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        sleep 1
        continue
      fi
    fi

    if i2c_write_register "$sel_vr" "$sel_page" "$sel_reg" "$norm_val" wp; then
      # Read back to verify
      local readback
      readback=$(i2c_read_register "$sel_vr" "$sel_page" "$sel_reg" wp 2>/dev/null) || readback="ERR"
      echo -e "\033[1;36m[✓ ]\033[0m Written. Readback: \033[1;32m$readback\033[0m"
      echo -e "\033[1;37mDiff:\033[0m  $cur_val  \033[1;37m->\033[0m  \033[1;32m$readback\033[0m"
      log_action "WRITE OK vr=$sel_vr page=$sel_page reg=$sel_reg label=$sel_label old=$cur_val new=$norm_val readback=$readback"
    else
      echo -e "\033[1;31m[✗ ] Write failed.\033[0m"
      log_action "WRITE FAILED vr=$sel_vr page=$sel_page reg=$sel_reg label=$sel_label old=$cur_val attempted=$norm_val"
    fi
    sleep 2
  done
}

#############################################
# Main execution flow
#############################################

acquire_lock

echo -e "\033[H\033[J"
export LC_NUMERIC=C
detect_os
check_i2c_module
install_i2c_tools
find_i2c_bus
gpu_check
load_register_table

log_action "Session started (bus=i2c-$bus_number backend=$I2C_BACKEND read_only=$READ_ONLY)"

if [[ -n "$DUMP_FILE" ]]; then
  dump_register_table_to_file "$DUMP_FILE"
  log_action "Session ended (dump-file mode)"
  exit 0
fi

if (( READ_ONLY )); then
  show_register_table
  log_action "Session ended (read-only mode)"
  exit 0
fi

raw_register_editor

log_action "Session ended"
echo "Exiting..."
exit 0
