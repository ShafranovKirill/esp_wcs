# ESP32-S3-DevKitC-1 v1.1 (N16R8) — справочник по плате

Общая информация по плате и пинам. Источники: руководство Espressif
ESP32-S3-DevKitC-1 v1.1, даташиты ESP32-S3 и ESP32-S3-WROOM-1, проверка на
конкретном экземпляре платы.

---

## Плата

| Параметр | Значение |
| --- | --- |
| Плата | клон ESP32-S3-DevKitC-1 **v1.1** (надпись на обороте «AI S3», фиолетовая) |
| Модуль | ESP32-S3-WROOM-1-N16R8 (маркировка на экране: MCN16R8) |
| Чип | ESP32-S3 (QFN56), 2 ядра Xtensa LX7, до 240 МГц, ревизия v0.2, кварц 40 МГц |
| SRAM / ROM | 512 КБ / 384 КБ |
| Flash | 16 МБ, Quad SPI, режим QIO, 80 МГц (GigaDevice, JEDEC ID c8/4018 — GD25Q128). Питание 3.3 В |
| PSRAM | 8 МБ, **Octal SPI (OPI)**, 80 МГц (AP Memory, 64 Мбит, 3.3 В). Встроена в корпус чипа (eFuse: PSRAM_VENDOR=AP_3v3) |
| Свободная куча | ~8.78 МБ всего: ~380 КБ внутренней RAM + ~8.38 МБ PSRAM (замерено на пустом приложении) |
| Беспроводная связь | Wi-Fi 802.11 b/g/n 2.4 ГГц, Bluetooth 5 LE |
| Антенна | на плате модуля (PCB) |
| Логические уровни | **3.3 В, пины НЕ выдерживают 5 В** |

### Разъёмы и элементы

| Элемент | Описание |
| --- | --- |
| Разъём **COM** | USB-UART мост → UART0 (GPIO43 TX / GPIO44 RX). Прошивка, логи, питание. На этой плате мост **WCH CH343** (USB ID 1a86:55d3, драйвер cdc_acm) → `/dev/ttyACM0`. На других клонах бывает CP2102/CH340 → `/dev/ttyUSB0` |
| Разъём **USB** | нативный USB 1.1 Full Speed (GPIO19 D- / GPIO20 D+): USB-Serial-JTAG, USB OTG (устройство или хост), прошивка, питание |
| Надпись «USB OTG» на обороте | площадки для подачи 5 В на порт USB в режиме USB-хоста. По умолчанию не нужны |
| Кнопка **BOOT** | GPIO0. Удержание BOOT + нажатие RESET → режим прошивки. После загрузки работает как обычная кнопка (нажата = 0) |
| Кнопка **RESET** | вывод EN, перезагрузка чипа |
| RGB-светодиод | адресуемый WS2812, **GPIO48** (проверено на плате). В документации Espressif для v1.1 указан GPIO38, но на этом клоне светодиод распаян на GPIO48, как в v1.0 |
| Светодиод питания | горит при наличии 3.3 В |
| LDO 5 В → 3.3 В | питает модуль и пины 3V3 |

### Питание

Три взаимоисключающих способа:

1. Через разъём COM и/или USB (5 В) — рекомендуется.
2. Через пины **5V** и **G**.
3. Через пины **3V3** и **G** (стабилизированные 3.3 В, LDO в обход).

Одновременно подавать питание разными способами нельзя.

---

## Ограничения по пинам

### Нельзя использовать

| GPIO | Причина |
| --- | --- |
| 26–32 | внутренняя шина SPI flash, на гребёнки не выведены |
| **35, 36, 37** | заняты **Octal PSRAM** (в модулях с OPI-памятью). Выведены на гребёнку, но использовать нельзя |

### Использовать осторожно

| GPIO | Назначение по умолчанию | Что учитывать |
| --- | --- | --- |
| 43, 44 | UART0 TX/RX, разъём COM | через них идут прошивка и логи. Если занять — пропадут логи |
| 19, 20 | USB D-/D+, разъём USB | заняты, пока используется нативный USB или JTAG через USB |
| 48 | встроенный RGB-светодиод (на этом клоне; по документации v1.1 — GPIO38) | можно использовать, но светодиод будет реагировать |
| 39–42 | внешний JTAG (MTCK, MTDO, MTDI, MTMS) | свободны, если JTAG идёт через USB (по умолчанию) |
| 15, 16 | XTAL_32K_P/N | свободны, если не ставить внешний кварц 32 кГц |

### Strapping-пины (влияют на загрузку)

Их состояние считывается в момент включения питания или сброса.

