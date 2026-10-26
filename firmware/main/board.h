/*
 * Аппаратная конфигурация платы ESP32-S3-DevKitC-1 v1.1 (N16R8, клон «AI S3»).
 *
 * Единственное место в коде, где задаются номера пинов и параметры железа.
 * Справочник по плате: docs/hardware/esp32-s3-n16r8-board.md
 */
#pragma once

#include "driver/gpio.h"
#include "hal/uart_types.h"

/* Консоль коммутатора/маршрутизатора: UART1 → MAX3232 → RJ45 */
#define BOARD_CONSOLE_UART_NUM      UART_NUM_1
#define BOARD_CONSOLE_TX_GPIO       GPIO_NUM_17 /* J1-10, U1TXD */
#define BOARD_CONSOLE_RX_GPIO       GPIO_NUM_18 /* J1-11, U1RXD */
#define BOARD_CONSOLE_DEFAULT_BAUD  9600        /* 8N1, без управления потоком */
#define BOARD_CONSOLE_BREAK_MS      300         /* удержание TX в нуле для BREAK */

/* Встроенный адресуемый RGB-светодиод WS2812, формат GRB.
 * На этом клоне — GPIO48 (в документации Espressif для v1.1 указан GPIO38). */
#define BOARD_RGB_LED_GPIO          GPIO_NUM_48
#define BOARD_RGB_LED_BRIGHTNESS    40          /* 255 слепит */

/* Кнопка режимов: встроенная BOOT (strapping-пин, нажата = 0, подтяжка на плате).
 * Для корпуса планируется внешняя кнопка на GPIO4. */
#define BOARD_BUTTON_GPIO           GPIO_NUM_0
#define BOARD_BUTTON_ACTIVE_LEVEL   0
