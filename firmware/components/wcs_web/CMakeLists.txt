set(www_dir "${CMAKE_CURRENT_SOURCE_DIR}/www")
set(gen_src "${CMAKE_CURRENT_BINARY_DIR}/web_files_gen.c")
if(CMAKE_BUILD_EARLY_EXPANSION)
    file(GLOB_RECURSE www_files "${www_dir}/*")
else()
    file(GLOB_RECURSE www_files CONFIGURE_DEPENDS "${www_dir}/*")
    set(www_list "${CMAKE_CURRENT_BINARY_DIR}/www_files.txt")
    file(CONFIGURE OUTPUT "${www_list}" CONTENT "${www_files}")
endif()

idf_component_register(SRCS "wcs_web.c" "web_setup.c" "web_direct.c" "${gen_src}"
                       INCLUDE_DIRS "include"
                       PRIV_INCLUDE_DIRS "."
                       REQUIRES wcs_storage
                       PRIV_REQUIRES esp_http_server esp_https_server wcs_tls wcs_auth wcs_wifi wcs_bastion wcs_link esp_app_format esp_hw_support esp_timer)

idf_build_get_property(python PYTHON)
add_custom_command(OUTPUT "${gen_src}"
                   COMMAND "${python}" "${CMAKE_CURRENT_SOURCE_DIR}/gen_www.py" "${www_dir}" "${gen_src}"
                   DEPENDS ${www_files} "${www_list}" "${CMAKE_CURRENT_SOURCE_DIR}/gen_www.py"
                   COMMENT "Embedding web files from www/"
                   VERBATIM)
