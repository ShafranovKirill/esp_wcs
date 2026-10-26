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

## Заводские настройки и пароли (`firmware/.env`)

Логин и пароль администратора, имя и пароль Wi-Fi точки настройки задаются
в `firmware/.env`. Файл в git не попадает; шаблон — `firmware/.env.example`.

```sh
cd firmware
cp .env.example .env   # если .env нет, сборка создаст его сама с заводскими значениями
$EDITOR .env
idf.py build           # значения перегенерируются автоматически
```

| Переменная | По умолчанию | Ограничения |
| --- | --- | --- |
| `WCS_SETUP_AP_SSID_PREFIX` | `ESP-WCS-` | до 28 символов; к нему добавляются 4 hex-цифры MAC |
| `WCS_SETUP_AP_PASSWORD` | `adminadmin` | 8–63 символа (WPA2) |
| `WCS_ADMIN_USERNAME` | `admin` | до 32 символов |
| `WCS_ADMIN_PASSWORD` | `admin` | до 64 символов |
| `WCS_PBKDF2_ITERATIONS` | `10000` | 1000–1000000 |

Пароль администратора в прошивку попадает только хэшем PBKDF2-HMAC-SHA256
со случайной солью (`components/wcs_defaults/gen_defaults.py`). Пароль Wi-Fi
хранится как есть: точке доступа он нужен в открытом виде (защитит Flash
Encryption на этапе 3). Допустимы только печатные ASCII-символы.

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

## Вход в настройку

1. Удерживать **BOOT** 5 секунд (уже после загрузки, не при подаче питания) и отпустить.
2. Подключиться к Wi-Fi `ESP-WCS-XXXX` (XXXX — конец MAC), пароль из `.env`.
3. Открыть в браузере `http://192.168.4.1/`. Автоматического окна входа (captive portal)
   нет сознательно: Android/Samsung его не показывали, а с самоподписанным HTTPS оно бесполезно.
4. Войти логином и паролем администратора.

Пока веб-интерфейс работает по HTTP; HTTPS — пункт 3 этапа 1.

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
