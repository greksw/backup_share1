#!/bin/bash

# Пути к лог-файлу и точкам монтирования
LOG_FILE="/mnt/srv-ts5.log"
MOUNT_POINT1="/mnt/srv-ts5"
MOUNT_POINT2="/mnt/srv-ts5-tr"

# Telegram Bot API параметры
TOKEN="1115999333:dddmuRf8mAfEpSjXZLdffghhlQu0jY"
CHAT_ID="116667787"


# Название скрипта для уведомлений
SCRIPT_NAME="Резервное копирование srv-ts5_d:\*"

# Функция для записи логов и отправки уведомлений
log_and_notify() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $message" >> $LOG_FILE
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d chat_id=$CHAT_ID -d text="$SCRIPT_NAME: $message" > /dev/null
}

# IP адреса компьютеров
HOST1="192.168.2.13"
HOST2="192.168.2.200"

# Пароль для архива
ZIP_PASSWORD="1234567890"

# Создание имени архива на основе текущей даты
DATE=$(date '+%Y-%m-%d')
ARCHIVE_NAME="srv-ts5_backup_$DATE.zip"

# Проверка доступности хостов
ping -c 1 $HOST1 > /dev/null 2>&1
HOST1_STATUS=$?

ping -c 1 $HOST2 > /dev/null 2>&1
HOST2_STATUS=$?

# Если оба хоста доступны
if [ $HOST1_STATUS -eq 0 ] && [ $HOST2_STATUS -eq 0 ]; then
    log_and_notify "✅ Оба хоста доступны, монтируем шары..."

    # Монтируем шары
    sudo mount -t cifs //192.168.2.13/d$/test $MOUNT_POINT1 -o username=user1,password=123,domain=test.loc,iocharset=utf8,file_mode=0777,dir_mode=0777
    MOUNT1_STATUS=$?

    sudo mount -t cifs //192.168.2.200/srv-win/srv-ts5 $MOUNT_POINT2 -o username=user2,password=123,domain=workgroup,iocharset=utf8,file_mode=0777,dir_mode=0777
    MOUNT2_STATUS=$?

    # Если монтирование прошло успешно
    if [ $MOUNT1_STATUS -eq 0 ] && [ $MOUNT2_STATUS -eq 0 ]; then
        log_and_notify "✅ Шары успешно примонтированы, выполняем архивирование..."

        # Создание архива с паролем
        zip -r -P $ZIP_PASSWORD /mnt/$ARCHIVE_NAME $MOUNT_POINT1
        ZIP_STATUS=$?

        if [ $ZIP_STATUS -eq 0 ]; then
            log_and_notify "✅ Архивирование успешно завершено: $ARCHIVE_NAME."
        else
            log_and_notify "❌ Ошибка при создании архива."
        fi

        # Размонтируем шары
        log_and_notify "🔄 Выполняем отмонтирование..."
        sudo umount $MOUNT_POINT1
        sudo umount $MOUNT_POINT2
        log_and_notify "✅ Шары успешно отмонтированы."
    else
        log_and_notify "❌ Не удалось примонтировать одну или обе шары."

        # Попытка размонтирования в случае частичного монтирования
        if mount | grep $MOUNT_POINT1 > /dev/null; then
            sudo umount $MOUNT_POINT1
        fi
        
        if mount | grep $MOUNT_POINT2 > /dev/null; then
            sudo umount $MOUNT_POINT2
        fi
    fi
else
    log_and_notify "❌ Один или оба хоста недоступны."
fi
