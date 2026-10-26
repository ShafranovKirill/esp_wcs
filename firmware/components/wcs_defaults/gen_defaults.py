#!/usr/bin/env python3
"""Генерирует C-файл с заводскими настройками из .env.

Пароль администратора превращается в PBKDF2-HMAC-SHA256 со случайной солью,
в прошивку попадают только соль и хэш.
"""
import hashlib
import os
import sys

SALT_LEN = 16
HASH_LEN = 32
REQUIRED = (
    'WCS_SETUP_AP_SSID_PREFIX',
    'WCS_SETUP_AP_PASSWORD',
    'WCS_DIRECT_AP_SSID_PREFIX',
    'WCS_DIRECT_AP_PASSWORD',
    'WCS_ADMIN_USERNAME',
    'WCS_ADMIN_PASSWORD',
    'WCS_PBKDF2_ITERATIONS',
)


def fail(msg):
    sys.exit(f'gen_defaults: {msg}')


def parse_env(path):
    values = {}
    with open(path, encoding='utf-8') as f:
        for num, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            key, sep, value = line.partition('=')
            if not sep:
                fail(f'{path}:{num}: ожидается KEY=VALUE')
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
                value = value[1:-1]
            values[key.strip()] = value
    return values


def check_ssid_prefix(env, name):
    prefix = env[name]
    if not 1 <= len(prefix) <= 28:
        fail(f'{name}: от 1 до 28 символов (SSID до 32, плюс 4 цифры MAC)')
    return prefix


def check_ap_password(env, name):
    password = env[name]
    if not 8 <= len(password) <= 63:
        fail(f'{name}: от 8 до 63 символов (требование WPA2)')
    return password


def c_string(value, name):
    if not all(0x20 <= ord(ch) < 0x7f for ch in value):
        fail(f'{name}: допустимы только печатные ASCII-символы')
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def c_bytes(data):
    return '{' + ', '.join(f'0x{b:02x}' for b in data) + '}'


def main():
    if len(sys.argv) != 4:
        fail('использование: gen_defaults.py <.env> <.env.example> <выходной .c>')
    # Новые переменные, которых ещё нет в .env пользователя, берутся из шаблона
    env = parse_env(sys.argv[2])
    env.update(parse_env(sys.argv[1]))
    missing = [k for k in REQUIRED if k not in env]
    if missing:
        fail(f'не заданы {", ".join(missing)}')

    setup_prefix = check_ssid_prefix(env, 'WCS_SETUP_AP_SSID_PREFIX')
    setup_password = check_ap_password(env, 'WCS_SETUP_AP_PASSWORD')
    direct_prefix = check_ssid_prefix(env, 'WCS_DIRECT_AP_SSID_PREFIX')
    direct_password = check_ap_password(env, 'WCS_DIRECT_AP_PASSWORD')
    username = env['WCS_ADMIN_USERNAME']
    if not 1 <= len(username) <= 32:
        fail('WCS_ADMIN_USERNAME: от 1 до 32 символов')
    password = env['WCS_ADMIN_PASSWORD']
    if not 1 <= len(password) <= 64:
        fail('WCS_ADMIN_PASSWORD: от 1 до 64 символов')
    try:
        iterations = int(env['WCS_PBKDF2_ITERATIONS'])
    except ValueError:
        fail('WCS_PBKDF2_ITERATIONS: нужно целое число')
    if not 1000 <= iterations <= 1000000:
        fail('WCS_PBKDF2_ITERATIONS: от 1000 до 1000000')

    salt = os.urandom(SALT_LEN)
    digest = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, iterations, HASH_LEN)

    source = f'''/* Сгенерировано gen_defaults.py из .env — не редактировать. */
#include "wcs_defaults.h"

const wcs_defaults_t wcs_defaults = {{
    .setup_ap_ssid_prefix = {c_string(setup_prefix, 'WCS_SETUP_AP_SSID_PREFIX')},
    .setup_ap_password = {c_string(setup_password, 'WCS_SETUP_AP_PASSWORD')},
    .direct_ap_ssid_prefix = {c_string(direct_prefix, 'WCS_DIRECT_AP_SSID_PREFIX')},
    .direct_ap_password = {c_string(direct_password, 'WCS_DIRECT_AP_PASSWORD')},
    .admin_username = {c_string(username, 'WCS_ADMIN_USERNAME')},
    .admin_password = {{
        .iterations = {iterations},
        .salt = {c_bytes(salt)},
        .hash = {c_bytes(digest)},
    }},
}};
'''
    with open(sys.argv[3], 'w', encoding='utf-8') as f:
        f.write(source)


if __name__ == '__main__':
    main()
