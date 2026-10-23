#!/usr/bin/env bash
#
# provision-db-access.sh  —  phiên bản: xem SCRIPT_VERSION
#
# Tạo DB user (mức quyền theo ACCESS_MODE) trên MySQL / MariaDB / PostgreSQL,
# và (tuỳ chọn) tạo SSH account chỉ-dùng-để-tunnel (không shell) để connect tới DB đó.
# Có chế độ xoá: gỡ tunnel user do script tạo (nhận diện qua TUNNEL_GECOS / Match block) và xoá DB user.
# (Menu 4) Tạo SSH user có shell (tuỳ chọn sudo) cho từng người, thay cho việc dùng chung ec2-user / ubuntu
# (nhận diện qua SHELL_GECOS; xoá bằng cùng chế độ xoá tunnel).
#
# Nguyên tắc an toàn:
#   - Không thay đổi hệ thống/DB khi chưa có xác nhận rõ ràng; luôn hiện "kế hoạch" trước khi làm.
#   - Backup file trước khi sửa (sshd_config, authorized_keys); "sshd -t" trước khi reload,
#     tự rollback sshd_config nếu invalid.
#   - Idempotent: kiểm tra user OS / role DB / entry authorized_keys / Match block trước khi tạo.
#   - Không sinh câu lệnh DROP / CREATE DATABASE / ALTER TABLE.
#   - Password không bao giờ xuất hiện trong log, process list hay output màn hình
#     (trừ khi bạn chủ động chọn hiển thị). Toàn bộ credential nằm trong CRED_FILE (chỉ owner đọc được).
#   - Không đụng tới user OS / SSH key khác ngoài tunnel user đang thao tác.
#
# Hỗ trợ: Ubuntu, Amazon Linux 2023
# Chạy:   sudo bash <file script>     (biến môi trường tuỳ chọn: xem --help)
#
# Toàn bộ script nằm trong khối { … } → bash đọc HẾT file trước khi chạy. Nhờ vậy chép đè bản mới
# lên file trong lúc một lần chạy đang dở cũng không làm lần chạy đó lỗi "syntax error" giữa chừng.
{
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="1.2.0"

# ---- Cấu hình: chỉ sửa ở đây. Comment / thông báo bên dưới tham chiếu TÊN biến, không lặp giá trị.
UI_DELAY_SET="${UI_DELAY+x}"  # rỗng = người dùng không đặt (chế độ --yes sẽ tắt hiệu ứng)
UI_DELAY="${UI_DELAY:-0.3}"   # giây giữa các dòng thông báo (0 = tắt hiệu ứng); ghi đè bằng biến môi trường
MIN_DISK_MB=300               # dừng nếu ổ / còn ít hơn mức này
PASS_LEN=24                   # độ dài password tự sinh
BOX_INNER=58                  # bề rộng bên trong khung banner
TUNNEL_SUFFIX="-db-tunnel"    # hậu tố gợi ý cho user OS tunnel
OS_USER_MAX=32                # độ dài tối đa tên user Linux
SSH_PORT=22                   # port SSH in ra trong credentials / hướng dẫn DBeaver
TUNNEL_GECOS="DB tunnel only" # GECOS gắn cho user tunnel; dùng để nhận diện khi xoá
SHELL_GECOS="SSH shell user"  # GECOS gắn cho SSH user có shell (menu 4); dùng để nhận diện khi xoá

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
# Khi chạy dưới `script` (ghi console), tiến trình con dùng lại timestamp của tiến trình cha
TS="${_DBSETUP_TS:-$(date +%Y%m%d_%H%M%S)}"
# Tất cả output gom vào 1 thư mục cha cạnh file script (không phụ thuộc thư mục đang đứng),
# mỗi lần chạy là 1 thư mục con theo timestamp. Đổi chỗ bằng: OUT_BASE=/path sudo -E bash …
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || printf '%s' "$PWD")"
OUT_BASE="${OUT_BASE:-${SCRIPT_DIR%/}/db-user-setup-output}"
# Nhiều lần chạy trong cùng 1 giây (CI chạy hàng loạt) → thêm PID để thư mục output không trùng.
# Tiến trình con dưới `script` dùng lại đúng TS của tiến trình cha nên không bị đổi.
if [[ -z "${_DBSETUP_TS:-}" && -e "${OUT_BASE%/}/${TS}" ]]; then TS="${TS}_$$"; fi
OUT_DIR="${OUT_BASE%/}/${TS}"
LOG_FILE="${OUT_DIR}/run.log"
CRED_FILE="${OUT_DIR}/credentials.txt"
EVIDENCE_DIR="${OUT_DIR}/evidence"
CONSOLE_LOG="${OUT_DIR}/console.log"
CHANGES_FILE="${OUT_DIR}/changes.txt"
TMP_FILES=()

# ============================== Quyền sở hữu output =======================
# Chạy bằng sudo → file tạo ra thuộc root, user thường không mở được (file manager hiện ổ khoá).
# Chuyển owner về user đã gọi sudo; giữ nguyên permission nên user khác trên máy không đọc được.
give_output_to_sudo_user() {
  local u="${SUDO_USER:-}" g
  [[ -n "$u" && "$u" != "root" ]] || return 0
  id "$u" >/dev/null 2>&1 || return 0
  g="$(id -gn "$u")"
  [[ -d "$OUT_DIR" ]] && chown -R "${u}:${g}" "$OUT_DIR" 2>/dev/null
  [[ -d "$OUT_BASE" ]] && chown "${u}:${g}" "$OUT_BASE" 2>/dev/null
  [[ -L "${OUT_BASE%/}/latest" ]] && chown -h "${u}:${g}" "${OUT_BASE%/}/latest" 2>/dev/null
  return 0
}

# ============================== Ghi lại toàn bộ console ===================
# Chạy lại chính script này bên trong `script` (util-linux, có sẵn trên Ubuntu / AL2023) để ghi
# NGUYÊN VĂN mọi thứ hiện trên màn hình — kể cả lỗi của bash và những gì bạn gõ — vào CONSOLE_LOG.
# Password nhập bằng `read -s` không echo ra terminal nên KHÔNG bị ghi lại.
# Tắt bằng NO_RECORD=1.
if [[ -z "${_DBSETUP_RECORDING:-}" && -z "${NO_RECORD:-}" && "${1:-}" != "-h" && "${1:-}" != "--help" ]] \
   && [[ "$(id -u)" -eq 0 && -t 0 && -t 1 ]] && command -v script >/dev/null 2>&1; then
  mkdir -p "$OUT_BASE" "$OUT_DIR"
  chmod 700 "$OUT_BASE" "$OUT_DIR"
  RAW_CONSOLE="${OUT_DIR}/.console.raw"
  rc=0
  _DBSETUP_RECORDING=1 _DBSETUP_TS="$TS" OUT_BASE="$OUT_BASE" \
    script -qefc "$(printf '%q ' bash "${BASH_SOURCE[0]}" "$@")" "$RAW_CONSOLE" || rc=$?
  # Bỏ mã màu ANSI, \r và dòng header/footer của `script`, giữ lại text thuần
  if [[ -f "$RAW_CONSOLE" ]]; then
    sed -E -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r//g' \
      -e '/^Script (started|done) on /d' "$RAW_CONSOLE" >"$CONSOLE_LOG" || true
    chmod 600 "$CONSOLE_LOG"
    rm -f "$RAW_CONSOLE"
  fi
  give_output_to_sudo_user
  exit "$rc"
fi

# ============================== UI ========================================

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; MAGENTA=$'\033[35m'; CYAN=$'\033[36m'
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
fi

RULE="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
STEP_NO=0
STEP_TOTAL="?"

# Hiệu ứng hiện từng dòng: chờ UI_DELAY giây sau mỗi dòng thông báo.
# Chỉ khi stderr là terminal; UI_DELAY=0 để tắt. Luôn return 0 (an toàn với set -e).
pace() {
  if [[ -t 2 && "$UI_DELAY" != "0" ]]; then sleep "$UI_DELAY"; fi
  return 0
}