| GPIO | Что определяет | По умолчанию | Риск |
| --- | --- | --- | --- |
| **0** | режим загрузки | подтяжка вверх (кнопка BOOT) | 0 при старте → режим прошивки вместо запуска программы |
| **3** | источник JTAG (USB или пины) | не подтянут | на этом чипе не читается: eFuse STRAP_JTAG_SEL=0, JTAG всегда через USB |
| **45** | напряжение VDD_SPI (flash/PSRAM) | подтяжка вниз → 3.3 В | на этом чипе игнорируется: eFuse VDD_SPI_FORCE=1 фиксирует 3.3 В. На чипах без этого eFuse 1 при старте → 1.8 В, **модуль не загрузится** |
| **46** | режим загрузки, вывод ROM-лога | подтяжка вниз | вместе с GPIO0 может мешать загрузке |

Правило: не подключать к strapping-пинам внешние цепи, которые при старте тянут
их не в ту сторону. GPIO0 удобно использовать как кнопку.

### Свободные пины

GPIO **1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 21, 38, 39, 40, 41, 42, 47**.

---

## Возможности периферии

На ESP32-S3 почти любую цифровую функцию можно назначить на любой свободный
GPIO через матрицу GPIO. Исключения — аналоговые функции (АЦП, touch),
привязанные к конкретным пинам.

| Периферия | Количество | Пины |
| --- | --- | --- |
| UART | 3 (UART0 занят под логи) | любые. По умолчанию: UART1 — GPIO17 TX / GPIO18 RX |
| I2C | 2 | любые |
| SPI общего назначения | 2 (SPI2/FSPI, SPI3) | любые. Быстрые IOMUX-пины FSPI: CS0 10, MOSI 11, CLK 12, MISO 13, WP 14, HD 9 |
| I2S | 2 | любые |
| LED PWM (LEDC) | 8 каналов | любые |
| RMT (WS2812, ИК) | 8 каналов: 4 на передачу + 4 на приём | любые |
| TWAI (CAN) | 1 | любые (нужен внешний трансивер) |
| MCPWM | 2 блока | любые |
| АЦП1 | 10 каналов | **GPIO1–10** |
| АЦП2 | 10 каналов | **GPIO11–20**. Делится с Wi-Fi: `adc_oneshot_read` может вернуть ошибку, пока Wi-Fi занят. В непрерывном (DMA) режиме не поддерживается — только АЦП1 |
| Touch | 14 каналов | **GPIO1–14** |
| RTC GPIO (пробуждение из deep sleep) | 22 | GPIO0–21 |
| Камера (DVP), LCD | по 1 | любые |
| USB OTG / USB-Serial-JTAG | 1 | только GPIO19/20 |

### Электрические параметры GPIO

- Уровни 3.3 В. Подача 5 В на любой GPIO повреждает чип.
- Ток вывода по умолчанию ~20 мА, максимум ~40 мА. Светодиоды и реле — через резистор или транзистор.
- Встроенные подтяжки вверх/вниз ~45 кОм на каждом GPIO.
- Пинов «только вход» нет (в отличие от обычного ESP32): все выведенные GPIO работают в обе стороны.
- Максимальный ток с пина 3V3 ограничен LDO платы (порядка 500 мА суммарно с модулем; Wi-Fi в пике берёт до ~350 мА).

---

## Полная распиновка

Тип: P — питание, G — земля, I — вход, O — выход, T — высокоимпедансное состояние.
Нумерация как на схеме платы. Ориентация: антенна сверху, разъёмы USB снизу.

### J1 (левый ряд)

