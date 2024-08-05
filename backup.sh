#!/bin/bash

# Пути к лог-файлу и точкам монтирования
LOG_FILE="/mnt/rabota.log"
MOUNT_POINT1="/mnt/rabota"
MOUNT_POINT2="/mnt/rabota-tr-rabota"

# Telegram Bot API параметры
TOKEN="1115999333:dddmuRf8mAfEpSjXZLdffghhlQu0jY"
CHAT_ID="116667787"

# Название скрипта для уведомлений
SCRIPT_NAME="Резервное копирование egoshin-pc_d:\Rabota"

# Функция для записи логов и отправки уведомлений
log_and_notify() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $message" >> $LOG_FILE
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d chat_id=$CHAT_ID -d text="$SCRIPT_NAME: $message" > /dev/null
}

# IP адреса компьютеров
HOST1="192.168.2.69"
HOST2="192.168.2.200"

# Проверка доступности хостов
ping -c 1 $HOST1 > /dev/null 2>&1
HOST1_STATUS=$?

ping -c 1 $HOST2 > /dev/null 2>&1
HOST2_STATUS=$?

# Если оба хоста доступны
if [ $HOST1_STATUS -eq 0 ] && [ $HOST2_STATUS -eq 0 ]; then
    log_and_notify "✅ Оба хоста доступны, монтируем шары..."

    # Монтируем шары
    sudo mount -t cifs //192.168.2.69/d$/Rabota $MOUNT_POINT1 -o username=user1,password=123,domain=test.loc,iocharset=utf8,file_mode=0777,dir_mode=0777
    MOUNT1_STATUS=$?

    sudo mount -t cifs //192.168.2.200//Rabota $MOUNT_POINT2 -o username=user2,password=123,domain=workgroup,iocharset=utf8,file_mode=0777,dir_mode=0777
    MOUNT2_STATUS=$?

    # Если монтирование прошло успешно
    if [ $MOUNT1_STATUS -eq 0 ] && [ $MOUNT2_STATUS -eq 0 ]; then
        log_and_notify "✅ Шары успешно примонтированы, выполняем rsync..."

        # Выполняем rsync с дополнительными параметрами
        rsync -ruP  -t --delete  $MOUNT_POINT1/ $MOUNT_POINT2/
        RSYNC_STATUS=$?

        if [ $RSYNC_STATUS -eq 0 ]; then
            log_and_notify "✅ Резервное копирование успешно завершено."
        else
            log_and_notify "❌ Ошибка при выполнении rsync."
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
