add_library(CNIOHTTPParser STATIC
  c_nio_http_parser.c)
target_include_directories(CNIOHTTPParser PUBLIC
  include)
set_target_properties(CNIOHTTPParser PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_CURRENT_SOURCE_DIR}/include)
