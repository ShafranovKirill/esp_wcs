# Прошивка ESP WCS (ESP-IDF v6.1, ESP32-S3)
cmake_minimum_required(VERSION 3.22)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# Собирать только main и то, от чего он реально зависит
idf_build_set_property(MINIMAL_BUILD ON)
project(esp_wcs)
