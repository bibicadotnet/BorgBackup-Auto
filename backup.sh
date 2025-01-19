#!/bin/bash

####################################################################################################################################
# Set up Telegram bot API và chat ID
BOT_API_KEY="xxxxxxx:xxxxx-xxxxx_xxxxxxxx"
CHAT_ID="xxxxxxxx"

# Thiết lập biến cấu hình cho việc backup

# Đường dẫn tới kho lưu trữ Borg
# Đây là nơi Borg sẽ lưu trữ các bản sao lưu, có thể là một thư mục cục bộ hoặc một kho lưu trữ trên một máy chủ từ xa.
BORG_REPO="/root/borg-temp/borg-repo"

# Đây là các thư mục, file ... chứa dữ liệu cần sao lưu. 
# Ví dụ: /home và /var/spool/cron/crontabs/root (phân cách nhau bằng khoảng trắng)
BACKUP_DIR="/home /var/spool/cron/crontabs/root"

# Cấu hình cho Rclone để đồng bộ dữ liệu lên cloud
# Ví dụ cấu hình Cloudflare R2, Google Drive trên Rclone, và đường dẫn đích (borg-backup/bibica-net).
RCLONE_REMOTE="cloudflare-r2:/borg-backup/bibica-net"
RCLONE_REMOTE2="google-drive:/borg-backup/bibica-net"

# Số lượng bản backup được giữ lại mỗi giờ. 
# Giữ 24 bản backup cho 24 giờ gần nhất (1h 1 bản)
KEEP_HOURLY=24

# Số lượng bản backup được giữ lại trong bao nhiêu ngày
# Trong trường hợp này, giữ 31 bản backup, tức là giữ lại 1 bản backup mỗi ngày trong 31 ngày gần nhất.
KEEP_DAILY=31

# Tham số này quyết định số lượng bản backup được giữ lại mỗi tháng. 
# Trong trường hợp này, giữ lại mỗi tháng, nghĩa là 12 bản backup cho một năm hoặc 24 bản backup cho hai năm.
KEEP_MONTHLY=1

# Thời gian chạy kiểm tra lại toàn bộ dữ liệu backup có bị lỗi không (quan trọng)
# Trên hệ thống quan trọng, 1 ngày kiểm tra 1 lần như mặc định
# Trên hệ thống thông thường, 7-14-30 ngày kiểm tra 1 lần là đủ
VERIFY_INTERVAL=86400  # 24 giờ tính bằng giây
LAST_VERIFY_FILE="/var/log/borgbackup/borg-last-verify"

# Đường dẫn tới tệp log của script sao lưu
# Kiểm tra lịch sử sao lưu và xử lý các sự cố khi cần.
LOG_FILE="/var/log/borgbackup/borg-backup.log"
MAX_LOG_SIZE=10485760  # 10MB (tính bằng byte)

# Đường dẫn lock file
LOCKFILE="/var/log/borgbackup/borg-backup.lock"
LOCK_TIMEOUT=3600  # 1 giờ (tính bằng giây)
####################################################################################################################################

# Kiểm tra root privileges
if [ "$(id -u)" != "0" ]; then
    echo "Script này cần chạy với quyền root"
    exit 1
fi

# Giảm mức ưu tiên CPU và I/O của script để giảm ảnh hưởng đến hiệu suất hệ thống
renice -n 19 -p $$ > /dev/null 2>&1  # Đặt mức ưu tiên CPU thấp nhất cho script
ionice -c 2 -n 7 -p $$ > /dev/null 2>&1  # Đặt mức ưu tiên I/O thấp nhất ở chế độ "best-effort"

