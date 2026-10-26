# Заводские настройки: генерируются из firmware/.env при сборке
set(gen_src "${CMAKE_CURRENT_BINARY_DIR}/wcs_defaults_gen.c")

idf_component_register(SRCS "${gen_src}"
                       INCLUDE_DIRS "include")

idf_build_get_property(project_dir PROJECT_DIR)
idf_build_get_property(python PYTHON)
set(env_file "${project_dir}/.env")
set(env_example "${project_dir}/.env.example")

if(NOT EXISTS "${env_file}")
    message(WARNING "firmware/.env не найден — создаю из .env.example с заводскими значениями")
    file(COPY_FILE "${env_example}" "${env_file}")
endif()

add_custom_command(OUTPUT "${gen_src}"
                   COMMAND "${python}" "${CMAKE_CURRENT_SOURCE_DIR}/gen_defaults.py" "${env_file}" "${env_example}" "${gen_src}"
                   DEPENDS "${env_file}" "${env_example}" "${CMAKE_CURRENT_SOURCE_DIR}/gen_defaults.py"
                   COMMENT "Generating factory defaults from .env"
                   VERBATIM)
