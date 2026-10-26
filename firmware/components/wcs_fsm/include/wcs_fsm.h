/*
 * Машина состояний устройства (ТЗ, «Состояния и кнопка»).
 *
 *   Заводское ──5 с──▶ Настройка ──применить──▶ Direct / Bastion
 *        ▲                ▲                          │
 *        └──── 15 с ──────┴────────── 5 с ───────────┘
 *
 * Три быстрых нажатия из любого состояния — сразу Direct с поднятой точкой
 * доступа, без веб-интерфейса настройки (настройки бастиона сохраняются).
 *
 * Все переходы выполняются в собственной задаче: события кнопки, Wi-Fi, таймера
 * и веб-сервера приходят командами через очередь. Индикация — docs/led.md.
 * Параметры — menuconfig → «ESP WCS: состояния и кнопка».
 */
#pragma once

#include "driver/gpio.h"
#include "esp_err.h"

typedef enum {
    WCS_FSM_STATE_FACTORY, /* режим не выбран */
    WCS_FSM_STATE_SETUP,
    WCS_FSM_STATE_DIRECT,
    WCS_FSM_STATE_BASTION,
} wcs_fsm_state_t;

/* Железо, нужное машине состояний; значения — из board.h */
typedef struct {
    gpio_num_t button_gpio;
    int button_active_level;
} wcs_fsm_config_t;

/*
 * Готовит сертификат HTTPS, входит в сохранённый режим, запускает кнопку и
 * задачу машины состояний; возвращается сразу.
 * До вызова: nvs_flash_init(), esp_netif_init(), esp_event_loop_create_default(),
 * wcs_led_init(), wcs_auth_init(). Вызывать один раз.
 */
esp_err_t wcs_fsm_start(const wcs_fsm_config_t *config);

/* Текущее состояние; можно вызывать из любой задачи */
wcs_fsm_state_t wcs_fsm_get_state(void);
