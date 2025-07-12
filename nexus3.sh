#!/bin/bash

set -e

BASE_DIR="$HOME/nexus-nodes"
WATCHTOWER_DIR="$HOME/watchtower"

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
BLUE='\033[1;34m'
NC='\033[0m'

NODE_NAME=""
NODE_ID=""

show_logo() {
  echo -e "\n\n${NC}Добро пожаловать в скрипт управления нодами Nexus${NC}"
  curl -s https://raw.githubusercontent.com/pittpv/nexus-node/refs/heads/main/other/logo.sh | bash
}

print_menu() {
  show_logo
  echo ""
  echo -e "${NC}========= Меню управления нодами Nexus =========${NC}"
  echo -e "${YELLOW}1) Проверить ресурсы системы${NC}"
  echo "2) Установить Docker (последняя версия)"
  echo -e "${GREEN}3) Установить ноду Nexus${NC}"
  echo "4) Подключиться к контейнеру ноды (логи)"
  echo -e "${RED}5) Удалить ноду Nexus${NC}"
  echo "6) Остановить контейнер ноды"
  echo "7) Запустить контейнер ноды"
  echo "8) Настроить Swap-файл"
  echo "9) Увеличить лимит файловых дескрипторов"
  echo -e "${RED}0) Выход${NC}"
  echo -e "${NC}===============================================${NC}"
  echo -n "Выберите опцию: "
}

check_docker_installed() {
  if ! command -v docker &>/dev/null; then
    echo -e "${RED}Docker не установлен.${NC}"
    echo -e "${YELLOW}Выберите опцию 2 для установки Docker.${NC}"
    return 0
  fi
  return 0
}

install_docker() {
  echo -e "${GREEN}Установка Docker...${NC}"
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
  else
    echo "Docker уже установлен."
  fi

  if ! docker compose version &>/dev/null; then
    echo -e "${GREEN}Установка Docker Compose...${NC}"
    sudo curl -L "https://github.com/docker/compose/releases/download/$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
  else
    echo "Docker Compose уже установлен."
  fi
  echo -e "${GREEN}Docker и Docker Compose установлены.${NC}"
}

install_watchtower_if_needed() {
  if [ ! -f "$WATCHTOWER_DIR/docker-compose.yml" ]; then
    mkdir -p "$WATCHTOWER_DIR"

    echo -e "${YELLOW}Загрузка образа Watchtower...${NC}"
    docker pull containrrr/watchtower:latest

    cat > "$WATCHTOWER_DIR/docker-compose.yml" <<EOF
services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=3600
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_LABEL_ENABLE=true
EOF

    (cd "$WATCHTOWER_DIR" && docker compose up -d)
    echo -e "${GREEN}Watchtower установлен.${NC}"
  fi
}