| № | Имя | Тип | Функции | Примечание |
| --- | --- | --- | --- | --- |
| 1 | 3V3 | P | питание 3.3 В | |
| 2 | 3V3 | P | питание 3.3 В | |
| 3 | RST | I | EN | сброс |
| 4 | 4 | I/O/T | RTC_GPIO4, GPIO4, TOUCH4, ADC1_CH3 | |
| 5 | 5 | I/O/T | RTC_GPIO5, GPIO5, TOUCH5, ADC1_CH4 | |
| 6 | 6 | I/O/T | RTC_GPIO6, GPIO6, TOUCH6, ADC1_CH5 | |
| 7 | 7 | I/O/T | RTC_GPIO7, GPIO7, TOUCH7, ADC1_CH6 | |
| 8 | 15 | I/O/T | RTC_GPIO15, GPIO15, U0RTS, ADC2_CH4, XTAL_32K_P | |
| 9 | 16 | I/O/T | RTC_GPIO16, GPIO16, U0CTS, ADC2_CH5, XTAL_32K_N | |
| 10 | 17 | I/O/T | RTC_GPIO17, GPIO17, U1TXD, ADC2_CH6 | UART1 TX по умолчанию |
| 11 | 18 | I/O/T | RTC_GPIO18, GPIO18, U1RXD, ADC2_CH7, CLK_OUT3 | UART1 RX по умолчанию |
| 12 | 8 | I/O/T | RTC_GPIO8, GPIO8, TOUCH8, ADC1_CH7, SUBSPICS1 | |
| 13 | 3 | I/O/T | RTC_GPIO3, GPIO3, TOUCH3, ADC1_CH2 | strapping |
| 14 | 46 | I/O/T | GPIO46 | strapping |
| 15 | 9 | I/O/T | RTC_GPIO9, GPIO9, TOUCH9, ADC1_CH8, FSPIHD, SUBSPIHD | |
| 16 | 10 | I/O/T | RTC_GPIO10, GPIO10, TOUCH10, ADC1_CH9, FSPICS0, FSPIIO4, SUBSPICS0 | |
| 17 | 11 | I/O/T | RTC_GPIO11, GPIO11, TOUCH11, ADC2_CH0, FSPID, FSPIIO5, SUBSPID | |
| 18 | 12 | I/O/T | RTC_GPIO12, GPIO12, TOUCH12, ADC2_CH1, FSPICLK, FSPIIO6, SUBSPICLK | |
| 19 | 13 | I/O/T | RTC_GPIO13, GPIO13, TOUCH13, ADC2_CH2, FSPIQ, FSPIIO7, SUBSPIQ | |
| 20 | 14 | I/O/T | RTC_GPIO14, GPIO14, TOUCH14, ADC2_CH3, FSPIWP, FSPIDQS, SUBSPIWP | |
| 21 | 5V | P | питание 5 В | |
| 22 | G | G | земля | |

### J3 (правый ряд)

| № | Имя | Тип | Функции | Примечание |
| --- | --- | --- | --- | --- |
| 1 | G | G | земля | |
| 2 | TX | I/O/T | U0TXD, GPIO43, CLK_OUT1 | UART0, логи |
| 3 | RX | I/O/T | U0RXD, GPIO44, CLK_OUT2 | UART0, логи |
| 4 | 1 | I/O/T | RTC_GPIO1, GPIO1, TOUCH1, ADC1_CH0 | |
| 5 | 2 | I/O/T | RTC_GPIO2, GPIO2, TOUCH2, ADC1_CH1 | |
| 6 | 42 | I/O/T | MTMS, GPIO42 | |
| 7 | 41 | I/O/T | MTDI, GPIO41, CLK_OUT1 | |
| 8 | 40 | I/O/T | MTDO, GPIO40, CLK_OUT2 | |
| 9 | 39 | I/O/T | MTCK, GPIO39, CLK_OUT3, SUBSPICS1 | |
| 10 | 38 | I/O/T | GPIO38, FSPIWP, SUBSPIWP | свободен (по документации v1.1 здесь RGB LED, на этом клоне — нет) |
| 11 | 37 | I/O/T | SPIDQS, GPIO37, FSPIQ, SUBSPIQ | **занят PSRAM** |
| 12 | 36 | I/O/T | SPIIO7, GPIO36, FSPICLK, SUBSPICLK | **занят PSRAM** |
| 13 | 35 | I/O/T | SPIIO6, GPIO35, FSPID, SUBSPID | **занят PSRAM** |
| 14 | 0 | I/O/T | RTC_GPIO0, GPIO0 | strapping, кнопка BOOT |
| 15 | 45 | I/O/T | GPIO45 | strapping |
| 16 | 48 | I/O/T | GPIO48, SPICLK_N, SUBSPICLK_N_DIFF | встроенный RGB-светодиод |
| 17 | 47 | I/O/T | GPIO47, SPICLK_P, SUBSPICLK_P_DIFF | |
| 18 | 21 | I/O/T | RTC_GPIO21, GPIO21 | |
| 19 | 20 | I/O/T | RTC_GPIO20, GPIO20, U1CTS, ADC2_CH9, CLK_OUT1, USB_D+ | нативный USB |
| 20 | 19 | I/O/T | RTC_GPIO19, GPIO19, U1RTS, ADC2_CH8, CLK_OUT2, USB_D- | нативный USB |
| 21 | G | G | земля | |
| 22 | G | G | земля | |

---

## ESP-IDF: настройки под эту плату

Проверено на ESP-IDF v6.1. Файл `sdkconfig.defaults`:

```
CONFIG_IDF_TARGET="esp32s3"
CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y
CONFIG_ESPTOOLPY_FLASHMODE_QIO=y
CONFIG_SPIRAM=y
CONFIG_SPIRAM_MODE_OCT=y
CONFIG_SPIRAM_SPEED_80M=y
CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ_240=y
```

