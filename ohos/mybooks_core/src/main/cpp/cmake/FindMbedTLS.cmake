# FindMbedTLS.cmake — use vendored mbedtls targets built in this project.
# curl's CMake calls find_package(MbedTLS REQUIRED); we satisfy that with
# CMake target names instead of prebuilt .a paths.

if(TARGET mbedtls AND TARGET mbedx509 AND TARGET mbedcrypto)
  get_target_property(_mbedtls_inc mbedtls INTERFACE_INCLUDE_DIRECTORIES)
  if(NOT _mbedtls_inc)
    set(_mbedtls_inc "${MBEDTLS_SOURCE_DIR}/include")
  endif()
  set(MBEDTLS_INCLUDE_DIRS "${_mbedtls_inc}" CACHE PATH "mbedTLS include dirs" FORCE)
  set(MBEDTLS_LIBRARY mbedtls CACHE STRING "mbedTLS library" FORCE)
  set(MBEDX509_LIBRARY mbedx509 CACHE STRING "mbedX509 library" FORCE)
  set(MBEDCRYPTO_LIBRARY mbedcrypto CACHE STRING "mbedCrypto library" FORCE)
  set(MBEDTLS_LIBRARIES mbedtls mbedx509 mbedcrypto CACHE STRING "mbedTLS libs" FORCE)
  set(MbedTLS_FOUND TRUE)
  set(MBEDTLS_FOUND TRUE)
else()
  find_path(MBEDTLS_INCLUDE_DIRS mbedtls/ssl.h)
  find_library(MBEDTLS_LIBRARY mbedtls)
  find_library(MBEDX509_LIBRARY mbedx509)
  find_library(MBEDCRYPTO_LIBRARY mbedcrypto)
  set(MBEDTLS_LIBRARIES "${MBEDTLS_LIBRARY}" "${MBEDX509_LIBRARY}" "${MBEDCRYPTO_LIBRARY}")
endif()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(MbedTLS DEFAULT_MSG
    MBEDTLS_INCLUDE_DIRS MBEDTLS_LIBRARY MBEDX509_LIBRARY MBEDCRYPTO_LIBRARY)

mark_as_advanced(MBEDTLS_INCLUDE_DIRS MBEDTLS_LIBRARY MBEDX509_LIBRARY MBEDCRYPTO_LIBRARY)
