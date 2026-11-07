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

execute_process(COMMAND "${python}" -B -c "import sys; sys.path.insert(0, sys.argv[1]); from gen_defaults import parse_env; e=parse_env(sys.argv[3]); e.update(parse_env(sys.argv[2])); print(e.get('WCS_LAPTOP_CA_FILE', ''))" "${CMAKE_CURRENT_SOURCE_DIR}" "${env_file}" "${env_example}"
                OUTPUT_VARIABLE laptop_ca_file OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
set(laptop_ca_dependency "")
if(laptop_ca_file)
    get_filename_component(laptop_ca_dependency "${laptop_ca_file}" ABSOLUTE BASE_DIR "${project_dir}")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${laptop_ca_dependency} "${env_file}" "${env_example}")

add_custom_command(OUTPUT "${gen_src}"
                   COMMAND "${python}" "${CMAKE_CURRENT_SOURCE_DIR}/gen_defaults.py" "${env_file}" "${env_example}" "${gen_src}"
                   DEPENDS ${laptop_ca_dependency} "${env_file}" "${env_example}" "${CMAKE_CURRENT_SOURCE_DIR}/gen_defaults.py"
                   COMMENT "Generating factory defaults from .env"
                   VERBATIM)
