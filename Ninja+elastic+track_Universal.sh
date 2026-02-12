#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# === Перевірка наявності змінних середовища ===
REQUIRED_VARS=(
    "NINJAONE_AGENT_VERSION"
    "NINJAONE_REENROLL_TOKEN"
    "NINJAONE_REENROLL_AGENT_VERSION"
    "NINJAONE_REENROLL_DEB_NAME"
    "TRACK_DEVICE_API"
    "TRACK_DEVICE_TOKEN"
    "CISCO_VPN_HOST"
    "NINJA_TOKEN_HEAD_ADM"
    "NINJA_TOKEN_HEAD_AUD"
    "NINJA_TOKEN_HEAD_DFE"
    "NINJA_TOKEN_HEAD_DIT"
    "NINJA_TOKEN_HEAD_OMK"
    "NINJA_TOKEN_HEAD_PER"
    "NINJA_TOKEN_HEAD_URD"
    "NINJA_TOKEN_HEAD_DBB"
	"NINJA_TOKEN_HEAD_RAF"
	"NINJA_TOKEN_HEAD_B2B"
    "NINJA_TOKEN_PO_ADM"
    "NINJA_TOKEN_PO_AUD"
    "NINJA_TOKEN_PO_BKRTL"
    "NINJA_TOKEN_PO_CC"
    "NINJA_TOKEN_PO_CCNTB"
    "NINJA_TOKEN_PO_BACKOFFICE"
    "NINJA_TOKEN_PO_DBB"
    "NINJA_TOKEN_PO_DFE"
    "NINJA_TOKEN_PO_PER"
    "NINJA_TOKEN_PO_CALCR"
    "NINJA_TOKEN_PO_RISK"
    "NINJA_TOKEN_VAS_ADM"
    "NINJA_TOKEN_VAS_BLS"
    "NINJA_TOKEN_VAS_CAZ"
    "NINJA_TOKEN_VAS_CUA"
    "NINJA_TOKEN_VAS_DBB"
    "NINJA_TOKEN_VAS_OMK"
    "NINJA_TOKEN_VAS_VOD"
    "NINJA_TOKEN_VAS_VOF"
    "NINJA_TOKEN_VAS_RISK"
    "NINJA_TOKEN_BYOD"
	"NINJA_TOKEN_BIO"
)

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    echo "❌ Помилка: Не встановлені обов'язкові змінні середовища:"
    printf '  - %s\n' "${MISSING_VARS[@]}"
    echo "Будь ласка, запустіть спочатку onboard_script_new.sh"
    exit 1
fi

# === Логування ===
LOG_FILE="/var/log/install_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log "--- ПОЧАТОК СКРИПТА ---"

if ! command -v curl &> /dev/null; then
    echo "curl не знайдено. Встановлення..."
    sudo apt update && sudo apt install -y curl || { echo "Помилка встановлення curl"; exit 1; }
else
    echo "curl встановлено в системі."
fi

# === APT LOCK PROTECTION ===
function wait_for_apt() {
  local TIMEOUT=120 INTERVAL=5 ELAPSED=0
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    log "apt lock: ${ELAPSED}s..."
    sleep $INTERVAL
    ((ELAPSED+=INTERVAL))
    (( ELAPSED>=TIMEOUT )) && break
  done
  log "apt unlocked"
}

# === Модулі та Функції ===

setup_ninjaone_reenroll() {
    log "🔧 Налаштовую NinjaOne auto-reenroll systemd timer..."

    local SCRIPT_PATH="/usr/local/sbin/ninjaone_reenroll.sh"
    local SERVICE_PATH="/etc/systemd/system/ninjaone-reenroll.service"
    local TIMER_PATH="/etc/systemd/system/ninjaone-reenroll.timer"

    # --- Створюємо основний скрипт ---
    cat << EOF > "$SCRIPT_PATH"
#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/ninjaone_reenroll.log"
exec >> "\$LOG_FILE" 2>&1

NINJAONE_TOKEN="${NINJAONE_REENROLL_TOKEN}"
NINJAONE_AGENT_VERSION="${NINJAONE_REENROLL_AGENT_VERSION}"
NINJAONE_DEB_NAME="${NINJAONE_REENROLL_DEB_NAME}"
INSTALLER_URL="https://eu.ninjarmm.com/agent/installer/\${NINJAONE_TOKEN}/\${NINJAONE_AGENT_VERSION}/\${NINJAONE_DEB_NAME}"

log() {
    echo "\$(date '+%F %T') [NinjaOne-ReEnroll] \$*"
}

install_agent() {
    log "Встановлення/реєстрація NinjaOne..."
    TMP=\$(mktemp -d -t ninjaone-XXXXXX)
    DEB="\$TMP/ninjaone.deb"
    curl -s -L "\$INSTALLER_URL" -o "\$DEB"
    apt install -y "\$DEB" || dpkg -i "\$DEB"
    rm -rf "\$TMP"
}

if ! command -v ninja-agent &>/dev/null; then
    log "NinjaOne агент не знайдено — встановлюю"
    install_agent
    exit 0
fi

if ! systemctl is-active --quiet ninjarmm-agent; then
    log "NinjaOne агент знайдено, але він не активний — перевстановлюю"
    apt remove -y ninjaone-agent || true
    install_agent
    exit 0
fi

DEVICE_ID_FILE="/opt/NinjaRMMAgent/programfiles/device_id.txt"
if [ ! -s "\$DEVICE_ID_FILE" ]; then
    log "Enrollment відсутній — виконую чисту перевстановку"
    apt remove -y ninjaone-agent || true
    install_agent
    exit 0
fi

log "NinjaOne агент працює та зареєстрований"
EOF

    chmod +x "$SCRIPT_PATH"

    # --- systemd service ---
    cat << EOF > "$SERVICE_PATH"
[Unit]
Description=NinjaOne auto-reenrollment
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
EOF

    # --- systemd timer ---
    cat << EOF > "$TIMER_PATH"
[Unit]
Description=Run NinjaOne reenroll daily

[Timer]
OnBootSec=5min
OnUnitActiveSec=1d
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # --- Активація ---
    systemctl daemon-reload
    systemctl enable --now ninjaone-reenroll.timer

    log "✅ NinjaOne reenroll systemd timer налаштований"
}

