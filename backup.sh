#!/bin/bash

# Kiểm tra root privileges
if [ "$(id -u)" != "0" ]; then
    echo "Script này cần chạy với quyền root"
    exit 1
fi

# Tự động renice chính script này
renice -n 19 -p $$ > /dev/null 2>&1
ionice -c 2 -n 7 -p $$ > /dev/null 2>&1

# Set up Telegram bot API và chat ID
BOT_API_KEY="6360723418:AAE-nXLphf2dGqEM_oKOMTvwQq9Otis5hQg"
CHAT_ID="489842337"

# Thiết lập biến cấu hình
BORG_REPO="/root/borg-temp/borg-repo"
BACKUP_DIR="/home /var/spool/cron/crontabs/root"
RCLONE_REMOTE="cloudflare-r2:/borg-backup/bibica-net"
LOG_FILE="/var/log/borg-backup.log"
export PATH=$PATH:/usr/local/bin:/usr/bin:/bin


# Hàm ghi log
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    echo "[$level] $message"
}

# Hàm kiểm tra điều kiện tiên quyết
check_prerequisites() {
    # Kiểm tra borg đã được cài đặt
    if ! command -v borg &> /dev/null; then
        log_message "ERROR" "Borg backup chưa được cài đặt"
        return 1
    fi

    # Kiểm tra rclone đã được cài đặt
    if ! command -v rclone &> /dev/null; then
        log_message "ERROR" "Rclone chưa được cài đặt"
        return 1
    fi

    # Kiểm tra thư mục và file backup tồn tại
    for path in $BACKUP_DIR; do
        if [ ! -e "$path" ]; then
            log_message "ERROR" "Đường dẫn backup không tồn tại: $path"
            return 1
        fi
    done

    # Kiểm tra và tạo thư mục borg repository nếu cần
    if [ ! -d "$BORG_REPO" ]; then
        log_message "INFO" "Tạo mới Borg repository: $BORG_REPO"
        mkdir -p "$BORG_REPO"
        borg init --encryption=none "$BORG_REPO"
        if [ $? -ne 0 ]; then
            log_message "ERROR" "Không thể khởi tạo Borg repository"
            return 1
        fi
    fi

    # Tạo thư mục log nếu chưa tồn tại
    log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
    fi

    return 0
}

# Hàm gửi thông báo Telegram với log chi tiết
send_telegram_message() {
    local message="$1"
    local error_log="$2"
    
    # Nếu là thông báo thành công và không có log lỗi, không gửi
    if [[ "$message" == *"✅"* ]] && [ -z "$error_log" ]; then
        return 0
    fi
    
    # Chuẩn bị thông báo với thông tin chi tiết
    local full_message="$message"
    if [ ! -z "$error_log" ]; then
        # Thêm thông tin thời gian
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        full_message="${full_message}\n\n🕒 Thời gian: ${timestamp}"
        # Thêm chi tiết lỗi
        full_message="${full_message}\n\n📝 Chi tiết:\n<code>${error_log}</code>"
        # Thêm thông tin hệ thống
        local hostname=$(hostname)
        local system_info=$(uname -a)
        full_message="${full_message}\n\n🖥 Máy chủ: ${hostname}\n💻 Hệ thống: ${system_info}"
    fi
    
    curl -s -X POST "https://api.telegram.org/bot$BOT_API_KEY/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d "text=${full_message}" \
        -d "parse_mode=HTML" \
        > /dev/null
    
    # Ghi log
    log_message "INFO" "Đã gửi thông báo Telegram"
}

# Đường dẫn lock file
LOCKFILE="/var/lock/borg-backup.lock"
LOCK_TIMEOUT=3600  # 1 giờ (tính bằng giây)

# Hàm tạo tên backup độc nhất với random
generate_unique_backup_name() {
    local datestamp=$(date +%Y-%m-%d-%H-%M-%S)
    echo "backup-${datestamp}-$RANDOM"
}

# Hàm kiểm tra xem lỗi có nên retry không
should_retry() {
    local error_message="$1"
    
    # Danh sách các lỗi không nên retry
    local fatal_errors=(
        "Repository does not exist"
        "Connection refused"
        "No such file or directory"
        "Permission denied"
        "Authentication failed"
    )
    
    for error in "${fatal_errors[@]}"; do
        if echo "$error_message" | grep -q "$error"; then
            return 1
        fi
    done
    
    return 0
}