# Hàm ghi log
log_message() {
    local level="$1"  # Mức độ log (ví dụ: WARNING, ERROR, INFO)
    local message="$2"  # Nội dung thông báo log
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')  # Thời gian hiện tại

    # Kiểm tra dung lượng file log
    if [ -f "$LOG_FILE" ] && [ $(stat -c %s "$LOG_FILE") -ge $MAX_LOG_SIZE ]; then
        echo -e "[$timestamp] [INFO] File log vượt quá dung lượng $MAX_LOG_SIZE bytes. Đang xử lý..." >> "$LOG_FILE"

        # Lọc chỉ giữ lại WARNING và ERROR
        grep -E '^\[.*\] \[(WARNING|ERROR)\]' "$LOG_FILE" > "$TEMP_LOG_FILE"
        mv "$TEMP_LOG_FILE" "$LOG_FILE"

        # Kiểm tra lại dung lượng sau khi lọc
        if [ $(stat -c %s "$LOG_FILE") -ge $MAX_LOG_SIZE ]; then
            echo -e "[$timestamp] [INFO] File log vẫn vượt quá dung lượng sau khi lọc. Cắt bớt log cũ..." >> "$LOG_FILE"
            
            # Cắt bớt các dòng cũ, chỉ giữ lại 100 dòng cuối
            tail -n 100 "$LOG_FILE" > "$TEMP_LOG_FILE"
            mv "$TEMP_LOG_FILE" "$LOG_FILE"
        fi
    fi

    # Ghi log mới vào file log
    echo -e "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # In log ra màn hình
    echo -e "[$level] $message"
}

# Hàm kiểm tra xem có nên chạy verify không
should_run_verify() {
    # Nếu file không tồn tại, tạo mới với timestamp hiện tại
    if [ ! -f "$LAST_VERIFY_FILE" ]; then
        echo "$(date +%s)" > "$LAST_VERIFY_FILE"
        return 0
    fi

    last_verify=$(cat "$LAST_VERIFY_FILE")
    current_time=$(date +%s)
    elapsed=$((current_time - last_verify))

    # Chạy verify nếu đã qua VERIFY_INTERVAL
    if [ $elapsed -ge $VERIFY_INTERVAL ]; then
        echo "$current_time" > "$LAST_VERIFY_FILE"
        return 0
    fi
    return 1
}

# Hàm verify với logging và thông báo
perform_verify() {
    if should_run_verify; then
        # Ghi vào log để biết quá trình verify bắt đầu
        log_message "INFO" "Bắt đầu verify backup..."

        # Thực hiện verify, vừa hiện ra màn hình vừa capture vào error_log
        local error_log=""
        error_log=$(borg check --verify-data -v "$BORG_REPO" 2>&1 | tee /dev/tty)
        local verify_status=$?

        # Kiểm tra nếu có thông báo "Finished full repository check, no problems found" và "Archive consistency check complete, no problems found"
        if echo "$error_log" | grep -q "Finished full repository check, no problems found" && \
           echo "$error_log" | grep -q "Archive consistency check complete, no problems found"; then
            # Nếu không có vấn đề, ghi vào log với mức độ INFO và không gửi Telegram
            log_message "INFO" "Verify backup thành công (không có vấn đề)"
            log_message "INFO" "Chi tiết:\n$(
                echo "$error_log" | grep -m 1 "Finished full repository check, no problems found"
                echo "$error_log" | grep -m 1 "Archive consistency check complete, no problems found"
            )"
        elif [ $verify_status -ne 0 ]; then
            # Nếu có lỗi, ghi vào log và gửi thông báo Telegram
            log_message "ERROR" "Verify thất bại với lỗi:\n$error_log"
            send_telegram_message "❌ Verify thất bại!" "$error_log"
            return 1
        else
            # Kiểm tra các cảnh báo (WARNING)
            if echo "$error_log" | grep -qi "WARNING"; then
                log_message "WARNING" "Verify có cảnh báo:\n$error_log"
                send_telegram_message "⚠️ Verify có cảnh báo" "$error_log"
            else
                log_message "INFO" "Verify backup thành công"
            fi
        fi
    else
        log_message "INFO" "Bỏ qua verify (chưa đến thời gian)"
    fi
    return 0
}