set_timezone() {
    log "Встановлення часового поясу"
    timedatectl set-timezone Europe/Kyiv
    timedatectl set-ntp true
    timedatectl status
    date
}

disable_wayland() {
    log "Редагуємо конфігураційний файл"
    local CONF="/etc/gdm3/custom.conf"

    if grep -q '^WaylandEnable=' "$CONF"; then
        sed -i 's/^WaylandEnable=.*/WaylandEnable=false/' "$CONF"
        log "Змінено рядок WaylandEnable=false"
    else
        sed -i '/^\[daemon\]/a WaylandEnable=false' "$CONF"
        log "Додано рядок WaylandEnable=false після [daemon]"
    fi
}

setup_pam_groups() {
    log "Налаштування PAM-груп"
    wait_for_apt
    apt install -y libpam-script

    log "Створення /usr/local/bin/add_user_groups.sh"
    cat <<'EOF' > /usr/local/bin/add_user_groups.sh
#!/bin/bash
USER=$PAM_USER
usermod -aG lpadmin,video,netdev "$USER"
exit 0
EOF

    chmod +x /usr/local/bin/add_user_groups.sh

    local LINE="session optional pam_exec.so /usr/local/bin/add_user_groups.sh"
    grep -qxF "$LINE" /etc/pam.d/common-session || echo "$LINE" >> /etc/pam.d/common-session
}


function select_location() {
  echo "───────────────────────────────"
  echo "📍 Оберіть локацію:"
  echo "───────────────────────────────"

  local options=(
    "Head Office"
    "Pochaina Office"
    "Vasylkivska Office"
    "BYOD"
  )

  local i=1
  for opt in "${options[@]}"; do
    echo "  $i) $opt"
    ((i++))
  done

  while true; do
    echo -n "➡️  Ваш вибір [1-${#options[@]}]: "
    read -r choice

    if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      LOCATION="${options[$((choice-1))]}"
      log "✅ Обрано локацію: $LOCATION"
      break
    else
      echo "❌ Некоректний вибір. Спробуйте ще раз."
    fi
  done
}

