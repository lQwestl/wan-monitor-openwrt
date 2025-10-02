#!/bin/sh
# Скрипт проверки интернета на WAN интерфейсе для OpenWrt
# При отсутствии интернета перезагружает WAN интерфейс

# === НАСТРОЙКИ ===
PING_HOST="8.8.8.8"          # Хост для проверки (Google DNS)
PING_HOST_2="1.1.1.1"        # Резервный хост (Cloudflare DNS)
PING_COUNT=3                  # Количество пинг-пакетов
PING_TIMEOUT=5                # Таймаут для каждого пинга (секунды)
LOG_FILE="/var/log/wan_monitor.log"

# === ФУНКЦИИ ===

# Логирование с временной меткой
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Автоматическое определение WAN интерфейса
detect_wan_interface() {
    log_msg "Автоматическое определение WAN интерфейса..."
    
    # Получаем список всех интерфейсов
    local interfaces=$(ubus call network.interface dump | jsonfilter -e '@.interface[@.interface!="loopback"].interface')
    
    # Ищем интерфейс с именем содержащим "wan"
    for iface in $interfaces; do
        if echo "$iface" | grep -qi "wan"; then
            # Проверяем, что интерфейс активен (up)
            local is_up=$(ubus call network.interface.$iface status | jsonfilter -e '@.up')
            if [ "$is_up" = "true" ]; then
                WAN_INTERFACE="$iface"
                log_msg "✓ Найден WAN интерфейс: $WAN_INTERFACE"
                return 0
            fi
        fi
    done
    
    # Если не нашли по имени, ищем интерфейс с default route
    log_msg "Поиск интерфейса с маршрутом по умолчанию..."
    local default_iface=$(ip route show default | head -1 | grep -o 'dev [^ ]*' | awk '{print $2}')
    
    if [ -n "$default_iface" ]; then
        # Определяем логический интерфейс OpenWrt по физическому устройству
        for iface in $interfaces; do
            local device=$(ubus call network.interface.$iface status 2>/dev/null | jsonfilter -e '@.l3_device' -e '@.device' | head -1)
            if [ "$device" = "$default_iface" ]; then
                WAN_INTERFACE="$iface"
                log_msg "✓ Найден WAN интерфейс по маршруту: $WAN_INTERFACE (устройство: $default_iface)"
                return 0
            fi
        done
        
        # Если не нашли логический, используем физический
        WAN_INTERFACE="$default_iface"
        log_msg "✓ Используем физическое устройство: $WAN_INTERFACE"
        return 0
    fi
    
    log_msg "✗ ОШИБКА: Не удалось определить WAN интерфейс автоматически"
    log_msg "Доступные интерфейсы:"
    echo "$interfaces" | tee -a "$LOG_FILE"
    return 1
}

# Получение физического устройства для интерфейса
get_physical_device() {
    local iface=$1
    
    # Пытаемся получить через ubus
    local device=$(ubus call network.interface.$iface status 2>/dev/null | jsonfilter -e '@.l3_device' -e '@.device' | head -1)
    
    # Если не получилось, возможно это уже физическое устройство
    if [ -z "$device" ]; then
        device="$iface"
    fi
    
    echo "$device"
}

# Проверка доступности хоста
check_host() {
    local host=$1
    local device=$2
    
    # Пингуем через физическое устройство
    if [ -n "$device" ]; then
        ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -I "$device" "$host" > /dev/null 2>&1
    else
        # Запасной вариант без указания интерфейса
        ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" > /dev/null 2>&1
    fi
    return $?
}

# Проверка интернета
check_internet() {
    log_msg "Проверка подключения к интернету..."
    
    # Проверяем первый хост
    if check_host "$PING_HOST" "$WAN_DEVICE"; then
        log_msg "✓ Интернет доступен (проверка через $PING_HOST)"
        return 0
    fi
    
    # Проверяем резервный хост
    log_msg "⚠ Первый хост недоступен, проверяем резервный..."
    if check_host "$PING_HOST_2" "$WAN_DEVICE"; then
        log_msg "✓ Интернет доступен (проверка через $PING_HOST_2)"
        return 0
    fi
    
    log_msg "✗ Интернет недоступен на обоих хостах"
    return 1
}

# Перезагрузка WAN интерфейса
restart_wan() {
    log_msg "═══════════════════════════════════════"
    log_msg "⚠ ВНИМАНИЕ: Перезагрузка $WAN_INTERFACE интерфейса"
    log_msg "═══════════════════════════════════════"
    
    # Проверяем, это логический интерфейс OpenWrt или физическое устройство
    if ubus call network.interface.$WAN_INTERFACE status > /dev/null 2>&1; then
        # Логический интерфейс - используем ifdown/ifup
        ifdown "$WAN_INTERFACE"
        log_msg "Интерфейс $WAN_INTERFACE выключен"
        
        sleep 5
        
        ifup "$WAN_INTERFACE"
        log_msg "Интерфейс $WAN_INTERFACE включен"
    else
        # Физическое устройство - используем ip link
        ip link set "$WAN_INTERFACE" down
        log_msg "Устройство $WAN_INTERFACE выключено"
        
        sleep 5
        
        ip link set "$WAN_INTERFACE" up
        log_msg "Устройство $WAN_INTERFACE включено"
    fi
    
    # Ждем 30 секунд для установки соединения
    log_msg "Ожидание 30 секунд для установки соединения..."
    sleep 30
    
    # Обновляем информацию о физическом устройстве
    WAN_DEVICE=$(get_physical_device "$WAN_INTERFACE")
    
    # Проверяем, помогло ли это
    if check_internet; then
        log_msg "✓ Интернет восстановлен после перезагрузки интерфейса"
        return 0
    else
        log_msg "✗ Интернет все еще недоступен после перезагрузки"
        return 1
    fi
}

# === ОСНОВНАЯ ЛОГИКА ===

log_msg "════════════════════════════════════════"
log_msg "Запуск мониторинга WAN интерфейса"
log_msg "════════════════════════════════════════"

# Автоматически определяем WAN интерфейс
if ! detect_wan_interface; then
    log_msg "✗ КРИТИЧЕСКАЯ ОШИБКА: Невозможно определить WAN интерфейс"
    log_msg "════════════════════════════════════════"
    exit 1
fi

# Получаем физическое устройство
WAN_DEVICE=$(get_physical_device "$WAN_INTERFACE")

log_msg "Логический интерфейс: $WAN_INTERFACE"
log_msg "Физическое устройство: ${WAN_DEVICE:-не определено}"
log_msg "Хосты для проверки: $PING_HOST, $PING_HOST_2"
log_msg "────────────────────────────────────────"

# Выполняем проверку
if ! check_internet; then
    restart_wan
else
    log_msg "Мониторинг завершен: все в порядке"
fi

log_msg "════════════════════════════════════════"