# Hàm thực hiện backup với retry logic và log lỗi chi tiết
perform_backup_with_retry() {
    local command="$1"
    local operation="$2"
    local max_retries=3
    local retry_delay=5
    local retry_count=0
    local error_log=""
    
    while [ $retry_count -lt $max_retries ]; do
        # Chuẩn bị command cần thực thi
        local exec_command="$command"
        if [ "$operation" = "Borg Create" ]; then
            BACKUP_NAME=$(generate_unique_backup_name)
            exec_command="borg create --stats \"$BORG_REPO::$BACKUP_NAME\" $BACKUP_DIR"
        fi
        
        log_message "INFO" "Thử $operation lần $((retry_count + 1))..."
        
        # Thực thi lệnh và capture output
        error_log=$(eval "$exec_command" 2>&1)
        if [ $? -eq 0 ]; then
            log_message "INFO" "$operation thành công!"
            return 0
        else
            local attempt=$((retry_count + 1))
            log_message "ERROR" "Lần thử $attempt thất bại:\n$error_log"
            
            # Kiểm tra xem có nên retry không
            if ! should_retry "$error_log"; then
                log_message "ERROR" "Lỗi nghiêm trọng, không retry"
                send_telegram_message "❌ $operation thất bại với lỗi nghiêm trọng!" "$error_log"
                return 1
            fi
            
            # Gửi thông báo lỗi ngay khi gặp lỗi
            send_telegram_message "⚠️ $operation thất bại lần thử $attempt/$max_retries" "$error_log"
            
            sleep $retry_delay
            retry_count=$((retry_count + 1))
        fi
    done
    
    send_telegram_message "❌ $operation thất bại sau $max_retries lần thử!" "$error_log"
    return 1
}

# Kiểm tra điều kiện tiên quyết
log_message "INFO" "Kiểm tra điều kiện tiên quyết..."
if ! check_prerequisites; then
    send_telegram_message "❌ Kiểm tra điều kiện tiên quyết thất bại!" "$(tail -n 50 "$LOG_FILE")"
    exit 1
fi

# Kiểm tra lock file
if [ -e "$LOCKFILE" ]; then
    LOCK_AGE=$(($(date +%s) - $(date +%s -r "$LOCKFILE")))
    if [ "$LOCK_AGE" -gt "$LOCK_TIMEOUT" ]; then
        log_message "WARNING" "Lock file quá cũ (${LOCK_AGE}s). Xóa và tiếp tục."
        rm -f "$LOCKFILE"
    else
        log_message "WARNING" "Script đang chạy (${LOCK_AGE}s). Thoát."
        send_telegram_message "⚠️ Không thể chạy backup - Script đang chạy" "Lock file age: ${LOCK_AGE}s"
        exit 1
    fi
fi

# Sử dụng flock để kiểm tra và tạo lock file
exec 200>"$LOCKFILE"
flock -n 200 || {
    log_message "WARNING" "Script đang chạy (lock file). Thoát."
    send_telegram_message "⚠️ Không thể chạy backup - Script đang chạy" "Lock file exists"
    exit 1
}

# Ghi PID vào lock file
echo $$ > "$LOCKFILE"

# Đảm bảo lock file được xóa khi script kết thúc
trap 'rm -f "$LOCKFILE"; log_message "INFO" "Script kết thúc."; exit' EXIT SIGINT SIGTERM

# Backup bằng Borg với retry logic
log_message "INFO" "Bắt đầu tạo backup với Borg..."
perform_backup_with_retry "" "Borg Create"
if [ $? -ne 0 ]; then
    exit 1
fi

# Prune các backup cũ
log_message "INFO" "Bắt đầu prune backup cũ..."
perform_backup_with_retry "borg prune \
    --keep-daily=30 \
    --keep-monthly=1 \
    \"$BORG_REPO\"" "Borg Prune"
if [ $? -ne 0 ]; then
    exit 1
fi

# Compact repository
log_message "INFO" "Bắt đầu compact repository..."
perform_backup_with_retry "borg compact \"$BORG_REPO\"" "Borg Compact"
if [ $? -ne 0 ]; then
    exit 1
fi

# Đồng bộ backup lên Cloudflare R2
log_message "INFO" "Đồng bộ backup lên Cloudflare R2..."
perform_backup_with_retry "rclone sync \"$BORG_REPO\" \"$RCLONE_REMOTE\" \
    --transfers=30 --checkers=30 --size-only" "Rclone Sync"
if [ $? -ne 0 ]; then
    exit 1
fi

# Kết thúc script thành công - không gửi thông báo
log_message "INFO" "Backup hoàn thành!"
exit 0