# Mọi output giao diện đi ra stderr, để $(...) chỉ bắt đúng dữ liệu trả về.
ok()    { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$*" >&2; log "OK   $*"; pace; }
warn()  { printf '  %s⚠%s %s\n' "$YELLOW" "$RESET" "$*" >&2; log "WARN $*"; pace; }
err()   { printf '  %s✖%s %s\n' "$RED" "$RESET" "$*" >&2; log "ERR  $*"; pace; }
info()  { printf '  %s➜%s %s\n' "$CYAN" "$RESET" "$*" >&2; pace; }
note()  { printf '    %s%s%s\n' "$DIM" "$*" "$RESET" >&2; pace; }
blank() { printf '\n' >&2; }

step() {
  STEP_NO=$((STEP_NO + 1))
  printf '\n%s%s%s\n' "$BLUE" "$RULE" "$RESET" >&2
  printf ' %s%s[%s/%s]%s  %s%s%s\n' "$BOLD" "$BLUE" "$STEP_NO" "$STEP_TOTAL" "$RESET" "$BOLD" "$1" "$RESET" >&2
  printf '%s%s%s\n' "$BLUE" "$RULE" "$RESET" >&2
  log "===== STEP ${STEP_NO}: $1 ====="
}

kv() {
  # kv "Nhãn" "giá trị" — căn cột theo số ký tự (không phải byte)
  local label="$1" value="$2" pad len
  len="$(LC_ALL=C.UTF-8 bash -c 'printf "%s" "${#1}"' _ "$label" 2>/dev/null || printf '%s' "${#label}")"
  pad=$((20 - len)); (( pad < 1 )) && pad=1
  printf '  %s%s%*s%s%s\n' "$DIM" "$label" "$pad" "" "$RESET" "$value" >&2
  pace
}

codeblock() {
  # In nội dung (đã mask) trong khung
  printf '  %s┌────────────────────────────────────────────────────────%s\n' "$DIM" "$RESET" >&2
  while IFS= read -r line; do
    printf '  %s│%s %s\n' "$DIM" "$RESET" "$line" >&2
  done <<<"$1"
  printf '  %s└────────────────────────────────────────────────────────%s\n' "$DIM" "$RESET" >&2
}

banner() {
  printf '\n%s╭──────────────────────────────────────────────────────────╮%s\n' "$MAGENTA" "$RESET" >&2
  # Căn lề theo độ dài version để viền phải luôn thẳng (bề rộng trong khung = BOX_INNER)
  local title="DB User & SSH Tunnel Setup" ver="v${SCRIPT_VERSION}" pad
  pad=$(( BOX_INNER - 2 - ${#title} - ${#ver} - 2 )); (( pad < 1 )) && pad=1
  printf '%s│%s  %s%s%s%*s%s  %s│%s\n' "$MAGENTA" "$RESET" "$BOLD" "$title" "$RESET" "$pad" "" "$ver" "$MAGENTA" "$RESET" >&2
  printf '%s│%s  %sMySQL · MariaDB · PostgreSQL  —  Ubuntu · Amazon Linux%s  %s│%s\n' "$MAGENTA" "$RESET" "$DIM" "$RESET" "$MAGENTA" "$RESET" >&2
  # Dòng hệ điều hành của server đang chạy: "<PRETTY_NAME> · kernel <uname -r>", cắt bớt nếu quá dài
  local os_line os_len os_max=$(( BOX_INNER - 4 ))
  os_line="$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-${ID:-Linux}}") || printf 'Linux')"
  os_line="${os_line} · kernel $(uname -r 2>/dev/null || echo '?')"
  os_len="$(LC_ALL=C.UTF-8 bash -c 'printf "%s" "${#1}"' _ "$os_line" 2>/dev/null || printf '%s' "${#os_line}")"
  if (( os_len > os_max )); then
    os_line="$(LC_ALL=C.UTF-8 bash -c 'printf "%s…" "${1:0:$2}"' _ "$os_line" "$(( os_max - 1 ))")"; os_len=$os_max
  fi
  printf '%s│%s  %s%s%*s  %s│%s\n' "$MAGENTA" "$RESET" "$os_line" "$RESET" "$(( os_max - os_len ))" "" "$MAGENTA" "$RESET" >&2
  printf '%s╰──────────────────────────────────────────────────────────╯%s\n' "$MAGENTA" "$RESET" >&2
}

# ============================== Core helpers ==============================

log() {
  [[ -d "$OUT_DIR" ]] || return 0
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

# ---- Mã thoát (dùng cho CI / script gọi từ ngoài)
EXIT_ERROR=1          # lỗi chung
EXIT_USAGE=2          # tham số sai / thiếu
EXIT_ADMIN_CONN=3     # không kết nối được bằng admin
EXIT_ADMIN_PRIV=4     # admin thiếu quyền
EXIT_USER_EXISTS=5    # user đã tồn tại, không có --allow-alter
EXIT_CANCELLED=6      # huỷ / xác nhận không khớp

# ---- Tham số dòng lệnh (điền bởi parse_args)
declare -A OPT=()
NONINTERACTIVE=0      # 1 khi có --yes: không hỏi gì, thiếu tham số → thoát EXIT_USAGE
OUTPUT_JSON=0
LAST_ERROR=""
# Biến mà ask()/choose() điền  →  tên tham số --<key> tương ứng
declare -A OPT_FOR_VAR=(
  [SCOPE_IDX]=scope-idx [ENGINE_IDX]=engine [ACCESS_IDX]=mode [KEY_IDX]=key-type
  [DB_HOST]=host [DB_PORT]=port [DB_NAME]=database [NEW_DB_USER]=user [CONN_LIMIT]=max-conn
  [SCHEMAS_RAW]=schemas [MYSQL_HOST_PART]=host-part [ADMIN_USER]=admin-user
  [TUNNEL_OS_USER]=tunnel-user [KEY_NAME]=key-name [KEY_COMMENT]=key-comment
  [TUNNEL_TARGET]=tunnel-target [DROP_MANUAL_USER]=db-user
)

die() {
  err "$*"
  LAST_ERROR="$*"
  exit "${DIE_CODE:-$EXIT_ERROR}"
}

die_code() {
  # die_code <mã thoát> "thông báo"
  DIE_CODE="$1"; shift
  die "$@"
}

preset_note() {
  # In dòng "› câu hỏi: giá trị (tham số)" khi giá trị lấy từ tham số / mặc định
  printf '  %s›%s %s: %s %s(%s)%s\n' "$CYAN" "$RESET" "$1" "$2" "$DIM" "$3" "$RESET" >&2
  log "PRESET $1 = $2 ($3)"
}

# ---------------------- Nhật ký thay đổi (change journal) ----------------
# Mỗi thay đổi THẬT SỰ đã xảy ra được ghi lại kèm lệnh rollback.
# Danh sách luôn được lưu vào CHANGES_FILE; chỉ in ra màn hình khi script thoát do lỗi / Ctrl+C.
CHANGES=()
UNDOS=()

record() {
  # record "mô tả thay đổi" ["lệnh rollback"]
  CHANGES+=("$1")
  UNDOS+=("${2:-}")
  log "CHANGE: $1${2:+ | rollback: $2}"
}

report_changes() {
  # report_changes "tiêu đề"
  local title="$1" i n=${#CHANGES[@]}
  printf '\n  %s%s%s\n' "$BOLD" "$title" "$RESET" >&2
  if (( n == 0 )); then
    printf '    %s✔ Chưa có thay đổi nào trên server / DB.%s\n' "$GREEN" "$RESET" >&2
  else
    for (( i = 0; i < n; i++ )); do
      printf '    %s%d.%s %s\n' "$CYAN" "$((i + 1))" "$RESET" "${CHANGES[$i]}" >&2
      if [[ -n "${UNDOS[$i]}" ]]; then printf '       %s↩ %s%s\n' "$DIM" "${UNDOS[$i]}" "$RESET" >&2; fi
    done
    note "↩ = rollback · chạy ngược từ dưới lên"
  fi
  write_changes_file
}

write_changes_file() {
  # Luôn ghi CHANGES_FILE (evidence / rollback), kể cả khi chạy thành công và không in ra màn hình
  local i n=${#CHANGES[@]}
  if [[ -d "$OUT_DIR" ]]; then
    {
      printf '# Thay đổi do %s thực hiện — %s\n' "$SCRIPT_NAME" "$(date '+%F %T')"
      printf '# Rollback: chạy theo thứ tự NGƯỢC (từ dưới lên)\n\n'
      for (( i = 0; i < n; i++ )); do
        printf '%d. %s\n' "$((i + 1))" "${CHANGES[$i]}"
        if [[ -n "${UNDOS[$i]}" ]]; then printf '   rollback: %s\n' "${UNDOS[$i]}"; fi
      done
      if (( n == 0 )); then printf 'Không có thay đổi nào.\n'; fi
    } >"$CHANGES_FILE"
    chmod 600 "$CHANGES_FILE"
  fi
}

on_err() {
  local line="$1" cmd="$2"
  # Chỉ báo ở shell chính — lỗi trong $(...) sẽ được shell cha báo lại, tránh in trùng
  (( BASH_SUBSHELL == 0 )) || return 0
  err "Lệnh lỗi ngoài dự kiến ở dòng ${line}: ${cmd}"
  note "Chi tiết: ${LOG_FILE}"
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

cleanup() {
  local f
  for f in "${TMP_FILES[@]}"; do rm -f -- "$f"; done
}

reveal_summary() {
  # Phát từng dòng, cách nhau UI_DELAY giây. Dòng trống không chờ.
  # Không phải terminal (pipe / CI) hoặc UI_DELAY=0 → in một lần.
  local f="$1" delay="$UI_DELAY" line
  [[ -t 2 ]] || delay=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >&2
    if [[ -n "$line" && "$delay" != "0" ]]; then sleep "$delay"; fi
  done <"$f"
}

on_exit() {
  local rc=$?
  trap - ERR
  # Lỗi xảy ra giữa lúc đang ghi bộ đệm Tổng kết → trả stderr về terminal và in hết những gì đã có
  if [[ "${IN_SUMMARY:-0}" == "1" ]]; then
    exec 2>&3 3>&-
    IN_SUMMARY=0
    [[ -f "${SUMMARY_BUF:-}" ]] && cat "$SUMMARY_BUF" >&2
  fi
  cleanup
  # Chỉ in báo cáo khi thoát bất thường; khi thành công chỉ ghi file (xem write_changes_file).
  if (( rc != 0 )) && [[ -d "$OUT_DIR" ]]; then
    printf '\n%s%s%s\n' "$RED" "$RULE" "$RESET" >&2
    if (( rc == 130 )); then
      printf ' %s%sScript bị huỷ (Ctrl+C)%s\n' "$BOLD" "$RED" "$RESET" >&2
    else
      printf ' %s%sScript dừng do lỗi%s  %s(exit code %d)%s\n' "$BOLD" "$RED" "$RESET" "$DIM" "$rc" "$RESET" >&2
    fi
    printf '%s%s%s\n' "$RED" "$RULE" "$RESET" >&2
    report_changes "Những gì ĐÃ được thay đổi trước khi dừng:"
    blank
    kv "Danh sách thay đổi" "$CHANGES_FILE"
    kv "Console" "$CONSOLE_LOG"
    kv "Log" "$LOG_FILE"
    blank
    log "EXIT rc=${rc}"
  fi
  if (( rc != 0 )); then
    emit_json status error exit_code "$rc" error "${LAST_ERROR:-Lỗi không xác định (xem log)}" \
      changes "${#CHANGES[@]}" output_dir "$OUT_DIR" changes_file "$CHANGES_FILE" log_file "$LOG_FILE"
  fi
  # Chuyển owner SAU CÙNG (sau khi đã ghi CHANGES_FILE). Khi chạy dưới `script`,
  # tiến trình cha làm việc này sau khi ghi CONSOLE_LOG.
  [[ -n "${_DBSETUP_RECORDING:-}" ]] || give_output_to_sudo_user
}
trap on_exit EXIT
trap 'printf "\n" >&2; exit 130' INT

confirm() {
  # confirm "câu hỏi" [y|n mặc định] [trả lời khi --yes]  -> 0 nếu đồng ý
  #   trả lời khi --yes: y | n | fail:<mã thoát>:<lý do>   (mặc định: n — an toàn)
  local msg="$1" def="${2:-n}" auto="${3:-n}" hint ans
  if (( NONINTERACTIVE )); then
    case "$auto" in
      y) printf '  %s?%s %s %s→ y (--yes)%s\n' "$YELLOW" "$RESET" "$msg" "$DIM" "$RESET" >&2; log "AUTO y: $msg"; return 0 ;;
      n) printf '  %s?%s %s %s→ n (--yes)%s\n' "$YELLOW" "$RESET" "$msg" "$DIM" "$RESET" >&2; log "AUTO n: $msg"; return 1 ;;
      fail:*)
        local code="${auto#fail:}"; local why="${code#*:}"; code="${code%%:*}"
        die_code "$code" "${why}" ;;
    esac
  fi
  if [[ "$def" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    read -r -p "  ${YELLOW}?${RESET} ${msg} ${DIM}[${hint}]${RESET} " ans || die "Không đọc được input."
    ans="${ans:-$def}"
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     warn "Nhập y hoặc n." ;;
    esac
  done
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

ask() {
  # ask VAR "câu hỏi" [mặc định] [regex] [thông báo khi sai]
  local __var="$1" prompt="$2" def="${3:-}" re="${4:-}" msg="${5:-Giá trị không hợp lệ.}" val
  local key="${OPT_FOR_VAR[$__var]:-}"
  # Giá trị truyền qua tham số --<key> → không hỏi
  if [[ -n "$key" && -n "${OPT[$key]+x}" ]]; then
    val="$(trim "${OPT[$key]}")"
    [[ -n "$val" ]] || die_code "$EXIT_USAGE" "--${key} không được để trống."
    if [[ -n "$re" && ! "$val" =~ $re ]]; then die_code "$EXIT_USAGE" "--${key}=${val}: ${msg}"; fi
    preset_note "$prompt" "$val" "--${key}"
    printf -v "$__var" '%s' "$val"
    return 0
  fi
  # --yes mà không có tham số: dùng mặc định nếu có, không thì báo thiếu
  if (( NONINTERACTIVE )); then
    [[ -n "$def" ]] || die_code "$EXIT_USAGE" "Thiếu tham số --${key:-?} (${prompt})."
    preset_note "$prompt" "$def" "mặc định"
    printf -v "$__var" '%s' "$def"
    return 0
  fi
  while true; do
    if [[ -n "$def" ]]; then
      read -r -p "  ${CYAN}›${RESET} ${prompt} ${DIM}[${def}]${RESET}: " val || die "Không đọc được input."
      val="${val:-$def}"
    else
      read -r -p "  ${CYAN}›${RESET} ${prompt}: " val || die "Không đọc được input."
    fi
    val="$(trim "$val")"
    if [[ -z "$val" ]]; then warn "Không được để trống."; continue; fi
    if [[ -n "$re" && ! "$val" =~ $re ]]; then warn "$msg"; continue; fi
    printf -v "$__var" '%s' "$val"
    return 0
  done
}

ask_optional() {
  # ask_optional VAR "câu hỏi" [regex] [thông báo] — cho phép để trống
  local __var="$1" prompt="$2" re="${3:-}" msg="${4:-Giá trị không hợp lệ.}" val
  while true; do
    read -r -p "  ${CYAN}›${RESET} ${prompt} ${DIM}[bỏ trống = bỏ qua]${RESET}: " val || die "Không đọc được input."
    val="$(trim "$val")"
    if [[ -n "$val" && -n "$re" && ! "$val" =~ $re ]]; then warn "$msg"; continue; fi
    printf -v "$__var" '%s' "$val"
    return 0
  done
}

ask_secret() {
  # ask_secret VAR "câu hỏi"  — nhập 2 lần; để trống => trả về rỗng
  # Không hỏi nếu có biến môi trường DB_NEW_PASS; --yes mà không có → rỗng (tự sinh)
  local __var="$1" prompt="$2" v1 v2
  if [[ -n "${DB_NEW_PASS:-}" ]]; then
    preset_note "$prompt" "********" "DB_NEW_PASS"; printf -v "$__var" '%s' "$DB_NEW_PASS"; return 0
  fi
  if (( NONINTERACTIVE )); then printf -v "$__var" '%s' ""; return 0; fi
  while true; do
    read -r -s -p "  ${CYAN}›${RESET} ${prompt}: " v1 || die "Không đọc được input."; printf '\n' >&2
    if [[ -z "$v1" ]]; then printf -v "$__var" '%s' ""; return 0; fi
    read -r -s -p "  ${CYAN}›${RESET} Nhập lại để xác nhận: " v2 || die "Không đọc được input."; printf '\n' >&2
    if [[ "$v1" == "$v2" ]]; then printf -v "$__var" '%s' "$v1"; return 0; fi
    warn "Hai lần nhập không khớp, thử lại."
  done
}

ask_admin_secret() {
  # Nguồn theo thứ tự: biến môi trường DB_ADMIN_PASS → --admin-pass-stdin → hỏi
  local __var="$1" prompt="$2" v
  if [[ -n "${DB_ADMIN_PASS:-}" ]]; then
    preset_note "$prompt" "********" "DB_ADMIN_PASS"; printf -v "$__var" '%s' "$DB_ADMIN_PASS"; return 0
  fi
  if [[ -n "${ADMIN_PASS_STDIN:-}" ]]; then
    preset_note "$prompt" "********" "stdin"; printf -v "$__var" '%s' "$ADMIN_PASS_STDIN"; return 0
  fi
  (( NONINTERACTIVE )) && die_code "$EXIT_USAGE" "Thiếu password admin: đặt DB_ADMIN_PASS hoặc dùng --admin-pass-stdin."
  read -r -s -p "  ${CYAN}›${RESET} ${prompt}: " v || die "Không đọc được input."; printf '\n' >&2
  printf -v "$__var" '%s' "$v"
}

choose() {
  # choose VAR "câu hỏi" "lựa chọn 1" "lựa chọn 2" ...  -> VAR = số thứ tự (1-based)
  # Nhấn Enter = lựa chọn đầu tiên. Đặt CHOOSE_NO_DEFAULT=1 khi gọi để BẮT BUỘC chọn:
  #   CHOOSE_NO_DEFAULT=1 choose VAR "…" …
  local __var="$1" prompt="$2"; shift 2
  local i=1 opt ans n=$# hint
  local key="${OPT_FOR_VAR[$__var]:-}" pre=""
  [[ -n "$key" ]] && pre="${OPT[$key]:-}"
  if [[ -n "$pre" ]]; then
    # Nhận số thứ tự, hoặc tên khớp từ đầu tiên / tiền tố của lựa chọn (không phân biệt hoa thường)
    local p="${pre,,}" lab first
    ans=""
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= n )); then ans="$p"; fi
    i=1
    for opt in "$@"; do
      [[ -n "$ans" ]] && break
      lab="${opt,,}"; first="${lab%% *}"
      if [[ "$first" == "$p" || "$lab" == "$p"* ]]; then ans="$i"; fi
      i=$((i + 1))
    done
    if [[ -z "$ans" ]]; then
      local names=() o
      for o in "$@"; do o="${o,,}"; names+=("${o%% *}"); done
      die_code "$EXIT_USAGE" "--${key}=${pre} không hợp lệ (chọn: ${names[*]})."
    fi
    local opts=("$@") src="--${key}"; opt="${opts[$((ans - 1))]}"
    if [[ "$key" == "scope-idx" ]]; then   # khoá nội bộ, suy ra từ --action / --scope
      if [[ "${OPT[action]:-create}" == "create" ]]; then src="--scope"; else src="--action"; fi
    fi
    preset_note "${prompt%:}" "$opt" "$src"
    printf -v "$__var" '%s' "$ans"
    return 0
  fi
  if (( NONINTERACTIVE )); then
    [[ -z "${CHOOSE_NO_DEFAULT:-}" ]] || die_code "$EXIT_USAGE" "Thiếu tham số --${key:-?} (${prompt%:})."
    preset_note "${prompt%:}" "$1" "mặc định"
    printf -v "$__var" '%s' 1
    return 0
  fi
  printf '  %s%s%s\n' "$BOLD" "$prompt" "$RESET" >&2
  for opt in "$@"; do
    printf '     %s%d)%s %s\n' "$CYAN" "$i" "$RESET" "$opt" >&2
    i=$((i + 1))
  done
  if [[ -n "${CHOOSE_NO_DEFAULT:-}" ]]; then hint="1-${n}"; else hint="1-${n}, Default: 1"; fi
  while true; do
    read -r -p "  ${CYAN}›${RESET} Chọn ${DIM}[${hint}]${RESET}: " ans || die "Không đọc được input."
    ans="$(trim "$ans")"
    if [[ -z "$ans" ]]; then
      if [[ -n "${CHOOSE_NO_DEFAULT:-}" ]]; then warn "Bắt buộc chọn 1 trong ${n} lựa chọn."; continue; fi
      ans=1
    fi
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= n )); then
      printf -v "$__var" '%s' "$ans"
      return 0
    fi
    warn "Lựa chọn không hợp lệ."
  done
}

mask() {
  local s="$1"
  if (( ${#s} <= 4 )); then printf '****'; else printf '%s%s' "${s:0:3}" "********"; fi
}

gen_password() {
  # Dài PASS_LEN, đủ hoa/thường/số/ký tự đặc biệt an toàn để qua được validate_password của MySQL.
  # Không dùng openssl | head (SIGPIPE + pipefail có thể làm script chết ngẫu nhiên).
  local pw re_up='[A-Z]' re_lo='[a-z]' re_num='[0-9]' re_sp='[_.-]'
  while true; do
    pw="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9_.-')"
    pw="${pw:0:PASS_LEN}"
    if (( ${#pw} == PASS_LEN )) && [[ "$pw" =~ $re_up && "$pw" =~ $re_lo && "$pw" =~ $re_num && "$pw" =~ $re_sp ]]; then
      printf '%s' "$pw"
      return 0
    fi
  done
}

# SQL literal escaping
mysql_str() { local s="${1//\\/\\\\}"; s="${s//\'/\'\'}"; printf '%s' "$s"; }
pg_str()    { printf '%s' "${1//\'/\'\'}"; }
pg_ident()  { printf '"%s"' "${1//\"/\"\"}"; }

backup_file() {
  # backup_file <file> <VAR>  -> VAR = đường dẫn backup (rỗng nếu file không tồn tại)
  local f="$1" __var="$2" bak=""
  if [[ -f "$f" ]]; then
    bak="${f}.bak.${TS}"
    [[ -e "$bak" ]] || cp -p -- "$f" "$bak"
    ok "Backup: ${f} → ${bak}"
  fi
  printf -v "$__var" '%s' "$bak"
}

# ============================== Preflight =================================

require_root() {
  [[ "$(id -u)" -eq 0 ]] || { printf '%s✖ Script cần chạy bằng sudo/root.%s\n' "$RED" "$RESET" >&2; exit 1; }
}

require_tty() {
  (( NONINTERACTIVE )) && return 0
  [[ -t 0 ]] || { printf '%s✖ Script cần chạy interactive (stdin là terminal).%s\n' "$RED" "$RESET" >&2; exit 1; }
}

detect_os() {
  [[ -f /etc/os-release ]] || die "Không có /etc/os-release — chỉ hỗ trợ Ubuntu / Amazon Linux 2023."
  # Đọc trong subshell: /etc/os-release định nghĩa VERSION, ID, NAME… — không để nó ghi đè biến của script
  local os_id os_name
  os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  os_name="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${ID:-}}")"
  case "$os_id" in
    ubuntu) OS_FAMILY="ubuntu";       PKG_INSTALL=(apt-get install -y); PKG_UPDATE=(apt-get update -y) ;;
    amzn)   OS_FAMILY="amazon-linux"; PKG_INSTALL=(dnf install -y);     PKG_UPDATE=(dnf makecache -y) ;;
    *)      die "OS '${os_id:-unknown}' chưa được hỗ trợ (chỉ Ubuntu / Amazon Linux 2023)." ;;
  esac
  ok "OS: ${os_name}"
}

check_disk_space() {
  local avail_mb avail_h
  avail_mb="$(df -Pm / | awk 'NR==2{print $4}')"
  (( avail_mb >= MIN_DISK_MB )) || die "Ổ / chỉ còn ${avail_mb} MB trống (< ${MIN_DISK_MB} MB). Dọn dẹp trước khi chạy tiếp."
  # ≥ 1 GB hiển thị GB (1 chữ số thập phân), dưới đó giữ MB
  if (( avail_mb >= 1024 )); then
    avail_h="$(awk -v m="$avail_mb" 'BEGIN{printf "%.1f GB", m/1024}')"
  else
    avail_h="${avail_mb} MB"
  fi
  ok "Disk: ${avail_h} trống"
}

install_pkg() {
  local pkg="$1"
  check_disk_space
  log "Installing package: $pkg"
  if [[ "$OS_FAMILY" == "ubuntu" ]]; then "${PKG_UPDATE[@]}" >>"$LOG_FILE" 2>&1 || true; fi
  info "Cài ${pkg}…"
  "${PKG_INSTALL[@]}" "$pkg" >>"$LOG_FILE" 2>&1 || die "Cài '${pkg}' thất bại — xem log."
  if [[ "$OS_FAMILY" == "ubuntu" ]]; then
    record "Cài package: ${pkg}" "apt-get remove -y ${pkg}"
  else
    record "Cài package: ${pkg}" "dnf remove -y ${pkg}"
  fi
}

require_cmd_or_install() {
  # require_cmd_or_install <cmd> <pkg-ubuntu> <pkg-amzn>
  local cmd="$1" pkg
  # CMD_QUIET=1: đã có thì không in gì (dùng khi kiểm tra sớm ở bước 1; bước 2 mới báo "có sẵn")
  if command -v "$cmd" >/dev/null 2>&1; then [[ -n "${CMD_QUIET:-}" ]] || ok "${cmd}: có sẵn"; return 0; fi
  if [[ "$OS_FAMILY" == "ubuntu" ]]; then pkg="$2"; else pkg="$3"; fi
  warn "Chưa có '${cmd}' (gói: ${pkg})."
  confirm "Cài ${pkg}? (chỉ client)" n y || die "Cần '${cmd}' để tiếp tục."
  install_pkg "$pkg"
  command -v "$cmd" >/dev/null 2>&1 || die "Cài '${pkg}' xong nhưng vẫn không thấy '${cmd}'."
  ok "Cài ${pkg} xong"
}

find_sshd_bin() {
  local b=""
  b="$(command -v sshd 2>/dev/null || true)"
  if [[ -z "$b" && -x /usr/sbin/sshd ]]; then b="/usr/sbin/sshd"; fi
  if [[ -z "$b" && -x /usr/bin/sshd ]]; then b="/usr/bin/sshd"; fi
  printf '%s' "$b"
}

find_ssh_service() {
  local s
  for s in ssh sshd; do
    if systemctl cat "${s}.service" >/dev/null 2>&1; then printf '%s' "$s"; return 0; fi
  done
  printf ''
}

find_ssh_connection() {
  # SSH_CONNECTION = "<ip client> <port client> <ip server> <port server>" của phiên SSH đang chạy script.
  # sudo / `script` thường xoá biến này → dò ngược lên các tiến trình cha (root đọc được /proc/*/environ).
  local pid="$$" v=""
  [[ -n "${SSH_CONNECTION:-}" ]] && { printf '%s' "$SSH_CONNECTION"; return 0; }
  while [[ -n "$pid" && "$pid" -gt 1 ]]; do
    v="$(tr '\0' '\n' <"/proc/${pid}/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n 1)"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    pid="$(awk '/^PPid:/{print $2}' "/proc/${pid}/status" 2>/dev/null)"
  done
  return 0
}

detect_server_ip() {
  # Gán PUBLIC_IP + IP_SOURCE (không in ra; gọi trực tiếp, không qua $(...))
  # IP để người dùng SSH vào server, theo thứ tự ưu tiên:
  #   1. IP server trong phiên SSH bạn đang dùng (đúng địa chỉ bạn vừa SSH vào: LAN, VPN hay public)
  #   2. Public IPv4 của EC2 (IMDSv2)
  #   3. IP của card mạng ra Internet (route mặc định)
  # Ghi nguồn vào IP_SOURCE để hiển thị. Không tìm được → placeholder.
  local ip="" token="" re='^[0-9]{1,3}(\.[0-9]{1,3}){3}$' conn
  conn="$(find_ssh_connection)"
  if [[ -n "$conn" ]]; then
    ip="$(awk '{print $3}' <<<"$conn")"
    [[ "$ip" =~ $re ]] && { IP_SOURCE="IP bạn đang SSH vào"; PUBLIC_IP="$ip"; return 0; }
  fi
  if command -v curl >/dev/null 2>&1; then
    token="$(curl -s -m 2 -X PUT 'http://169.254.169.254/latest/api/token' \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
      ip="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: ${token}" \
        'http://169.254.169.254/latest/meta-data/public-ipv4' 2>/dev/null || true)"
      [[ "$ip" =~ $re ]] && { IP_SOURCE="EC2 public IP"; PUBLIC_IP="$ip"; return 0; }
    fi
  fi
  # Không phải máy nào cũng có lệnh `ip` (image tối giản) → kiểm tra trước, dự phòng bằng hostname -I
  ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$( { ip -4 route get 1.1.1.1 2>/dev/null || true; } | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n 1)"
  fi
  if [[ ! "$ip" =~ $re ]] && command -v hostname >/dev/null 2>&1; then
    ip="$( { hostname -I 2>/dev/null || true; } | awk '{print $1}')"
  fi
  [[ "$ip" =~ $re ]] && { IP_SOURCE="IP card mạng chính"; PUBLIC_IP="$ip"; return 0; }
  IP_SOURCE="không tự phát hiện được — thay bằng IP thật"
  PUBLIC_IP="<IP-server>"
}

tcp_reachable() {
  timeout 3 bash -c ": </dev/tcp/$1/$2" >/dev/null 2>&1
}

# ============================== DB helpers ================================

make_mycnf() {
  # make_mycnf VAR user password — option file tạm (chmod 600), tránh lộ password qua `ps`
  local __var="$1" user="$2" pass="$3" f p
  f="$(mktemp "${OUT_DIR}/.my.XXXXXX")"
  TMP_FILES+=("$f")
  p="${pass//\\/\\\\}"; p="${p//\"/\\\"}"
  printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\nconnect-timeout=10\n' \
    "$DB_HOST" "$DB_PORT" "$user" "$p" >"$f"
  printf -v "$__var" '%s' "$f"
}

run_mysql() { local cnf="$1"; shift; mysql --defaults-extra-file="$cnf" "$@"; }

run_psql() {
  local user="$1" pass="$2"; shift 2
  PGPASSWORD="$pass" PGCONNECT_TIMEOUT=10 psql -X -h "$DB_HOST" -p "$DB_PORT" -U "$user" "$@"
}

run_sql_file() {
  # Chạy $SQL_FILE bằng admin; stderr vào $SQL_ERR (và log)
  local rc=0
  case "$DB_ENGINE" in
    mysql|mariadb)
      run_mysql "$ADMIN_CNF" <"$SQL_FILE" 2>"$SQL_ERR" || rc=$?
      ;;
    postgres)
      # ON_ERROR_STOP bắt buộc: không có nó psql -f vẫn exit 0 khi có lệnh lỗi.
      run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -v ON_ERROR_STOP=1 -q -f "$SQL_FILE" \
        >>"$LOG_FILE" 2>"$SQL_ERR" || rc=$?
      ;;
  esac
  cat "$SQL_ERR" >>"$LOG_FILE"
  return "$rc"
}

sql_failed_line() {
  # Số dòng của câu lệnh lỗi trong $SQL_FILE; rỗng nếu không xác định được
  # MySQL:  "ERROR 1227 (42000) at line 4: ..."     psql: "psql:/path/file.sql:4: ERROR: ..."
  local n=""
  case "$DB_ENGINE" in
    mysql|mariadb) n="$(grep -oE 'at line [0-9]+' "$SQL_ERR" | head -n 1 | grep -oE '[0-9]+' || true)" ;;
    postgres)      n="$(grep -oE "${SQL_FILE##*/}:[0-9]+: ERROR" "$SQL_ERR" | head -n 1 | grep -oE ':[0-9]+:' | tr -d ':' || true)" ;;
  esac
  printf '%s' "$n"
}

first_stmt_line() {
  grep -nE '^(CREATE|ALTER) (USER|ROLE)' "$SQL_FILE" | head -n 1 | cut -d: -f1
}

sql_rollback_for() {
  # In câu SQL rollback cho 1 câu lệnh (rỗng nếu không có)
  local stmt="$1" re
  re='^CREATE USER ([^ ]+) IDENTIFIED'
  if [[ "$stmt" =~ $re ]]; then printf 'DROP USER %s;' "${BASH_REMATCH[1]}"; return; fi
  re='^CREATE ROLE ([^ ]+) WITH'
  if [[ "$stmt" =~ $re ]]; then printf 'DROP ROLE %s;' "${BASH_REMATCH[1]}"; return; fi
  re='^(ALTER USER|ALTER ROLE) '
  if [[ "$stmt" =~ $re ]]; then printf '(không tự rollback được: password cũ không được lưu)'; return; fi
  re='^ALTER DEFAULT PRIVILEGES (.*) GRANT (.*) TO ([^ ;]+);$'
  if [[ "$stmt" =~ $re ]]; then
    printf 'ALTER DEFAULT PRIVILEGES %s REVOKE %s FROM %s;' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; return
  fi
  re='^GRANT (.*) TO ([^;]+);$'
  if [[ "$stmt" =~ $re ]]; then printf 'REVOKE %s FROM %s;' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return; fi
}

record_sql_executed() {
  # record_sql_executed <dòng lỗi | 0 = chạy hết>
  # Các câu lệnh TRƯỚC dòng lỗi đã chạy xong (autocommit) → ghi vào nhật ký kèm rollback.
  local failed="$1" ln=0 line db_ctx="" undo masked
  if [[ -z "$failed" ]]; then
    record "Không xác định được câu SQL nào đã chạy trước khi lỗi — kiểm tra tay (SHOW GRANTS / \\du)" ""
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    ln=$((ln + 1))
    (( failed > 0 && ln >= failed )) && break
    [[ -z "$line" || "$line" == --* ]] && continue
    if [[ "$line" == \\connect* ]]; then db_ctx="${line#\\connect }"; continue; fi
    masked="${line//"$(mysql_str "$NEW_DB_PASS")"/********}"
    masked="${masked//"$(pg_str "$NEW_DB_PASS")"/********}"
    undo="$(sql_rollback_for "$line")"
    [[ -n "$db_ctx" && -n "$undo" && "$undo" != \(* ]] && undo="[trong DB ${db_ctx}] ${undo}"
    record "SQL: ${masked}" "$undo"
  done <"$SQL_FILE"
  return 0
}

sshd_check() {
  # sshd_check → 0 nếu "sshd -t" OK; lỗi thì để nội dung trong SSHD_T_OUT.
  # Ubuntu 22.10+ dùng socket activation: khi ssh.service chưa từng chạy thì /run/sshd chưa có
  # → "sshd -t" báo "Missing privilege separation directory" dù config đúng. Tạo thư mục đó
  # (đúng việc systemd làm khi start service, nằm trên tmpfs) rồi kiểm tra lại.
  SSHD_T_OUT="$("$SSHD_BIN" -t 2>&1)" && return 0
  SSHD_T_OUT="${SSHD_T_OUT//$'\r'/}"   # sshd có thể kèm \r cuối dòng
  if [[ "$SSHD_T_OUT" == *"Missing privilege separation directory"* ]]; then
    local d
    d="$(sed -nE 's/.*Missing privilege separation directory: ([^ ]+).*/\1/p' <<<"$SSHD_T_OUT" | head -n 1)"
    d="${d:-/run/sshd}"
    info "Thiếu ${d} (ssh.service chưa chạy lần nào) → tạo để kiểm tra config"
    mkdir -p "$d" && chmod 0755 "$d"
    SSHD_T_OUT="$("$SSHD_BIN" -t 2>&1)" && return 0
    SSHD_T_OUT="${SSHD_T_OUT//$'\r'/}"
  fi
  printf '%s\n' "$SSHD_T_OUT" >>"$LOG_FILE"
  return 1
}

admin_conn_fail() {
  # In lỗi thật từ client (vd: role "x" does not exist / password authentication failed)
  local out="$1"
  printf '%s\n' "$out" >>"$LOG_FILE"
  err "Không kết nối được bằng admin '${ADMIN_USER}':"
  # psql thử SSL rồi non-SSL nên lỗi hay lặp 2 lần → bỏ tiền tố, lọc trùng
  codeblock "$(sed -e 's/^psql: error: //' <<<"$out" | grep -v '^[[:space:]]*$' | awk '!seen[$0]++' | tail -n 3)"
  note "Kiểm tra: admin user (≠ tên DB), password, host/port, pg_hba / SG"
  die_code "$EXIT_ADMIN_CONN" "Không kết nối được bằng admin '${ADMIN_USER}'. Chưa có gì bị thay đổi."
}

set_db_list() {
  # set_db_list "a, b" | "all" → DB_LIST (bỏ trùng, giữ thứ tự), DB_ALL, DB_NAME (chuỗi hiển thị)
  local raw="$1" d seen=" "
  DB_LIST=()
  if [[ "${raw,,}" == "all" ]]; then DB_ALL="yes"; DB_NAME="all"; return 0; fi
  DB_ALL="no"
  IFS=',' read -r -a parts <<<"$raw"
  for d in "${parts[@]}"; do
    d="$(trim "$d")"
    [[ -n "$d" && "$seen" != *" $d "* ]] || continue
    DB_LIST+=("$d"); seen+="$d "
  done
  DB_NAME="$(IFS=,; printf '%s' "${DB_LIST[*]}")"; DB_NAME="${DB_NAME//,/, }"
}

resolve_db_list() {
  # resolve_db_list "<danh sách DB đang có, mỗi dòng 1 tên>" → kiểm tra DB_LIST / bung "all"
  local existing="$1" d missing=()
  if [[ "$DB_ALL" == "yes" ]]; then
    mapfile -t DB_LIST < <(grep -v '^[[:space:]]*$' <<<"$existing")
    (( ${#DB_LIST[@]} > 0 )) || die "Không có database nào (ngoài DB hệ thống) để cấp quyền."
    DB_NAME="$(IFS=,; printf '%s' "${DB_LIST[*]}")"; DB_NAME="${DB_NAME//,/, }"
    ok "Database (all): ${DB_NAME}"
    return 0
  fi
  for d in "${DB_LIST[@]}"; do grep -qxF -- "$d" <<<"$existing" || missing+=("$d"); done
  (( ${#missing[@]} == 0 )) || die "Database không tồn tại: ${missing[*]}. Chưa có gì bị thay đổi."
  if (( ${#DB_LIST[@]} == 1 )); then ok "Database '${DB_LIST[0]}' tồn tại"
  else ok "${#DB_LIST[@]} database tồn tại: ${DB_NAME}"; fi
}

list_databases() {
  # In danh sách database (trừ DB hệ thống), mỗi dòng 1 tên; cần ADMIN_USER/ADMIN_PASS (+ ADMIN_CNF cho MySQL)
  case "$DB_ENGINE" in
    mysql|mariadb)
      run_mysql "$ADMIN_CNF" -N -B -e \
        "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
          WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys')
          ORDER BY 1;" 2>>"$LOG_FILE" ;;
    postgres)
      run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc \
        "SELECT datname FROM pg_database
          WHERE datallowconn AND NOT datistemplate AND datname NOT IN ('postgres','rdsadmin')
          ORDER BY 1;" 2>>"$LOG_FILE" ;;
  esac
}

pick_databases() {
  # Chế độ tương tác: kết nối admin trước → hiện danh sách database để chọn (nhiều / all).
  # Bỏ trống admin user → quay về gõ tên database (dùng được cả khi không có admin, chạy SQL tay).
  # Thành công: DB_LIST, DB_NAME, ADMIN_READY=1 (bước Thực thi SQL dùng lại admin này).
  local out names=() i
  note "Nhập admin để liệt kê database · bỏ trống user = tự gõ tên database"
  if [[ -n "${OPT[admin-user]:-}" ]]; then
    ADMIN_USER="${OPT[admin-user]}"; preset_note "Admin DB user" "$ADMIN_USER" "--admin-user"
  else
    ask_optional ADMIN_USER "Admin DB user" '^[A-Za-z0-9_.@-]+$' "Tên user không hợp lệ."
  fi
  if [[ -n "$ADMIN_USER" ]]; then
    case "$DB_ENGINE" in
      mysql)    CMD_QUIET=1 require_cmd_or_install mysql "mysql-client" "mariadb105" ;;
      mariadb)  CMD_QUIET=1 require_cmd_or_install mysql "mariadb-client" "mariadb105" ;;
      postgres) CMD_QUIET=1 require_cmd_or_install psql "postgresql-client" "postgresql15" ;;
    esac
    ask_admin_secret ADMIN_PASS "Admin DB password"
    case "$DB_ENGINE" in
      mysql|mariadb)
        make_mycnf ADMIN_CNF "$ADMIN_USER" "$ADMIN_PASS"
        out="$(run_mysql "$ADMIN_CNF" -N -B -e "SELECT 1;" 2>&1)" || admin_conn_fail "$out" ;;
      postgres)
        out="$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc "SELECT 1;" 2>&1)" || admin_conn_fail "$out" ;;
    esac
    ok "Kết nối admin OK"
    ADMIN_READY=1
    out="$(list_databases || true)"
    mapfile -t names < <(grep -v '^[[:space:]]*$' <<<"$out")
    if (( ${#names[@]} > 0 )); then
      blank
      CHOOSE_MULTI_DEFAULT_ALL=1 choose_multi "Database (đã ẩn DB hệ thống):" "${names[@]}"
      DB_ALL="no"; DB_LIST=()
      for i in "${CHOSEN[@]}"; do DB_LIST+=("${names[$i]}"); done
      DB_NAME="$(IFS=,; printf '%s' "${DB_LIST[*]}")"; DB_NAME="${DB_NAME//,/, }"
      ok "Đã chọn ${#DB_LIST[@]} database: ${DB_NAME}"
      return 0
    fi
    warn "Không liệt kê được database (thiếu quyền hoặc không có DB nào) → tự gõ tên."
  fi
  note "Nhiều database: cách nhau dấu phẩy (vd: appdb, reportdb) · all = mọi database (trừ DB hệ thống)"
  ask DB_NAME "Database" "all" '^([Aa][Ll][Ll]|[A-Za-z0-9_$-]{1,64}([[:space:]]*,[[:space:]]*[A-Za-z0-9_$-]{1,64})*)$' \
    "Tên database chỉ gồm chữ, số, _ - \$ (tối đa 64 ký tự), cách nhau dấu phẩy; hoặc all."
  set_db_list "$DB_NAME"
}

collect_conn_info() {
  # Engine quyết định cú pháp SQL / port → không cho chọn mặc định, tránh nhấn Enter nhầm
  CHOOSE_NO_DEFAULT=1 choose ENGINE_IDX "DB engine:" "MySQL" "MariaDB" "PostgreSQL"
  case "$ENGINE_IDX" in 1) DB_ENGINE="mysql" ;; 2) DB_ENGINE="mariadb" ;; 3) DB_ENGINE="postgres" ;; esac
  case "$DB_ENGINE" in mysql|mariadb) DEFAULT_PORT=3306 ;; postgres) DEFAULT_PORT=5432 ;; esac

  blank
  note "Local: 127.0.0.1 · RDS: endpoint[:port]"
  ask DB_HOST "DB host" "127.0.0.1" '^[A-Za-z0-9._-]+(:[0-9]{1,5})?$' "Host không hợp lệ (chỉ hostname/IP, có thể kèm :port)."
  if [[ "$DB_HOST" == *:* ]]; then DEFAULT_PORT="${DB_HOST##*:}"; DB_HOST="${DB_HOST%:*}"; fi
  ask DB_PORT "DB port" "$DEFAULT_PORT" '^[0-9]{1,5}$' "Port phải là số."

  if [[ "$DB_HOST" =~ \.rds\.amazonaws\.com$ ]]; then IS_RDS="yes"; ok "AWS RDS"; else IS_RDS="no"; fi
  log "Engine=${DB_ENGINE} Host=${DB_HOST}:${DB_PORT} RDS=${IS_RDS}"
}

gen_sql() {
  # gen_sql create|alter
  local mode="$1" privs s role pw owner_clause=""
  {
    printf -- '-- Sinh bởi %s v%s lúc %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$(date '+%F %T')"
    printf -- '-- Engine: %s · Host: %s:%s · Quyền: %s\n\n' "$DB_ENGINE" "$DB_HOST" "$DB_PORT" "$ACCESS_MODE"
    case "$DB_ENGINE" in
      mysql|mariadb)
        local u h p
        u="$(mysql_str "$NEW_DB_USER")"; h="$(mysql_str "$MYSQL_HOST_PART")"; p="$(mysql_str "$NEW_DB_PASS")"
        case "$ACCESS_MODE" in
          readonly) privs="SELECT, SHOW VIEW" ;;
          dml)      privs="SELECT, INSERT, UPDATE, DELETE, SHOW VIEW" ;;
          # ddl: đủ cho migration (Laravel / TypeORM / Prisma…). Lưu ý: DROP trên db.* cho phép DROP DATABASE.
          ddl)      privs="SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES, CREATE VIEW, SHOW VIEW, TRIGGER, CREATE TEMPORARY TABLES, LOCK TABLES" ;;
        esac
        if [[ "$mode" == "create" ]]; then
          printf "CREATE USER '%s'@'%s' IDENTIFIED BY '%s' WITH MAX_USER_CONNECTIONS %s;\n" "$u" "$h" "$p" "$CONN_LIMIT"
        else
          printf "ALTER USER '%s'@'%s' IDENTIFIED BY '%s' WITH MAX_USER_CONNECTIONS %s;\n" "$u" "$h" "$p" "$CONN_LIMIT"
        fi
        local d
        for d in "${DB_LIST[@]}"; do
          printf "GRANT %s ON \`%s\`.* TO '%s'@'%s';\n" "$privs" "$d" "$u" "$h"
        done
        ;;
      postgres)
        role="$(pg_ident "$NEW_DB_USER")"; pw="$(pg_str "$NEW_DB_PASS")"
        [[ -n "$PG_OWNER" ]] && owner_clause="FOR ROLE $(pg_ident "$PG_OWNER") "
        local schema_privs="USAGE"
        case "$ACCESS_MODE" in
          readonly) privs="SELECT" ;;
          dml)      privs="SELECT, INSERT, UPDATE, DELETE" ;;
          ddl)      privs="SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER"; schema_privs="USAGE, CREATE" ;;
        esac
        printf -- '-- Phần 1: chạy trên database "postgres"\n'
        if [[ "$mode" == "create" ]]; then
          printf "CREATE ROLE %s WITH LOGIN PASSWORD '%s' CONNECTION LIMIT %s;\n" "$role" "$pw" "$CONN_LIMIT"
        else
          printf "ALTER ROLE %s WITH LOGIN PASSWORD '%s' CONNECTION LIMIT %s;\n" "$role" "$pw" "$CONN_LIMIT"
        fi
        local d schemas=()
        for d in "${DB_LIST[@]}"; do
          printf 'GRANT CONNECT ON DATABASE %s TO %s;\n' "$(pg_ident "$d")" "$role"
        done
        printf '\n-- Phần 2: chạy TRONG từng database đích (psql tự chuyển nhờ \\connect;\n'
        printf -- '--         nếu dùng DBeaver: mở connection vào đúng database rồi chạy khối tương ứng)\n'
        for d in "${DB_LIST[@]}"; do
          # Schema thực có trong DB này (kiểm tra lúc kết nối admin); chưa kiểm tra → dùng danh sách đã nhập
          if [[ -n "${PG_SCHEMAS_BY_DB[$d]+x}" ]]; then
            read -r -a schemas <<<"${PG_SCHEMAS_BY_DB[$d]}"
          else
            schemas=("${PG_SCHEMAS[@]}")
          fi
          printf '\\connect %s\n' "$(pg_ident "$d")"
          (( ${#schemas[@]} > 0 )) || printf -- '-- (không có schema nào trong danh sách → chỉ có quyền CONNECT)\n'
          for s in "${schemas[@]}"; do
            s="$(pg_ident "$s")"
            printf 'GRANT %s ON SCHEMA %s TO %s;\n' "$schema_privs" "$s" "$role"
            printf 'GRANT %s ON ALL TABLES IN SCHEMA %s TO %s;\n' "$privs" "$s" "$role"
            printf 'ALTER DEFAULT PRIVILEGES %sIN SCHEMA %s GRANT %s ON TABLES TO %s;\n' "$owner_clause" "$s" "$privs" "$role"
            if [[ "$ACCESS_MODE" != "readonly" ]]; then
              printf 'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %s TO %s;\n' "$s" "$role"
              printf 'ALTER DEFAULT PRIVILEGES %sIN SCHEMA %s GRANT USAGE, SELECT ON SEQUENCES TO %s;\n' "$owner_clause" "$s" "$role"
            fi
          done
        done
        # Postgres chỉ cho OWNER của bảng ALTER/DROP nó. Cho user ddl làm thành viên role owner
        # để migration sửa được cả các bảng đã có sẵn (do owner tạo).
        if [[ "$ACCESS_MODE" == "ddl" && -n "$PG_OWNER" && "$PG_GRANT_OWNER" == "yes" ]]; then
          printf -- '-- Thành viên role owner → ALTER/DROP được bảng do %s sở hữu\n' "$(pg_ident "$PG_OWNER")"
          printf 'GRANT %s TO %s;\n' "$(pg_ident "$PG_OWNER")" "$role"
        fi
        ;;
    esac
  } >"$SQL_FILE"
  chmod 600 "$SQL_FILE"
}

show_sql_masked() {
  local content
  content="$(<"$SQL_FILE")"
  [[ -n "$NEW_DB_PASS" ]] && content="${content//"$(mysql_str "$NEW_DB_PASS")"/********}"
  [[ -n "$NEW_DB_PASS" ]] && content="${content//"$(pg_str "$NEW_DB_PASS")"/********}"
  codeblock "$content"
}

# ============================== Xoá (drop) ================================

confirm_typed() {
  # confirm_typed "chuỗi" [hành động] → bắt gõ lại đúng chuỗi (chống nhấn y nhầm). Hành động mặc định: XOÁ
  local want="$1" action="${2:-XOÁ}" got
  read -r -p "  ${RED}?${RESET} Gõ ${BOLD}${want}${RESET} để xác nhận ${action}: " got || die "Không đọc được input."
  [[ "$(trim "$got")" == "$want" ]]
}

confirm_drop() {
  # confirm_drop item… → 1 mục: gõ lại tên · nhiều mục: gõ "XOA <số mục>"
  # --yes: --confirm phải lặp lại ĐÚNG giá trị đã truyền ở CONFIRM_EXPECT (--tunnel-user / --db-user)
  if (( NONINTERACTIVE )); then
    [[ -n "${OPT[confirm]:-}" && "${OPT[confirm]}" == "${CONFIRM_EXPECT:-}" ]] \
      || die_code "$EXIT_CANCELLED" "Xoá cần --confirm \"${CONFIRM_EXPECT:-}\" (lặp lại đúng danh sách cần xoá). Chưa thay đổi gì."
    preset_note "Xác nhận XOÁ" "${OPT[confirm]}" "--confirm"
    return 0
  fi
  local want
  if (( $# == 1 )); then want="$1"; else want="XOA $#"; fi
  confirm_typed "$want" || die "Không khớp. Huỷ, chưa thay đổi gì."
}

choose_multi() {
  # choose_multi "câu hỏi" "lựa chọn 1" … → mảng toàn cục CHOSEN (chỉ số 0-based, tăng dần, không trùng)
  # Cú pháp: 1 3 · 1,3 · 2-4 · all
  local prompt="$1"; shift
  local opts=("$@") n=$# i ans tok a b sel=()
  printf '  %s%s%s\n' "$BOLD" "$prompt" "$RESET" >&2
  for (( i = 0; i < n; i++ )); do printf '     %s%d)%s %s\n' "$CYAN" "$((i + 1))" "$RESET" "${opts[$i]}" >&2; done
  while true; do
    if [[ -n "${CHOOSE_MULTI_DEFAULT_ALL:-}" ]]; then
      read -r -p "  ${CYAN}›${RESET} Chọn ${DIM}[vd: 1 3 · 2-4 · all, Default: all]${RESET}: " ans || die "Không đọc được input."
    else
      read -r -p "  ${CYAN}›${RESET} Chọn ${DIM}[vd: 1 3 · 2-4 · all]${RESET}: " ans || die "Không đọc được input."
    fi
    ans="$(trim "${ans//,/ }")"
    if [[ -z "$ans" && -n "${CHOOSE_MULTI_DEFAULT_ALL:-}" ]]; then ans="all"; fi
    [[ -n "$ans" ]] || { warn "Bắt buộc chọn ít nhất 1 mục."; continue; }
    sel=()
    if [[ "${ans,,}" == "all" ]]; then
      for (( i = 1; i <= n; i++ )); do sel+=("$i"); done
    else
      for tok in $ans; do
        if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
          a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
          (( a >= 1 && b <= n && a <= b )) || { sel=(); break; }
          for (( i = a; i <= b; i++ )); do sel+=("$i"); done
        elif [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= n )); then
          sel+=("$tok")
        else
          sel=(); break
        fi
      done
    fi
    if (( ${#sel[@]} == 0 )); then warn "Lựa chọn không hợp lệ."; continue; fi
    mapfile -t CHOSEN < <(printf '%s\n' "${sel[@]}" | sort -n -u | awk '{print $1 - 1}')
    return 0
  done
}

mysql_label() {
  # mysql_label "user@host" [độ rộng cột tên] → "user   (mọi host)" cho dễ đọc
  local u="${1%@*}" h="${1##*@}" w="${2:-0}" hl
  case "$h" in
    %)         hl="mọi host" ;;
    localhost) hl="chỉ localhost" ;;
    *)         hl="$h" ;;
  esac
  if (( w > 0 )); then printf '%-*s  (%s)' "$w" "$u" "$hl"; else printf '%s (%s)' "$u" "$hl"; fi
}

select_by_names() {
  # select_by_names "<a,b,…>" raw… → CHOSEN (chỉ số 0-based). Khớp đúng tên; với MySQL cho phép
  # chỉ ghi tên user nếu tên đó là duy nhất (không cần @host).
  local list="$1"; shift
  local raw=("$@") want i hit n_hit out=()
  IFS=',' read -r -a wants <<<"${list// /}"
  for want in "${wants[@]}"; do
    [[ -n "$want" ]] || continue
    hit=-1; n_hit=0
    for (( i = 0; i < ${#raw[@]}; i++ )); do
      if [[ "${raw[$i]}" == "$want" ]]; then hit=$i; n_hit=1; break; fi
      if [[ "${raw[$i]%@*}" == "$want" ]]; then hit=$i; n_hit=$((n_hit + 1)); fi
    done
    (( n_hit == 1 )) || {
      (( n_hit == 0 )) && die_code "$EXIT_USAGE" "'${want}' không có trong danh sách: ${raw[*]}"
      die_code "$EXIT_USAGE" "'${want}' khớp nhiều tài khoản — ghi rõ dạng user@host."
    }
    out+=("$hit")
  done
  (( ${#out[@]} > 0 )) || die_code "$EXIT_USAGE" "Danh sách cần xoá rỗng."
  mapfile -t CHOSEN < <(printf '%s\n' "${out[@]}" | sort -n -u)
}

set_match_markers() {
  # Marker cố định (KHÔNG đổi theo tên file) để mọi lần chạy đều nhận ra block cũ
  MATCH_BEGIN="# >>> db-tunnel: ${1} (managed by db-user-tunnel-setup.sh) >>>"
  MATCH_END="# <<< db-tunnel: ${1} <<<"
}

list_tunnel_users() {
  # Các user do script tạo: GECOS = TUNNEL_GECOS / SHELL_GECOS, hoặc có Match block trong sshd_config
  {
    getent passwd | awk -F: -v g="$TUNNEL_GECOS" -v h="$SHELL_GECOS" '$5==g || $5==h {print $1}'
    sed -nE 's/^# >>> db-tunnel: ([^ ]+) .*/\1/p' /etc/ssh/sshd_config 2>/dev/null
  } | sort -u
}

drop_tunnel() {
  step "Chọn SSH tunnel / SSH user cần xoá"
  local all=() sel=() u i
  mapfile -t all < <(list_tunnel_users)
  if (( ${#all[@]} == 0 )); then
    info "Không tìm thấy tunnel / SSH user nào do script tạo."
    STEP_TOTAL=$((STEP_NO + 1))
    return 0
  fi
  if [[ -n "${OPT[tunnel-user]:-}" ]]; then
    select_by_names "${OPT[tunnel-user]}" "${all[@]}"
    CONFIRM_EXPECT="${OPT[tunnel-user]}"
  elif (( NONINTERACTIVE )); then
    die_code "$EXIT_USAGE" "Thiếu --tunnel-user (có: ${all[*]})."
  else
    local labels=() x kind
    for x in "${all[@]}"; do
      case "$(getent passwd "$x" | cut -d: -f5)" in
        "$SHELL_GECOS") kind="shell"; [[ -f "$(sudoers_file_for "$x")" ]] && kind="shell + sudo" ;;
        *) kind="tunnel" ;;
      esac
      labels+=("$(printf '%-28s (%s)' "$x" "$kind")")
    done
    choose_multi "User do script tạo:" "${labels[@]}"
  fi
  for i in "${CHOSEN[@]}"; do sel+=("${all[$i]}"); done

  SSHD_CFG="/etc/ssh/sshd_config"
  SSHD_BIN="$(find_sshd_bin)"; [[ -n "$SSHD_BIN" ]] || die "Không thấy sshd."

  # Kiểm tra + khảo sát từng user (chưa thay đổi gì)
  local -A has_user=() has_match=() in_allow=() n_proc=()
  local need_cfg="no" gecos
  for u in "${sel[@]}"; do
    if [[ "$u" == "root" || "$u" == "${SUDO_USER:-}" ]]; then die "Không xoá '${u}'."; fi
    set_match_markers "$u"
    has_user[$u]="no"; has_match[$u]="no"; in_allow[$u]="no"; n_proc[$u]=0
    if id "$u" &>/dev/null; then
      has_user[$u]="yes"
      n_proc[$u]="$( { pgrep -u "$u" 2>/dev/null || true; } | wc -l)"   # pgrep trả 1 khi không có tiến trình
    fi
    grep -qF "$MATCH_BEGIN" "$SSHD_CFG" 2>/dev/null && has_match[$u]="yes"
    grep -Eq "^[[:space:]]*AllowUsers([[:space:]].*)?[[:space:]]${u}([[:space:]]|\$)" "$SSHD_CFG" && in_allow[$u]="yes"
    gecos=""; [[ "${has_user[$u]}" == "yes" ]] && gecos="$(getent passwd "$u" | cut -d: -f5)"
    [[ "$gecos" == "$TUNNEL_GECOS" || "$gecos" == "$SHELL_GECOS" || "${has_match[$u]}" == "yes" ]] \
      || die "'${u}' không phải user do script tạo (GECOS lạ, không có Match block). Không xoá."
    [[ "${has_match[$u]}" == "yes" || "${in_allow[$u]}" == "yes" ]] && need_cfg="yes"
  done

  step "Xoá ${#sel[@]} user"
  info "Kế hoạch:"
  for u in "${sel[@]}"; do
    note "• ${u}:"
    [[ "${has_match[$u]}" == "yes" ]] && note "    gỡ Match block trong sshd_config"
    [[ "${in_allow[$u]}" == "yes" ]] && note "    gỡ khỏi AllowUsers"
    (( ${n_proc[$u]} > 0 )) && note "    ngắt ${n_proc[$u]} tiến trình / tunnel đang mở"
    [[ -f "$(sudoers_file_for "$u")" ]] && note "    gỡ sudo: xoá $(sudoers_file_for "$u")"
    [[ "${has_user[$u]}" == "yes" ]] && note "    userdel -r (xoá cả home, authorized_keys)"
  done
  note "• Private key đã giao trước đây sẽ không dùng được nữa"
  blank
  confirm_drop "${sel[@]}"

  # sshd_config: 1 lần backup, sửa cho mọi user, 1 lần sshd -t, 1 lần reload
  if [[ "$need_cfg" == "yes" ]]; then
    sshd_check || { err "sshd_config hiện tại đã lỗi sẵn:"; codeblock "$SSHD_T_OUT"; die "Sửa sshd_config trước. Chưa thay đổi gì."; }
    backup_file "$SSHD_CFG" SSHD_BAK
    local tmp; tmp="$(mktemp)"; TMP_FILES+=("$tmp")
    for u in "${sel[@]}"; do
      set_match_markers "$u"
      awk -v b="$MATCH_BEGIN" -v e="$MATCH_END" '
        $0==b {skip=1; next}
        skip && $0==e {skip=0; next}
        !skip {print}
      ' "$SSHD_CFG" >"$tmp"
      cat "$tmp" >"$SSHD_CFG"
      if [[ "${in_allow[$u]}" == "yes" ]]; then
        sed -i -E "/^[[:space:]]*AllowUsers/ s/[[:space:]]+${u}([[:space:]]|\$)/\1/" "$SSHD_CFG"
      fi
    done
    if sshd_check; then
      ok "sshd -t OK"
      record "Gỡ Match block / AllowUsers của: ${sel[*]} khỏi ${SSHD_CFG}" "cp -p ${SSHD_BAK} ${SSHD_CFG}"
    else
      err "sshd -t báo lỗi sau khi sửa:"; codeblock "$SSHD_T_OUT"
      cp -p -- "$SSHD_BAK" "$SSHD_CFG"
      die "Đã rollback ${SSHD_CFG}. Chưa xoá user nào."
    fi
    local svc; svc="$(find_ssh_service)"
    if [[ -n "$svc" ]] && systemctl is-active --quiet "$svc"; then
      systemctl reload "$svc" || die "Reload ${svc} thất bại — kiểm tra tay."
      ok "Reload ${svc}: xong"
    fi
  fi

  DROPPED=()
  for u in "${sel[@]}"; do
    if [[ "${has_user[$u]}" == "yes" ]]; then
      if (( ${n_proc[$u]} > 0 )); then
        pkill -KILL -u "$u" 2>/dev/null || true
        sleep 1
      fi
      userdel -r "$u" >>"$LOG_FILE" 2>&1 || die "userdel -r ${u} thất bại — xem log."
      record "Xoá user OS '${u}' (home + authorized_keys)" "Tạo lại bằng script (key cũ không khôi phục được)"
    fi
    if [[ -f "$(sudoers_file_for "$u")" ]]; then
      rm -f -- "$(sudoers_file_for "$u")"
      record "Xoá $(sudoers_file_for "$u") (gỡ sudo của '${u}')" "Cấp lại bằng script"
    fi
    ok "Đã xoá '${u}'"
    DROPPED+=("'${u}'")
  done
}

drop_db_user() {
  step "Thông tin Database"
  collect_conn_info

  step "Chuẩn bị CLI client"
  case "$DB_ENGINE" in
    mysql)    require_cmd_or_install mysql "mysql-client" "mariadb105" ;;
    mariadb)  require_cmd_or_install mysql "mariadb-client" "mariadb105" ;;
    postgres) require_cmd_or_install psql "postgresql-client" "postgresql15" ;;
  esac

  step "Chọn DB user cần xoá"
  info "Cần admin DB để xoá → nhập thông tin admin:"
  ask ADMIN_USER "Admin DB user"
  ask_admin_secret ADMIN_PASS "Admin DB password"

  # Kết nối admin trước, rồi liệt kê user có thật trong DB để chọn (tránh gõ nhầm tên database…)
  local out cands=() sel=() u i list_out list_ok="yes"
  case "$DB_ENGINE" in
    mysql|mariadb)
      make_mycnf ADMIN_CNF "$ADMIN_USER" "$ADMIN_PASS"
      out="$(run_mysql "$ADMIN_CNF" -N -B -e "SELECT 1;" 2>&1)" || admin_conn_fail "$out"
      ok "Kết nối admin OK"
      # Phân biệt "truy vấn lỗi" (thiếu quyền) với "truy vấn được nhưng không có user nào"
      list_out="$(run_mysql "$ADMIN_CNF" -N -B -e \
        "SELECT CONCAT(User,'@',Host) FROM mysql.user
          WHERE User <> '' AND User <> SUBSTRING_INDEX(CURRENT_USER(),'@',1)
            AND User NOT IN ('root','rdsadmin','mysql.sys','mysql.session','mysql.infoschema','mariadb.sys')
          ORDER BY User, Host;" 2>>"$LOG_FILE")" || list_ok="no"
      ;;
    postgres)
      out="$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc "SELECT 1;" 2>&1)" || admin_conn_fail "$out"
      ok "Kết nối admin OK"
      list_out="$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc \
        "SELECT rolname FROM pg_roles
          WHERE rolcanlogin AND NOT rolsuper AND rolname !~ '^(pg_|rds)' AND rolname <> current_user
          ORDER BY 1;" 2>>"$LOG_FILE")" || list_ok="no"
      ;;
  esac
  if [[ "$list_ok" == "yes" && -n "$list_out" ]]; then mapfile -t cands <<<"$list_out"; fi

  # Đọc được danh sách nhưng rỗng → không có gì để xoá, kết thúc bình thường
  if [[ "$list_ok" == "yes" && ${#cands[@]} -eq 0 ]]; then
    blank
    info "Không có DB user nào để xoá (đã ẩn admin '${ADMIN_USER}', user hệ thống, superuser)."
    STEP_TOTAL=$((STEP_NO + 1))   # bỏ qua bước xoá → bước tiếp theo là Tổng kết
    return 0
  fi

  blank
  if (( ${#cands[@]} > 0 )); then
    local labels=() w=0 c
    if [[ "$DB_ENGINE" == "postgres" ]]; then
      labels=("${cands[@]}")
    else
      # MySQL: hiện "tên (host)" căn cột; giá trị thật vẫn là user@host
      for c in "${cands[@]}"; do c="${c%@*}"; (( ${#c} > w )) && w=${#c}; done
      for c in "${cands[@]}"; do labels+=("$(mysql_label "$c" "$w")"); done
    fi
    if [[ -n "${OPT[db-user]:-}" ]]; then
      select_by_names "${OPT[db-user]}" "${cands[@]}"
      CONFIRM_EXPECT="${OPT[db-user]}"
    elif (( NONINTERACTIVE )); then
      die_code "$EXIT_USAGE" "Thiếu --db-user (có: ${cands[*]})."
    else
      choose_multi "DB user hiện có (đã ẩn admin / user hệ thống / superuser):" "${labels[@]}"
    fi
    for i in "${CHOSEN[@]}"; do sel+=("${cands[$i]}"); done
  else
    # MySQL: admin không đọc được mysql.user → nhập tay (1 user)
    warn "Không liệt kê được user (admin thiếu quyền đọc danh sách) → nhập tay."
    ask DROP_MANUAL_USER "DB user cần xoá" "" '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}$' "Tên user không hợp lệ."
    u="$DROP_MANUAL_USER"; CONFIRM_EXPECT="${OPT[db-user]:-$u}"
    if [[ "$DB_ENGINE" != "postgres" ]]; then
      ask MYSQL_HOST_PART "Host part" "%" '^[A-Za-z0-9.%_:-]+$' "Host part không hợp lệ."
      u="${u}@${MYSQL_HOST_PART}"
    fi
    sel=("$u")
  fi

  # Kiểm tra + lưu evidence từng user (chưa thay đổi gì)
  step "Xoá ${#sel[@]} DB user"
  local name dbs=() db evidence role acct h
  local -A n_sess=() acct_of=() ev_of=()
  if [[ "$DB_ENGINE" == "postgres" ]]; then
    mapfile -t dbs < <(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc \
      "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1;" 2>>"$LOG_FILE")
  fi
  for u in "${sel[@]}"; do
    name="${u%@*}"; [[ "$DB_ENGINE" == "postgres" ]] && name="$u"
    [[ "$name" == "$ADMIN_USER" ]] && die "Không xoá chính user admin đang dùng."
    case "${name,,}" in root|postgres|rdsadmin|rds_superuser|mysql.sys|mysql.session|mysql.infoschema|mariadb.sys)
      die "'${name}' là user hệ thống. Không xoá." ;;
    esac
    # MySQL: cùng tên khác host là 2 tài khoản → tên file kèm host để không ghi đè nhau
    evidence="${EVIDENCE_DIR}/before_drop_${name}"
    if [[ "$DB_ENGINE" != "postgres" ]]; then
      h="${u##*@}"; h="${h//%/any}"                   # '%' → 'any' cho dễ đọc
      evidence+="@$(printf '%s' "$h" | tr -c 'A-Za-z0-9._-' '_')"
    fi
    evidence+=".txt"; ev_of[$u]="$evidence"
    case "$DB_ENGINE" in
      mysql|mariadb)
        acct="'$(mysql_str "$name")'@'$(mysql_str "${u##*@}")'"
        acct_of[$u]="$acct"
        if ! run_mysql "$ADMIN_CNF" -e "SHOW GRANTS FOR ${acct};" >"$evidence" 2>&1; then
          grep -q 'ERROR 1141' "$evidence" && die "User ${acct} không tồn tại. Chưa thay đổi gì."
          die "Không đọc được quyền của ${acct}: $(tail -n 1 "$evidence")"
        fi
        ;;
      postgres)
        [[ "$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc \
          "SELECT 1 FROM pg_roles WHERE rolname='$(pg_str "$name")';" 2>>"$LOG_FILE")" == "1" ]] \
          || die "Role '${name}' không tồn tại. Chưa thay đổi gì."
        [[ "$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc \
          "SELECT rolsuper FROM pg_roles WHERE rolname='$(pg_str "$name")';" 2>>"$LOG_FILE")" == "t" ]] \
          && die "'${name}' là SUPERUSER. Không xoá bằng script."
        {
          printf '== Role\n'; run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -c "\\du $(pg_ident "$name")" 2>&1
          for db in "${dbs[@]}"; do
            printf '\n== Quyền trên bảng trong DB %s\n' "$db"
            run_psql "$ADMIN_USER" "$ADMIN_PASS" -d "$db" -c \
              "SELECT table_schema, privilege_type, count(*) AS tables FROM information_schema.role_table_grants
                WHERE grantee='$(pg_str "$name")' GROUP BY 1,2 ORDER BY 1,2;" 2>&1
          done
        } >"$evidence"
        n_sess[$u]="$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc \
          "SELECT count(*) FROM pg_stat_activity WHERE usename='$(pg_str "$name")';" 2>>"$LOG_FILE" || echo 0)"
        ;;
    esac
  done
  ok "Đã lưu quyền hiện tại của ${#sel[@]} user vào evidence"

  info "Kế hoạch:"
  for u in "${sel[@]}"; do
    if [[ "$DB_ENGINE" == "postgres" ]]; then
      note "• ${u}: thu hồi quyền trong ${#dbs[@]} database → DROP ROLE$( (( ${n_sess[$u]:-0} > 0 )) && printf ' (ngắt %s session)' "${n_sess[$u]}")"
    else
      note "• $(mysql_label "$u"): DROP USER ${acct_of[$u]}"
    fi
  done
  [[ "$DB_ENGINE" == "postgres" ]] && note "  (bảng user đó sở hữu → chuyển owner sang '${ADMIN_USER}', không mất dữ liệu)"
  blank
  # MySQL: chỉ cần gõ tên (bỏ @host) khi xoá 1 user
  if [[ "$DB_ENGINE" != "postgres" && ${#sel[@]} -eq 1 ]]; then confirm_drop "${sel[0]%@*}"; else confirm_drop "${sel[@]}"; fi

  DROPPED=()
  for u in "${sel[@]}"; do
    case "$DB_ENGINE" in
      mysql|mariadb)
        acct="${acct_of[$u]}"
        out="$(run_mysql "$ADMIN_CNF" -e "DROP USER ${acct};" 2>&1)" || die "DROP USER ${acct} thất bại: ${out}"
        record "SQL: DROP USER ${acct};" "Tạo lại bằng script · quyền cũ: evidence/$(basename "${ev_of[$u]}")"
        ok "Đã xoá $(mysql_label "$u")"
        ;;
      postgres)
        role="$(pg_ident "$u")"
        if (( ${n_sess[$u]:-0} > 0 )); then
          run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc \
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename='$(pg_str "$u")';" >>"$LOG_FILE" 2>&1 || true
        fi
        for db in "${dbs[@]}"; do
          out="$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d "$db" -v ON_ERROR_STOP=1 -q \
            -c "REASSIGN OWNED BY ${role} TO CURRENT_USER;" -c "DROP OWNED BY ${role};" 2>&1)" \
            || die "Dọn quyền của '${u}' trong DB '${db}' thất bại: ${out}"
          record "SQL [${db}]: REASSIGN OWNED BY ${role} TO CURRENT_USER; DROP OWNED BY ${role};" "Cấp lại quyền bằng script · tham khảo: evidence/$(basename "${ev_of[$u]}")"
        done
        out="$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -v ON_ERROR_STOP=1 -q -c "DROP ROLE ${role};" 2>&1)" \
          || die "DROP ROLE ${role} thất bại: ${out}"
        record "SQL: DROP ROLE ${role};" "Tạo lại bằng script"
        ok "Đã xoá role '${u}'"
        ;;
    esac
    if [[ "$DB_ENGINE" == "postgres" ]]; then DROPPED+=("DB user '${u}'"); else DROPPED+=("DB user $(mysql_label "$u")"); fi
  done
  [[ "$DB_ENGINE" != "postgres" ]] && note "Session MySQL đang mở của các user này vẫn sống tới khi ngắt kết nối."
  return 0
}

finish_drop() {
  # Tổng kết ngắn cho chế độ xoá, rồi thoát (không chạy phần tạo)
  write_changes_file
  step "Tổng kết"
  local d
  if (( ${#DROPPED[@]} > 0 )); then
    for d in "${DROPPED[@]}"; do ok "Đã xoá ${d}"; done
  else
    info "Không có gì bị xoá."
  fi
  blank
  printf '  %sFile output%s\n' "$BOLD" "$RESET" >&2
  printf '  Link: %s\n' "$OUT_DIR" >&2
  blank
  printf '%s%s%s\n✔ Hoàn tất\n%s%s\n\n' "$BOLD" "$GREEN" "$RULE" "$RULE" "$RESET" >&2
  log "===== Hoàn tất (xoá) ====="
  emit_json status ok action "$([[ "$SCOPE_IDX" == 5 ]] && echo drop-tunnel || echo drop-db-user)" \
    dropped "$(json_array "${DROPPED[@]}")" output_dir "$OUT_DIR" changes_file "$CHANGES_FILE" log_file "$LOG_FILE"
  exit 0
}

# ============================== SSH user (shell, tuỳ chọn sudo) ==========
# Menu 4. Tài khoản SSH riêng cho từng người (thay vì dùng chung ec2-user / ubuntu). Chỉ đăng nhập bằng key;
# password (nếu có) chỉ dùng cho sudo. Nhận diện để xoá qua SHELL_GECOS + Match block có marker.

sudoers_file_for() { printf '/etc/sudoers.d/90-ssh-user-%s' "$1"; }

create_ssh_user() {
  step "Thông tin SSH user"
  note "Tài khoản riêng cho từng người, thay cho việc dùng chung ec2-user / ubuntu"
  local u gecos pubkey="" fp ak_tmp sudo_tmp sf svc
  ask SSH_NEW_USER "Username" "" "^[a-z_][a-z0-9_-]{0,$(( OS_USER_MAX - 1 ))}\$" \
    "Chỉ dùng a-z, 0-9, _ , - ; bắt đầu bằng chữ; tối đa ${OS_USER_MAX} ký tự."
  u="$SSH_NEW_USER"
  [[ "$u" != "root" && "$u" != "${SUDO_USER:-}" ]] || die "Không dùng '${u}'."
  local existed="no"
  if id "$u" &>/dev/null; then
    gecos="$(getent passwd "$u" | cut -d: -f5)"
    [[ "$gecos" == "$SHELL_GECOS" ]] \
      || die "User '${u}' đã có trên server và không do script tạo (GECOS='${gecos}'). Không đụng tới."
    existed="yes"
    info "User '${u}' đã có (do script tạo) → cập nhật key / sudo."
  fi

  # ---- Key: mặc định dán public key của người dùng (private key không rời máy họ)
  blank
  choose KEYSRC_IDX "SSH key:" \
    "Dán public key của người dùng (khuyến nghị)" \
    "Sinh cặp key mới ed25519 vào thư mục output"
  if [[ "$KEYSRC_IDX" == "1" ]]; then
    note "Trên máy người dùng: cat ~/.ssh/id_ed25519.pub  (chưa có thì: ssh-keygen -t ed25519)"
    local kf; kf="$(mktemp "${OUT_DIR}/.pub.XXXXXX")"; TMP_FILES+=("$kf")
    while true; do
      read -r -p "  ${CYAN}›${RESET} Public key: " pubkey || die "Không đọc được input."
      pubkey="$(trim "$pubkey")"
      if [[ "$pubkey" == *"PRIVATE KEY"* ]]; then warn "Đây là PRIVATE key — chỉ dán PUBLIC key (.pub)."; continue; fi
      printf '%s\n' "$pubkey" >"$kf"
      if fp="$(ssh-keygen -lf "$kf" 2>/dev/null)"; then ok "Key hợp lệ: $(awk '{print $2, $NF}' <<<"$fp")"; break; fi
      warn "Không phải public key hợp lệ (dạng: ssh-ed25519 AAAA… comment)."
    done
    KEY_OUT=""
  fi

  # ---- Sudo
  blank
  choose SUDO_IDX "Quyền sudo:" \
    "Không sudo" \
    "sudo không cần password (giống ec2-user / ubuntu)" \
    "sudo cần password (script sinh password)"
  case "$SUDO_IDX" in 1) SUDO_MODE="none" ;; 2) SUDO_MODE="nopasswd" ;; 3) SUDO_MODE="password" ;; esac
  if [[ "$SUDO_MODE" != "none" ]]; then
    command -v visudo >/dev/null 2>&1 || die "Không có visudo (gói sudo) — không kiểm tra được sudoers."
    warn "sudo = TOÀN QUYỀN root trên server: đọc mọi file (.env, key), sửa mọi config, tạo/xoá user."
    note "Chỉ cấp cho người vận hành server. Thu hồi: chạy lại script → 5) Xoá SSH tunnel / SSH user."
    confirm_typed "$u" "CẤP SUDO" || die "Không khớp. Huỷ, chưa thay đổi gì."
  fi

  # ---- Khảo sát sshd (chỉ đọc)
  SSHD_CFG="/etc/ssh/sshd_config"
  SSHD_BIN="$(find_sshd_bin)"; [[ -n "$SSHD_BIN" ]] || die "Không thấy sshd (openssh-server chưa cài?)."
  if ! sshd_check; then
    err "sshd_config hiện tại ĐÃ lỗi sẵn (trước khi script sửa gì):"; codeblock "$SSHD_T_OUT"
    die "Sửa sshd_config trước rồi chạy lại. Chưa thay đổi gì."
  fi
  local eff allow_users allow_groups need_allow="no" match_exists="no"
  eff="$("$SSHD_BIN" -T 2>>"$LOG_FILE" || true)"
  allow_users="$(awk '$1=="allowusers"{print $2}' <<<"$eff")"
  allow_groups="$(awk '$1=="allowgroups"{print $2}' <<<"$eff")"
  if [[ -n "$allow_users" ]] && ! grep -qxF "$u" <<<"$allow_users"; then
    need_allow="yes"; grep -Eq '^[[:space:]]*AllowUsers[[:space:]]' "$SSHD_CFG" || need_allow="manual"
  fi
  set_match_markers "$u"
  grep -qF "$MATCH_BEGIN" "$SSHD_CFG" && match_exists="yes"
  sf="$(sudoers_file_for "$u")"

  # ---- Kế hoạch
  step "Áp dụng thay đổi"
  info "Kế hoạch:"
  if [[ "$existed" == "yes" ]]; then note "• User '${u}' đã có → giữ nguyên"
  else note "• Tạo user '${u}' (shell /bin/bash, home /home/${u})"; fi
  if [[ "$KEYSRC_IDX" == "1" ]]; then note "• authorized_keys: thêm public key đã dán (thay key cũ do script thêm)"
  else note "• Sinh key ed25519 vào thư mục output, thêm public key vào authorized_keys"; fi
  case "$SUDO_MODE" in
    none)     [[ -f "$sf" ]] && note "• Gỡ sudo: xoá ${sf}" ;;
    nopasswd) note "• sudo không password: ${sf} (kiểm tra bằng visudo)" ;;
    password) note "• sudo cần password: ${sf} + đặt password (chỉ dùng cho sudo, không SSH bằng password)" ;;
  esac
  case "$need_allow" in
    yes)    note "• AllowUsers: thêm '${u}'" ;;
    manual) note "• ⚠ AllowUsers khai báo ngoài ${SSHD_CFG} → bạn cần tự thêm '${u}'" ;;
  esac
  [[ -n "$allow_groups" ]] && note "• ⚠ sshd có AllowGroups (${allow_groups//$'\n'/ }) → user cần thuộc 1 group trong đó"
  note "• sshd_config: Match block chỉ cho đăng nhập bằng key → sshd -t (lỗi → rollback) → reload"
  blank
  confirm "Tiến hành?" n y || die "Huỷ theo yêu cầu. Chưa có gì bị thay đổi."

  # 1. User
  if [[ "$existed" == "no" ]]; then
    useradd -m -s /bin/bash -c "$SHELL_GECOS" "$u"
    ok "Đã tạo user '${u}'"
    record "Tạo user OS '${u}' (shell)" "userdel -r ${u}"
  fi
  local grp; grp="$(id -gn "$u")"

  # 2. Key
  if [[ "$KEYSRC_IDX" == "2" ]]; then
    KEY_OUT="${OUT_DIR}/${u}-key"
    ssh-keygen -q -t ed25519 -f "$KEY_OUT" -C "${u}@$(hostname -s 2>/dev/null || echo server)" -N ""
    chmod 600 "$KEY_OUT"
    pubkey="$(<"${KEY_OUT}.pub")"
    ok "Key: $(basename "$KEY_OUT") · $(ssh-keygen -lf "${KEY_OUT}.pub" | awk '{print $2}')"
  fi
  local tag="[ssh-user:${u}]" home ssh_dir ak
  home="$(getent passwd "$u" | cut -d: -f6)"; ssh_dir="${home}/.ssh"; ak="${ssh_dir}/authorized_keys"
  install -d -m 700 -o "$u" -g "$grp" "$ssh_dir"
  backup_file "$ak" AK_BAK
  ak_tmp="$(mktemp "${ssh_dir}/.authorized_keys.XXXXXX")"; TMP_FILES+=("$ak_tmp")
  if [[ -f "$ak" ]]; then grep -vF "$tag" "$ak" >"$ak_tmp" || true; fi
  printf '%s %s\n' "$pubkey" "$tag" >>"$ak_tmp"
  chmod 600 "$ak_tmp"; chown "${u}:${grp}" "$ak_tmp"; mv -f "$ak_tmp" "$ak"
  ok "authorized_keys: đã thêm key"
  if [[ -n "$AK_BAK" ]]; then record "Sửa ${ak} (entry ${tag})" "cp -p ${AK_BAK} ${ak}"
  else record "Tạo ${ak} (entry ${tag})" "rm -f ${ak}"; fi

  # 3. Sudo (file riêng trong sudoers.d, kiểm tra bằng visudo TRƯỚC khi đặt vào chỗ)
  SUDO_PASS=""
  if [[ "$SUDO_MODE" == "none" ]]; then
    if [[ -f "$sf" ]]; then rm -f -- "$sf"; ok "Đã gỡ sudo (${sf})"; record "Xoá ${sf} (gỡ sudo của '${u}')" "Cấp lại bằng script"; fi
  else
    sudo_tmp="$(mktemp)"; TMP_FILES+=("$sudo_tmp")
    if [[ "$SUDO_MODE" == "nopasswd" ]]; then
      printf '# managed by %s — %s\n%s ALL=(ALL) NOPASSWD:ALL\n' "$SCRIPT_NAME" "$(date '+%F %T')" "$u" >"$sudo_tmp"
    else
      printf '# managed by %s — %s\n%s ALL=(ALL:ALL) ALL\n' "$SCRIPT_NAME" "$(date '+%F %T')" "$u" >"$sudo_tmp"
    fi
    visudo -cf "$sudo_tmp" >>"$LOG_FILE" 2>&1 || die "File sudoers sinh ra không hợp lệ (visudo). Chưa cấp sudo."
    install -m 440 -o root -g root "$sudo_tmp" "$sf"
    if ! visudo -c >>"$LOG_FILE" 2>&1; then
      rm -f -- "$sf"; die "visudo -c báo lỗi sau khi thêm ${sf} → đã gỡ file. Kiểm tra /etc/sudoers."
    fi
    ok "sudo: ${sf} (visudo OK)"
    record "Tạo ${sf} (sudo ${SUDO_MODE} cho '${u}')" "rm -f ${sf}"
    if [[ "$SUDO_MODE" == "password" ]]; then
      SUDO_PASS="$(gen_password)"
      printf '%s:%s\n' "$u" "$SUDO_PASS" | chpasswd
      ok "Đã đặt password cho sudo (→ $(basename "$CRED_FILE"))"
      record "Đặt password cho '${u}' (dùng cho sudo)" "passwd -l ${u}"
    fi
  fi

  # 4. sshd_config: AllowUsers + Match block (chỉ key, không password)
  backup_file "$SSHD_CFG" SSHD_BAK
  if [[ "$need_allow" == "yes" ]]; then
    sed -i -E "0,/^([[:space:]]*AllowUsers)([[:space:]])/s//\1 ${u}\2/" "$SSHD_CFG"
    ok "AllowUsers += ${u}"
  elif [[ "$need_allow" == "manual" ]]; then
    warn "Nhớ tự thêm '${u}' vào AllowUsers (đang khai báo ngoài ${SSHD_CFG})."
  fi
  if [[ "$match_exists" == "yes" ]]; then
    local cfg_tmp; cfg_tmp="$(mktemp)"; TMP_FILES+=("$cfg_tmp")
    awk -v b="$MATCH_BEGIN" -v e="$MATCH_END" '$0==b{skip=1;next} skip&&$0==e{skip=0;next} !skip{print}' "$SSHD_CFG" >"$cfg_tmp"
    cat "$cfg_tmp" >"$SSHD_CFG"
  fi
  [[ -n "$(tail -n 1 "$SSHD_CFG")" ]] && printf '\n' >>"$SSHD_CFG"
  {
    printf '%s\n' "$MATCH_BEGIN"
    printf 'Match User %s\n' "$u"
    printf '    AuthenticationMethods publickey\n'
    printf '    PasswordAuthentication no\n'
    printf '    KbdInteractiveAuthentication no\n'
    printf '%s\n' "$MATCH_END"
  } >>"$SSHD_CFG"
  record "Ghi Match block / AllowUsers cho '${u}' vào ${SSHD_CFG}" "cp -p ${SSHD_BAK} ${SSHD_CFG}"
  if sshd_check; then
    ok "sshd -t OK"
  else
    err "sshd -t báo lỗi sau khi sửa:"; codeblock "$SSHD_T_OUT"
    cp -p -- "$SSHD_BAK" "$SSHD_CFG"
    record "ĐÃ ROLLBACK ${SSHD_CFG} về ${SSHD_BAK} (sshd -t lỗi)" ""
    die "Đã rollback ${SSHD_CFG}. sshd KHÔNG bị reload."
  fi
  local evid="${EVIDENCE_DIR}/ssh_user_${u}.txt"
  {
    printf '== sshd -T -C user=%s\n' "$u"; { "$SSHD_BIN" -T -C "user=${u},host=localhost,addr=127.0.0.1" 2>&1 || true; } \
      | { grep -Ei '^(authenticationmethods|passwordauthentication|permittty|allowtcpforwarding) ' || true; }
    printf '\n== sudo -l -U %s\n' "$u"; sudo -l -U "$u" 2>&1 || true
  } >"$evid"
  if grep -qi '^authenticationmethods publickey' "$evid"; then ok "Hiệu lực: chỉ đăng nhập bằng key"
  else warn "Chưa thấy 'AuthenticationMethods publickey' hiệu lực cho '${u}' — xem ${evid}"; fi
  svc="$(find_ssh_service)"
  if [[ -n "$svc" ]] && systemctl is-active --quiet "$svc"; then
    if confirm "Reload ${svc}? (không rớt session)" y y; then
      systemctl reload "$svc" || die "Reload thất bại — kiểm tra tay. KHÔNG restart để tránh mất kết nối."
      ok "Reload ${svc}: xong"
    else
      warn "Chưa reload — chạy: systemctl reload ${svc}"
    fi
  fi

  # ---- Credentials + Tổng kết
  detect_server_ip
  local ssh_p_opt="" scp_p_opt="" conn
  [[ "$SSH_PORT" != "22" ]] && { ssh_p_opt="-p ${SSH_PORT} "; scp_p_opt="-P ${SSH_PORT} "; }
  conn="ssh ${ssh_p_opt}${KEY_OUT:+-i $(basename "$KEY_OUT") }${u}@${PUBLIC_IP}"
  {
    printf '# %s v%s — %s\n# File chứa bí mật. Lấy xong thì XOÁ khỏi server.\n\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$(date '+%F %T')"
    printf '[ssh_user]\nhost     = %s\nport     = %s\nuser     = %s\nsudo     = %s\n' "$PUBLIC_IP" "$SSH_PORT" "$u" "$SUDO_MODE"
    [[ -n "$SUDO_PASS" ]] && printf 'sudo_password = %s\n' "$SUDO_PASS"
    [[ -n "${KEY_OUT:-}" ]] && printf 'private_key = %s\n' "$(basename "$KEY_OUT")"
    printf '\n# Connect: %s\n' "$conn"
  } >"$CRED_FILE"
  chmod 600 "$CRED_FILE"
  write_changes_file

  step "Tổng kết"
  local show="no" sudo_label
  [[ -n "$SUDO_PASS" ]] && confirm "Hiện password sudo?" && show="yes"
  case "$SUDO_MODE" in none) sudo_label="không" ;; nopasswd) sudo_label="có, không cần password" ;; password) sudo_label="có, cần password" ;; esac
  blank
  printf '  %sSSH user%s\n' "$BOLD" "$RESET" >&2
  kv "SSH host" "${PUBLIC_IP}:${SSH_PORT}  ${DIM}(${IP_SOURCE})${RESET}"
  kv "User" "$u"
  kv "Sudo" "$sudo_label"
  if [[ -n "$SUDO_PASS" ]]; then
    if [[ "$show" == "yes" ]]; then kv "Password sudo" "$SUDO_PASS"
    else kv "Password sudo" "$(mask "$SUDO_PASS")  ${DIM}(xem $(basename "$CRED_FILE"))${RESET}"; fi
  fi
  if [[ -n "${KEY_OUT:-}" ]]; then kv "Private key" "$KEY_OUT"
  else kv "Key" "public key người dùng đã dán · $(awk '{print $2}' <<<"${fp:-}")"; fi
  kv "Connect" "${CYAN}${conn}${RESET}"
  blank
  local cat_cmd="sudo cat"; [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && cat_cmd="cat"
  printf '  %sFile output%s\n' "$BOLD" "$RESET" >&2
  kv "Link" "$OUT_DIR"
  kv "Credentials" "${CYAN}${cat_cmd} $(printf '%q' "$CRED_FILE")${RESET}"
  if [[ -n "${KEY_OUT:-}" ]]; then
    local scp_user="${SUDO_USER:-<user>}"; [[ "$scp_user" == "root" ]] && scp_user="<user>"
    kv "Copy private key" "${CYAN}scp ${scp_p_opt}${scp_user}@${PUBLIC_IP}:$(printf '%q' "$KEY_OUT") . && chmod 600 $(printf '%q' "$(basename "$KEY_OUT")")${RESET}"
  fi
  blank
  printf '  %s⚠ Nhắc nhở bảo mật%s\n' "$YELLOW" "$RESET" >&2
  note "• Thử đăng nhập bằng user mới ở cửa sổ khác TRƯỚC khi đóng phiên hiện tại."
  note "• Security Group / firewall: chỉ whitelist IP cần thiết cho port ${SSH_PORT} (SSH)."
  note "• Xoá:  rm -rf ${OUT_DIR} hoặc xoá output của mọi lần chạy:  rm -rf ${OUT_BASE}"
  blank
  printf '%s%s%s\n✔ Hoàn tất\n%s%s\n\n' "$BOLD" "$GREEN" "$RULE" "$RULE" "$RESET" >&2
  log "===== Hoàn tất (SSH user) ====="
  exit 0
}

# ============================== Start =====================================

usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Tạo DB user readonly / dml / ddl (MySQL, MariaDB, PostgreSQL) và SSH account tunnel-only.
Xoá: SSH tunnel do script tạo, DB user (thu hồi quyền trên mọi database rồi DROP).

CÁCH CHẠY
  Tương tác (hỏi từng bước):   sudo bash ${SCRIPT_NAME}
  Truyền sẵn một phần:          sudo bash ${SCRIPT_NAME} --engine postgres --port 5439
                                (tham số nào có thì không hỏi; vẫn hỏi xác nhận)
  Không tương tác (CI):         thêm --yes; thiếu tham số bắt buộc → thoát mã ${EXIT_USAGE}

HÀNH ĐỘNG
  --action create|drop-tunnel|drop-db-user
  --scope  db|tunnel|both            (với create)

DATABASE
  --engine mysql|mariadb|postgres    --host HOST     --port PORT
  --database NAME                    --mode readonly|dml|ddl
  --user NAME                        --max-conn N    --schemas a,b (Postgres)
  --host-part HOST (MySQL)           --admin-user NAME
  --sql-only        chỉ sinh file SQL, không chạy
  --allow-alter     user đã tồn tại → đổi password + cấp thêm quyền (không có: thoát mã ${EXIT_USER_EXISTS})

SSH TUNNEL
  --tunnel-user NAME   --key-name NAME   --key-type ed25519|rsa
  --key-comment TEXT   --tunnel-target HOST:PORT

XOÁ
  --tunnel-user a,b    (drop-tunnel)     --db-user a,b    (drop-db-user; MySQL: user hoặc user@host)
  --confirm "a,b"      bắt buộc khi --yes, phải lặp lại đúng danh sách cần xoá

CHUNG
  --yes, -y            không hỏi; mọi câu xác nhận dùng câu trả lời an toàn định sẵn
  --config FILE        đọc tham số từ file (mỗi dòng key=value, key = tên tham số bỏ "--")
  --output json        in kết quả JSON ra stdout (giao diện vẫn ở stderr)
  --admin-pass-stdin   đọc password admin từ stdin

BÍ MẬT (không truyền qua tham số để tránh lộ trong ps / history)
  DB_ADMIN_PASS        password admin DB
  DB_NEW_PASS          password cho user mới (không có → tự sinh)

BIẾN MÔI TRƯỜNG KHÁC
  NO_COLOR=1   tắt màu
  NO_RECORD=1  không ghi $(basename "$CONSOLE_LOG")
  UI_DELAY=…   giây giữa các dòng thông báo (hiện tại: ${UI_DELAY}; 0 = tắt; --yes mặc định 0)
  OUT_BASE=…   đổi thư mục cha chứa output (mặc định: cạnh file script)

MÃ THOÁT
  0 thành công · ${EXIT_ERROR} lỗi chung · ${EXIT_USAGE} tham số sai/thiếu · ${EXIT_ADMIN_CONN} không kết nối được admin
  ${EXIT_ADMIN_PRIV} admin thiếu quyền · ${EXIT_USER_EXISTS} user đã tồn tại · ${EXIT_CANCELLED} huỷ / --confirm không khớp

VÍ DỤ
  # Tạo user readonly trên Postgres, không hỏi gì, kết quả JSON
  sudo DB_ADMIN_PASS='…' bash ${SCRIPT_NAME} --yes --output json \\
    --action create --scope db --engine postgres --port 5432 \\
    --database appdb --mode readonly --admin-user app

  # Xoá 2 user MySQL
  sudo DB_ADMIN_PASS='…' bash ${SCRIPT_NAME} --yes --action drop-db-user --engine mysql \\
    --port 3307 --admin-user root --db-user dml_shop,readonly_shop --confirm dml_shop,readonly_shop

Output: ${OUT_BASE}/<timestamp>/ (chỉ owner đọc được), chứa
  $(basename "$CRED_FILE"), file SQL, private key, evidence/, $(basename "$LOG_FILE"), $(basename "$CONSOLE_LOG"), $(basename "$CHANGES_FILE")
EOF
}

# Tham số nhận giá trị (--key value / --key=value). Dùng chung cho --config.
VALUE_OPTS=" action scope engine host port database mode user max-conn schemas host-part admin-user
  tunnel-user key-name key-type key-comment tunnel-target db-user confirm output config "
FLAG_OPTS=" yes sql-only allow-alter admin-pass-stdin "
VALUE_OPTS="${VALUE_OPTS//$'\n'/ }"   # gộp về 1 dòng để so " key " không lệch ở chỗ xuống dòng

set_opt() {
  # set_opt key value (key đã được kiểm tra hợp lệ)
  case "$1" in
    action)
      case "$2" in
        create) ;;
        drop-tunnel)  OPT[scope-idx]=5 ;;
        drop-db-user) OPT[scope-idx]=6 ;;
        *) die_code "$EXIT_USAGE" "--action=$2 không hợp lệ (create | drop-tunnel | drop-db-user)." ;;
      esac
      OPT[action]="$2" ;;
    scope)
      case "$2" in
        both) OPT[scope-idx]=1 ;; db) OPT[scope-idx]=2 ;; tunnel) OPT[scope-idx]=3 ;;
        *) die_code "$EXIT_USAGE" "--scope=$2 không hợp lệ (db | tunnel | both)." ;;
      esac ;;
    output)
      [[ "$2" == "json" ]] || die_code "$EXIT_USAGE" "--output chỉ hỗ trợ json."
      OUTPUT_JSON=1 ;;
    *) OPT[$1]="$2" ;;
  esac
}