rename_byod_pc() {
    echo
    echo "Обрано локацію BYOD"
    echo "Рекомендується перейменувати ПК відповідно до стандарту."
    echo "Приклад: BYOD-Cherniienko"
    echo

    read -rp "Перейменувати ПК зараз? (y/N): " RENAME_CHOICE
    RENAME_CHOICE="${RENAME_CHOICE,,}"  # to lowercase

    if [[ "$RENAME_CHOICE" != "y" ]]; then
        echo "Перейменування пропущено"
        return
    fi

    CURRENT_HOSTNAME="$(hostnamectl --static)"
    echo "Поточне імʼя ПК: $CURRENT_HOSTNAME"

    read -rp "Введіть нове імʼя ПК: " NEW_HOSTNAME

    if [[ -z "$NEW_HOSTNAME" ]]; then
        echo "❌ Імʼя не може бути порожнім, пропускаємо"
        return
    fi

    if ! [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
        echo "❌ Імʼя може містити лише літери, цифри та '-'"
        return
    fi

    echo "🔄 Змінюю hostname на: $NEW_HOSTNAME"
    sudo hostnamectl set-hostname "$NEW_HOSTNAME"

    echo "✅ Hostname змінено успішно"
    echo "ℹ️  Рекомендується перелогін або reboot"
}


function install_ninjaone() {
  log "NinjaOne: старт перевірки"

  # === МАПІНГ РОЛЕЙ І ТОКЕНІВ ===
  declare -A NINJA_TOKENS

  # --- Head Office ---
  NINJA_TOKENS["Head Office-adm"]="${NINJA_TOKEN_HEAD_ADM}"
  NINJA_TOKENS["Head Office-aud"]="${NINJA_TOKEN_HEAD_AUD}"
  NINJA_TOKENS["Head Office-dfe"]="${NINJA_TOKEN_HEAD_DFE}"
  NINJA_TOKENS["Head Office-dit"]="${NINJA_TOKEN_HEAD_DIT}"
  NINJA_TOKENS["Head Office-omk"]="${NINJA_TOKEN_HEAD_OMK}"
  NINJA_TOKENS["Head Office-per"]="${NINJA_TOKEN_HEAD_PER}"
  NINJA_TOKENS["Head Office-urd"]="${NINJA_TOKEN_HEAD_URD}"
  NINJA_TOKENS["Head Office-dbb"]="${NINJA_TOKEN_HEAD_DBB}"
  NINJA_TOKENS["Head Office-raf"]="${NINJA_TOKEN_HEAD_RAF}"
  NINJA_TOKENS["Head Office-b2b"]="${NINJA_TOKEN_HEAD_B2B}"
  NINJA_TOKENS["Head Office-bio"]="${NINJA_TOKEN_HEAD_BIO}"

  # --- Pochaina Office ---
  NINJA_TOKENS["Pochaina Office-adm"]="${NINJA_TOKEN_PO_ADM}"
  NINJA_TOKENS["Pochaina Office-aud"]="${NINJA_TOKEN_PO_AUD}"
  NINJA_TOKENS["Pochaina Office-bkrtl"]="${NINJA_TOKEN_PO_BKRTL}"
  NINJA_TOKENS["Pochaina Office-cc"]="${NINJA_TOKEN_PO_CC}"
  NINJA_TOKENS["Pochaina Office-ccntb"]="${NINJA_TOKEN_PO_CCNTB}"
  NINJA_TOKENS["Pochaina Office-backoffice"]="${NINJA_TOKEN_PO_BACKOFFICE}"
  NINJA_TOKENS["Pochaina Office-dbb"]="${NINJA_TOKEN_PO_DBB}"
  NINJA_TOKENS["Pochaina Office-dfe"]="${NINJA_TOKEN_PO_DFE}"
  NINJA_TOKENS["Pochaina Office-per"]="${NINJA_TOKEN_PO_PER}"
  NINJA_TOKENS["Pochaina Office-calcr"]="${NINJA_TOKEN_PO_CALCR}"
  NINJA_TOKENS["Pochaina Office-risk"]="${NINJA_TOKEN_PO_RISK}"

  # --- Vasylkivska Office ---
  NINJA_TOKENS["Vasylkivska Office-adm"]="${NINJA_TOKEN_VAS_ADM}"
  NINJA_TOKENS["Vasylkivska Office-bls"]="${NINJA_TOKEN_VAS_BLS}"
  NINJA_TOKENS["Vasylkivska Office-caz"]="${NINJA_TOKEN_VAS_CAZ}"
  NINJA_TOKENS["Vasylkivska Office-cua"]="${NINJA_TOKEN_VAS_CUA}"
  NINJA_TOKENS["Vasylkivska Office-dbb"]="${NINJA_TOKEN_VAS_DBB}"
  NINJA_TOKENS["Vasylkivska Office-omk"]="${NINJA_TOKEN_VAS_OMK}"
  NINJA_TOKENS["Vasylkivska Office-vod"]="${NINJA_TOKEN_VAS_VOD}"
  NINJA_TOKENS["Vasylkivska Office-vof"]="${NINJA_TOKEN_VAS_VOF}"
  NINJA_TOKENS["Vasylkivska Office-risk"]="${NINJA_TOKEN_VAS_RISK}"

  # --- BYOD ---
  NINJA_TOKENS["BYOD"]="${NINJA_TOKEN_BYOD}"

  # === Перевірка наявності NinjaOne ===
  if systemctl list-units --type=service | grep -q "ninjarmm-agent.service"; then
      if systemctl is-active --quiet ninjarmm-agent; then
          log "✅ NinjaOne агент вже встановлений і працює — пропускаємо інсталяцію."
          return 0
      else
          log "⚠️ NinjaOne знайдено, але сервіс не активний — перевстановлюємо."
          apt remove -y ninjaone-agent || true
      fi
  elif [ -d "/opt/NinjaRMMAgent" ]; then
      log "⚠️ Каталог /opt/NinjaRMMAgent існує, ймовірно агент вже є — перевстановлюємо."
      apt remove -y ninjaone-agent || true
  fi

  # === ВИБІР ЛОКАЦІЇ ===
  select_location

  # ==================================================
  # BYOD FLOW (NO ROLE / NO HOSTNAME PARSING)
  # ==================================================
  if [[ "$LOCATION" == "BYOD" ]]; then
        rename_byod_pc
    if [[ -z "${NINJA_TOKENS["BYOD"]:-}" ]]; then
      log "❌ NINJA_TOKEN_BYOD не задано"
      exit 1
    fi

    NINJAONE_TOKEN="${NINJA_TOKENS["BYOD"]}"
    log "✅ BYOD режим — використовується окремий токен"

    cd /tmp
    curl -L \
      "https://eu.ninjarmm.com/ws/api/v2/generic-installer/NinjaOneAgent-x86_64.deb" \
      -o "NinjaOneAgent-x86_64.deb"

    sudo TOKENID="$NINJAONE_TOKEN" dpkg -i NinjaOneAgent-x86_64.deb || {
      log "❌ Помилка встановлення NinjaOne (BYOD)"
      exit 1
    }

    rm -f NinjaOneAgent-x86_64.deb
    log "✅ NinjaOne агент встановлено (BYOD)"
    return 0
  fi

  # === ОЧИЩЕННЯ HOSTNAME ТА ВИЗНАЧЕННЯ РОЛІ ===
  RAW_HOSTNAME=$(hostname | tr '[:upper:]' '[:lower:]')

  IFS='-' read -r -a parts <<< "$RAW_HOSTNAME"
  if (( ${#parts[@]} < 2 )); then
    log "❌ Hostname занадто короткий: $RAW_HOSTNAME"
    exit 1
  fi

  ROLE=""
  ROLE_IDX=-1

  # шукаємо роль справа-наліво
  for (( idx=${#parts[@]}-2; idx>=0; idx-- )); do
    candidate="${parts[$idx]}"
    KEY="${LOCATION}-${candidate}"

    if [[ -n "${NINJA_TOKENS["$KEY"]+x}" ]]; then
      ROLE="$candidate"
      ROLE_IDX=$idx
      break
    fi
  done

  if [[ -z "$ROLE" || $ROLE_IDX -lt 0 ]]; then
    log "❌ Не вдалося визначити роль через NINJA_TOKENS для hostname: $RAW_HOSTNAME (location: $LOCATION)"
    exit 1
  fi

  # хвіст = усе після ROLE
  TAIL=""
  for (( j=ROLE_IDX+1; j<${#parts[@]}; j++ )); do
    if [[ -z "$TAIL" ]]; then
      TAIL="${parts[$j]}"
    else
      TAIL="${TAIL}-${parts[$j]}"
    fi
  done

  if [[ -z "$TAIL" ]]; then
    log "❌ Некоректний hostname: після ролі '$ROLE' немає хвоста ($RAW_HOSTNAME)"
    exit 1
  fi

  CLEAN_HOSTNAME="${ROLE}-${TAIL}"

  if [[ "$CLEAN_HOSTNAME" != "$RAW_HOSTNAME" ]]; then
    log "🧹 Виправляю hostname: $RAW_HOSTNAME → $CLEAN_HOSTNAME"
    hostnamectl set-hostname "$CLEAN_HOSTNAME"
    export HOSTNAME="$CLEAN_HOSTNAME"
    systemctl restart systemd-logind.service || true
  fi

  log "Визначено роль: $ROLE"

  # === ВИЗНАЧЕННЯ КЛЮЧА ТА ТОКЕНУ ===
  KEY="${LOCATION}-${ROLE}"

  if [[ -n "${NINJA_TOKENS["$KEY"]+x}" ]]; then
      NINJAONE_TOKEN="${NINJA_TOKENS["$KEY"]}"
      log "✅ Знайдено токен для ${LOCATION}, роль ${ROLE}"
  else
      log "❌ Токен не знайдено для комбінації: ${LOCATION}, роль ${ROLE}"
      echo "Перевірте правильність hostname або додайте роль у список токенів."
      exit 1
  fi

  log "Використовується токен: $NINJAONE_TOKEN"

  # === Інсталяція NinjaOne через generic installer ===
  log "⬇️ Завантаження NinjaOne generic installer"
  cd /tmp
  curl -L "https://eu.ninjarmm.com/ws/api/v2/generic-installer/NinjaOneAgent-x86_64.deb" -o "NinjaOneAgent-x86_64.deb"

  if [ ! -f "NinjaOneAgent-x86_64.deb" ]; then
      log "❌ Не вдалося завантажити NinjaOneAgent-x86_64.deb"
      exit 1
  fi

  log "⚙️ Встановлення NinjaOne агента через dpkg"
  sudo TOKENID="$NINJAONE_TOKEN" dpkg -i NinjaOneAgent-x86_64.deb || {
      log "❌ Помилка встановлення NinjaOne через dpkg"
      exit 1
  }

  rm -f NinjaOneAgent-x86_64.deb
  log "✅ NinjaOne агент встановлено успішно"
}


function setup_luks_pam() {
    read -rsp "🔐 Enter existing LUKS passphrase: " EXISTING_LUKS_PASS
    echo

    LOG="/var/log/luks_deploy.log"
    NINJA_CLI="/opt/NinjaRMMAgent/programdata/ninjarmm-cli"
    TIMEOUT=300
while [ ! -x "$NINJA_CLI" ] && [ $TIMEOUT -gt 0 ]; do
    sleep 2
    TIMEOUT=$((TIMEOUT-2))
done

if [ ! -x "$NINJA_CLI" ]; then
    echo "$(date) ❌ Не знайдено $NINJA_CLI після очікування. Перевірте стан агента NinjaOne." | tee -a "$LOG"
    exit 1
fi

    set +o history
    "/opt/NinjaRMMAgent/programdata/ninjarmm-cli" set "existinglukspass" "$EXISTING_LUKS_PASS"
    STORED_VALUE=$("/opt/NinjaRMMAgent/programdata/ninjarmm-cli" get "existinglukspass")
    set -o history

if [ -n "$STORED_VALUE" ]; then
    echo "$(date) ✅ LUKS passphrase збережено в NinjaOne custom field 'existinglukspass'" | tee -a "$LOG"
else
    echo "$(date) ❌ Не вдалося зберегти LUKS passphrase в NinjaOne" | tee -a "$LOG"
fi


    PAM_FILE="/etc/pam.d/common-auth"
    HOOK_LINE="auth optional pam_exec.so expose_authtok /usr/local/sbin/luks_sync.sh"
    ADMINKEY="/etc/luks-keyfile"
    CRYPTSETUP="/usr/sbin/cryptsetup"
    SLOTS_DIR="/var/lib/luks-users"

    echo "$(date) === Старт автоматизації LUKS/PAM ===" | tee -a "$LOG"

    if [ "$EXISTING_LUKS_PASS" == "ВАШ_ПАРОЛЬ_ТУТ" ]; then
        echo "$(date) ❌ Не змінено EXISTING_LUKS_PASS! Будь ласка, вкажіть пароль." | tee -a "$LOG"
        exit 1
    fi

    DISK=$(lsblk -rpno NAME,TYPE | grep "part" | while read -r dev _; do
        cryptsetup isLuks "$dev" >/dev/null 2>&1 && echo "$dev" && break
    done)

    if [ -z "$DISK" ]; then
        echo "$(date) ❌ Не знайдено LUKS-розділ. Переконайтеся, що LUKS-диск існує." | tee -a "$LOG"
        exit 1
    fi

    echo "$(date) ✅ Знайдено LUKS-диск: $DISK" | tee -a "$LOG"

    echo "$(date) 🧹 Спроба очищення слотів (крім слота 0)..." | tee -a "$LOG"

    if printf "%s" "$EXISTING_LUKS_PASS" | $CRYPTSETUP open --test-passphrase "$DISK" >/dev/null 2>&1; then
        echo "$(date) ✅ EXISTING_LUKS_PASS діє — виконуємо очищення слотів." | tee -a "$LOG"
        
        FULL_LUKS_DUMP=$(sudo cryptsetup luksDump "$DISK")

        SLOTS_TO_KILL=""
        for slot_num in {1..31}; do
            if echo "$FULL_LUKS_DUMP" | grep -qE "^\s*$slot_num:\s*luks2$"; then
                SLOTS_TO_KILL+=" $slot_num"
            fi
        done

        if [ -n "$SLOTS_TO_KILL" ]; then
            echo "$(date) Знайдено існуючі слоти для видалення: $SLOTS_TO_KILL" | tee -a "$LOG"
            for current_slot in $SLOTS_TO_KILL; do
                printf "%s" "$EXISTING_LUKS_PASS" | $CRYPTSETUP luksKillSlot "$DISK" "$current_slot" >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    echo "$(date) 🗑️ Видалено слот $current_slot" | tee -a "$LOG"
                else
                    echo "$(date) ⚠️ Не вдалося видалити слот $current_slot. Можливо, він вже порожній або ключ недійсний. Перевірте статус LUKS." | tee -a "$LOG"
                fi
            done
        else
            echo "$(date) ℹ️ Немає існуючих слотів (крім слота 0), які потребують видалення." | tee -a "$LOG"
        fi
    else
        echo "$(date) ❌ EXISTING_LUKS_PASS НЕ підходить — очищення слотів пропущено. Будь ласка, перевірте пароль." | tee -a "$LOG"
    fi

    echo "$(date) 🔐 Генерація нового адмін-ключа..." | tee -a "$LOG"
    rm -f "$ADMINKEY"
    dd if=/dev/urandom of="$ADMINKEY" bs=64 count=1 status=none
    chmod 600 "$ADMINKEY"
    chown root:root "$ADMINKEY"

    printf "%s" "$EXISTING_LUKS_PASS" | $CRYPTSETUP luksAddKey "$DISK" "$ADMINKEY"
    echo "$(date) ✅ Додано новий адмін-ключ до LUKS" | tee -a "$LOG"

    echo "$(date) 🧹 Очищення /var/lib/luks-users/" | tee -a "$LOG"
    rm -rf "$SLOTS_DIR"
    mkdir -p "$SLOTS_DIR"

    if ! grep -Fxq "$HOOK_LINE" "$PAM_FILE"; then
        echo "$HOOK_LINE" >> "$PAM_FILE"
        echo "$(date) ✅ Додано PAM-хук" | tee -a "$LOG"
    else
        echo "$(date) ℹ️ PAM-хук вже є" | tee -a "$LOG"
    fi

    cat << 'EOF' > /usr/local/sbin/luks_sync.sh
#!/bin/bash

DISK=$(lsblk -rpno NAME,TYPE | grep "part" | while read -r dev _; do
    cryptsetup isLuks "$dev" >/dev/null 2>&1 && echo "$dev" && break
done)

ADMINKEY="/etc/luks-keyfile"
CRYPTSETUP="/usr/sbin/cryptsetup"
LOG="/var/log/luks_sync.log"
SLOTS_DIR="/var/lib/luks-users"

read -r USERPASS
USERNAME="${PAM_USER:-unknown}"

mkdir -p "$SLOTS_DIR"

echo "$(date) === [$USERNAME] Спроба синхронізації ===" >> "$LOG"

cleanup_deleted_users() {
    echo "$(date) 🧹 Запуск очищення слотів для видалених користувачів..." >> "$LOG"
    while IFS= read -r f; do
        SLOT_USER=$(basename "$f" .slot)
        if [ -n "$SLOT_USER" ]; then
            if ! grep -q "^$SLOT_USER:" /etc/passwd; then
                SLOT_NUM=$(cat "$f")
                if [ -n "$SLOT_NUM" ]; then
                    $CRYPTSETUP luksKillSlot "$DISK" "$SLOT_NUM" --key-file "$ADMINKEY" >/dev/null 2>&1
                    if [ $? -eq 0 ]; then
                        rm -f "$f"
                        echo "$(date) 🗑️ Видалено слот $SLOT_NUM для видаленого користувача $SLOT_USER" >> "$LOG"
                    else
                        echo "$(date) ⚠️ Не вдалося видалити слот $SLOT_NUM для $SLOT_USER. Можливо, вже видалено або ключ недійсний." >> "$LOG"
                    fi
                else
                    echo "$(date) ⚠️ Порожній слот-файл '$f' для $SLOT_USER — пропускаємо видалення." >> "$LOG"
                fi
            fi
        else
            echo "$(date) ⚠️ Знайдено файл слоту з порожнім ім'ям користувача: '$f'. Пропускаємо обробку." >> "$LOG"
        fi
    done < <(find "$SLOTS_DIR" -type f -name "*.slot")
    echo "$(date) 🧹 Очищення слотів для видалених користувачів завершено." >> "$LOG"
}

if [[ "$USERNAME" == "root" || "$USERNAME" == "administrator" ]]; then
    echo "$(date) ⚠️ Пропущено системного користувача $USERNAME. Запуск очищення видалених користувачів." >> "$LOG"
    cleanup_deleted_users
    exit 0
fi

if [ -z "$USERPASS" ]; then
    echo "$(date) 🔸 Порожній пароль — пропуск для $USERNAME. Запуск очищення видалених користувачів." >> "$LOG"
    cleanup_deleted_users
    exit 0
fi

echo "$USERPASS" | $CRYPTSETUP open --test-passphrase "$DISK" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "$(date) ✅ Пароль вже активний для $USERNAME. Запуск очищення видалених користувачів." >> "$LOG"
    cleanup_deleted_users
    exit 0
fi

USER_SLOT_FILE="$SLOTS_DIR/$USERNAME.slot"
OLD_SLOT=""

if [ -f "$USER_SLOT_FILE" ]; then
    OLD_SLOT=$(cat "$USER_SLOT_FILE")
    echo "$(date) ℹ️ Знайдено старий слот $OLD_SLOT для $USERNAME." >> "$LOG"
fi

ACTIVE_SLOTS_BEFORE=$(sudo cryptsetup luksDump "$DISK" | grep -E '^\s*[0-9]+:\s*luks2$' | awk '{print $1}' | tr -d ':')

echo "$USERPASS" | $CRYPTSETUP luksAddKey "$DISK" --key-file "$ADMINKEY" >/dev/null 2>&1
ADD_KEY_STATUS=$?

if [ $ADD_KEY_STATUS -eq 0 ]; then
    ACTIVE_SLOTS_AFTER=$(sudo cryptsetup luksDump "$DISK" | grep -E '^\s*[0-9]+:\s*luks2$' | awk '{print $1}' | tr -d ':')
    
    NEW_SLOT=$(comm -13 <(echo "$ACTIVE_SLOTS_BEFORE" | sort) <(echo "$ACTIVE_SLOTS_AFTER" | sort) | head -n 1)

    if [ -z "$NEW_SLOT" ]; then
        echo "$(date) ⚠️ comm не визначив новий слот, спроба перебору для $USERNAME..." >> "$LOG"
        for i in {0..31}; do
            echo "$USERPASS" | $CRYPTSETUP open --test-passphrase --key-slot $i "$DISK" 2>/dev/null
            if [ $? -eq 0 ]; then
                NEW_SLOT="$i"
                break
            fi
        done
    fi

    if [ -n "$NEW_SLOT" ]; then
        echo "$NEW_SLOT" > "$USER_SLOT_FILE"
        echo "$(date) ✅ Додано новий ключ у слот $NEW_SLOT для $USERNAME." >> "$LOG"
    else
        echo "$(date) ⚠️ Не вдалося визначити новий слот, але ключ, ймовірно, додано для $USERNAME. Можливі проблеми з відстеженням." >> "$LOG"
    fi

    if [ -n "$OLD_SLOT" ] && [ "$OLD_SLOT" != "$NEW_SLOT" ]; then
        echo "$(date) ℹ️ Спроба видалення старого слота $OLD_SLOT для $USERNAME..." >> "$LOG"
        $CRYPTSETUP luksKillSlot "$DISK" "$OLD_SLOT" --key-file "$ADMINKEY" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "$(date) 🔁 Видалено старий слот $OLD_SLOT для $USERNAME." >> "$LOG"
        else
            echo "$(date) ⚠️ Не вдалося видалити старий слот $OLD_SLOT для $USERNAME. Можливо, його вже немає або ключ недійсний." >> "$LOG"
        fi
    elif [ -n "$OLD_SLOT" ] && [ "$OLD_SLOT" == "$NEW_SLOT" ]; then
        echo "$(date) ℹ️ Старий слот $OLD_SLOT збігається з новим. Пропускаємо видалення." >> "$LOG"
    fi
else
    echo "$(date) ❌ Не вдалося додати ключ для $USERNAME. Можливо, слот переповнений або пароль недійсний." >> "$LOG"
fi

cleanup_deleted_users

exit 0

EOF

    chmod 700 /usr/local/sbin/luks_sync.sh
    chown root:root /usr/local/sbin/luks_sync.sh

    echo "$(date) ✅ Інсталяція luks_sync.sh завершена. PAM + LUKS синхронізація активна." | tee -a "$LOG" 

    cat << 'EOF' > /etc/logrotate.d/luks_sync
/var/log/luks_sync.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 600 root root
}
EOF

    echo "$(date) ✅ Налаштовано logrotate для /var/log/luks_sync.log" | tee -a "$LOG"
}

function get_mac() {
    iface=$(ip -4 route | awk '/default/ {print $5; exit}')
    [ -n "$iface" ] && ip link show "$iface" | awk '/ether/ {print $2}' || echo "Не знайдено MAC-адресу"
}
function get_ip() {
    hostname -I | awk '{print $1}' || echo "Не знайдено IP-адресу"
}

function get_hostname() {
    hostname || echo "Не знайдено ім'я хоста"
}

function trackDeviceInfo(){

    local ip=$(get_ip)
    local mac=$(get_mac)
    local name=$(get_hostname)
    local device_name=$name
    date=$(stat -c "%w" /opt/Elastic/Agent/elastic-agent | cut -d' ' -f1 | xargs -I {} date -d "{}" +"%d.%m.%Y")

    json_payload='{"hostname":"'"$device_name"'","ip":"'"$ip"'","mac":"'"$mac"'","install_date":"'"$date"'","api_key":"'"${TRACK_DEVICE_API}"'"}'

	curl -s -X POST -H "Content-Type: application/json" \
    -d "$json_payload" \
    "https://script.google.com/macros/s/${TRACK_DEVICE_TOKEN}/exec"
}

function cisco_setup() {

mkdir -p "/Library/FAVBET"
[[ ! -f "$LOG_FILE" ]] && touch "$LOG_FILE"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Перевірка доступності GitHub (DNS + HTTPS)
check_download_access() {
    log "Перевірка доступності GitHub для завантаження..."

    if ! getent hosts github.com >/dev/null 2>&1; then
        log "DNS-резолв github.com не працює."
        return 1
    fi

    if ! curl -Is --connect-timeout 5 https://github.com >/dev/null 2>&1; then
        log "HTTP/HTTPS-зʼєднання з https://github.com не встановлено."
        return 1
    fi

    log "GitHub доступний."
    return 0
}

# Завантаження з повторними спробами до 3 хвилин
download_with_retries() {
    local url="$1"
    local outfile="$2"
    local MAX_TIME=180
    local INTERVAL=10
    local ELAPSED=0
    local ATTEMPT=1

    log "Перевірка доступності ${url} з авто-повторами (до ${MAX_TIME} сек)…"

    while (( ELAPSED < MAX_TIME )); do
        log "Спроба ${ATTEMPT}: перевірка доступності GitHub…"

        if check_download_access; then
            log "GitHub доступний. Спроба завантаження файлу…"

            if curl -L --fail --connect-timeout 10 -o "$outfile" "$url"; then
                log "Завантаження успішне: $outfile"
                return 0
            else
                log "Помилка curl при завантаженні файлу. Повтор через ${INTERVAL} сек."
            fi
        else
            log "GitHub тимчасово недоступний. Повтор через ${INTERVAL} сек."
        fi

        sleep "$INTERVAL"
        (( ELAPSED += INTERVAL ))
        (( ATTEMPT += 1 ))
    done

    log "ПОМИЛКА: не вдалося завантажити файл за ${MAX_TIME} сек."
    return 1
}

# Цільова версія
TARGET_VERSION="5.1.13.177"

# Перевірка, чи Cisco вже встановлений, і визначення версії
if [ -d "/opt/cisco/secureclient" ] || [ -d "/opt/cisco/anyconnect" ]; then
    log "Cisco Secure Client знайдено в системі"

    MANIFEST_FILE="/opt/cisco/anyconnect/ACManifestVPN.xml"
    if [ -f "$MANIFEST_FILE" ]; then
        INSTALLED_VERSION=$(grep -oP 'version="\K[^"]+' "$MANIFEST_FILE" 2>/dev/null | head -n 1)
        log "Встановлена версія: $INSTALLED_VERSION"

        if [ "$INSTALLED_VERSION" == "$TARGET_VERSION" ]; then
            log "Версія $TARGET_VERSION вже встановлена. Пропуск переустановлення."
            log "Скрипт завершено - версія актуальна!"
            return 0
        else
            log "Встановлена версія ($INSTALLED_VERSION) відрізняється від цільової ($TARGET_VERSION). Продовження встановлення..."
        fi
    else
        log "Файл маніфесту не знайдено. Продовження встановлення..."
    fi
else
    log "Cisco Secure Client не знайдено в системі"
fi

log "Checking for running Cisco Secure Client processes..."

PIDS=$(pgrep -f "cisco|vpnagentd|vpnui|vpn" | tr '\n' ' ')
if [[ -n "$PIDS" ]]; then
    log "Running Cisco processes found: $PIDS"
    log "Stopping processes..."
    killall -9 vpnagentd vpnui cscotun sff_agent 2>/dev/null || true
else
    log "No active Cisco processes detected."
fi

TMP_DIR=$(mktemp -d)
log "Використання тимчасового каталогу: $TMP_DIR"

cd "$TMP_DIR" || { log "Невдалося перейти до тимчасового каталогу"; return 1; }

# Detect CPU architecture
ARCH=$(uname -m)
log "Виявлена архітектура процесора: $ARCH"

if [[ "$ARCH" == "x86_64" ]]; then
    DOWNLOAD_URL="https://github.com/Vovvka/provision_files/raw/refs/heads/main/CiscoSecureClient-5.1.13.177.tar.gz"
    PACKAGE_NAME="CiscoSecureClient-5.1.13.177.tar.gz"
    log "Використовується пакет для x86_64"
elif [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
    DOWNLOAD_URL="https://github.com/Vovvka/provision_files/raw/refs/heads/main/CiscoSecureClient-arm-5.1.13.177.tar.gz"
    PACKAGE_NAME="CiscoSecureClient-arm-5.1.13.177.tar.gz"
    log "Використовується пакет для ARM"
else
    log "Помилка: Непідтримувана архітектура процесора: $ARCH"
    return 1
fi

# Завантаження
if ! download_with_retries "$DOWNLOAD_URL" "$PACKAGE_NAME"; then
    log "Фатальна помилка: файл не завантажено після множинних спроб."
    return 1
fi

log "Розпакування архіву..."
tar -xzf "$PACKAGE_NAME" || { log "Не вдалося розпакувати архів"; return 1; }

cd vpn || { log "Не вдалося знайти папку vpn"; return 1; }
log "Перейшли до папки vpn: $(pwd)"

# Деінсталяція старої версії
if [ -d "/opt/cisco/secureclient" ] || [ -d "/opt/cisco/anyconnect" ]; then
    log "Запуск деінсталяції..."

    if [ -f "./vpn_uninstall.sh" ]; then
        log "Запуск vpn_uninstall.sh..."
        sudo bash ./vpn_uninstall.sh || log "Попередження: деінсталяція завершилась з помилкою"
    else
        log "Попередження: vpn_uninstall.sh не знайдено"
    fi
else
    log "Попередня версія не знайдена"
fi

# Видалення профілів
if [ -d "/opt/cisco/anyconnect/profile/" ]; then
    log "Видалення /opt/cisco/anyconnect/profile/..."
    sudo rm -rf /opt/cisco/anyconnect/profile/
fi

if [ -d "/opt/cisco/secureclient/profile/" ]; then
    log "Видалення /opt/cisco/secureclient/profile/..."
    sudo rm -rf /opt/cisco/secureclient/profile/
fi

# Встановлення нової версії
if [ -f "./vpn_install.sh" ]; then
    log "Запуск vpn_install.sh з автоматичним прийняттям ліцензії..."
    yes | sudo bash ./vpn_install.sh || { log "Помилка встановлення"; return 1; }
else
    log "Помилка: vpn_install.sh не знайдено"
    return 1
fi

log "Встановлення завершено успішно"

sudo mkdir -p /opt/cisco/secureclient/vpn/profile/

log "Створення clean_client_profile.xml..."
clean_client_profile=$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<AnyConnectProfile xmlns="http://schemas.xmlsoap.org/encoding/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://schemas.xmlsoap.org/encoding/ AnyConnectProfile.xsd">
	<ClientInitialization>
		<UseStartBeforeLogon UserControllable="true">true</UseStartBeforeLogon>
		<AutomaticCertSelection UserControllable="false">true</AutomaticCertSelection>
		<ShowPreConnectMessage>false</ShowPreConnectMessage>
		<CertificateStore>All</CertificateStore>
		<CertificateStoreMac>All</CertificateStoreMac>
		<CertificateStoreLinux>All</CertificateStoreLinux>
		<CertificateStoreOverride>false</CertificateStoreOverride>
		<ProxySettings>Native</ProxySettings>
		<AllowLocalProxyConnections>true</AllowLocalProxyConnections>
		<AuthenticationTimeout>30</AuthenticationTimeout>
		<AutoConnectOnStart UserControllable="true">false</AutoConnectOnStart>
		<MinimizeOnConnect UserControllable="true">true</MinimizeOnConnect>
		<LocalLanAccess UserControllable="true">false</LocalLanAccess>
		<DisableCaptivePortalDetection UserControllable="true">false</DisableCaptivePortalDetection>
		<ClearSmartcardPin UserControllable="false">true</ClearSmartcardPin>
		<IPProtocolSupport>IPv4</IPProtocolSupport>
		<AutoReconnect UserControllable="false">true
			<AutoReconnectBehavior UserControllable="false">ReconnectAfterResume</AutoReconnectBehavior>
		</AutoReconnect>
		<SuspendOnConnectedStandby>false</SuspendOnConnectedStandby>
		<AutoUpdate UserControllable="false">true</AutoUpdate>
		<RSASecurIDIntegration UserControllable="false">Automatic</RSASecurIDIntegration>
		<WindowsLogonEnforcement>SingleLocalLogon</WindowsLogonEnforcement>
		<LinuxLogonEnforcement>SingleLocalLogon</LinuxLogonEnforcement>
		<WindowsVPNEstablishment>LocalUsersOnly</WindowsVPNEstablishment>
		<LinuxVPNEstablishment>LocalUsersOnly</LinuxVPNEstablishment>
		<AutomaticVPNPolicy>false</AutomaticVPNPolicy>
		<PPPExclusion UserControllable="false">Disable
			<PPPExclusionServerIP UserControllable="false"></PPPExclusionServerIP>
		</PPPExclusion>
		<EnableScripting UserControllable="false">false</EnableScripting>
		<EnableAutomaticServerSelection UserControllable="false">false
			<AutoServerSelectionImprovement>20</AutoServerSelectionImprovement>
			<AutoServerSelectionSuspendTime>4</AutoServerSelectionSuspendTime>
		</EnableAutomaticServerSelection>
		<RetainVpnOnLogoff>false
		</RetainVpnOnLogoff>
		<CaptivePortalRemediationBrowserFailover>false</CaptivePortalRemediationBrowserFailover>
		<AllowManualHostInput>true</AllowManualHostInput>
	</ClientInitialization>
	<ServerList>
		<HostEntry>
            <HostName>${CISCO_VPN_HOST}</HostName>
            <HostAddress>${CISCO_VPN_HOST}</HostAddress>
        </HostEntry>
	</ServerList>
</AnyConnectProfile>
EOF
)

echo "$clean_client_profile" | sudo tee /opt/cisco/secureclient/vpn/profile/clean_client_profile.xml > /dev/null
log "Профіль clean_client_profile.xml створено"

log "Очистка тимчасових файлів..."
cd /
rm -rf "$TMP_DIR"

"/opt/NinjaRMMAgent/programdata/ninjarmm-cli" set "cscverison" "True"
"/opt/NinjaRMMAgent/programdata/ninjarmm-cli" get "cscverison"

log "Встановлення пакету завершено!"

}


# === ПЕРЕВІРКИ ЗАЛЕЖНОСТЕЙ ===
for pkg in curl tar; do
  if ! command -v $pkg &>/dev/null; then
    log "Install $pkg"
    wait_for_apt && apt update && apt install -y $pkg
  else
    log "$pkg є"
  fi
done

# === ВИКЛИК МОДУЛІВ ===

disable_wayland
set_timezone
setup_pam_groups
install_ninjaone
trackDeviceInfo
setup_luks_pam
cisco_setup


log "✅ ВСІ МОДУЛІ ВИКОНАНІ УСПІШНО"
log "--- КІНЕЦЬ СКРИПТА ---"
