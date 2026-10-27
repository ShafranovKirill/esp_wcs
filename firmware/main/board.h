#pragma once

#include "driver/gpio.h"
#include "hal/uart_types.h"

#define BOARD_CONSOLE_UART_NUM      UART_NUM_1
#define BOARD_CONSOLE_TX_GPIO       GPIO_NUM_17
#define BOARD_CONSOLE_RX_GPIO       GPIO_NUM_18
#define BOARD_CONSOLE_DEFAULT_BAUD  9600
#define BOARD_CONSOLE_BREAK_MS      300

#define BOARD_RGB_LED_GPIO          GPIO_NUM_48
#define BOARD_RGB_LED_BRIGHTNESS    40

#define BOARD_BUTTON_GPIO           GPIO_NUM_0
#define BOARD_BUTTON_ACTIVE_LEVEL   0