Особенности:

- **ESP-IDF 6.x**: настройки PSRAM работают, только если компонент `esp_psram` указан в `REQUIRES` или `PRIV_REQUIRES` компонента. Иначе `CONFIG_SPIRAM_*` молча игнорируются.
- **ESP-IDF 6.x**: драйверы разделены на отдельные компоненты (`esp_driver_uart`, `esp_driver_gpio`, `esp_driver_spi` и т.д.), их нужно указывать в зависимостях явно.
- После удаления `sdkconfig` выполнить `idf.py set-target esp32s3`, иначе сборка пойдёт под обычный ESP32.
- В Arduino IDE: плата «ESP32S3 Dev Module», Flash Size 16MB, PSRAM «OPI PSRAM».

### Признаки правильной настройки в логе загрузки

```
boot.esp32s3: SPI Mode       : QIO
boot.esp32s3: SPI Flash Size : 16MB
esp_psram: Found 8MB PSRAM device
esp_psram: SPI SRAM memory test OK
cpu_start: cpu freq: 240000000 Hz
```

---

## Встроенный RGB-светодиод (проверено на плате)

WS2812 на **GPIO48**, порядок цветов GRB. Управление через RMT, компонент
`espressif/led_strip` v3. В `main/idf_component.yml`:

```yaml
dependencies:
  espressif/led_strip: "^3.0.0"
```

Инициализация:

```c
led_strip_config_t strip_config = {
    .strip_gpio_num = 48,
    .max_leds = 1,
    .led_model = LED_MODEL_WS2812,
    .color_component_format = LED_STRIP_COLOR_COMPONENT_FMT_GRB,
};
led_strip_rmt_config_t rmt_config = {
    .clk_src = RMT_CLK_SRC_DEFAULT,
    .resolution_hz = 10 * 1000 * 1000,
};
led_strip_handle_t strip;
ESP_ERROR_CHECK(led_strip_new_rmt_device(&strip_config, &rmt_config, &strip));
```

- На полной яркости (255) светодиод слепит, достаточно ~40.
- Если светодиод не горит вообще: на части клонов рядом с ним есть перемычка
  **RGB** (две площадки под пайку), её нужно запаять.

---

## Результаты проверки платы (2026-10-26)

Что проверено на этом экземпляре и как.

**С компьютера** (`esptool flash-id`, `espefuse summary`, только чтение):

- ESP32-S3 (QFN56) v0.2, кварц 40 МГц, MAC `7c:2c:67:8c:85:80`
- Flash c8/4018 (GD25Q128, 16 МБ), тип в eFuse — quad, напряжение 3.3 В задано eFuse
- PSRAM 8 МБ AP_3v3 встроена в корпус
- eFuse: VDD_SPI_FORCE=1 (GPIO45 не влияет), STRAP_JTAG_SEL=0 (GPIO3 не влияет),
  secure boot и шифрование flash выключены, USB-Serial-JTAG и USB OTG включены
- USB-UART мост WCH CH343 (1a86:55d3) → `/dev/ttyACM0`

**Тестовой прошивкой:**

- Физический размер flash 16 МБ, PSRAM 8 МБ, свободная куча 8 775 723 байт
  (внутренняя 389 567, PSRAM 8 386 156)
- Прозвонка пинов встроенными подтяжками (вверх → 1, вниз → 0 = ни к чему не подключён):
  GPIO1–18, 21, 38–42, 45–48 — свободны; GPIO0 — подтянут к 3V3 на плате (кнопка BOOT).
  GPIO48 читается как свободный, потому что вход WS2812 не тянет линию
- Замыканий между этими пинами нет
- Встроенный RGB-светодиод мигает на GPIO48

**По исходникам ESP-IDF v6.1** (`soc_caps.h`, HAL): 3 UART, 2 I2C, 2 I2S,
8 каналов LEDC, 2 блока MCPWM, 1 TWAI, touch 1–14, 22 RTC GPIO, IOMUX-пины
FSPI (9–14) — совпадает с таблицей выше. ЦАП у ESP32-S3 нет.

**Не проверено** (нужны руки или приборы): соответствие надписей на плате
номерам GPIO, токи и напряжения, работа JTAG через USB, площадки USB OTG.

---

## Документация

- ESP32-S3-DevKitC-1 v1.1 User Guide — docs.espressif.com/projects/esp-dev-kits
- Схема платы — `SCH_ESP32-S3-DevKitC-1_V1.1` (PDF на dl.espressif.com)
- ESP32-S3 Datasheet и Technical Reference Manual — espressif.com
- ESP32-S3-WROOM-1 / WROOM-1U Datasheet — espressif.com
