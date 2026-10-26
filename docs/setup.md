# Установка среды и сборка

## ESP-IDF

Используется **ESP-IDF v6.1**, установлен в `~/esp/esp-idf`.

```sh
mkdir -p ~/esp && cd ~/esp
git clone -b v6.1 --recursive https://github.com/espressif/esp-idf.git
cd esp-idf && ./install.sh esp32s3
```

Активация окружения в каждом новом терминале (удобно завести алиас):

```sh
alias get_idf='. $HOME/esp/esp-idf/export.sh'
get_idf
```

## Доступ к порту (Linux)

Плата видна как `/dev/ttyACM0` (мост WCH CH343, драйвер `cdc_acm`).
Пользователь должен быть в группе `dialout`:

```sh
sudo usermod -aG dialout $USER   # затем перелогиниться
```

## Сборка и прошивка

```sh
cd firmware
idf.py set-target esp32s3        # один раз, и после удаления sdkconfig
idf.py build
idf.py -p /dev/ttyACM0 flash
idf.py -p /dev/ttyACM0 monitor   # выход: Ctrl+]
```

Если `sdkconfig` удалён, обязательно заново `idf.py set-target esp32s3` —
иначе сборка пойдёт под обычный ESP32.

## Признаки правильной настройки в логе загрузки

```
boot.esp32s3: SPI Mode       : QIO
boot.esp32s3: SPI Flash Size : 16MB
esp_psram: Found 8MB PSRAM device
cpu_start: cpu freq: 240000000 Hz
wcs: esp_wcs <версия> (ESP-IDF v6.1)
```

## Таблица разделов

`firmware/partitions.csv` (16 МБ):

| Раздел | Адрес | Размер | Назначение |
| --- | --- | --- | --- |
| nvs | 0x9000 | 64 КБ | настройки, хэши паролей, ключи, сертификаты |
| otadata | 0x19000 | 8 КБ | выбор активного слота OTA |
| phy_init | 0x1B000 | 4 КБ | калибровка радио |
| ota_0 | 0x20000 | 4 МБ | прошивка, слот 0 |
| ota_1 | 0x420000 | 4 МБ | прошивка, слот 1 (OTA, этап 3) |
| nvs_keys | 0x820000 | 4 КБ | ключи шифрования NVS (Flash Encryption, этап 3) |
| — | 0x821000 | ~7.8 МБ | свободно, резерв |

## CI

GitHub Actions (`.github/workflows/firmware.yml`) собирает прошивку на каждый
PR и push в `main`, если менялось что-то в `firmware/`. Готовые `.bin`
выкладываются как артефакты сборки.