# Hàm kiểm tra điều kiện tiên quyết
check_prerequisites() {
    # Kiểm tra borg đã được cài đặt
    if ! command -v borg &> /dev/null; then
        log_message "ERROR" "BorgBackup chưa được cài đặt. Vui lòng cài đặt BorgBackup để tiếp tục."
        return 1
    fi

    # Kiểm tra rclone đã được cài đặt
    if ! command -v rclone &> /dev/null; then
        log_message "ERROR" "Rclone chưa được cài đặt. Vui lòng cài đặt Rclone để tiếp tục."
        return 1
    fi

    # Kiểm tra thư mục và file backup tồn tại
    for path in $BACKUP_DIR; do
        if [ ! -e "$path" ]; then
            log_message "ERROR" "Đường dẫn chứa dữ liệu cần sao lưu không tồn tại: $path"
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
            exec_command="borg create --compression lz4 \"$BORG_REPO::$BACKUP_NAME\" $BACKUP_DIR"
        fi
        
        log_message "INFO" "Thử $operation lần $((retry_count + 1))..."
        
        # Thực thi lệnh và capture output
        error_log=$(eval "$exec_command" 2>&1)
        if [ $? -eq 0 ]; then
            log_message "INFO" "$operation thành công!"
            return 0
        else
            # Kiểm tra lỗi "file changed while we backed it up"
			# Các file, thư mục backup đang có ứng dụng khác chiếm quyền ghi, khiến born không đọc được
            if echo "$error_log" | grep -q "file changed while we backed it up"; then
                log_message "WARNING" "Phát hiện file bị thay đổi trong quá trình backup, đợi 30s và thử lại...\n$error_log"
                sleep 30
                continue # Thử lại ngay mà không tăng retry_count
            fi
            
            local attempt=$((retry_count + 1))
            log_message "ERROR" "Lần thử $attempt thất bại:\n$error_log"
            
            if ! should_retry "$error_log"; then
                log_message "ERROR" "Lỗi nghiêm trọng, không retry"
                send_telegram_message "❌ $operation thất bại với lỗi nghiêm trọng!" "$error_log"
                return 1
            fi
            
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
    LOCK_PID=$(cat "$LOCKFILE")
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        LOCK_AGE=$(($(date +%s) - $(date +%s -r "$LOCKFILE")))
        if [ "$LOCK_AGE" -gt "$LOCK_TIMEOUT" ]; then
            log_message "WARNING" "Lock file quá cũ (${LOCK_AGE}s). Xóa và tiếp tục."
            rm -f "$LOCKFILE"
        else
            log_message "WARNING" "Script đang chạy (${LOCK_AGE}s). Thoát."
            exit 1
        fi
    else
        # Process không còn tồn tại, xóa lock file cũ
        log_message "WARNING" "Lock file tồn tại nhưng process đã kết thúc. Xóa và tiếp tục."
        rm -f "$LOCKFILE"
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

# Borg Verify - kiểm tra các bản backup
perform_verify
if [ $? -ne 0 ]; then
    exit 1
fi

# Prune các backup cũ
log_message "INFO" "Bắt đầu prune backup cũ..."
perform_backup_with_retry "borg prune \
    --keep-hourly=$KEEP_HOURLY \
    --keep-daily=$KEEP_DAILY \
    --keep-monthly=$KEEP_MONTHLY \
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

# Đồng bộ backup lên RCLONE_REMOTE
log_message "INFO" "Đồng bộ backup lên: $RCLONE_REMOTE..."
perform_backup_with_retry "rclone sync \"$BORG_REPO\" \"$RCLONE_REMOTE\" \
    --transfers=30 --checkers=30 --size-only" "Rclone Sync $RCLONE_REMOTE"
if [ $? -ne 0 ]; then
    exit 1
fi

# Đồng bộ backup lên RCLONE_REMOTE2
log_message "INFO" "Đồng bộ backup lên: $RCLONE_REMOTE2..."
perform_backup_with_retry "rclone sync \"$BORG_REPO\" \"$RCLONE_REMOTE2\" \
    --transfers=30 --checkers=30 --size-only" "Rclone Sync $RCLONE_REMOTE2"
if [ $? -ne 0 ]; then
    exit 1
fi

# Kết thúc script thành công - không gửi thông báo Telegram
log_message "INFO" "Backup hoàn thành!"
exit 0