load_config() {
  # Mỗi dòng key=value (key = tên tham số, bỏ "--"); bỏ qua dòng trống / comment. KHÔNG source file.
  local f="$1" line k v n=0
  [[ -r "$f" ]] || die_code "$EXIT_USAGE" "Không đọc được --config ${f}."
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="$(trim "${line%%#*}")"
    [[ -n "$line" ]] || continue
    [[ "$line" == *=* ]] || die_code "$EXIT_USAGE" "${f}:${n}: thiếu dấu '='."
    k="$(trim "${line%%=*}")"; v="$(trim "${line#*=}")"
    v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
    case "$k" in *pass*) die_code "$EXIT_USAGE" "${f}:${n}: không để password trong file cấu hình — dùng DB_ADMIN_PASS / DB_NEW_PASS." ;; esac
    if [[ "$VALUE_OPTS" == *" $k "* && "$k" != "config" ]]; then set_opt "$k" "$v"
    elif [[ "$FLAG_OPTS" == *" $k "* ]]; then
      case "${v,,}" in 1|true|yes|y) set_opt "$k" 1 ;; 0|false|no|n|"") ;; *) die_code "$EXIT_USAGE" "${f}:${n}: ${k} chỉ nhận true/false." ;; esac
    else die_code "$EXIT_USAGE" "${f}:${n}: không biết tham số '${k}'."
    fi
  done <"$f"
}

