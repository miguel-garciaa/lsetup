#!/bin/bash
set -e

# Ejecutar despues de instalar paquetes o modificar la aplicacion.

PROYECTO_DIR="${PROYECTO_DIR:-/var/www/peluqueria}"
if [ ! -f "$PROYECTO_DIR/artisan" ] && [ -f /var/www/laravel/artisan ]; then
    PROYECTO_DIR="/var/www/laravel"
fi

cd "$PROYECTO_DIR"

sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer composer dump-autoload --optimize --no-scripts --no-interaction
sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer php artisan package:discover --ansi

if sudo -u laravel php artisan list --raw | grep -q '^webpush:vapid'; then
    if ! grep -Eq '^VAPID_PUBLIC_KEY=.+$' .env || ! grep -Eq '^VAPID_PRIVATE_KEY=.+$' .env; then
        sudo -u laravel php artisan webpush:vapid --force --no-interaction
    fi

    if ! grep -Eq '^VAPID_SUBJECT=.+$' .env; then
        APP_URL_VALUE=$(sed -n 's/^APP_URL=//p' .env | tail -n 1 | tr -d '"')
        if [[ "$APP_URL_VALUE" == https://* ]]; then
            printf '\nVAPID_SUBJECT=%s\n' "$APP_URL_VALUE" | sudo tee -a .env > /dev/null
            sudo chown laravel:laravel .env
        else
            echo "AVISO: configura VAPID_SUBJECT con una URL HTTPS o mailto: válida."
        fi
    fi
fi

sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer php artisan optimize:clear
sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer APP_ENV=production php artisan migrate --force --no-interaction
sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer APP_ENV=production php artisan config:cache
sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer APP_ENV=production php artisan route:cache
sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer APP_ENV=production php artisan view:cache
sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer php artisan queue:restart

sudo tee /etc/systemd/system/laravel-queue.service > /dev/null << EOF
[Unit]
Description=Laravel Queue Worker
After=network.target postgresql.service redis-server.service

[Service]
Type=simple
User=laravel
Group=laravel
WorkingDirectory=$PROYECTO_DIR
ExecStart=/usr/bin/php artisan queue:work redis --queue=emails,default --sleep=1 --tries=3 --timeout=90
ExecReload=/usr/bin/php artisan queue:restart
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=100
Environment=APP_ENV=production

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/laravel-scheduler.service > /dev/null << EOF
[Unit]
Description=Laravel Scheduler
After=network.target postgresql.service redis-server.service

[Service]
Type=oneshot
User=laravel
Group=laravel
WorkingDirectory=$PROYECTO_DIR
ExecStart=/usr/bin/php artisan schedule:run
Environment=APP_ENV=production
EOF

sudo tee /etc/systemd/system/laravel-scheduler.timer > /dev/null << 'EOF'
[Unit]
Description=Run Laravel Scheduler every minute

[Timer]
OnCalendar=*-*-* *:*:00
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now laravel-queue
sudo systemctl restart laravel-queue
sudo systemctl enable --now laravel-scheduler.timer

sudo systemctl restart octane

sudo nginx -t
sudo systemctl reload nginx
