#!/bin/bash
set -e

# Ejecutar despues de instalar paquetes o modificar la aplicacion.

cd /var/www/laravel

sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer composer dump-autoload --optimize --no-interaction

sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer php artisan optimize:clear
sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer APP_ENV=production php artisan config:cache
sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer APP_ENV=production php artisan route:cache
sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer APP_ENV=production php artisan view:cache
sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer php artisan queue:restart

sudo systemctl restart octane

sudo nginx -t
sudo systemctl reload nginx
