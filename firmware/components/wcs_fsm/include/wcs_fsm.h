#pragma once

#include "driver/gpio.h"
#include "esp_err.h"

typedef enum {
    WCS_FSM_STATE_FACTORY,
    WCS_FSM_STATE_SETUP,
    WCS_FSM_STATE_DIRECT,
    WCS_FSM_STATE_BASTION,
} wcs_fsm_state_t;

typedef struct {
    gpio_num_t button_gpio;
    int button_active_level;
} wcs_fsm_config_t;

esp_err_t wcs_fsm_start(const wcs_fsm_config_t *config);

wcs_fsm_state_t wcs_fsm_get_state(void);
