# Cloud Backup Sync

Bash-скрипт для ежедневного резервного копирования данных между S3-compatible хранилищами через `rclone`.

Проект реализует автоматический cloud-to-cloud backup: данные копируются из исходного remote-хранилища в backup-хранилище, складываются в папку с датой запуска, логируются и очищаются по retention-политике.

## Стек

- Bash
- rclone
- systemd
- systemd timer
- Linux
- S3-compatible storage

## Возможности

- Ежедневное резервное копирование между cloud storage remote;
- создание отдельной папки под каждый день в формате `DD.MM.YYYY`;
- безопасное копирование через `rclone copy`;
- защита от параллельного запуска через `flock`;
- логирование в отдельный log-файл;
- retention-политика с удалением старых backup-папок;
- настройка через environment variables;
- запуск как `systemd oneshot` service;
- запуск по расписанию через `systemd timer`.

## Структура проекта

```text
cloud-backup-sync/
├── README.md
├── r2_to_s3_daily.sh
├── .gitignore
└── systemd/
    ├── cloud-backup-sync.service.example
    └── cloud-backup-sync.timer.example
```

## Как работает backup

Скрипт выполняет две основные операции.

### 1. Копирование данных

Данные копируются из исходного remote в backup remote:

```bash
rclone copy "$SRC" "$DST"
```

Каждый запуск создаёт отдельную папку с текущей датой:

```text
s3:backup-bucket/24.04.2026/
```

Используется именно `rclone copy`, а не `rclone sync`, потому что backup пишется в новую dated-папку. Это снижает риск случайного удаления данных в уже созданных резервных копиях.

### 2. Retention

После копирования скрипт получает список папок в backup bucket, выбирает папки в формате:

```text
DD.MM.YYYY
```

Затем удаляет те, которые старше заданного количества дней.

По умолчанию:

```bash
KEEP_DAYS=3
```

Это означает, что хранятся:

- сегодняшний backup;
- backup за вчера;
- backup за позавчера.

Более старые папки удаляются через:

```bash
rclone purge
```

## Конфигурация

Скрипт настраивается через переменные окружения.

Пример:

```bash
SRC_REMOTE="r2:source-bucket/"
DST_REMOTE="s3:backup-bucket"
KEEP_DAYS=3
RCLONE_CFG="/etc/rclone/rclone.conf"
LOG_DIR="/var/log/rclone"
LOG_FILE="/var/log/rclone/cloud-backup-sync.log"
LOCK_FILE="/var/lock/cloud-backup-sync.lock"
TZ="Europe/Moscow"
```

## Основной скрипт

Файл:

```text
r2_to_s3_daily.sh
```

Ключевые части реализации:

```bash
set -euo pipefail
```

Используется строгий режим Bash, чтобы скрипт завершался при ошибках, обращении к несуществующим переменным и ошибках в pipeline.

```bash
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  echo "Another backup is running, exiting." >>"$LOG_FILE"
  exit 0
fi
```

Эта часть защищает backup от параллельного запуска.

```bash
DATE_TAG="$(date +%d.%m.%Y)"
DST="${DST_BUCKET}/${DATE_TAG}/"
```

Эта часть формирует папку текущего дня.

## systemd service

Пример service-файла находится здесь:

```text
systemd/cloud-backup-sync.service.example
```

Пример:

```ini
[Unit]
Description=Daily cloud-to-cloud backup with retention
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=SRC_REMOTE=r2:source-bucket/
Environment=DST_REMOTE=s3:backup-bucket
Environment=KEEP_DAYS=3
Environment=RCLONE_CFG=/etc/rclone/rclone.conf
ExecStart=/usr/local/bin/r2_to_s3_daily.sh
```

`Type=oneshot` используется потому, что backup-скрипт запускается, выполняет задачу и завершается.

## systemd timer

Пример timer-файла находится здесь:

```text
systemd/cloud-backup-sync.timer.example
```

Пример:

```ini
[Unit]
Description=Run cloud backup sync daily

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true
Unit=cloud-backup-sync.service

[Install]
WantedBy=timers.target
```

`Persistent=true` нужен для того, чтобы systemd запустил пропущенную задачу после включения сервера, если сервер был выключен в момент расписания.

## Установка на сервер

Скопировать скрипт:

```bash
sudo cp r2_to_s3_daily.sh /usr/local/bin/r2_to_s3_daily.sh
sudo chmod +x /usr/local/bin/r2_to_s3_daily.sh
```

Скопировать systemd service и timer:

```bash
sudo cp systemd/cloud-backup-sync.service.example /etc/systemd/system/cloud-backup-sync.service
sudo cp systemd/cloud-backup-sync.timer.example /etc/systemd/system/cloud-backup-sync.timer
```

Перечитать systemd:

```bash
sudo systemctl daemon-reload
```

Включить timer:

```bash
sudo systemctl enable cloud-backup-sync.timer
sudo systemctl start cloud-backup-sync.timer
```

Проверить timer:

```bash
systemctl list-timers --all | grep cloud-backup-sync
```

Запустить backup вручную:

```bash
sudo systemctl start cloud-backup-sync.service
```

Проверить статус:

```bash
sudo systemctl status cloud-backup-sync.service --no-pager
```

## Логи

По умолчанию лог пишется в файл:

```text
/var/log/rclone/cloud-backup-sync.log
```

Посмотреть последние строки:

```bash
tail -n 100 /var/log/rclone/cloud-backup-sync.log
```

Также можно смотреть логи systemd:

```bash
journalctl -u cloud-backup-sync.service -n 100 --no-pager
```

## Диагностика

Проверить, что `rclone` установлен:

```bash
rclone version
```

Проверить список remote:

```bash
rclone listremotes --config /etc/rclone/rclone.conf
```

Проверить доступ к исходному remote:

```bash
rclone lsf r2:source-bucket/ --config /etc/rclone/rclone.conf
```

Проверить доступ к backup remote:

```bash
rclone lsf s3:backup-bucket/ --config /etc/rclone/rclone.conf
```

Проверить активные locks:

```bash
ls -la /var/lock/cloud-backup-sync.lock
```

## Безопасность

В репозитории нельзя хранить:

- реальные access keys;
- secret keys;
- production `rclone.conf`;
- реальные имена приватных bucket;
- логи с приватными путями;
- backup-данные;
- `.env` файлы.

Файл `rclone.conf` должен храниться только на сервере, например:

```text
/etc/rclone/rclone.conf
```

В публичный GitHub добавляются только обезличенные примеры.

## Что реализовано

- Bash-скрипт для cloud-to-cloud backup;
- копирование через `rclone copy`;
- dated folders в формате `DD.MM.YYYY`;
- retention-политика на заданное количество дней;
- удаление старых backup-папок через `rclone purge`;
- защита от параллельного запуска через `flock`;
- логирование в отдельный файл;
- конфигурация через environment variables;
- systemd oneshot service;
- systemd timer для ежедневного запуска;
- команды диагностики и ручного запуска.

## Цель проекта

Цель проекта — показать практический DevOps-подход к резервному копированию данных: автоматизация backup-процесса, защита от параллельных запусков, логирование, retention-политика и интеграция с systemd.

Проект демонстрирует навыки работы с Linux, Bash, rclone, systemd, S3-compatible storage и эксплуатацией серверной инфраструктуры.