prompt_node_config() {
  echo "Выберите способ указания NODE_ID:"
  echo "1) Из файла nexus-nodes.txt"
  echo "2) Ввести вручную"
  read -rp "Ваш выбор [1 или 2]: " choice

  NODE_IDS=()
  NODE_COUNT=0

  if [[ "$choice" == "1" ]]; then
    if [[ -f "nexus-nodes.txt" ]]; then
      mapfile -t NODE_IDS < nexus-nodes.txt
      NODE_COUNT=${#NODE_IDS[@]}
      echo -e "${GREEN}Используется файл nexus-nodes.txt (найдено NODE_ID: $NODE_COUNT).${NC}"
    else
      echo -e "${RED}Файл nexus-nodes.txt не найден. Создайте его и добавьте NODE_ID (каждый с новой строки).${NC}"
      return 0
    fi
  elif [[ "$choice" == "2" ]]; then
    echo -n "Сколько нод Nexus установить? [по умолчанию 1]: "
    read -r NODE_COUNT
    [[ ! "$NODE_COUNT" =~ ^[1-9][0-9]*$ ]] && NODE_COUNT=1
  else
    echo -e "${RED}Неверный выбор. Возврат в меню.${NC}"
    return 0
  fi

  echo -n "Количество потоков на ноду [1-8, по умолчанию 1]: "
  read -r THREADS
  [[ ! "$THREADS" =~ ^[1-8]$ ]] && THREADS=1

  echo -e "${GREEN}Загрузка образа nexusxyz/nexus-cli:latest...${NC}"
  docker pull nexusxyz/nexus-cli:latest

  for ((n=1; n<=NODE_COUNT; n++)); do
    if [[ "$choice" == "1" && ${#NODE_IDS[@]} -ge n ]]; then
      NODE_ID="${NODE_IDS[$((n-1))]}"
      echo "Используется NODE_ID из файла: $NODE_ID"
    else
      echo -n "Введите NODE_ID: "
      read -r NODE_ID
      while [[ -z "$NODE_ID" ]]; do
        echo -n "NODE_ID не может быть пустым. Введите снова: "
        read -r NODE_ID
      done
    fi

    SAFE_NODE_ID=$(echo "$NODE_ID" | tr -c 'a-zA-Z0-9_.-' '-')
    SAFE_NODE_ID=$(echo "$SAFE_NODE_ID" | sed -E 's/^-+//; s/-+$//; s/-+/-/g')
    NODE_NAME="nexus-$SAFE_NODE_ID"
    NODE_DIR="$BASE_DIR/$NODE_NAME"

    if [[ -d "$NODE_DIR" ]]; then
      echo -e "${YELLOW}Директория $NODE_DIR уже существует. Пропускаем эту ноду.${NC}"
      continue
    fi

    mkdir -p "$NODE_DIR"
    echo -e "\nНастройка $NODE_NAME"

    cat > "$NODE_DIR/.env" <<EOF
NODE_ID=$NODE_ID
MAX_THREADS=$THREADS
EOF

    cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  nexus-node:
    container_name: $NODE_NAME
    restart: unless-stopped
    image: nexusxyz/nexus-cli:latest
    init: true
    command: start --node-id \${NODE_ID} --max-threads \${MAX_THREADS}
    stdin_open: true
    tty: true
    env_file:
      - .env
    labels:
      - com.centurylinklabs.watchtower.enable=true
EOF

    (cd "$NODE_DIR" && docker compose up -d)
    echo -e "${GREEN}Нода '$NODE_NAME' установлена и запущена.${NC}"
  done
}

install_nexus_node() {
  check_docker_installed || return
  install_watchtower_if_needed
  prompt_node_config
}

select_node() {
  nodes=($(ls "$BASE_DIR" 2>/dev/null))
  if [ ${#nodes[@]} -eq 0 ]; then
    echo -e "${RED}❌ Ноды Nexus не найдены.${NC}"
    echo ""
    return 1
  fi

  echo -e "\n${BLUE}Выберите ноду:${NC}"
  for i in "${!nodes[@]}"; do
    node_name="${nodes[$i]}"
    container_status=$(docker ps -a --format '{{.Names}}' | grep -w "$node_name" &>/dev/null && echo "✅" || echo "❌")
    echo -e "  $((i+1))) ${GREEN}${node_name}${NC} $container_status"
  done
  echo -e "  $(( ${#nodes[@]} + 1 ))) ${YELLOW}Все ноды${NC}"
  echo -e "  0) ${YELLOW}Назад в меню${NC}"

  while true; do
    echo -ne "\nВведите номер: "
    read -r choice

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if [ "$choice" -eq 0 ]; then
        return 1
      elif [ "$choice" -le ${#nodes[@]} ]; then
        NODE_NAME="${nodes[$((choice-1))]}"
        return 0
      elif [ "$choice" -eq $(( ${#nodes[@]} + 1 )) ]; then
        NODE_NAME="ALL"
        return 0
      fi
    fi
    echo -e "${RED}Неверный выбор. Введите число от 0 до $((${#nodes[@]} + 1)).${NC}"
  done
}

remove_node() {
  if ! select_node; then
    return
  fi

  if [ "$NODE_NAME" = "ALL" ]; then
    echo -e "${YELLOW}Удалить ВСЕ ноды? [y/N]: ${NC}"
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      echo -e "${YELLOW}Отмена.${NC}"
      return
    fi

    for dir in "$BASE_DIR"/*; do
      [ -d "$dir" ] || continue
      (cd "$dir" && docker compose down -v)
      rm -rf "$dir"
      echo -e "${GREEN}Удалено: $(basename "$dir")${NC}"
    done

    if [ -d "$BASE_DIR" ] && [ -z "$(ls -A "$BASE_DIR")" ]; then
      rm -rf "$BASE_DIR"
      echo -e "${GREEN}Директория '$BASE_DIR' удалена.${NC}"
    fi
  else
    NODE_DIR="$BASE_DIR/$NODE_NAME"
    (cd "$NODE_DIR" && docker compose down -v)
    rm -rf "$NODE_DIR"
    echo -e "${GREEN}Нода '$NODE_NAME' удалена.${NC}"
  fi

  if [ -d "$WATCHTOWER_DIR" ]; then
    echo -ne "${YELLOW}Удалить Watchtower? [y/N]: ${NC}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
      (cd "$WATCHTOWER_DIR" && docker compose down -v)
      rm -rf "$WATCHTOWER_DIR"
      echo -e "${GREEN}Watchtower удалён.${NC}"
    else
      echo -e "${YELLOW}Watchtower сохранён.${NC}"
    fi
  fi
}

stop_containers() {
  if ! select_node; then
    return
  fi

  if [ "$NODE_NAME" = "ALL" ]; then
    echo -e "${YELLOW}Остановка ВСЕХ нод...${NC}"
    for dir in "$BASE_DIR"/*; do
      [ -d "$dir" ] || continue
      (cd "$dir" && docker compose down)
      echo -e "${GREEN}Остановлена: $(basename "$dir")${NC}"
    done
  else
    (cd "$BASE_DIR/$NODE_NAME" && docker compose down)
    echo -e "${GREEN}Нода '$NODE_NAME' остановлена.${NC}"
  fi
}

start_containers() {
  if ! select_node; then
    return
  fi

  if [ "$NODE_NAME" = "ALL" ]; then
    echo -e "${YELLOW}Запуск ВСЕХ нод...${NC}"
    for dir in "$BASE_DIR"/*; do
      [ -d "$dir" ] || continue
      (cd "$dir" && docker compose up -d)
      echo -e "${GREEN}Запущена: $(basename "$dir")${NC}"
    done
  else
    (cd "$BASE_DIR/$NODE_NAME" && docker compose up -d)
    echo -e "${GREEN}Нода '$NODE_NAME' запущена.${NC}"
  fi
}

attach_nexus_container() {
    echo -e "${GREEN}📋 Подключение к контейнерам Nexus через tmux...${NC}"

    if ! command -v tmux &> /dev/null; then
        echo -e "${RED}❌ tmux не установлен. Установите его сначала.${NC}"
        return 0
    fi

    containers=($(docker ps --format "{{.Names}}" | grep "nexus" | sort))
    total=${#containers[@]}

    if [ $total -eq 0 ]; then
        echo -e "${RED}❌ Нет запущенных контейнеров Nexus.${NC}"
        return
    fi

    echo -e "${GREEN}🔍 Найдено контейнеров: $total.${NC}"

    max_per_session=4
    session_count=$(( (total + max_per_session - 1) / max_per_session ))

    echo -e "${YELLOW}🧭 Будет создано сессий tmux: $session_count.${NC}"
    echo
    echo -e "${GREEN}✅ Управление в tmux:${NC}"
    echo -e "   Ctrl+b → o — переключение между панелями"
    echo -e "   Ctrl+b → w — список окон"
    echo -e "   Ctrl+b → d — отключиться от сессии"
    echo
    echo -e "${YELLOW}⏳ Запуск через 5 секунд... Ctrl+C для отмены.${NC}"
    sleep 5

    session_ids=()
    container_index=1

    for ((s=0; s<session_count; s++)); do
        session_name="nexus_attach_$((s+1))"
        session_ids+=("$session_name")

        if tmux has-session -t "$session_name" 2>/dev/null; then
            echo -e "${YELLOW}🧹 Удаляем старую сессию '$session_name'...${NC}"
            tmux kill-session -t "$session_name"
            sleep 1
        fi

        echo -e "🛠 Создаём сессию $session_name..."

        start=$((s * max_per_session))
        group=("${containers[@]:$start:$max_per_session}")

        tmux new-session -d -s "$session_name" -n "[${container_index}] ${group[0]}" "docker attach ${group[0]}"
        ((container_index++))

        for ((i=1; i<${#group[@]}; i++)); do
            tmux split-window -h -t "$session_name"
            tmux send-keys -t "$session_name" "clear; echo \"Контейнер [${container_index}] ${group[$i]}\"; docker attach ${group[$i]}" C-m
            ((container_index++))
        done

        tmux select-layout -t "$session_name" tiled
    done

    echo
    echo -e "${GREEN}🚀 Сессии tmux готовы.${NC}"
    echo -e "Подключитесь командой: ${BLUE}tmux attach -t session_name${NC}"
    for sid in "${session_ids[@]}"; do
        echo -e "  👉  ${BLUE}tmux attach -t $sid${NC}"
    done

    echo
    echo -e "${GREEN}ℹ️ Подключаемся к первой сессии: ${BLUE}${session_ids[0]}${NC}"
    sleep 2

    tmux attach -t "${session_ids[0]}"
}

create_swap() {
  echo ""

  if swapon --show | grep -q '^/swapfile'; then
    SWAP_ACTIVE=true
    SWAP_SIZE=$(swapon --show --bytes | awk '/\/swapfile/ { printf "%.0f", $3 / 1024 / 1024 }')
    echo -e "${YELLOW}Найден активный swap-файл: /swapfile (${SWAP_SIZE} MB)${NC}"
  else
    SWAP_ACTIVE=false
    echo -e "${YELLOW}Активный swap-файл не найден.${NC}"

    if [ -f /swapfile ]; then
      SWAP_INACTIVE_SIZE=$(ls -lh /swapfile | awk '{print $5}')
      echo -e "${YELLOW}Найден неактивный swap-файл: /swapfile (${SWAP_INACTIVE_SIZE}).${NC}"

      echo -n "Активировать его? [y/N]: "
      read -r activate_choice
      if [[ "$activate_choice" =~ ^[Yy]$ ]]; then
        sudo mkswap /swapfile
        sudo swapon /swapfile
        echo -e "${GREEN}Swap-файл активирован.${NC}"

        if grep -i -q microsoft /proc/version; then
          echo -n "Добавить автозагрузку swap в /etc/wsl.conf? [y/N]: "
          read -r wsl_startup
          if [[ "$wsl_startup" =~ ^[Yy]$ ]]; then
            sudo mkdir -p /etc
            if ! grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then
              echo -e "\n[boot]" | sudo tee -a /etc/wsl.conf > /dev/null
            fi
            if ! grep -q 'swapon /swapfile' /etc/wsl.conf 2>/dev/null; then
              echo 'command = "swapon /swapfile"' | sudo tee -a /etc/wsl.conf > /dev/null
              echo -e "${GREEN}Команда добавлена в /etc/wsl.conf.${NC}"
            else
              echo -e "${YELLOW}Команда уже есть в /etc/wsl.conf.${NC}"
            fi
            echo " "
            echo -e "${NC}Для применения изменений:${NC}"
            echo -e "${YELLOW}1. Выйдите из скрипта (опция 0)"
            echo -e "2. Выполните в PowerShell/CMD: ${GREEN}wsl --shutdown${YELLOW}"
            echo -e "3. Перезапустите WSL${NC}"
            echo -e "${YELLOW}Возврат в меню через 10 секунд...${NC}"
            sleep 10
            return
          fi
        else
          if ! grep -q '/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
            echo -e "${GREEN}Добавлено в /etc/fstab.${NC}"
          else
            echo -e "${YELLOW}Swap уже есть в /etc/fstab.${NC}"
          fi
        fi
        return
      else
        echo -n "Удалить неактивный swap-файл? [y/N]: "
        read -r remove_choice
        if [[ "$remove_choice" =~ ^[Yy]$ ]]; then
          sudo rm -f /swapfile
          sudo sed -i '/\/swapfile/d' /etc/fstab
          echo -e "${GREEN}Файл удалён.${NC}"
        else
          echo -e "${YELLOW}Файл сохранён.${NC}"
        fi
        return
      fi
    fi
  fi

  echo -e "${NC}---------- Меню Swap-файла ----------"
  echo "1) Создать Swap 8GB"
  echo "2) Создать Swap 16GB"
  echo "3) Создать Swap 32GB"
  echo "4) Удалить Swap-файл"
  echo -e "${RED}0) Назад в меню${NC}"
  echo -e "${NC}------------------------------------"
  echo -n "Выберите опцию: "
  read -r swap_choice

  case $swap_choice in
    1) SWAP_SIZE_MB=8192 ;;
    2) SWAP_SIZE_MB=16384 ;;
    3) SWAP_SIZE_MB=32768 ;;
    4)
      SWAP_FILE=$(swapon --show --noheadings --raw | awk '$1 ~ /^\// {print $1}' | head -n1)

      if [ -z "$SWAP_FILE" ]; then
        echo -e "${RED}❌ Активный swap-файл не найден.${NC}"
        return
      fi

      echo -e "${YELLOW}Найден swap-файл: ${SWAP_FILE}${NC}"

      echo -e "${YELLOW}Отключаем swap...${NC}"
      if ! sudo swapoff "$SWAP_FILE"; then
        echo -e "${RED}❌ Ошибка. Возможно, swap управляется системой.${NC}"
        return
      fi

      if [ -f "$SWAP_FILE" ] && stat -c %F "$SWAP_FILE" | grep -q 'regular file'; then
        echo -e "${YELLOW}Удаляем файл...${NC}"
        sudo rm -f "$SWAP_FILE"

        if grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null; then
          sudo sed -i "\|$SWAP_FILE|d" /etc/fstab
          echo -e "${GREEN}Удалено из /etc/fstab.${NC}"
        fi

        if grep -qi microsoft /proc/version; then
          if grep -q "swapon $SWAP_FILE" /etc/wsl.conf 2>/dev/null; then
            sudo sed -i "\|swapon $SWAP_FILE|d" /etc/wsl.conf
            echo -e "${GREEN}Удалено из /etc/wsl.conf.${NC}"
          fi
        fi

        echo -e "${GREEN}Файл ${SWAP_FILE} удалён.${NC}"
      else
        echo -e "${RED}❌ ${SWAP_FILE} не является файлом или не существует.${NC}"
      fi

      return
      ;;
    0) return ;;
    *) echo -e "${RED}Неверный выбор.${NC}"; return ;;
  esac

  echo -e "${GREEN}Создаём swap-файл (${SWAP_SIZE_MB}MB)...${NC}"
  sudo dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE_MB status=progress
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile

  if grep -i -q microsoft /proc/version; then
    echo -e "${YELLOW}Для WSL добавьте swapon в /etc/wsl.conf вручную.${NC}"
  else
    if ! grep -q '/swapfile' /etc/fstab; then
      echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
      echo -e "${GREEN}Добавлено в /etc/fstab.${NC}"
    fi
  fi

  echo -e "${GREEN}Swap-файл (${SWAP_SIZE_MB}MB) создан и активирован.${NC}"
}

increase_ulimit() {
  echo -e "${YELLOW}Увеличиваем лимит файловых дескрипторов...${NC}"
  OLD_LIMIT=$(ulimit -n)
  echo -e "Текущий лимит: ${GREEN}${OLD_LIMIT}${NC}"

  ulimit -n 65535 2>/dev/null

  NEW_LIMIT=$(ulimit -n)
  echo -e "Новый лимит: ${GREEN}${NEW_LIMIT}${NC}"
}

check_system_resources() {
    TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    TOTAL_CPU_CORES=$(nproc)
    AVAILABLE_RAM_GB=$((TOTAL_RAM_GB - 2))
    AVAILABLE_CPU_CORES=$((TOTAL_CPU_CORES - 1))

    MAX_NODES=$(( (AVAILABLE_RAM_GB / 4) < (AVAILABLE_CPU_CORES / 2) ? (AVAILABLE_RAM_GB / 4) : (AVAILABLE_CPU_CORES / 2) ))
    MAX_NODES=$(( MAX_NODES < 1 ? 1 : (MAX_NODES > 8 ? 8 : MAX_NODES) ))
    CPUS_PER_NODE=$(awk -v avail="$AVAILABLE_CPU_CORES" -v max="$MAX_NODES" 'BEGIN{printf "%.1f", avail/max}')

    echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║          Анализ системы и рекомендации             ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}💻 Процессор:${NC}"
    echo "  Модель: $(lscpu | grep 'Model name' | sed 's/Model name: *//')"
    echo "  Ядер: ${TOTAL_CPU_CORES}"
    echo "  Доступно для нод: ${AVAILABLE_CPU_CORES}"
    echo ""
    echo -e "${GREEN}🧠 Память:${NC}"
    echo "  Всего RAM: ${TOTAL_RAM_GB}GB"
    echo "  Доступно RAM: ${AVAILABLE_RAM_GB}GB"
    echo "  Свободно: $(free -h | awk '/^Mem:/{print $7}')"
    echo ""
    echo -e "${GREEN}💾 Диск:${NC}"
    if grep -q "WSL" /proc/version 2>/dev/null; then
        df -h /mnt/c | tail -n 1 | awk '{print "  Диск C: " $2 " всего, " $4 " свободно (" $5 " занято)"}'
    else
        df -h / | tail -n 1 | awk '{print "  Корневой раздел: " $2 " всего, " $4 " свободно (" $5 " занято)"}'
    fi
    echo ""
    echo -e "${GREEN}🔄 Swap:${NC}"
    if swapon --show | grep -q '/'; then
        swapon --show --bytes | awk 'NR>1 { printf "  Swap-файл: %.1fGB\n", $3 / 1024 / 1024 / 1024 }'
    else
        echo "  Swap не настроен"
    fi
    echo ""
    echo -e "${GREEN}🐳 Docker:${NC}"
    if command -v docker &>/dev/null; then
        DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
        echo "  Установлен (версия: $DOCKER_VERSION)"
    else
        echo "  Не установлен (используйте опцию 2)"
    fi
    echo ""
    echo -e "${GREEN}📈 Рекомендации:${NC}"
    echo "  Оптимальное количество нод: ${MAX_NODES}"
    echo "  CPU на ноду: ${CPUS_PER_NODE} ядер"
    echo "  RAM на ноду: ~4GB"
    INT_CPUS_PER_NODE=${CPUS_PER_NODE%.*}
    echo "  Всего ресурсов: $((MAX_NODES * 4))GB RAM, $((MAX_NODES * INT_CPUS_PER_NODE)) ядер CPU"
    echo ""
}

while true; do
  print_menu
  read -r choice
  case $choice in
    1) check_system_resources ;;
    2) install_docker ;;
    3) install_nexus_node ;;
    4) attach_nexus_container ;;
    5) remove_node ;;
    6) stop_containers ;;
    7) start_containers ;;
    8) create_swap ;;
    9) increase_ulimit ;;
    0) echo "Выход..."; exit 0 ;;
    *) echo "Неверный ввод. Выберите от 0 до 9." ;;
  esac
  echo ""
  echo -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read -r
  clear
done