parse_args() {
  local a k v i args=("$@")
  # Lượt 1: --output json (để cả lỗi lúc đọc config cũng ra JSON), rồi --config
  # (đọc trước để tham số dòng lệnh ghi đè giá trị trong file)
  for (( i = 0; i < ${#args[@]}; i++ )); do
    if [[ "${args[$i]}" == "--output=json" || ( "${args[$i]}" == "--output" && "${args[$((i + 1))]:-}" == "json" ) ]]; then
      OUTPUT_JSON=1
    fi
  done
  for (( i = 0; i < ${#args[@]}; i++ )); do
    case "${args[$i]}" in
      --config=*) load_config "${args[$i]#--config=}" ;;
      --config)   load_config "${args[$((i + 1))]:-}" ;;
    esac
  done
  while (( $# > 0 )); do
    a="$1"; shift
    case "$a" in
      -h|--help) usage; exit 0 ;;
      -y) k="yes" ;;
      --*=*) k="${a%%=*}"; k="${k#--}"; v="${a#*=}"
             [[ "$VALUE_OPTS" == *" $k "* ]] || die_code "$EXIT_USAGE" "Tham số không hợp lệ: ${a%%=*} (xem --help)."
             [[ "$k" == "config" ]] || set_opt "$k" "$v"
             continue ;;
      --*) k="${a#--}" ;;
      *) die_code "$EXIT_USAGE" "Tham số không hợp lệ: ${a} (xem --help)." ;;
    esac
    if [[ "$FLAG_OPTS" == *" $k "* ]]; then
      set_opt "$k" 1
    elif [[ "$VALUE_OPTS" == *" $k "* ]]; then
      (( $# > 0 )) || die_code "$EXIT_USAGE" "--${k} cần giá trị."
      v="$1"; shift
      [[ "$k" == "config" ]] || set_opt "$k" "$v"
    else
      die_code "$EXIT_USAGE" "Tham số không hợp lệ: --${k} (xem --help)."
    fi
  done

  if [[ -n "${OPT[yes]:-}" ]]; then NONINTERACTIVE=1; fi
  if [[ -n "${OPT[admin-pass-stdin]:-}" ]]; then
    [[ ! -t 0 ]] || die_code "$EXIT_USAGE" "--admin-pass-stdin cần password được pipe vào stdin."
    IFS= read -r ADMIN_PASS_STDIN || true
    [[ -n "$ADMIN_PASS_STDIN" ]] || die_code "$EXIT_USAGE" "--admin-pass-stdin: stdin rỗng."
  fi
  # --yes: tắt hiệu ứng từng dòng, trừ khi người dùng tự đặt UI_DELAY
  if (( NONINTERACTIVE )) && [[ -z "$UI_DELAY_SET" ]]; then UI_DELAY=0; fi
  if (( NONINTERACTIVE )) && [[ -z "${OPT[scope-idx]:-}" ]]; then
    die_code "$EXIT_USAGE" "--yes cần --action (và --scope db|tunnel|both với create)."
  fi
  return 0
}

json_str() {
  # In chuỗi JSON đã escape (kèm dấu ")
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

json_array() {
  local out="[" first=1 x
  for x in "$@"; do (( first )) || out+=","; first=0; out+="$(json_str "$x")"; done
  printf '%s]' "$out"
}

emit_json() {
  # emit_json key value … → 1 object JSON ra stdout (chỉ khi --output json).
  # Giá trị bắt đầu bằng "[" hoặc là số / true / false / null được in nguyên; còn lại in như chuỗi.
  (( OUTPUT_JSON )) || return 0
  local first=1 k v
  printf '{'
  while (( $# >= 2 )); do
    k="$1"; v="$2"; shift 2
    (( first )) || printf ','
    first=0
    printf '%s:' "$(json_str "$k")"
    if [[ "$v" == \[* || "$v" =~ ^-?[0-9]+$ || "$v" == "true" || "$v" == "false" || "$v" == "null" ]]; then printf '%s' "$v"
    else json_str "$v"; fi
  done
  printf '}\n'
}

parse_args "$@"

require_root
require_tty
mkdir -p "$OUT_BASE"
chmod 700 "$OUT_BASE"
mkdir -p "$OUT_DIR" "$EVIDENCE_DIR"
chmod 700 "$OUT_DIR"
ln -sfn "$TS" "${OUT_BASE%/}/latest"   # trỏ tới lần chạy mới nhất
log "===== ${SCRIPT_NAME} v${SCRIPT_VERSION} ====="

banner
blank
info "Kiểm tra môi trường"
ok "Thời gian: $(date '+%Y-%m-%d %H:%M:%S (UTC%:z)')"
detect_os
check_disk_space
ok "Output: ${OUT_DIR}"

blank
choose SCOPE_IDX "Phạm vi:" \
  "DB user + SSH tunnel" \
  "Chỉ DB user" \
  "Chỉ SSH tunnel" \
  "SSH User (Shell)" \
  "Xoá SSH tunnel / SSH user" \
  "Xoá DB user"
case "$SCOPE_IDX" in
  1) DO_DB_USER="yes"; DO_TUNNEL="yes"; STEP_TOTAL=7 ;;
  2) DO_DB_USER="yes"; DO_TUNNEL="no";  STEP_TOTAL=5 ;;
  3) DO_DB_USER="no";  DO_TUNNEL="yes"; STEP_TOTAL=4 ;;
  4) STEP_TOTAL=3; KEY_OUT=""; create_ssh_user ;;
  5) DROPPED=(); STEP_TOTAL=3; MYSQL_HOST_PART="%"; drop_tunnel;  finish_drop ;;
  6) DROPPED=(); STEP_TOTAL=5; MYSQL_HOST_PART="%"; drop_db_user; finish_drop ;;
esac
log "Scope: DO_DB_USER=${DO_DB_USER} DO_TUNNEL=${DO_TUNNEL}"

# Giá trị mặc định cho tổng kết
DB_LIST=(); DB_ALL="no"; declare -A PG_SCHEMAS_BY_DB=(); ADMIN_READY=0; ADMIN_USER=""
ACCESS_MODE="—"; DB_NAME="—"; NEW_DB_USER="—"; NEW_DB_PASS=""; SQL_FILE="—"; RUN_MODE="skipped"
MYSQL_HOST_PART="%"; PG_OWNER=""; PG_GRANT_OWNER="yes"; PG_SCHEMAS=(public); CONN_LIMIT=20
TUNNEL_OS_USER=""; KEY_OUT=""; KEY_PUB=""; PUBLIC_IP=""; IP_SOURCE=""; TUNNEL_TARGET=""
VERIFY_STATUS="—"; LOGIN_STATUS="—"

# ============================== DB user ===================================

if [[ "$DO_DB_USER" == "yes" ]]; then

  step "Thông tin Database"
  collect_conn_info

  blank
  choose ACCESS_IDX "Quyền:" \
    "readonly — SELECT" \
    "dml      — SELECT / INSERT / UPDATE / DELETE" \
    "ddl      — dml + CREATE / ALTER / DROP (migration)"
  case "$ACCESS_IDX" in 1) ACCESS_MODE="readonly" ;; 2) ACCESS_MODE="dml" ;; 3) ACCESS_MODE="ddl" ;; esac
  if [[ "$ACCESS_MODE" == "ddl" ]]; then
    warn "ddl xoá được bảng / dữ liệu hàng loạt. Chỉ nên dùng cho pipeline migration, không cấp cho người."
  fi

  blank
  if (( NONINTERACTIVE )) || [[ -n "${OPT[database]+x}" ]]; then
    # Có --database (hoặc chạy --yes): không liệt kê. --yes bắt buộc ghi rõ --database (kể cả all),
    # tránh lặng lẽ cấp quyền trên mọi DB.
    ask DB_NAME "Database" "" '^([Aa][Ll][Ll]|[A-Za-z0-9_$-]{1,64}([[:space:]]*,[[:space:]]*[A-Za-z0-9_$-]{1,64})*)$' \
      "Tên database chỉ gồm chữ, số, _ - \$ (tối đa 64 ký tự), cách nhau dấu phẩy; hoặc all."
    set_db_list "$DB_NAME"
  else
    pick_databases
  fi
  # 1 database → gợi ý <mode>_<db>; nhiều database / all → bắt nhập tên (không có tên mặc định hợp lý)
  local_user_default=""; (( ${#DB_LIST[@]} == 1 )) && local_user_default="${ACCESS_MODE}_${DB_LIST[0]}"
  while true; do
    ask NEW_DB_USER "DB user mới" "$local_user_default" '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$' \
      "Chỉ dùng chữ, số, _ . - (tối đa 32 ký tự)."
    # Tên có tiền tố "<mức quyền>_" khác ACCESS_MODE đang chọn → dễ cấp nhầm cho user khác
    name_prefix="${NEW_DB_USER%%_*}"
    if [[ "$NEW_DB_USER" == *_* && "$name_prefix" =~ ^(readonly|dml|ddl)$ && "$name_prefix" != "$ACCESS_MODE" ]]; then
      warn "Tên '${NEW_DB_USER}' gợi ý quyền '${name_prefix}', nhưng bạn đang chọn quyền '${ACCESS_MODE}'."
      confirm "Vẫn dùng tên này?" n y || continue
    fi
    break
  done
  ask CONN_LIMIT "Max connections" "20" '^[0-9]{1,4}$' "Phải là số."

  if [[ "$DB_ENGINE" == "postgres" ]]; then
    ask SCHEMAS_RAW "Schema (cách nhau dấu phẩy)" "public" \
      '^[A-Za-z0-9_]+(,[[:space:]]*[A-Za-z0-9_]+)*$' "Danh sách schema không hợp lệ."
    IFS=',' read -r -a PG_SCHEMAS <<<"${SCHEMAS_RAW// /}"
    # Không hỏi role owner (cố định bỏ qua): ALTER DEFAULT PRIVILEGES áp cho bảng do admin chạy script tạo sau này.
    PG_OWNER=""
  else
    if [[ "$ACCESS_MODE" == "ddl" ]]; then
      warn "MySQL: quyền DROP trên \`<db>\`.* cho phép cả DROP DATABASE <db> (${DB_NAME})."
    fi
    note "Host part: % = mọi nơi · giới hạn IP/subnet: 10.0.%"
    ask MYSQL_HOST_PART "Host part" "%" '^[A-Za-z0-9.%_:-]+$' "Host part không hợp lệ."
  fi

  blank
  ask_secret NEW_DB_PASS "Password (Enter = tự sinh)"
  if [[ -z "$NEW_DB_PASS" ]]; then
    NEW_DB_PASS="$(gen_password)"
    ok "Password: tự sinh ${PASS_LEN} ký tự → $(basename "$CRED_FILE")"
  fi

  # ---------------------------------------------------------------------
  step "Chuẩn bị CLI client"
  case "$DB_ENGINE" in
    # AL2023 không có gói mysql-client trong repo mặc định; client của MariaDB 10.5 dùng được với MySQL 8.
    mysql)    require_cmd_or_install mysql "mysql-client" "mariadb105" ;;
    mariadb)  require_cmd_or_install mysql "mariadb-client" "mariadb105" ;;
    postgres) require_cmd_or_install psql "postgresql-client" "postgresql15" ;;
  esac

  # ---------------------------------------------------------------------
  step "Sinh SQL"
  SQL_FILE="${OUT_DIR}/create_user_${NEW_DB_USER}.sql"
  if [[ "$DB_ALL" == "yes" ]]; then
    info "Database = all → SQL sẽ sinh sau khi kết nối admin và lấy được danh sách database."
  else
    gen_sql create
    ok "SQL: ${SQL_FILE}"
  fi

  # ---------------------------------------------------------------------
  step "Thực thi SQL"
  if [[ "$DB_ALL" == "yes" ]]; then
    [[ -z "${OPT[sql-only]:-}" ]] || die_code "$EXIT_USAGE" "Database = all cần kết nối admin để lấy danh sách → không dùng được với --sql-only."
    info "Database = all → bắt buộc tự chạy (cần admin để lấy danh sách database)."
  fi
  if [[ "$DB_ALL" != "yes" ]] && ! confirm "Tự chạy SQL? (cần admin DB)" "$( (( ADMIN_READY )) && echo y || echo n )" "$([[ -n "${OPT[sql-only]:-}" ]] && echo n || echo y)"; then
    RUN_MODE="manual"
    info "Chạy tay file SQL dưới đây:"
    show_sql_masked
    if [[ "$DB_ENGINE" == "postgres" ]]; then
      note "psql:    psql -h ${DB_HOST} -p ${DB_PORT} -U <admin> -d postgres -f ${SQL_FILE}"
      note "DBeaver: chạy Phần 1 ở DB 'postgres', mỗi khối Phần 2 ở đúng DB của nó (bỏ dòng \\connect)"
    else
      note "mysql:   mysql -h ${DB_HOST} -P ${DB_PORT} -u <admin> -p < ${SQL_FILE}"
    fi
  else
    RUN_MODE="auto"
    if (( ADMIN_READY )); then
      info "Dùng admin '${ADMIN_USER}' đã nhập ở bước 1"
    else
      info "Cần admin DB để chạy SQL → nhập thông tin admin:"
      ask ADMIN_USER "Admin DB user"
      ask_admin_secret ADMIN_PASS "Admin DB password"
    fi

    # --- 1. Test kết nối + kiểm tra hiện trạng (read-only) ---
    info "Kiểm tra admin & hiện trạng…"
    USER_EXISTS="no"
    case "$DB_ENGINE" in
      mysql|mariadb)
        make_mycnf ADMIN_CNF "$ADMIN_USER" "$ADMIN_PASS"
        CONN_OUT="$(run_mysql "$ADMIN_CNF" -N -B -e "SELECT 1;" 2>&1)" \
          || admin_conn_fail "$CONN_OUT"
        (( ADMIN_READY )) || ok "Kết nối admin OK"   # đã báo ở bước 1

        # Kiểm tra quyền admin TRƯỚC khi làm gì: cần CREATE USER (hoặc ALL ON *.*) và GRANT OPTION.
        ADMIN_GRANTS="$(run_mysql "$ADMIN_CNF" -N -B -e "SHOW GRANTS FOR CURRENT_USER();" 2>>"$LOG_FILE" || true)"
        printf '%s\n' "$ADMIN_GRANTS" >"${EVIDENCE_DIR}/admin_grants_${ADMIN_USER}.txt"
        if grep -Eq 'GRANT ALL PRIVILEGES ON \*\.\*|CREATE USER' <<<"$ADMIN_GRANTS"; then
          ok "Admin có CREATE USER"
        else
          warn "Admin '${ADMIN_USER}' KHÔNG có quyền CREATE USER (theo SHOW GRANTS):"
          codeblock "${ADMIN_GRANTS:-<không đọc được grants>}"
          note "Docker: user từ MYSQL_USER chỉ có quyền trên 1 DB."
          note "Dùng root (MYSQL_ROOT_PASSWORD trong docker-compose / .env)."
          note "(Quyền cấp qua ROLE của MySQL 8 có thể không hiện ở đây → chọn tiếp tục.)"
          confirm "Vẫn dùng '${ADMIN_USER}'?" n "fail:${EXIT_ADMIN_PRIV}:Admin '${ADMIN_USER}' thiếu quyền CREATE USER." || die "Dừng lại. Chưa có gì bị thay đổi."
        fi

        EXISTING_DBS="$(run_mysql "$ADMIN_CNF" -N -B -e \
          "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
            WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys')
            ORDER BY 1;" 2>>"$LOG_FILE")" || die "Không đọc được danh sách database bằng admin '${ADMIN_USER}'."
        resolve_db_list "$EXISTING_DBS"
        # Admin không phải root thường KHÔNG có SELECT trên mysql.user → không coi là lỗi,
        # chỉ bỏ qua bước kiểm tra; lúc chạy CREATE USER sẽ bắt lỗi 1396 (user đã tồn tại).
        if USER_COUNT="$(run_mysql "$ADMIN_CNF" -N -B -e \
             "SELECT COUNT(*) FROM mysql.user WHERE User='$(mysql_str "$NEW_DB_USER")' AND Host='$(mysql_str "$MYSQL_HOST_PART")';" 2>>"$LOG_FILE")"; then
          [[ "$USER_COUNT" != "0" ]] && USER_EXISTS="yes"
        else
          USER_EXISTS="unknown"
          warn "Admin '${ADMIN_USER}' không đọc được mysql.user → không kiểm tra trước được user đã tồn tại hay chưa."
          note "User đã có → CREATE USER lỗi 1396 → script hỏi chuyển ALTER."
        fi
        ;;
      postgres)
        CONN_OUT="$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc "SELECT 1;" 2>&1)" \
          || admin_conn_fail "$CONN_OUT"
        (( ADMIN_READY )) || ok "Kết nối admin OK"   # đã báo ở bước 1
        EXISTING_DBS="$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc \
          "SELECT datname FROM pg_database
            WHERE datallowconn AND NOT datistemplate AND datname NOT IN ('postgres','rdsadmin')
            ORDER BY 1;" 2>>"$LOG_FILE")" || die "Không đọc được danh sách database bằng admin '${ADMIN_USER}'."
        resolve_db_list "$EXISTING_DBS"
        # Schema đã nhập có thể không có ở mọi DB → chỉ cấp trên schema thực có, báo phần bỏ qua
        local_schema_csv="$(printf "'%s'," "${PG_SCHEMAS[@]}")"; local_schema_csv="${local_schema_csv%,}"   # tên schema đã validate [A-Za-z0-9_]
        for d in "${DB_LIST[@]}"; do
          found="$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d "$d" -tAc \
            "SELECT string_agg(nspname, ' ' ORDER BY nspname) FROM pg_namespace WHERE nspname IN (${local_schema_csv});" 2>>"$LOG_FILE" || true)"
          PG_SCHEMAS_BY_DB[$d]="$found"
          schema_missing=""
          for sc in "${PG_SCHEMAS[@]}"; do [[ " $found " == *" $sc "* ]] || schema_missing+="${sc} "; done
          if [[ -n "$schema_missing" ]]; then
            if [[ -z "$found" ]]; then warn "DB '${d}': không có schema ${schema_missing% } → chỉ cấp CONNECT."
            else warn "DB '${d}': bỏ qua schema không tồn tại: ${schema_missing% }"; fi
          fi
        done
        ROLE_FOUND="$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc \
          "SELECT 1 FROM pg_roles WHERE rolname='$(pg_str "$NEW_DB_USER")';" 2>>"$LOG_FILE")"
        [[ "$ROLE_FOUND" == "1" ]] && USER_EXISTS="yes"

        # ddl + owner là superuser: làm thành viên role đó = có thể SET ROLE thành superuser → chặn mặc định
        if [[ "$ACCESS_MODE" == "ddl" && -n "$PG_OWNER" ]]; then
          OWNER_SUPER="$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc \
            "SELECT rolsuper FROM pg_roles WHERE rolname='$(pg_str "$PG_OWNER")';" 2>>"$LOG_FILE" || true)"
          if [[ -z "$OWNER_SUPER" ]]; then
            warn "Role owner '${PG_OWNER}' không tồn tại → bỏ phần làm thành viên role owner."
            PG_GRANT_OWNER="no"
          elif [[ "$OWNER_SUPER" == "t" ]]; then
            warn "Role owner '${PG_OWNER}' là SUPERUSER."
            note "Cho '${NEW_DB_USER}' làm thành viên role này = '${NEW_DB_USER}' có thể SET ROLE ${PG_OWNER}"
            note "và trở thành superuser. Nên chuyển bảng sang 1 owner thường (ALTER TABLE … OWNER TO …)."
            if ! confirm "Vẫn cho '${NEW_DB_USER}' làm thành viên '${PG_OWNER}'?" n n; then
              PG_GRANT_OWNER="no"
              info "Bỏ GRANT ${PG_OWNER} → chỉ sửa được bảng tự tạo."
            fi
          fi
          if [[ "$PG_GRANT_OWNER" == "no" ]]; then
            gen_sql create
          fi
        fi
        PG_VER="$(run_psql "$ADMIN_USER" "$ADMIN_PASS" -d postgres -tAc "SHOW server_version_num;" 2>>"$LOG_FILE" || echo 0)"
        if [[ "$ACCESS_MODE" != "ddl" ]] && (( PG_VER > 0 && PG_VER < 150000 )); then
          warn "PostgreSQL < 15: mặc định PUBLIC có quyền CREATE trên schema public,"
          note "nghĩa là user 'readonly' vẫn tạo được bảng. Cân nhắc (ảnh hưởng mọi role, cần review):"
          note "REVOKE CREATE ON SCHEMA public FROM PUBLIC;"
        fi
        ;;
    esac

    # Danh sách DB (và schema theo DB) đã chốt → sinh lại SQL theo đúng danh sách đó
    gen_sql create
    [[ "$DB_ALL" == "yes" ]] && ok "SQL: ${SQL_FILE}"   # lần đầu sinh SQL với all; còn lại: sinh lại lặng lẽ

    if [[ "$USER_EXISTS" == "yes" ]]; then
      warn "User '${NEW_DB_USER}' đã tồn tại."
      note "Tiếp tục sẽ ĐỔI PASSWORD: app / người đang dùng password cũ sẽ mất kết nối."
      note "Quyền '${ACCESS_MODE}' sẽ được CỘNG THÊM vào quyền hiện có (không thu hồi quyền cũ)."
      if confirm "Đổi password + cấp thêm quyền?" n "$( [[ -n "${OPT[allow-alter]:-}" ]] && echo y || echo "fail:${EXIT_USER_EXISTS}:User '${NEW_DB_USER}' đã tồn tại — thêm --allow-alter để đổi password + cấp thêm quyền." )"; then
        gen_sql alter
        info "SQL dùng ALTER thay CREATE"
      else
        die "Huỷ theo yêu cầu. Chưa có gì bị thay đổi."
      fi
    fi

    # --- 2. Thực thi ---
    blank
    kv "Host" "${DB_HOST}:${DB_PORT}"
    kv "Database" "$DB_NAME"
    kv "User" "$NEW_DB_USER  (${ACCESS_MODE})"
    kv "SQL" "$SQL_FILE"
    confirm "${BOLD}XÁC NHẬN CUỐI${RESET}: chạy SQL?" n y || { RUN_MODE="manual"; die "Huỷ theo yêu cầu. File SQL vẫn còn: ${SQL_FILE}"; }

    SQL_ERR="$(mktemp "${OUT_DIR}/.sqlerr.XXXXXX")"; TMP_FILES+=("$SQL_ERR")
    if ! run_sql_file; then
      FAILED_LINE="$(sql_failed_line)"
      record_sql_executed "$FAILED_LINE"
      LAST_ERR="$(grep -m1 'ERROR' "$SQL_ERR" || tail -n 1 "$SQL_ERR")"
      if [[ "$LAST_ERR" == "psql:${SQL_FILE}:"* ]]; then   # bỏ đường dẫn dài trong lỗi của psql
        LAST_ERR="dòng ${LAST_ERR#psql:"$SQL_FILE":}"
      fi

      # ERROR 1396 ở CREATE USER (câu đầu tiên) = user đã tồn tại, chưa có gì thay đổi → chuyển sang ALTER.
      if [[ "$DB_ENGINE" != "postgres" && "$LAST_ERR" == *"ERROR 1396"* && "$FAILED_LINE" == "$(first_stmt_line)" ]]; then
        warn "User '${NEW_DB_USER}'@'${MYSQL_HOST_PART}' đã tồn tại (ERROR 1396)."
        note "Tiếp tục sẽ ĐỔI PASSWORD: app / người đang dùng password cũ sẽ mất kết nối."
        note "Quyền '${ACCESS_MODE}' sẽ được CỘNG THÊM vào quyền hiện có (không thu hồi quyền cũ)."
        confirm "Đổi password + cấp thêm quyền?" n "$( [[ -n "${OPT[allow-alter]:-}" ]] && echo y || echo "fail:${EXIT_USER_EXISTS}:User '${NEW_DB_USER}' đã tồn tại — thêm --allow-alter để đổi password + cấp thêm quyền." )" \
          || die "Huỷ theo yêu cầu."
        gen_sql alter
        info "SQL dùng ALTER thay CREATE"
        if ! run_sql_file; then
          record_sql_executed "$(sql_failed_line)"
          die "Chạy SQL (ALTER) thất bại: $(grep -m1 'ERROR' "$SQL_ERR" || tail -n 1 "$SQL_ERR")"
        fi
        record_sql_executed 0
      else
        err "Chạy SQL thất bại: ${LAST_ERR}"
        if [[ "$LAST_ERR" == *"ERROR 1227"* || "$LAST_ERR" == *"permission denied"* || "$LAST_ERR" == *"must have"* ]]; then
          if [[ "$DB_ENGINE" == "postgres" ]]; then
            note "Admin thiếu quyền → dùng superuser / RDS master (Docker: POSTGRES_USER)."
          else
            note "Admin thiếu quyền → dùng root / RDS master (Docker: MYSQL_ROOT_PASSWORD)."
          fi
        fi
        exit 1
      fi
    else
      record_sql_executed 0
    fi
    ok "User '${NEW_DB_USER}': xong"

    # --- 3. Verify + lưu evidence ---
    blank
    info "Quyền đã cấp:"
    GRANTS_FILE="${EVIDENCE_DIR}/grants_${NEW_DB_USER}.txt"
    case "$DB_ENGINE" in
      mysql|mariadb)
        run_mysql "$ADMIN_CNF" -e "SHOW GRANTS FOR '$(mysql_str "$NEW_DB_USER")'@'$(mysql_str "$MYSQL_HOST_PART")';" \
          >"$GRANTS_FILE" 2>>"$LOG_FILE" && VERIFY_STATUS="ok" || VERIFY_STATUS="fail"
        ;;
      postgres)
        VERIFY_STATUS="ok"; : >"$GRANTS_FILE"
        for d in "${DB_LIST[@]}"; do
          (( ${#DB_LIST[@]} > 1 )) && printf '== %s\n' "$d" >>"$GRANTS_FILE"
          run_psql "$ADMIN_USER" "$ADMIN_PASS" -d "$d" -c \
            "SELECT table_schema, privilege_type, count(*) AS tables
               FROM information_schema.role_table_grants
              WHERE grantee = '$(pg_str "$NEW_DB_USER")'
              GROUP BY 1, 2 ORDER BY 1, 2;" >>"$GRANTS_FILE" 2>>"$LOG_FILE" || VERIFY_STATUS="fail"
        done
        ;;
    esac
    if [[ "$VERIFY_STATUS" == "ok" ]]; then codeblock "$(<"$GRANTS_FILE")"; else warn "Không lấy được danh sách quyền."; fi

    info "Test login user mới"
    LOGIN_FILE="${EVIDENCE_DIR}/login_test_${NEW_DB_USER}.txt"
    case "$DB_ENGINE" in
      mysql|mariadb)
        make_mycnf NEW_CNF "$NEW_DB_USER" "$NEW_DB_PASS"
        if run_mysql "$NEW_CNF" -e "SELECT CURRENT_USER() AS current_user_, NOW() AS at_;" >"$LOGIN_FILE" 2>&1; then
          LOGIN_STATUS="ok"; ok "Login OK"
        else
          LOGIN_STATUS="fail"; warn "Đăng nhập thất bại (kiểm tra host part '${MYSQL_HOST_PART}'). Chi tiết: ${LOGIN_FILE}"
        fi
        ;;
      postgres)
        # Mỗi DB cần quyền CONNECT riêng → login + test CREATE TABLE trên từng DB
        if [[ "$ACCESS_MODE" == "ddl" ]]; then PROBE_Q="tạo được"; else PROBE_Q="bị chặn"; fi
        DO_PROBE="no"
        confirm "Test CREATE TABLE trên ${#DB_LIST[@]} DB? (rollback · mong đợi: ${PROBE_Q})" y y && DO_PROBE="yes"
        LOGIN_STATUS="ok"; : >"$LOGIN_FILE"
        for d in "${DB_LIST[@]}"; do
          printf '== %s\n' "$d" >>"$LOGIN_FILE"
          if ! run_psql "$NEW_DB_USER" "$NEW_DB_PASS" -d "$d" -c "SELECT current_user, current_database(), now();" >>"$LOGIN_FILE" 2>&1; then
            LOGIN_STATUS="fail"; warn "[${d}] Đăng nhập thất bại (kiểm tra pg_hba / Security Group). Chi tiết: ${LOGIN_FILE}"
            continue
          fi
          # DDL trong Postgres có transaction => thử CREATE TABLE rồi ROLLBACK, không để lại gì.
          if [[ -n "${PG_SCHEMAS_BY_DB[$d]+x}" ]]; then read -r -a probe_schemas <<<"${PG_SCHEMAS_BY_DB[$d]}"
          else probe_schemas=("${PG_SCHEMAS[@]}"); fi
          if [[ "$DO_PROBE" != "yes" || ${#probe_schemas[@]} -eq 0 ]]; then ok "[${d}] Login OK"; continue; fi
          PROBE="$(pg_ident "${probe_schemas[0]}").$(pg_ident "__perm_probe_${TS}")"
          if run_psql "$NEW_DB_USER" "$NEW_DB_PASS" -d "$d" -v ON_ERROR_STOP=1 \
               -c "BEGIN;" -c "CREATE TABLE ${PROBE} (x int);" -c "ROLLBACK;" >>"$LOGIN_FILE" 2>&1; then
            if [[ "$ACCESS_MODE" == "ddl" ]]; then
              ok "[${d}] Login OK · CREATE TABLE được (đã rollback) ✓"
            else
              LOGIN_STATUS="ok (⚠ tạo được bảng)"
              warn "[${d}] User TẠO ĐƯỢC bảng (đã rollback). Xem lại quyền CREATE trên schema ${probe_schemas[0]}."
            fi
          else
            if [[ "$ACCESS_MODE" == "ddl" ]]; then
              LOGIN_STATUS="ok (⚠ không tạo được bảng)"
              warn "[${d}] User ddl KHÔNG tạo được bảng trong schema ${probe_schemas[0]}. Chi tiết: ${LOGIN_FILE}"
            else
              ok "[${d}] Login OK · CREATE TABLE bị chặn ✓"
            fi
          fi
        done
        ;;
    esac
  fi

else
  step "Thông tin kết nối DB (để xác định tunnel target)"
  collect_conn_info
fi

# ============================== SSH tunnel ================================

if [[ "$DO_TUNNEL" == "yes" ]]; then

  step "Thông tin SSH tunnel account"
  # Gợi ý tên: <database>${TUNNEL_SUFFIX}, chuẩn hoá theo luật đặt tên user Linux, tổng ≤ OS_USER_MAX
  TUNNEL_USER_DEFAULT=""
  if (( ${#DB_LIST[@]} > 0 )); then
    base="${DB_LIST[0],,}"                                  # chữ thường
    base="$(printf '%s' "$base" | sed -E 's/[^a-z0-9_-]+/-/g; s/-+/-/g; s/^[^a-z]+//; s/[-_]+$//')"
    base="${base:0:$(( OS_USER_MAX - ${#TUNNEL_SUFFIX} ))}"; base="${base%-}"
    [[ -n "$base" ]] && TUNNEL_USER_DEFAULT="${base}${TUNNEL_SUFFIX}"
  fi
  note "Quy ước: <project>-<env>${TUNNEL_SUFFIX} (vd: renkin-prod${TUNNEL_SUFFIX})"
  ask TUNNEL_OS_USER "User OS tunnel" "$TUNNEL_USER_DEFAULT" "^[a-z_][a-z0-9_-]{0,$(( OS_USER_MAX - 1 ))}\$" \
    "Chỉ dùng a-z, 0-9, _ , - ; bắt đầu bằng chữ; tối đa 32 ký tự."
  if id "$TUNNEL_OS_USER" &>/dev/null; then
    info "User '${TUNNEL_OS_USER}' đã có → giữ user, chỉ cập nhật key."
  fi
  ask KEY_NAME "Tên key" "${TUNNEL_OS_USER}-key" '^[A-Za-z0-9._-]+$' "Chỉ dùng chữ, số, . _ -"
  choose KEY_IDX "Loại key:" "ed25519 (khuyến nghị)" "rsa 4096 PEM (DBeaver / tool cũ)"
  if [[ "$KEY_IDX" == "1" ]]; then KEY_TYPE="ed25519"; else KEY_TYPE="rsa"; fi
  ask KEY_COMMENT "Key comment" "readonly-${TUNNEL_OS_USER}" '^[A-Za-z0-9._@ -]+$' "Chỉ dùng chữ, số, . _ @ - và dấu cách."

  DEFAULT_TARGET="127.0.0.1:${DB_PORT}"
  [[ "$IS_RDS" == "yes" ]] && DEFAULT_TARGET="${DB_HOST}:${DB_PORT}"
  note "Tunnel chỉ forward tới đích này (permitopen)."
  ask TUNNEL_TARGET "Đích host:port" "$DEFAULT_TARGET" '^[A-Za-z0-9._-]+:[0-9]{1,5}$' "Định dạng host:port."
  TGT_HOST="${TUNNEL_TARGET%:*}"; TGT_PORT="${TUNNEL_TARGET##*:}"

  if tcp_reachable "$TGT_HOST" "$TGT_PORT"; then
    ok "Tới được ${TUNNEL_TARGET}"
  else
    warn "Không tới được ${TUNNEL_TARGET} (SG / DB chưa listen?) → tunnel chưa dùng được."
  fi

  # ---- Khảo sát hiện trạng (chỉ đọc) ----
  SSHD_CFG="/etc/ssh/sshd_config"
  SSHD_BIN="$(find_sshd_bin)"
  SSH_SVC_GUESS="$(find_ssh_service)"; SSH_SVC_GUESS="${SSH_SVC_GUESS:-sshd}"
  if [[ -z "$SSHD_BIN" ]]; then
    warn "Không thấy binary sshd (openssh-server chưa cài?)."
    confirm "Cài openssh-server?" n y || die "Cần sshd để kiểm tra config. Dừng theo yêu cầu."
    install_pkg openssh-server
    SSHD_BIN="$(find_sshd_bin)"
    [[ -n "$SSHD_BIN" ]] || die "Cài xong vẫn không thấy sshd."
  fi

  # Kiểm tra config HIỆN TẠI trước khi sửa: nếu đã lỗi sẵn thì không phải do script
  if ! sshd_check; then
    err "sshd_config hiện tại ĐÃ lỗi sẵn (trước khi script sửa gì):"
    codeblock "$SSHD_T_OUT"
    die "Sửa sshd_config trước rồi chạy lại. Chưa thay đổi gì về SSH."
  fi

  NOLOGIN="$(command -v nologin 2>/dev/null || true)"
  [[ -z "$NOLOGIN" && -x /usr/sbin/nologin ]] && NOLOGIN="/usr/sbin/nologin"
  [[ -z "$NOLOGIN" && -x /sbin/nologin ]] && NOLOGIN="/sbin/nologin"
  [[ -n "$NOLOGIN" ]] || die "Không tìm thấy nologin."

  if id "$TUNNEL_OS_USER" &>/dev/null; then
    USER_EXISTS_OS="yes"
    HOME_DIR="$(getent passwd "$TUNNEL_OS_USER" | cut -d: -f6)"
  else
    USER_EXISTS_OS="no"
    HOME_DIR="/home/${TUNNEL_OS_USER}"
  fi
  SSH_DIR="${HOME_DIR}/.ssh"
  AUTH_KEYS="${SSH_DIR}/authorized_keys"
  KEY_TAG="[db-tunnel:${KEY_NAME}]"

  AK_ENTRY_EXISTS="no"
  if [[ -f "$AUTH_KEYS" ]] && grep -qF "$KEY_TAG" "$AUTH_KEYS"; then AK_ENTRY_EXISTS="yes"; fi

  # AllowUsers / AllowGroups hiệu lực (gồm cả sshd_config.d/*)
  EFFECTIVE="$("$SSHD_BIN" -T 2>>"$LOG_FILE" || true)"
  ALLOW_USERS="$(awk '$1=="allowusers"{print $2}' <<<"$EFFECTIVE")"
  ALLOW_GROUPS="$(awk '$1=="allowgroups"{print $2}' <<<"$EFFECTIVE")"
  NEED_ALLOWUSERS="no"
  if [[ -n "$ALLOW_USERS" ]] && ! grep -qxF "$TUNNEL_OS_USER" <<<"$ALLOW_USERS"; then
    NEED_ALLOWUSERS="yes"
    grep -Eq '^[[:space:]]*AllowUsers[[:space:]]' "$SSHD_CFG" || NEED_ALLOWUSERS="manual"
  fi

  set_match_markers "$TUNNEL_OS_USER"
  MATCH_EXISTS="no"
  grep -qF "$MATCH_BEGIN" "$SSHD_CFG" 2>/dev/null && MATCH_EXISTS="yes"

  # ---------------------------------------------------------------------
  step "Áp dụng thay đổi SSH"
  info "Kế hoạch:"
  if [[ "$USER_EXISTS_OS" == "yes" ]]; then
    note "• User OS '${TUNNEL_OS_USER}' đã tồn tại → giữ nguyên"
  else
    note "• Tạo user OS '${TUNNEL_OS_USER}' (shell: ${NOLOGIN})"
  fi
  note "• Sinh key ${KEY_TYPE} vào thư mục output"
  if [[ "$AK_ENTRY_EXISTS" == "yes" ]]; then
    note "• authorized_keys: thay entry ${KEY_TAG} (key khác giữ nguyên)"
  else
    note "• authorized_keys: thêm entry restricted (key khác giữ nguyên)"
  fi
  case "$NEED_ALLOWUSERS" in
    yes)    note "• AllowUsers: thêm '${TUNNEL_OS_USER}'" ;;
    manual) note "• ⚠ AllowUsers được khai báo ngoài ${SSHD_CFG} (sshd_config.d?) → bạn cần tự thêm" ;;
  esac
  [[ -n "$ALLOW_GROUPS" ]] && note "• ⚠ sshd có AllowGroups (${ALLOW_GROUPS//$'\n'/ }) → user cần thuộc 1 group trong đó"
  if [[ "$MATCH_EXISTS" == "yes" ]]; then
    note "• sshd_config: thay Match block của '${TUNNEL_OS_USER}'"
  else
    note "• sshd_config: thêm Match block cho '${TUNNEL_OS_USER}'"
  fi
  note "• sshd -t (lỗi → rollback) → hỏi reload"
  blank
  confirm "Tiến hành?" n y || die "Huỷ theo yêu cầu. Chưa có gì bị thay đổi trên server."

  # ---- 1. User OS ----
  if [[ "$USER_EXISTS_OS" == "no" ]]; then
    useradd -m -s "$NOLOGIN" -c "$TUNNEL_GECOS" "$TUNNEL_OS_USER"
    ok "Đã tạo user OS '${TUNNEL_OS_USER}'"
    record "Tạo user OS '${TUNNEL_OS_USER}' (home: ${HOME_DIR})" "userdel -r ${TUNNEL_OS_USER}"
  fi
  USER_GROUP="$(id -gn "$TUNNEL_OS_USER")"

  # ---- 2. Key ----
  # ed25519 → <tên>      (định dạng OpenSSH, không gắn .pem cho đúng định dạng)
  # rsa PEM → <tên>.pem  (định dạng PEM thật)        · public key luôn là <tên>.pub
  KEY_PUB="${OUT_DIR}/${KEY_NAME}.pub"
  FULL_COMMENT="${KEY_COMMENT} ${KEY_TAG}"
  if [[ "$KEY_TYPE" == "ed25519" ]]; then
    KEY_OUT="${OUT_DIR}/${KEY_NAME}"
    ssh-keygen -q -t ed25519 -f "$KEY_OUT" -C "$FULL_COMMENT" -N ""
  else
    KEY_OUT="${OUT_DIR}/${KEY_NAME}.pem"
    ssh-keygen -q -t rsa -b 4096 -m PEM -f "${OUT_DIR}/${KEY_NAME}" -C "$FULL_COMMENT" -N ""
    mv -f "${OUT_DIR}/${KEY_NAME}" "$KEY_OUT"
    note "RSA dùng chữ ký rsa-sha2-*; client quá cũ có thể báo 'ssh-rsa not in PubkeyAcceptedAlgorithms'."
  fi
  chmod 600 "$KEY_OUT"
  ok "Key: $(basename "$KEY_OUT") · $(ssh-keygen -lf "$KEY_PUB" | awk '{print $2}')"

  # ---- 3. authorized_keys (chỉ thay entry của chính key này) ----
  install -d -m 700 -o "$TUNNEL_OS_USER" -g "$USER_GROUP" "$SSH_DIR"
  backup_file "$AUTH_KEYS" AK_BAK
  RESTRICT_OPTS="restrict,port-forwarding,permitopen=\"${TUNNEL_TARGET}\",command=\"echo 'Tunnel only - no shell access'\""
  AK_TMP="$(mktemp "${SSH_DIR}/.authorized_keys.XXXXXX")"
  TMP_FILES+=("$AK_TMP")
  if [[ -f "$AUTH_KEYS" ]]; then grep -vF "$KEY_TAG" "$AUTH_KEYS" >"$AK_TMP" || true; fi
  printf '%s %s\n' "$RESTRICT_OPTS" "$(<"$KEY_PUB")" >>"$AK_TMP"
  chmod 600 "$AK_TMP"
  chown "${TUNNEL_OS_USER}:${USER_GROUP}" "$AK_TMP"
  mv -f "$AK_TMP" "$AUTH_KEYS"
  if [[ -n "$AK_BAK" ]]; then
    record "Sửa ${AUTH_KEYS} (thêm/thay entry ${KEY_TAG})" "cp -p ${AK_BAK} ${AUTH_KEYS}"
  else
    record "Tạo ${AUTH_KEYS} với entry ${KEY_TAG}" "rm -f ${AUTH_KEYS}"
  fi
  ok "authorized_keys: restrict + permitopen=${TUNNEL_TARGET}"

  # ---- 4. sshd_config (backup 1 lần duy nhất trước mọi thay đổi) ----
  backup_file "$SSHD_CFG" SSHD_BAK
  [[ -n "$SSHD_BAK" ]] || die "Không tìm thấy ${SSHD_CFG}."

  if [[ "$NEED_ALLOWUSERS" == "yes" ]]; then
    sed -i -E "0,/^([[:space:]]*AllowUsers)([[:space:]])/s//\1 ${TUNNEL_OS_USER}\2/" "$SSHD_CFG"
    ok "AllowUsers += ${TUNNEL_OS_USER}"
    record "Thêm '${TUNNEL_OS_USER}' vào AllowUsers trong ${SSHD_CFG}" "cp -p ${SSHD_BAK} ${SSHD_CFG} && systemctl reload ${SSH_SVC_GUESS}"
  elif [[ "$NEED_ALLOWUSERS" == "manual" ]]; then
    warn "Nhớ tự thêm '${TUNNEL_OS_USER}' vào AllowUsers (đang khai báo ngoài ${SSHD_CFG})."
  fi

  if [[ "$MATCH_EXISTS" == "yes" ]]; then
    CFG_TMP="$(mktemp)"; TMP_FILES+=("$CFG_TMP")
    awk -v b="$MATCH_BEGIN" -v e="$MATCH_END" '
      $0==b {skip=1; next}
      skip && $0==e {skip=0; next}
      !skip {print}
    ' "$SSHD_CFG" >"$CFG_TMP"
    cat "$CFG_TMP" >"$SSHD_CFG"   # giữ nguyên owner/permission/inode của file gốc
  fi
  # Chỉ chèn dòng trống nếu file chưa kết thúc bằng dòng trống (tránh phình file sau nhiều lần chạy)
  [[ -n "$(tail -n 1 "$SSHD_CFG")" ]] && printf '\n' >>"$SSHD_CFG"
  {
    printf '%s\n' "$MATCH_BEGIN"
    printf 'Match User %s\n' "$TUNNEL_OS_USER"
    printf '    AuthenticationMethods publickey\n'
    printf '    AllowTcpForwarding local\n'
    printf '    PermitOpen %s\n' "$TUNNEL_TARGET"
    printf '    AllowStreamLocalForwarding no\n'
    printf '    GatewayPorts no\n'
    printf '    PermitTunnel no\n'
    printf '    X11Forwarding no\n'
    printf '    AllowAgentForwarding no\n'
    printf '    PermitTTY no\n'
    printf "    ForceCommand echo 'Tunnel only - no shell access'\n"
    printf '%s\n' "$MATCH_END"
  } >>"$SSHD_CFG"
  ok "Match block: xong"
  record "Ghi Match block cho '${TUNNEL_OS_USER}' vào ${SSHD_CFG}" "cp -p ${SSHD_BAK} ${SSHD_CFG} && systemctl reload ${SSH_SVC_GUESS}"

  # ---- 5. Validate, rollback nếu lỗi ----
  if sshd_check; then
    ok "sshd -t OK"
  else
    err "sshd -t báo lỗi sau khi sửa:"
    codeblock "$SSHD_T_OUT"
    cp -p -- "$SSHD_BAK" "$SSHD_CFG"
    record "ĐÃ ROLLBACK ${SSHD_CFG} về ${SSHD_BAK} (sshd -t lỗi) — sshd_config như cũ, chưa reload" ""
    die "sshd -t báo lỗi → đã rollback ${SSHD_CFG} từ ${SSHD_BAK}. sshd KHÔNG bị reload."
  fi

  # ---- 6. Xác nhận config hiệu lực cho user này (evidence) ----
  SSHD_EVIDENCE="${EVIDENCE_DIR}/sshd_effective_${TUNNEL_OS_USER}.txt"
  if "$SSHD_BIN" -T -C "user=${TUNNEL_OS_USER},host=localhost,addr=127.0.0.1" >"$SSHD_EVIDENCE" 2>>"$LOG_FILE"; then
    for expect in "permittty no" "allowtcpforwarding local" "permitopen ${TUNNEL_TARGET}" "authenticationmethods publickey"; do
      if grep -qiF "$expect" "$SSHD_EVIDENCE"; then ok "Hiệu lực: ${expect}"; else warn "Chưa thấy hiệu lực: ${expect}"; fi
    done
  else
    warn "Không chạy được 'sshd -T -C' để xác nhận — bỏ qua bước này."
  fi

  # ---- 7. Reload ----
  SSH_SVC="$(find_ssh_service)"
  if [[ -z "$SSH_SVC" ]]; then
    warn "Không xác định được service ssh/sshd — tự reload sau."
  elif systemctl is-active --quiet "$SSH_SVC"; then
    if confirm "Reload ${SSH_SVC}? (không rớt session)" y y; then
      systemctl reload "$SSH_SVC" || die "Reload thất bại — kiểm tra tay. KHÔNG restart để tránh mất kết nối."
      ok "Reload ${SSH_SVC}: xong"
      record "Reload ${SSH_SVC} (config mới có hiệu lực)" ""
    else
      warn "Chưa reload — config mới chưa có hiệu lực. Chạy: systemctl reload ${SSH_SVC}"
    fi
  else
    info "${SSH_SVC} không chạy (socket activation?) → áp dụng khi khởi động."
  fi

  detect_server_ip
fi

# ============================== Credentials file ==========================

{
  printf '# %s v%s — %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$(date '+%F %T')"
  printf '# File chứa bí mật. Gửi qua kênh an toàn rồi XOÁ khỏi server.\n\n'
  if [[ "$DO_DB_USER" == "yes" ]]; then
    printf '[database]\n'
    printf 'engine   = %s\nhost     = %s\nport     = %s\ndatabase = %s\n' "$DB_ENGINE" "$DB_HOST" "$DB_PORT" "$DB_NAME"
    printf 'user     = %s\npassword = %s\naccess   = %s\n\n' "$NEW_DB_USER" "$NEW_DB_PASS" "$ACCESS_MODE"
  fi
  if [[ "$DO_TUNNEL" == "yes" ]]; then
    LOCAL_PORT="$TGT_PORT"   # cổng local = cổng DB; đổi nếu máy local đã dùng cổng này
    printf '[ssh_tunnel]\n'
    printf 'ssh_host    = %s\nssh_port    = %s\nssh_user    = %s\n' "$PUBLIC_IP" "$SSH_PORT" "$TUNNEL_OS_USER"
    printf 'private_key = %s\ntarget      = %s\n\n' "$(basename "$KEY_OUT")" "$TUNNEL_TARGET"
    printf '# DBeaver — tab SSH:  Host=%s  Port=%s  User=%s  Auth=Public Key  Key=%s\n' \
      "$PUBLIC_IP" "$SSH_PORT" "$TUNNEL_OS_USER" "$(basename "$KEY_OUT")"
    printf '# DBeaver — tab Main: Host=%s  Port=%s  (địa chỉ nhìn từ server SSH)\n' "$TGT_HOST" "$TGT_PORT"
    printf '# CLI:  ssh -i %s -N -L %s:%s %s@%s\n' "$(basename "$KEY_OUT")" "$LOCAL_PORT" "$TUNNEL_TARGET" "$TUNNEL_OS_USER" "$PUBLIC_IP"
    printf '#       rồi connect DB tới 127.0.0.1:%s\n' "$LOCAL_PORT"
  fi
} >"$CRED_FILE"
chmod 600 "$CRED_FILE"

# ============================== Summary ===================================

step "Tổng kết"

# Hỏi trước (prompt không thể nằm trong phần phát chậm bên dưới)
SHOW_PASS="no"
if [[ "$DO_DB_USER" == "yes" ]] && confirm "Hiện password DB?"; then SHOW_PASS="yes"; fi

# Phần còn lại ghi vào bộ đệm, cuối cùng phát ra từng dòng (reveal_summary)
SUMMARY_BUF="$(mktemp "${OUT_DIR}/.summary.XXXXXX")"; TMP_FILES+=("$SUMMARY_BUF")
exec 3>&2 2>"$SUMMARY_BUF"
IN_SUMMARY=1

# Thứ tự: SSH tunnel → DBeaver → Database → File output (đúng thứ tự người dùng cần khi kết nối)
blank
if [[ "$DO_TUNNEL" == "yes" ]]; then
  SSH_P_OPT="";  [[ "$SSH_PORT" != "22" ]] && SSH_P_OPT="-p ${SSH_PORT} "
  printf '  %sSSH tunnel%s\n' "$BOLD" "$RESET" >&2
  kv "SSH host" "${PUBLIC_IP}:${SSH_PORT}  ${DIM}(${IP_SOURCE})${RESET}"
  kv "SSH user" "$TUNNEL_OS_USER"
  kv "Private key" "$KEY_OUT"
  # -N bắt buộc: tunnel user không có shell, thiếu -N thì SSH chạy lệnh mặc định rồi đóng luôn tunnel
  kv "Connect" "${CYAN}ssh ${SSH_P_OPT}-i $(basename "$KEY_OUT") -N -L ${LOCAL_PORT}:${TUNNEL_TARGET} ${TUNNEL_OS_USER}@${PUBLIC_IP}${RESET}"
  blank
  printf '  %sDBeaver%s\n' "$BOLD" "$RESET" >&2
  kv "Tab SSH" "${PUBLIC_IP} · ${SSH_PORT} · ${TUNNEL_OS_USER} · Public Key"
  kv "Tab Main" "${TGT_HOST} · ${TGT_PORT}"
  blank
fi

if [[ "$DO_DB_USER" == "yes" ]]; then
  printf '  %sDatabase%s\n' "$BOLD" "$RESET" >&2
  kv "Engine" "$DB_ENGINE"
  kv "Host" "${DB_HOST}:${DB_PORT}$([[ "$IS_RDS" == "yes" ]] && printf '  (RDS)')"
  kv "Database" "$DB_NAME"
  kv "User" "$NEW_DB_USER"
  if [[ "$SHOW_PASS" == "yes" ]]; then
    kv "Password" "$NEW_DB_PASS"
  else
    kv "Password" "$(mask "$NEW_DB_PASS")  ${DIM}(xem $(basename "$CRED_FILE"))${RESET}"
  fi
  kv "Quyền" "$ACCESS_MODE"
  blank
  # Không in ra màn hình nữa, chỉ ghi log để tra cứu
  log "Kết quả: chạy SQL=${RUN_MODE} · verify grants=${VERIFY_STATUS} · test login=${LOGIN_STATUS}"
fi

# Chạy thành công: không in danh sách thay đổi (chỉ in khi thoát do lỗi), nhưng vẫn ghi CHANGES_FILE
write_changes_file
# Output được chuyển owner về user gọi sudo (give_output_to_sudo_user) → không cần sudo để đọc.
# Chạy thẳng bằng root (không qua sudo) thì file vẫn thuộc root → giữ sudo trong gợi ý.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then CAT_CMD="cat"; else CAT_CMD="sudo cat"; fi
printf '  %sFile output%s\n' "$BOLD" "$RESET" >&2
kv "Link" "$OUT_DIR"
kv "Credentials" "${CYAN}${CAT_CMD} $(printf '%q' "$CRED_FILE")${RESET}"
if [[ "$DO_TUNNEL" == "yes" && -n "$KEY_OUT" ]]; then
  # Chạy TRÊN MÁY LOCAL để kéo private key về. Đăng nhập bằng user đã gọi sudo (owner của output),
  # không phải tunnel user (tunnel user không có shell nên scp không dùng được).
  SCP_USER="${SUDO_USER:-<user>}"; [[ "$SCP_USER" == "root" ]] && SCP_USER="<user>"
  SCP_PORT_OPT=""; [[ "$SSH_PORT" != "22" ]] && SCP_PORT_OPT="-P ${SSH_PORT} "
  kv "Copy private key" "${CYAN}scp ${SCP_PORT_OPT}${SCP_USER}@${PUBLIC_IP}:$(printf '%q' "$KEY_OUT") . && chmod 600 $(printf '%q' "$(basename "$KEY_OUT")")${RESET}"
fi

blank
printf '  %s⚠ Nhắc nhở bảo mật%s\n' "$YELLOW" "$RESET" >&2
note "• Security Group / firewall: chỉ whitelist IP cần thiết cho port ${SSH_PORT} (SSH) và port DB."
note "• Xoá:  rm -rf ${OUT_DIR} hoặc xoá output của mọi lần chạy:  rm -rf ${OUT_BASE}"
blank
exec 2>&3 3>&-
IN_SUMMARY=0
reveal_summary "$SUMMARY_BUF"

# Khung "Hoàn tất" in cùng lúc (1 lệnh printf), không qua hiệu ứng từng dòng
printf '%s%s%s\n✔ Hoàn tất\n%s%s\n\n' "$BOLD" "$GREEN" "$RULE" "$RULE" "$RESET" >&2
log "===== Hoàn tất ====="
(( NONINTERACTIVE )) || sleep 2   # dừng để kịp đọc; bỏ qua khi chạy --yes (CI)

emit_json status ok action create \
  scope "$(case "$SCOPE_IDX" in 1) echo both ;; 2) echo db ;; 3) echo tunnel ;; esac)" \
  engine "${DB_ENGINE:-}" host "${DB_HOST:-}" port "${DB_PORT:-}" \
  database "$DB_NAME" databases "$(json_array "${DB_LIST[@]}")" db_user "$NEW_DB_USER" access "$ACCESS_MODE" run_sql "$RUN_MODE" \
  verify_grants "$VERIFY_STATUS" login_test "$LOGIN_STATUS" sql_file "$SQL_FILE" \
  tunnel_user "${TUNNEL_OS_USER:-}" tunnel_target "${TUNNEL_TARGET:-}" private_key "${KEY_OUT:-}" \
  credentials_file "$CRED_FILE" output_dir "$OUT_DIR" changes_file "$CHANGES_FILE" log_file "$LOG_FILE"

exit 0
}
