#!/bin/bash

# ==============================================================================
# TorrServer + Caddy Manager v0.1-beta by Feavenchik
# ==============================================================================

# Защита от ложно-успешных конвейеров (curl | sh)
set -o pipefail

MANAGER_CONF="/opt/torr-docker/manager.conf"

# 0. Проверка на root
if [[ $EUID -ne 0 ]]; then
    echo -e "\e[31mОшибка: Запустите скрипт от пользователя root (sudo bash manager.sh)\e[0m"
    exit 1
fi

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

load_config() {
    DOMAIN=$(grep '^DOMAIN=' "$MANAGER_CONF" | cut -d= -f2)
    PORT=$(grep '^PORT=' "$MANAGER_CONF" | cut -d= -f2)
    EMAIL=$(grep '^EMAIL=' "$MANAGER_CONF" | cut -d= -f2)
    PRIMARY_USER=$(grep '^PRIMARY_USER=' "$MANAGER_CONF" | cut -d= -f2)
}

get_status() {
    if [[ -d "/opt/torr-docker" ]] && [[ -f "$MANAGER_CONF" ]]; then
        load_config
        # Читаем тег из файла (на случай, если контейнер остановлен)
        local tag=$(grep -oP 'image: ghcr.io/yourok/torrserver:\K.*' /opt/torr-docker/docker-compose.yml 2>/dev/null)
        
        local real_ver=""
        if command -v docker &>/dev/null && docker ps -q -f "name=^/torrserver$" | grep -q .; then
            # Основа: Запрашиваем версию напрямую у API TorrServer с короткими флагами для BusyBox
            real_ver=$(docker exec torrserver wget -q -O- -T 2 -t 1 http://127.0.0.1:8090/echo 2>/dev/null | grep -o 'MatriX\.[^" ]*' | head -n 1)
            
            # Фоллбэк: если API не ответил (например, контейнер завис или только стартует)
            if [[ -z "$real_ver" ]]; then
                real_ver=$(docker logs torrserver 2>&1 | grep -m 1 -o 'MatriX\.[^ ]*')
            fi
        fi

        if [[ -n "$real_ver" ]]; then
            echo -e "\e[32mУстановлен (Версия: $real_ver) | Порт: $PORT\e[0m"
        elif [[ -n "$tag" ]]; then
            echo -e "\e[32mУстановлен (Тег: $tag) | Порт: $PORT\e[0m"
        else
            echo -e "\e[33mУстановлен (Версия не определена)\e[0m"
        fi
    else
        echo -e "\e[31mНе установлен\e[0m"
    fi
}

check_port() {
    local test_port="$1"
    if [[ ! "$test_port" =~ ^[0-9]+$ ]] || [[ "$test_port" -lt 1 ]] || [[ "$test_port" -gt 65535 ]]; then
        echo -e "\e[31mНекорректный формат порта!\e[0m"
        return 1
    fi
    # Проверяем строго TCP-соединения
    if ss -tlnp | grep -q ":$test_port "; then
        return 1 # Занят
    else
        return 0 # Свободен
    fi
}

check_dns() {
    local test_domain="$1"
    if [[ ! "$test_domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo -e "\e[31mНедопустимые символы в домене!\e[0m"
        return 1
    fi
    
    local server_ip
    server_ip=$(curl -4 -s --max-time 5 ifconfig.me)
    [[ -z "$server_ip" ]] && server_ip=$(curl -4 -s --max-time 5 icanhazip.com)
    
    local domain_ips=$(getent ahostsv4 "$test_domain" | awk '{ print $1 }')
    
    if [[ -z "$server_ip" ]] || [[ -z "$domain_ips" ]]; then
        echo -e "\e[31mОшибка проверки сети. Проверьте интернет-соединение.\e[0m"
        return 1
    fi
    
    if echo "$domain_ips" | grep -q "^$server_ip$"; then
        # ПРОВЕРКА IPv6 (AAAA записи) с фильтром от гибридных ::ffff: адресов
        local aaaa_ip=$(getent ahosts "$test_domain" | awk '{ print $1 }' | grep ":" | grep -v "::ffff:" | head -n 1)
        if [[ -n "$aaaa_ip" ]]; then
            echo -e "\e[33m[ВНИМАНИЕ] У вашего домена обнаружена IPv6-запись (AAAA).\e[0m"
            echo -e "\e[33mЕсли ваш сервер не поддерживает IPv6, выпуск сертификата может провалиться.\e[0m"
            echo -e "\e[33mРекомендуем удалить AAAA-запись в панели DNS-провайдера, оставив только A-запись.\e[0m"
            sleep 3
        fi
        return 0
    else
        echo -e "\e[31mОшибка! Домен не направлен на IP этого сервера ($server_ip).\e[0m"
        return 1
    fi
}

# --- ОСНОВНЫЕ ФУНКЦИИ ---

install_torr() {
    if [[ -d "/opt/torr-docker" ]]; then
        echo -e "\e[31mTorrServer уже установлен! Сначала удалите его.\e[0m"
        return
    fi

    echo "====================================="
    echo "Начинаем установку TorrServer (Docker)"
    echo "====================================="
    
    # Предварительная проверка 80 порта для Let's Encrypt
    if ! check_port 80 >/dev/null; then
        echo -e "\e[31mОшибка: Порт 80 занят другим процессом! Освободите его для получения сертификата.\e[0m"
        return
    fi
    
    while true; do
        read -p "Какой порт использовать? [по умолчанию 8443]: " PORT
        PORT=${PORT:-8443}
        if check_port "$PORT"; then
            echo -e "\e[32mПорт $PORT свободен!\e[0m\n"
            break
        else
            echo -e "\e[31mОшибка: Порт занят или введен неверно!\e[0m\n"
        fi
    done

    while true; do
        read -p "Введите ваш Домен (например, torr.example.com): " DOMAIN
        if check_dns "$DOMAIN"; then
            echo -e "\e[32mDNS настроен верно!\e[0m\n"
            break
        else
            read -p "Нажмите 1 чтобы проверить снова, или 0 для выхода в меню: " retry
            if [[ "$retry" == "0" ]]; then return; fi
        fi
    done

    while true; do
        read -p "Введите ваш Email (для Let's Encrypt): " EMAIL
        if [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            echo -e "\e[31mНекорректный формат email!\e[0m"
        fi
    done

    while true; do
        read -p "Придумайте Логин для TorrServer: " LOGIN
        if [[ -z "$LOGIN" ]] || [[ ! "$LOGIN" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
            echo -e "\e[31mЛогин может содержать только английские буквы, цифры, точку, дефис и подчёркивание!\e[0m"
        else
            break
        fi
    done
    
    while true; do
        read -s -p "Придумайте Пароль (минимум 6 символов): " PASSWORD
        echo ""
        read -s -p "Повторите Пароль: " PASSWORD_CONFIRM
        echo ""
        if [[ "$PASSWORD" == "$PASSWORD_CONFIRM" ]] && [[ ${#PASSWORD} -ge 6 ]]; then 
            break
        else 
            echo -e "\e[31mПароли не совпадают или слишком короткие! Попробуйте снова.\e[0m"
        fi
    done

    echo -e "\n[1/6] Настройка Firewall и пакетов..."
    if ! (apt update && apt install -y curl wget gnupg2 ca-certificates ufw socat cron unzip jq btop); then
        echo -e "\e[31mОшибка установки базовых пакетов! Проверьте интернет.\e[0m"
        return
    fi
    
    systemctl enable --now cron
    
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow OpenSSH
    ufw allow 80/tcp
    ufw allow "$PORT/tcp"
    ufw --force enable

    echo -e "\n[2/6] Установка Docker..."
    if ! command -v docker &> /dev/null; then
        if ! curl -fsSL https://get.docker.com | sh; then
            echo -e "\e[31mОшибка установки Docker!\e[0m"
            return
        fi
        systemctl enable --now docker
    fi
    
    if ! docker compose version &>/dev/null; then
        echo -e "\e[31mПлагин Docker Compose не найден!\e[0m"
        return
    fi

    echo -e "\n[3/6] Настройка базы данных и состояния..."
    mkdir -p /opt/torr-docker/config
    # Закрываем папку от других пользователей хоста, но позволяем докеру читать внутри
    chmod 700 /opt/torr-docker/config
    
    # Безопасная сборка JSON через jq
    if ! jq -n --arg u "$LOGIN" --arg p "$PASSWORD" '{($u): $p}' > /opt/torr-docker/config/accs.db; then
        echo -e "\e[31mОшибка создания базы аутентификации!\e[0m"
        return
    fi
    # Делаем файл читаемым для внутреннего юзера контейнера
    chmod 644 /opt/torr-docker/config/accs.db
    
    echo "DOMAIN=$DOMAIN" > "$MANAGER_CONF"
    echo "PORT=$PORT" >> "$MANAGER_CONF"
    echo "EMAIL=$EMAIL" >> "$MANAGER_CONF"
    echo "PRIMARY_USER=$LOGIN" >> "$MANAGER_CONF"

    echo -e "\n[4/6] Выпуск сертификатов..."
    if ! curl -s https://get.acme.sh | sh -s email="$EMAIL"; then
        echo -e "\e[31mОшибка установки скрипта acme.sh! Проверьте соединение.\e[0m"
        return
    fi
    
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    mkdir -p /opt/certs/torr
    chmod 700 /opt/certs/torr
    
    if ! ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256; then
        echo -e "\e[31mОшибка выпуска сертификата! Проверьте квоты Let's Encrypt и DNS.\e[0m"
        return
    fi

    if ! ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
      --key-file       /opt/certs/torr/torr.key \
      --fullchain-file /opt/certs/torr/torr.crt; then
        echo -e "\e[31mОшибка первичной укладки сертификата!\e[0m"
        return
    fi
    
    chmod 600 /opt/certs/torr/torr.key
    chmod 644 /opt/certs/torr/torr.crt

    echo -e "\n[5/6] Создание конфигурации Caddy и Docker..."
    cat << EOF > /opt/torr-docker/Caddyfile
{
    auto_https off
}

$DOMAIN:$PORT {
    tls /certs/torr.crt /certs/torr.key
    reverse_proxy torrserver:8090
}

:$PORT {
    tls internal
    abort
}
EOF

    cat << EOF > /opt/torr-docker/docker-compose.yml
services:
  torrserver:
    image: ghcr.io/yourok/torrserver:latest
    container_name: torrserver
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    environment:
      - TS_HTTPAUTH=1
      - TS_CONF_PATH=/opt/ts/config
      - TS_PORT=8090
    volumes:
      - /opt/torr-docker/config:/opt/ts/config
    networks:
      - internal

  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    ports:
      - "$PORT:$PORT"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - /opt/certs/torr:/certs:ro
    networks:
      - internal
    depends_on:
      - torrserver

networks:
  internal:
    driver: bridge
EOF

    echo -e "\n[6/6] Запуск контейнеров и регистрация автопродления..."
    cd /opt/torr-docker || { echo -e "\e[31mОшибка: Папка не найдена!\e[0m"; return; }
    if ! docker compose up -d; then
        echo -e "\e[31mОшибка запуска Docker контейнеров!\e[0m"
        return
    fi
    
    echo "Ожидание готовности Caddy для автопродления..."
    for i in {1..30}; do
        if docker exec caddy caddy version &>/dev/null; then break; fi
        sleep 1
    done
    
    if ! ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
      --key-file       /opt/certs/torr/torr.key \
      --fullchain-file /opt/certs/torr/torr.crt \
      --reloadcmd      "chmod 600 /opt/certs/torr/torr.key && chmod 644 /opt/certs/torr/torr.crt && docker restart caddy"; then
        echo -e "\e[31mОшибка установки сертификата в Caddy!\e[0m"
        return
    fi

    # ЗАЩИТА НА БУДУЩЕЕ (Проверка прав Торрсервера)
    if ! docker exec torrserver test -r /opt/ts/config/accs.db; then
        echo -e "\n\e[31m[ВНИМАНИЕ] Контейнер запущен, но не может прочитать базу пользователей!\e[0m"
        echo -e "\e[31mСкорее всего, в новой версии TorrServer разработчик изменил права доступа (UID).\e[0m"
        echo -e "\e[33mРешение: Зайдите в меню скрипта, выберите пункт «2. Обновить / Понизить версию»\e[0m"
        echo -e "\e[33mи вручную введите стабильную версию: MatriX.142.2\e[0m"
    fi

    echo -e "\n\e[32mУстановка успешно завершена!\e[0m"
    echo -e "\e[32mВаша ссылка для подключения: https://$DOMAIN:$PORT\e[0m"
}

change_version() {
    if [[ ! -f "/opt/torr-docker/docker-compose.yml" ]]; then echo -e "\e[31mНе установлен!\e[0m"; return; fi
    
    echo "====================================="
    read -p "Введите нужную версию (например, MatriX.141) или latest: " TARGET_VERSION
    TARGET_VERSION=${TARGET_VERSION:-latest}
    
    if [[ ! "$TARGET_VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo -e "\e[31mНедопустимые символы в версии!\e[0m"
        return
    fi

    BACKUP_DATE=$(date +%Y%m%d-%H%M%S)
    cp -a /opt/torr-docker/config "/opt/torr-docker/config.backup-$BACKUP_DATE"
    echo "Бэкап базы данных сохранен."
    
    ls -dt /opt/torr-docker/config.backup-* 2>/dev/null | tail -n +6 | xargs -r rm -rf

    cd /opt/torr-docker || return
    cp docker-compose.yml docker-compose.yml.bak
    sed -i "s|image: ghcr.io/yourok/torrserver:.*|image: ghcr.io/yourok/torrserver:${TARGET_VERSION}|" docker-compose.yml
    
    if ! docker compose pull torrserver || ! docker compose up -d torrserver; then
        echo -e "\e[31mОшибка! Откатываю конфигурацию...\e[0m"
        mv docker-compose.yml.bak docker-compose.yml
        docker compose up -d torrserver
        return
    fi
    
    rm -f docker-compose.yml.bak
    
    # Очистка старых образов (сортируем по дате создания, оставляем только 3 последних)
    docker images ghcr.io/yourok/torrserver --format '{{.CreatedAt}}\t{{.ID}}' | sort -r | awk '{print $NF}' | tail -n +4 | xargs -r docker rmi >/dev/null 2>&1
    
    echo -e "\n\e[32mВерсия успешно изменена!\e[0m"
    sleep 2 
}

# --- ПОДМЕНЮ: УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ ---

manage_users() {
    if [[ ! -f /opt/torr-docker/config/accs.db ]]; then
        echo -e "\e[31mTorrServer не установлен!\e[0m"; return
    fi
    
    load_config
    
    if ! command -v jq &> /dev/null; then
        echo "Установка утилиты jq..."
        apt update &>/dev/null && apt install -y jq &>/dev/null
    fi

    while true; do
        clear
        echo "============================================="
        echo "      Управление пользователями (Доступ)"
        echo "============================================="
        echo "Текущие логины в системе:"
        
        while read -r u; do
            if [[ "$u" == "$PRIMARY_USER" ]]; then
                echo -e " - \e[33m$u (Главный администратор)\e[0m"
            else
                echo " - $u"
            fi
        done < <(jq -r 'keys[]' /opt/torr-docker/config/accs.db)
        
        echo "---------------------------------------------"
        echo "  1. Добавить пользователя"
        echo "  2. Изменить пароль пользователя"
        echo "  3. Удалить пользователя (кроме Главного)"
        echo "---------------------------------------------"
        echo "  0. Назад в главное меню"
        echo "============================================="
        read -p "Выберите действие: " sub
        
        case "$sub" in
            1) add_user ;;
            2) change_user_password ;;
            3) delete_user ;;
            0) return ;;
            *) echo -e "\e[31mНеверный выбор!\e[0m" ;;
        esac
        echo ""
        read -p "Нажмите Enter для продолжения..."
    done
}

add_user() {
    read -p "Введите новый логин: " U
    if [[ -z "$U" ]] || [[ ! "$U" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        echo -e "\e[31mЛогин может содержать только английские буквы, цифры, точку, дефис и подчёркивание!\e[0m"; return
    fi
    
    if jq -e --arg u "$U" 'has($u)' /opt/torr-docker/config/accs.db &>/dev/null; then
        echo -e "\e[31mОшибка: Пользователь $U уже существует!\e[0m"; return
    fi
    
    read -s -p "Придумайте пароль (минимум 6 символов): " P; echo
    read -s -p "Повторите пароль: " P2; echo
    if [[ "$P" != "$P2" ]] || [[ ${#P} -lt 6 ]]; then
        echo -e "\e[31mПароли не совпадают или слишком короткие!\e[0m"; return
    fi
    
    if jq --arg u "$U" --arg p "$P" '. + {($u): $p}' /opt/torr-docker/config/accs.db > /opt/torr-docker/config/accs.db.tmp; then
        mv /opt/torr-docker/config/accs.db.tmp /opt/torr-docker/config/accs.db
        chmod 644 /opt/torr-docker/config/accs.db
        if ! docker restart torrserver >/dev/null; then echo -e "\e[31mОшибка перезапуска контейнера!\e[0m"; fi
        echo -e "\e[32mУспешно! Пользователь $U добавлен.\e[0m"
    else
        rm -f /opt/torr-docker/config/accs.db.tmp
        echo -e "\e[31mОшибка записи в базу!\e[0m"
    fi
}

change_user_password() {
    read -p "Введите логин для смены пароля: " U
    if ! jq -e --arg u "$U" 'has($u)' /opt/torr-docker/config/accs.db &>/dev/null; then
        echo -e "\e[31mОшибка: Пользователя $U не существует!\e[0m"; return
    fi
    
    read -s -p "Введите новый пароль (минимум 6 символов): " P; echo
    read -s -p "Повторите новый пароль: " P2; echo
    if [[ "$P" != "$P2" ]] || [[ ${#P} -lt 6 ]]; then
        echo -e "\e[31mПароли не совпадают или слишком короткие!\e[0m"; return
    fi
    
    if jq --arg u "$U" --arg p "$P" '.[$u] = $p' /opt/torr-docker/config/accs.db > /opt/torr-docker/config/accs.db.tmp; then
        mv /opt/torr-docker/config/accs.db.tmp /opt/torr-docker/config/accs.db
        chmod 644 /opt/torr-docker/config/accs.db
        if ! docker restart torrserver >/dev/null; then echo -e "\e[31mОшибка перезапуска контейнера!\e[0m"; fi
        echo -e "\e[32mУспешно! Пароль для $U изменен.\e[0m"
    else
        rm -f /opt/torr-docker/config/accs.db.tmp
        echo -e "\e[31mОшибка записи в базу!\e[0m"
    fi
}

delete_user() {
    read -p "Введите логин для удаления: " U
    if ! jq -e --arg u "$U" 'has($u)' /opt/torr-docker/config/accs.db &>/dev/null; then
        echo -e "\e[31mОшибка: Пользователя $U не существует!\e[0m"; return
    fi
    
    if [[ "$U" == "$PRIMARY_USER" ]]; then
        echo -e "\e[31mОшибка: Нельзя удалить главного администратора! Вы потеряете доступ к серверу.\e[0m"
        return
    fi
    
    if jq --arg u "$U" 'del(.[$u])' /opt/torr-docker/config/accs.db > /opt/torr-docker/config/accs.db.tmp; then
        mv /opt/torr-docker/config/accs.db.tmp /opt/torr-docker/config/accs.db
        chmod 644 /opt/torr-docker/config/accs.db
        if ! docker restart torrserver >/dev/null; then echo -e "\e[31mОшибка перезапуска контейнера!\e[0m"; fi
        echo -e "\e[32mУспешно! Пользователь $U удален.\e[0m"
    else
        rm -f /opt/torr-docker/config/accs.db.tmp
        echo -e "\e[31mОшибка записи в базу!\e[0m"
    fi
}

# --- КОНЕЦ ПОДМЕНЮ ---

change_port() {
    if [[ ! -f "$MANAGER_CONF" ]]; then echo -e "\e[31mНе установлен!\e[0m"; return; fi
    load_config

    echo "Текущий порт: $PORT"
    while true; do
        read -p "Введите новый порт: " NEW_PORT
        if check_port "$NEW_PORT"; then
            break
        else
            echo -e "\e[31mОшибка: Порт занят или введен неверно!\e[0m\n"
        fi
    done

    DOMAIN_REGEX="${DOMAIN//./\\.}"

    cd /opt/torr-docker || return
    cp Caddyfile Caddyfile.bak
    cp docker-compose.yml docker-compose.yml.bak
    
    sed -i "s/$DOMAIN_REGEX:$PORT/$DOMAIN:$NEW_PORT/g" Caddyfile
    sed -i "s/:$PORT {/:$NEW_PORT {/g" Caddyfile
    sed -i "s/\"$PORT:$PORT\"/\"$NEW_PORT:$NEW_PORT\"/g" docker-compose.yml
    
    if ! docker compose up -d caddy; then
        echo -e "\e[31mОшибка перезапуска Caddy! Откатываю настройки...\e[0m"
        mv Caddyfile.bak Caddyfile
        mv docker-compose.yml.bak docker-compose.yml
        docker compose up -d caddy
        return
    fi
    
    rm -f Caddyfile.bak docker-compose.yml.bak
    
    ufw --force delete allow "$PORT/tcp" >/dev/null 2>&1
    ufw allow "$NEW_PORT/tcp" >/dev/null 2>&1

    sed -i "s/PORT=$PORT/PORT=$NEW_PORT/g" "$MANAGER_CONF"

    echo -e "\n\e[32mУспешно! Ваша новая ссылка для подключения: https://$DOMAIN:$NEW_PORT\e[0m"
}

change_domain() {
    if [[ ! -f "$MANAGER_CONF" ]]; then echo -e "\e[31mНе установлен!\e[0m"; return; fi
    load_config

    echo -e "\e[31mВНИМАНИЕ: Новый домен уже должен быть направлен на IP этого сервера!\e[0m"
    while true; do
        read -p "Введите новый домен: " NEW_DOMAIN
        if check_dns "$NEW_DOMAIN"; then break; else
            read -p "Нажмите 1 чтобы проверить снова, или 0 для отмены: " retry
            if [[ "$retry" == "0" ]]; then return; fi
        fi
    done

    DOMAIN_REGEX="${DOMAIN//./\\.}"

    cd /opt/torr-docker || return
    cp Caddyfile Caddyfile.bak
    cp "$MANAGER_CONF" "${MANAGER_CONF}.bak"
    cp /opt/certs/torr/torr.crt /opt/certs/torr/torr.crt.bak
    cp /opt/certs/torr/torr.key /opt/certs/torr/torr.key.bak

    sed -i "s/$DOMAIN_REGEX:$PORT/$NEW_DOMAIN:$PORT/g" Caddyfile
    sed -i "s/DOMAIN=$DOMAIN/DOMAIN=$NEW_DOMAIN/g" "$MANAGER_CONF"

    if ! ~/.acme.sh/acme.sh --issue -d "$NEW_DOMAIN" --standalone -k ec-256; then
        echo -e "\e[31mОшибка выпуска сертификата! Откатываю настройки...\e[0m"
        mv Caddyfile.bak Caddyfile
        mv "${MANAGER_CONF}.bak" "$MANAGER_CONF"
        mv /opt/certs/torr/torr.crt.bak /opt/certs/torr/torr.crt
        mv /opt/certs/torr/torr.key.bak /opt/certs/torr/torr.key
        return
    fi
    
    if ! ~/.acme.sh/acme.sh --install-cert -d "$NEW_DOMAIN" \
      --key-file       /opt/certs/torr/torr.key \
      --fullchain-file /opt/certs/torr/torr.crt \
      --reloadcmd      "chmod 600 /opt/certs/torr/torr.key && chmod 644 /opt/certs/torr/torr.crt && docker restart caddy"; then
        echo -e "\e[31mОшибка применения сертификата! Откатываю настройки...\e[0m"
        mv Caddyfile.bak Caddyfile
        mv "${MANAGER_CONF}.bak" "$MANAGER_CONF"
        mv /opt/certs/torr/torr.crt.bak /opt/certs/torr/torr.crt
        mv /opt/certs/torr/torr.key.bak /opt/certs/torr/torr.key
        return
    fi

    rm -f Caddyfile.bak "${MANAGER_CONF}.bak" /opt/certs/torr/torr.crt.bak /opt/certs/torr/torr.key.bak

    # Удаление старого сертификата из базы acme.sh с флагом --ecc и очистка папки
    ~/.acme.sh/acme.sh --revoke -d "$DOMAIN" --ecc >/dev/null 2>&1
    ~/.acme.sh/acme.sh --remove -d "$DOMAIN" --ecc >/dev/null 2>&1
    rm -rf "$HOME/.acme.sh/${DOMAIN}_ecc"

    echo -e "\n\e[32mУспешно! Ваша новая ссылка для подключения: https://$NEW_DOMAIN:$PORT\e[0m"
}

uninstall_torr() {
    if [[ ! -d "/opt/torr-docker" ]]; then echo -e "\e[31mНе установлен!\e[0m"; return; fi
    
    read -p "Вы уверены, что хотите ПОЛНОСТЬЮ удалить TorrServer? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then return; fi

    if [[ -f "$MANAGER_CONF" ]]; then
        load_config
        ufw --force delete allow "$PORT/tcp" >/dev/null 2>&1
        # Удаление старого сертификата из базы acme.sh с флагом --ecc и очистка папки
        ~/.acme.sh/acme.sh --revoke -d "$DOMAIN" --ecc >/dev/null 2>&1
        ~/.acme.sh/acme.sh --remove -d "$DOMAIN" --ecc >/dev/null 2>&1
        rm -rf "$HOME/.acme.sh/${DOMAIN}_ecc"
    fi

    cd /opt/torr-docker && docker compose down
    rm -rf /opt/torr-docker
    rm -rf /opt/certs/torr
    
    echo -e "\n\e[32mTorrServer успешно и полностью удален с сервера!\e[0m"
}

# --- ГЛАВНЫЙ ЦИКЛ МЕНЮ ---
while true; do
    echo "============================================="
    echo "  TorrServer + Caddy Manager v0.1-beta by Feavenchik"
    echo "============================================="
    STATUS=$(get_status)
    echo -e "  Статус: $STATUS"
    echo "---------------------------------------------"
    echo "  1. Установить TorrServer (Docker)"
    echo "  2. Обновить / Понизить версию"
    echo "  3. Управление пользователями"
    echo "  4. Изменить порт"
    echo "  5. Изменить доменное имя"
    echo "  6. Мониторинг ресурсов (btop)"
    echo "---------------------------------------------"
    echo "  7. Полное удаление TorrServer"
    echo "  0. Выход"
    echo "============================================="
    read -p "Введите пункт меню: " choice

    case "$choice" in
        1) install_torr ;;
        2) change_version ;;
        3) manage_users ;;
        4) change_port ;;
        5) change_domain ;;
        6) 
            clear
            if command -v btop &> /dev/null; then
                btop
            else
                echo -e "\e[33mУтилита btop не найдена. Устанавливаем...\e[0m"
                apt update >/dev/null 2>&1 && apt install -y btop >/dev/null 2>&1
                if command -v btop &> /dev/null; then
                    btop
                else
                    echo -e "\e[31mНе удалось установить btop. Проверьте подключение к сети.\e[0m"
                fi
            fi
            ;;
        7) uninstall_torr ;;
        0) clear; exit 0 ;;
        *) echo -e "\e[31mНеверный выбор! Попробуйте снова.\e[0m" ;;
    esac
    
    echo ""
    read -p "Нажмите Enter для возврата в главное меню..."
    clear
done
