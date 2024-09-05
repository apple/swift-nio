/* Additional changes for SwiftNIO:
    - prefixed all symbols by 'c_nio_'
*/
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#ifdef __SSE4_2__
 #ifdef _MSC_VER
  #include <nmmintrin.h>
 #else  /* !_MSC_VER */
  #include <x86intrin.h>
 #endif  /* _MSC_VER */
#endif  /* __SSE4_2__ */

#ifdef _MSC_VER
 #define ALIGN(n) _declspec(align(n))
#else  /* !_MSC_VER */
 #define ALIGN(n) __attribute__((aligned(n)))
#endif  /* _MSC_VER */

#include "include/c_nio_llhttp.h"

typedef int (*c_nio_llhttp__internal__span_cb)(
             c_nio_llhttp__internal_t*, const char*, const char*);

static const unsigned char llparse_blob0[] = {
  0xd, 0xa
};
static const unsigned char llparse_blob1[] = {
  'o', 'n'
};
static const unsigned char llparse_blob2[] = {
  'e', 'c', 't', 'i', 'o', 'n'
};
static const unsigned char llparse_blob3[] = {
  'l', 'o', 's', 'e'
};
static const unsigned char llparse_blob4[] = {
  'e', 'e', 'p', '-', 'a', 'l', 'i', 'v', 'e'
};
static const unsigned char llparse_blob5[] = {
  'p', 'g', 'r', 'a', 'd', 'e'
};
static const unsigned char llparse_blob6[] = {
  'c', 'h', 'u', 'n', 'k', 'e', 'd'
};
#ifdef __SSE4_2__
static const unsigned char ALIGN(16) llparse_blob7[] = {
  0x9, 0x9, ' ', '~', 0x80, 0xff, 0x0, 0x0, 0x0, 0x0, 0x0,
  0x0, 0x0, 0x0, 0x0, 0x0
};
#endif  /* __SSE4_2__ */
#ifdef __SSE4_2__
static const unsigned char ALIGN(16) llparse_blob8[] = {
  '!', '!', '#', '\'', '*', '+', '-', '.', '0', '9', 'A',
  'Z', '^', 'z', '|', '|'
};
#endif  /* __SSE4_2__ */
#ifdef __SSE4_2__
static const unsigned char ALIGN(16) llparse_blob9[] = {
  '~', '~', 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
  0x0, 0x0, 0x0, 0x0, 0x0
};
#endif  /* __SSE4_2__ */
static const unsigned char llparse_blob10[] = {
  'e', 'n', 't', '-', 'l', 'e', 'n', 'g', 't', 'h'
};
static const unsigned char llparse_blob11[] = {
  'r', 'o', 'x', 'y', '-', 'c', 'o', 'n', 'n', 'e', 'c',
  't', 'i', 'o', 'n'
};
static const unsigned char llparse_blob12[] = {
  'r', 'a', 'n', 's', 'f', 'e', 'r', '-', 'e', 'n', 'c',
  'o', 'd', 'i', 'n', 'g'
};
static const unsigned char llparse_blob13[] = {
  'p', 'g', 'r', 'a', 'd', 'e'
};
static const unsigned char llparse_blob14[] = {
  'T', 'T', 'P', '/'
};
static const unsigned char llparse_blob15[] = {
  0xd, 0xa, 0xd, 0xa, 'S', 'M', 0xd, 0xa, 0xd, 0xa
};
static const unsigned char llparse_blob16[] = {
  'C', 'E', '/'
};
static const unsigned char llparse_blob17[] = {
  'T', 'S', 'P', '/'
};
static const unsigned char llparse_blob18[] = {
  'N', 'O', 'U', 'N', 'C', 'E'
};
static const unsigned char llparse_blob19[] = {
  'I', 'N', 'D'
};
static const unsigned char llparse_blob20[] = {
  'E', 'C', 'K', 'O', 'U', 'T'
};
static const unsigned char llparse_blob21[] = {
  'N', 'E', 'C', 'T'
};
static const unsigned char llparse_blob22[] = {
  'E', 'T', 'E'
};
static const unsigned char llparse_blob23[] = {
  'C', 'R', 'I', 'B', 'E'
};
static const unsigned char llparse_blob24[] = {
  'L', 'U', 'S', 'H'
};
static const unsigned char llparse_blob25[] = {
  'E', 'T'
};
static const unsigned char llparse_blob26[] = {
  'P', 'A', 'R', 'A', 'M', 'E', 'T', 'E', 'R'
};
static const unsigned char llparse_blob27[] = {
  'E', 'A', 'D'
};
static const unsigned char llparse_blob28[] = {
  'N', 'K'
};
static const unsigned char llparse_blob29[] = {
  'C', 'K'
};
static const unsigned char llparse_blob30[] = {
  'S', 'E', 'A', 'R', 'C', 'H'
};
static const unsigned char llparse_blob31[] = {
  'R', 'G', 'E'
};
static const unsigned char llparse_blob32[] = {
  'C', 'T', 'I', 'V', 'I', 'T', 'Y'
};
static const unsigned char llparse_blob33[] = {
  'L', 'E', 'N', 'D', 'A', 'R'
};
static const unsigned char llparse_blob34[] = {
  'V', 'E'
};
static const unsigned char llparse_blob35[] = {
  'O', 'T', 'I', 'F', 'Y'
};
static const unsigned char llparse_blob36[] = {
  'P', 'T', 'I', 'O', 'N', 'S'
};
static const unsigned char llparse_blob37[] = {
  'C', 'H'
};
static const unsigned char llparse_blob38[] = {
  'S', 'E'
};
static const unsigned char llparse_blob39[] = {
  'A', 'Y'
};
static const unsigned char llparse_blob40[] = {
  'S', 'T'
};
static const unsigned char llparse_blob41[] = {
  'I', 'N', 'D'
};
static const unsigned char llparse_blob42[] = {
  'A', 'T', 'C', 'H'
};
static const unsigned char llparse_blob43[] = {
  'G', 'E'
};
static const unsigned char llparse_blob44[] = {
  'I', 'N', 'D'
};
static const unsigned char llparse_blob45[] = {
  'O', 'R', 'D'
};
static const unsigned char llparse_blob46[] = {
  'I', 'R', 'E', 'C', 'T'
};
static const unsigned char llparse_blob47[] = {
  'O', 'R', 'T'
};
static const unsigned char llparse_blob48[] = {
  'R', 'C', 'H'
};
static const unsigned char llparse_blob49[] = {
  'P', 'A', 'R', 'A', 'M', 'E', 'T', 'E', 'R'
};
static const unsigned char llparse_blob50[] = {
  'U', 'R', 'C', 'E'
};
static const unsigned char llparse_blob51[] = {
  'B', 'S', 'C', 'R', 'I', 'B', 'E'
};
static const unsigned char llparse_blob52[] = {
  'A', 'R', 'D', 'O', 'W', 'N'
};
static const unsigned char llparse_blob53[] = {
  'A', 'C', 'E'
};
static const unsigned char llparse_blob54[] = {
  'I', 'N', 'D'
};
static const unsigned char llparse_blob55[] = {
  'N', 'K'
};
static const unsigned char llparse_blob56[] = {
  'C', 'K'
};
static const unsigned char llparse_blob57[] = {
  'U', 'B', 'S', 'C', 'R', 'I', 'B', 'E'
};
static const unsigned char llparse_blob58[] = {
  'H', 'T', 'T', 'P', '/'
};
static const unsigned char llparse_blob59[] = {
  'A', 'D'
};
static const unsigned char llparse_blob60[] = {
  'T', 'P', '/'
};

enum llparse_match_status_e {
  kMatchComplete,
  kMatchPause,
  kMatchMismatch
};
typedef enum llparse_match_status_e llparse_match_status_t;

struct llparse_match_s {
  llparse_match_status_t status;
  const unsigned char* current;
};
typedef struct llparse_match_s llparse_match_t;

static llparse_match_t llparse__match_sequence_id(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp,
    const unsigned char* seq, uint32_t seq_len) {
  uint32_t index;
  llparse_match_t res;

  index = s->_index;
  for (; p != endp; p++) {
    unsigned char current;

    current = *p;
    if (current == seq[index]) {
      if (++index == seq_len) {
        res.status = kMatchComplete;
        goto reset;
      }
    } else {
      res.status = kMatchMismatch;
      goto reset;
    }
  }
  s->_index = index;
  res.status = kMatchPause;
  res.current = p;
  return res;
reset:
  s->_index = 0;
  res.current = p;
  return res;
}

static llparse_match_t llparse__match_sequence_to_lower(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp,
    const unsigned char* seq, uint32_t seq_len) {
  uint32_t index;
  llparse_match_t res;

  index = s->_index;
  for (; p != endp; p++) {
    unsigned char current;

    current = ((*p) >= 'A' && (*p) <= 'Z' ? (*p | 0x20) : (*p));
    if (current == seq[index]) {
      if (++index == seq_len) {
        res.status = kMatchComplete;
        goto reset;
      }
    } else {
      res.status = kMatchMismatch;
      goto reset;
    }
  }
  s->_index = index;
  res.status = kMatchPause;
  res.current = p;
  return res;
reset:
  s->_index = 0;
  res.current = p;
  return res;
}

static llparse_match_t llparse__match_sequence_to_lower_unsafe(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp,
    const unsigned char* seq, uint32_t seq_len) {
  uint32_t index;
  llparse_match_t res;

  index = s->_index;
  for (; p != endp; p++) {
    unsigned char current;

    current = ((*p) | 0x20);
    if (current == seq[index]) {
      if (++index == seq_len) {
        res.status = kMatchComplete;
        goto reset;
      }
    } else {
      res.status = kMatchMismatch;
      goto reset;
    }
  }
  s->_index = index;
  res.status = kMatchPause;
  res.current = p;
  return res;
reset:
  s->_index = 0;
  res.current = p;
  return res;
}

enum llparse_state_e {
  s_error,
  s_n_llhttp__internal__n_closed,
  s_n_llhttp__internal__n_invoke_llhttp__after_message_complete,
  s_n_llhttp__internal__n_pause_1,
  s_n_llhttp__internal__n_chunk_data_almost_done,
  s_n_llhttp__internal__n_consume_content_length,
  s_n_llhttp__internal__n_span_start_llhttp__on_body,
  s_n_llhttp__internal__n_invoke_is_equal_content_length,
  s_n_llhttp__internal__n_chunk_size_almost_done,
  s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_name_complete,
  s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_name_complete_1,
  s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete,
  s_n_llhttp__internal__n_chunk_extension_quoted_value_done,
  s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete_1,
  s_n_llhttp__internal__n_error_21,
  s_n_llhttp__internal__n_chunk_extension_quoted_value,
  s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete_2,
  s_n_llhttp__internal__n_error_23,
  s_n_llhttp__internal__n_chunk_extension_value,
  s_n_llhttp__internal__n_span_start_llhttp__on_chunk_extension_value,
  s_n_llhttp__internal__n_error_24,
  s_n_llhttp__internal__n_chunk_extension_name,
  s_n_llhttp__internal__n_span_start_llhttp__on_chunk_extension_name,
  s_n_llhttp__internal__n_chunk_extensions,
  s_n_llhttp__internal__n_chunk_size_otherwise,
  s_n_llhttp__internal__n_chunk_size,
  s_n_llhttp__internal__n_chunk_size_digit,
  s_n_llhttp__internal__n_invoke_update_content_length_1,
  s_n_llhttp__internal__n_invoke_is_equal_upgrade,
  s_n_llhttp__internal__n_invoke_llhttp__on_message_complete_2,
  s_n_llhttp__internal__n_consume_content_length_1,
  s_n_llhttp__internal__n_span_start_llhttp__on_body_1,
  s_n_llhttp__internal__n_eof,
  s_n_llhttp__internal__n_span_start_llhttp__on_body_2,
  s_n_llhttp__internal__n_invoke_llhttp__after_headers_complete,
  s_n_llhttp__internal__n_error_5,
  s_n_llhttp__internal__n_headers_almost_done,
  s_n_llhttp__internal__n_header_field_colon_discard_ws,
  s_n_llhttp__internal__n_invoke_llhttp__on_header_value_complete,
  s_n_llhttp__internal__n_span_start_llhttp__on_header_value,
  s_n_llhttp__internal__n_header_value_discard_lws,
  s_n_llhttp__internal__n_header_value_discard_ws_almost_done,
  s_n_llhttp__internal__n_header_value_lws,
  s_n_llhttp__internal__n_header_value_almost_done,
  s_n_llhttp__internal__n_header_value_lenient,
  s_n_llhttp__internal__n_error_41,
  s_n_llhttp__internal__n_header_value_otherwise,
  s_n_llhttp__internal__n_header_value_connection_token,
  s_n_llhttp__internal__n_header_value_connection_ws,
  s_n_llhttp__internal__n_header_value_connection_1,
  s_n_llhttp__internal__n_header_value_connection_2,
  s_n_llhttp__internal__n_header_value_connection_3,
  s_n_llhttp__internal__n_header_value_connection,
  s_n_llhttp__internal__n_error_43,
  s_n_llhttp__internal__n_error_44,
  s_n_llhttp__internal__n_header_value_content_length_ws,
  s_n_llhttp__internal__n_header_value_content_length,
  s_n_llhttp__internal__n_error_46,
  s_n_llhttp__internal__n_error_45,
  s_n_llhttp__internal__n_header_value_te_token_ows,
  s_n_llhttp__internal__n_header_value,
  s_n_llhttp__internal__n_header_value_te_token,
  s_n_llhttp__internal__n_header_value_te_chunked_last,
  s_n_llhttp__internal__n_header_value_te_chunked,
  s_n_llhttp__internal__n_span_start_llhttp__on_header_value_1,
  s_n_llhttp__internal__n_header_value_discard_ws,
  s_n_llhttp__internal__n_invoke_llhttp__on_header_field_complete,
  s_n_llhttp__internal__n_header_field_general_otherwise,
  s_n_llhttp__internal__n_header_field_general,
  s_n_llhttp__internal__n_header_field_colon,
  s_n_llhttp__internal__n_header_field_3,
  s_n_llhttp__internal__n_header_field_4,
  s_n_llhttp__internal__n_header_field_2,
  s_n_llhttp__internal__n_header_field_1,
  s_n_llhttp__internal__n_header_field_5,
  s_n_llhttp__internal__n_header_field_6,
  s_n_llhttp__internal__n_header_field_7,
  s_n_llhttp__internal__n_header_field,
  s_n_llhttp__internal__n_span_start_llhttp__on_header_field,
  s_n_llhttp__internal__n_header_field_start,
  s_n_llhttp__internal__n_headers_start,
  s_n_llhttp__internal__n_url_to_http_09,
  s_n_llhttp__internal__n_url_skip_to_http09,
  s_n_llhttp__internal__n_url_skip_lf_to_http09_1,
  s_n_llhttp__internal__n_url_skip_lf_to_http09,
  s_n_llhttp__internal__n_req_pri_upgrade,
  s_n_llhttp__internal__n_req_http_complete_crlf,
  s_n_llhttp__internal__n_req_http_complete,
  s_n_llhttp__internal__n_invoke_load_method_1,
  s_n_llhttp__internal__n_invoke_llhttp__on_version_complete,
  s_n_llhttp__internal__n_error_51,
  s_n_llhttp__internal__n_error_57,
  s_n_llhttp__internal__n_req_http_minor,
  s_n_llhttp__internal__n_error_58,
  s_n_llhttp__internal__n_req_http_dot,
  s_n_llhttp__internal__n_error_59,
  s_n_llhttp__internal__n_req_http_major,
  s_n_llhttp__internal__n_span_start_llhttp__on_version,
  s_n_llhttp__internal__n_req_http_start_1,
  s_n_llhttp__internal__n_req_http_start_2,
  s_n_llhttp__internal__n_req_http_start_3,
  s_n_llhttp__internal__n_req_http_start,
  s_n_llhttp__internal__n_url_to_http,
  s_n_llhttp__internal__n_url_skip_to_http,
  s_n_llhttp__internal__n_url_fragment,
  s_n_llhttp__internal__n_span_end_stub_query_3,
  s_n_llhttp__internal__n_url_query,
  s_n_llhttp__internal__n_url_query_or_fragment,
  s_n_llhttp__internal__n_url_path,
  s_n_llhttp__internal__n_span_start_stub_path_2,
  s_n_llhttp__internal__n_span_start_stub_path,
  s_n_llhttp__internal__n_span_start_stub_path_1,
  s_n_llhttp__internal__n_url_server_with_at,
  s_n_llhttp__internal__n_url_server,
  s_n_llhttp__internal__n_url_schema_delim_1,
  s_n_llhttp__internal__n_url_schema_delim,
  s_n_llhttp__internal__n_span_end_stub_schema,
  s_n_llhttp__internal__n_url_schema,
  s_n_llhttp__internal__n_url_start,
  s_n_llhttp__internal__n_span_start_llhttp__on_url_1,
  s_n_llhttp__internal__n_url_entry_normal,
  s_n_llhttp__internal__n_span_start_llhttp__on_url,
  s_n_llhttp__internal__n_url_entry_connect,
  s_n_llhttp__internal__n_req_spaces_before_url,
  s_n_llhttp__internal__n_req_first_space_before_url,
  s_n_llhttp__internal__n_invoke_llhttp__on_method_complete_1,
  s_n_llhttp__internal__n_after_start_req_2,
  s_n_llhttp__internal__n_after_start_req_3,
  s_n_llhttp__internal__n_after_start_req_1,
  s_n_llhttp__internal__n_after_start_req_4,
  s_n_llhttp__internal__n_after_start_req_6,
  s_n_llhttp__internal__n_after_start_req_8,
  s_n_llhttp__internal__n_after_start_req_9,
  s_n_llhttp__internal__n_after_start_req_7,
  s_n_llhttp__internal__n_after_start_req_5,
  s_n_llhttp__internal__n_after_start_req_12,
  s_n_llhttp__internal__n_after_start_req_13,
  s_n_llhttp__internal__n_after_start_req_11,
  s_n_llhttp__internal__n_after_start_req_10,
  s_n_llhttp__internal__n_after_start_req_14,
  s_n_llhttp__internal__n_after_start_req_17,
  s_n_llhttp__internal__n_after_start_req_16,
  s_n_llhttp__internal__n_after_start_req_15,
  s_n_llhttp__internal__n_after_start_req_18,
  s_n_llhttp__internal__n_after_start_req_20,
  s_n_llhttp__internal__n_after_start_req_21,
  s_n_llhttp__internal__n_after_start_req_19,
  s_n_llhttp__internal__n_after_start_req_23,
  s_n_llhttp__internal__n_after_start_req_24,
  s_n_llhttp__internal__n_after_start_req_26,
  s_n_llhttp__internal__n_after_start_req_28,
  s_n_llhttp__internal__n_after_start_req_29,
  s_n_llhttp__internal__n_after_start_req_27,
  s_n_llhttp__internal__n_after_start_req_25,
  s_n_llhttp__internal__n_after_start_req_30,
  s_n_llhttp__internal__n_after_start_req_22,
  s_n_llhttp__internal__n_after_start_req_31,
  s_n_llhttp__internal__n_after_start_req_32,
  s_n_llhttp__internal__n_after_start_req_35,
  s_n_llhttp__internal__n_after_start_req_36,
  s_n_llhttp__internal__n_after_start_req_34,
  s_n_llhttp__internal__n_after_start_req_37,
  s_n_llhttp__internal__n_after_start_req_38,
  s_n_llhttp__internal__n_after_start_req_42,
  s_n_llhttp__internal__n_after_start_req_43,
  s_n_llhttp__internal__n_after_start_req_41,
  s_n_llhttp__internal__n_after_start_req_40,
  s_n_llhttp__internal__n_after_start_req_39,
  s_n_llhttp__internal__n_after_start_req_45,
  s_n_llhttp__internal__n_after_start_req_44,
  s_n_llhttp__internal__n_after_start_req_33,
  s_n_llhttp__internal__n_after_start_req_48,
  s_n_llhttp__internal__n_after_start_req_49,
  s_n_llhttp__internal__n_after_start_req_50,
  s_n_llhttp__internal__n_after_start_req_51,
  s_n_llhttp__internal__n_after_start_req_47,
  s_n_llhttp__internal__n_after_start_req_46,
  s_n_llhttp__internal__n_after_start_req_54,
  s_n_llhttp__internal__n_after_start_req_56,
  s_n_llhttp__internal__n_after_start_req_57,
  s_n_llhttp__internal__n_after_start_req_55,
  s_n_llhttp__internal__n_after_start_req_53,
  s_n_llhttp__internal__n_after_start_req_58,
  s_n_llhttp__internal__n_after_start_req_59,
  s_n_llhttp__internal__n_after_start_req_52,
  s_n_llhttp__internal__n_after_start_req_61,
  s_n_llhttp__internal__n_after_start_req_62,
  s_n_llhttp__internal__n_after_start_req_60,
  s_n_llhttp__internal__n_after_start_req_65,
  s_n_llhttp__internal__n_after_start_req_67,
  s_n_llhttp__internal__n_after_start_req_68,
  s_n_llhttp__internal__n_after_start_req_66,
  s_n_llhttp__internal__n_after_start_req_69,
  s_n_llhttp__internal__n_after_start_req_64,
  s_n_llhttp__internal__n_after_start_req_63,
  s_n_llhttp__internal__n_after_start_req,
  s_n_llhttp__internal__n_span_start_llhttp__on_method_1,
  s_n_llhttp__internal__n_res_line_almost_done,
  s_n_llhttp__internal__n_res_status,
  s_n_llhttp__internal__n_span_start_llhttp__on_status,
  s_n_llhttp__internal__n_res_status_start,
  s_n_llhttp__internal__n_res_status_code_otherwise,
  s_n_llhttp__internal__n_res_status_code_digit_3,
  s_n_llhttp__internal__n_res_status_code_digit_2,
  s_n_llhttp__internal__n_res_status_code_digit_1,
  s_n_llhttp__internal__n_res_after_version,
  s_n_llhttp__internal__n_invoke_llhttp__on_version_complete_1,
  s_n_llhttp__internal__n_error_73,
  s_n_llhttp__internal__n_error_85,
  s_n_llhttp__internal__n_res_http_minor,
  s_n_llhttp__internal__n_error_86,
  s_n_llhttp__internal__n_res_http_dot,
  s_n_llhttp__internal__n_error_87,
  s_n_llhttp__internal__n_res_http_major,
  s_n_llhttp__internal__n_span_start_llhttp__on_version_1,
  s_n_llhttp__internal__n_start_res,
  s_n_llhttp__internal__n_invoke_llhttp__on_method_complete,
  s_n_llhttp__internal__n_req_or_res_method_2,
  s_n_llhttp__internal__n_invoke_update_type_1,
  s_n_llhttp__internal__n_req_or_res_method_3,
  s_n_llhttp__internal__n_req_or_res_method_1,
  s_n_llhttp__internal__n_req_or_res_method,
  s_n_llhttp__internal__n_span_start_llhttp__on_method,
  s_n_llhttp__internal__n_start_req_or_res,
  s_n_llhttp__internal__n_invoke_load_type,
  s_n_llhttp__internal__n_invoke_update_finish,
  s_n_llhttp__internal__n_start,
};
typedef enum llparse_state_e llparse_state_t;

int c_nio_llhttp__on_method(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__on_url(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__on_version(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__on_header_field(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__on_header_value(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__on_body(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__on_chunk_extension_name(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__on_chunk_extension_value(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__on_status(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_load_initial_message_completed(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return state->initial_message_completed;
}

int c_nio_llhttp__on_reset(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_update_finish(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->finish = 2;
  return 0;
}

int c_nio_llhttp__on_message_begin(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_load_type(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return state->type;
}

int c_nio_llhttp__internal__c_store_method(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp,
    int match) {
  state->method = match;
  return 0;
}

int c_nio_llhttp__on_method_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_is_equal_method(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return state->method == 5;
}

int c_nio_llhttp__internal__c_update_http_major(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->http_major = 0;
  return 0;
}

int c_nio_llhttp__internal__c_update_http_minor(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->http_minor = 9;
  return 0;
}

int c_nio_llhttp__on_url_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_test_lenient_flags(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return (state->lenient_flags & 1) == 1;
}

int c_nio_llhttp__after_headers_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__on_message_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__after_message_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_update_content_length(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->content_length = 0;
  return 0;
}

int c_nio_llhttp__internal__c_update_initial_message_completed(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->initial_message_completed = 1;
  return 0;
}

int c_nio_llhttp__internal__c_update_finish_1(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->finish = 0;
  return 0;
}

int c_nio_llhttp__internal__c_test_lenient_flags_2(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return (state->lenient_flags & 4) == 4;
}

int c_nio_llhttp__internal__c_test_lenient_flags_3(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return (state->lenient_flags & 32) == 32;
}

int c_nio_llhttp__internal__c_mul_add_content_length(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp,
    int match) {
  /* Multiplication overflow */
  if (state->content_length > 0xffffffffffffffffULL / 16) {
    return 1;
  }
  
  state->content_length *= 16;
  
  /* Addition overflow */
  if (match >= 0) {
    if (state->content_length > 0xffffffffffffffffULL - match) {
      return 1;
    }
  } else {
    if (state->content_length < 0ULL - match) {
      return 1;
    }
  }
  state->content_length += match;
  return 0;
}

int c_nio_llhttp__on_chunk_header(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_is_equal_content_length(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return state->content_length == 0;
}

int c_nio_llhttp__on_chunk_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_test_lenient_flags_4(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return (state->lenient_flags & 128) == 128;
}

int c_nio_llhttp__internal__c_or_flags(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->flags |= 128;
  return 0;
}

int c_nio_llhttp__internal__c_test_lenient_flags_5(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return (state->lenient_flags & 64) == 64;
}

int c_nio_llhttp__on_chunk_extension_name_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__on_chunk_extension_value_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_is_equal_upgrade(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return state->upgrade == 1;
}

int c_nio_llhttp__internal__c_update_finish_3(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->finish = 1;
  return 0;
}

int c_nio_llhttp__internal__c_test_flags(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return (state->flags & 128) == 128;
}

int c_nio_llhttp__internal__c_test_flags_1(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return (state->flags & 544) == 544;
}

int c_nio_llhttp__internal__c_test_lenient_flags_6(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return (state->lenient_flags & 2) == 2;
}

int c_nio_llhttp__before_headers_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__on_headers_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_or_flags_1(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->flags |= 64;
  return 0;
}

int c_nio_llhttp__internal__c_update_upgrade(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->upgrade = 1;
  return 0;
}

int c_nio_llhttp__internal__c_store_header_state(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp,
    int match) {
  state->header_state = match;
  return 0;
}

int c_nio_llhttp__on_header_field_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_load_header_state(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return state->header_state;
}

int c_nio_llhttp__internal__c_or_flags_3(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->flags |= 1;
  return 0;
}

int c_nio_llhttp__internal__c_update_header_state(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->header_state = 1;
  return 0;
}

int c_nio_llhttp__on_header_value_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_or_flags_4(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->flags |= 2;
  return 0;
}

int c_nio_llhttp__internal__c_or_flags_5(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->flags |= 4;
  return 0;
}

int c_nio_llhttp__internal__c_or_flags_6(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->flags |= 8;
  return 0;
}

int c_nio_llhttp__internal__c_update_header_state_3(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->header_state = 6;
  return 0;
}

int c_nio_llhttp__internal__c_update_header_state_1(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->header_state = 0;
  return 0;
}

int c_nio_llhttp__internal__c_update_header_state_6(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->header_state = 5;
  return 0;
}

int c_nio_llhttp__internal__c_update_header_state_7(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->header_state = 7;
  return 0;
}

int c_nio_llhttp__internal__c_test_flags_2(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return (state->flags & 32) == 32;
}

int c_nio_llhttp__internal__c_mul_add_content_length_1(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp,
    int match) {
  /* Multiplication overflow */
  if (state->content_length > 0xffffffffffffffffULL / 10) {
    return 1;
  }
  
  state->content_length *= 10;
  
  /* Addition overflow */
  if (match >= 0) {
    if (state->content_length > 0xffffffffffffffffULL - match) {
      return 1;
    }
  } else {
    if (state->content_length < 0ULL - match) {
      return 1;
    }
  }
  state->content_length += match;
  return 0;
}

int c_nio_llhttp__internal__c_or_flags_15(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->flags |= 32;
  return 0;
}

int c_nio_llhttp__internal__c_test_flags_3(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return (state->flags & 8) == 8;
}

int c_nio_llhttp__internal__c_test_lenient_flags_13(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return (state->lenient_flags & 8) == 8;
}

int c_nio_llhttp__internal__c_or_flags_16(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->flags |= 512;
  return 0;
}

int c_nio_llhttp__internal__c_and_flags(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->flags &= -9;
  return 0;
}

int c_nio_llhttp__internal__c_update_header_state_8(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->header_state = 8;
  return 0;
}

int c_nio_llhttp__internal__c_or_flags_18(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->flags |= 16;
  return 0;
}

int c_nio_llhttp__internal__c_load_method(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return state->method;
}

int c_nio_llhttp__internal__c_store_http_major(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp,
    int match) {
  state->http_major = match;
  return 0;
}

int c_nio_llhttp__internal__c_store_http_minor(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp,
    int match) {
  state->http_minor = match;
  return 0;
}

int c_nio_llhttp__internal__c_test_lenient_flags_15(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return (state->lenient_flags & 16) == 16;
}

int c_nio_llhttp__on_version_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_load_http_major(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return state->http_major;
}

int c_nio_llhttp__internal__c_load_http_minor(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  return state->http_minor;
}

int c_nio_llhttp__internal__c_update_status_code(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->status_code = 0;
  return 0;
}

int c_nio_llhttp__internal__c_mul_add_status_code(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp,
    int match) {
  /* Multiplication overflow */
  if (state->status_code > 0xffff / 10) {
    return 1;
  }
  
  state->status_code *= 10;
  
  /* Addition overflow */
  if (match >= 0) {
    if (state->status_code > 0xffff - match) {
      return 1;
    }
  } else {
    if (state->status_code < 0 - match) {
      return 1;
    }
  }
  state->status_code += match;
  return 0;
}

int c_nio_llhttp__on_status_complete(
    c_nio_llhttp__internal_t* s, const unsigned char* p,
    const unsigned char* endp);

int c_nio_llhttp__internal__c_update_type(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->type = 1;
  return 0;
}

int c_nio_llhttp__internal__c_update_type_1(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  state->type = 2;
  return 0;
}

int c_nio_llhttp__internal_init(c_nio_llhttp__internal_t* state) {
  memset(state, 0, sizeof(*state));
  state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_start;
  return 0;
}

static llparse_state_t c_nio_llhttp__internal__run(
    c_nio_llhttp__internal_t* state,
    const unsigned char* p,
    const unsigned char* endp) {
  int match;
  switch ((llparse_state_t) (intptr_t) state->_current) {
    case s_n_llhttp__internal__n_closed:
    s_n_llhttp__internal__n_closed: {
      if (p == endp) {
        return s_n_llhttp__internal__n_closed;
      }
      switch (*p) {
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_closed;
        }
        case 13: {
          p++;
          goto s_n_llhttp__internal__n_closed;
        }
        default: {
          p++;
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_3;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__after_message_complete:
    s_n_llhttp__internal__n_invoke_llhttp__after_message_complete: {
      switch (c_nio_llhttp__after_message_complete(state, p, endp)) {
        case 1:
          goto s_n_llhttp__internal__n_invoke_update_content_length;
        default:
          goto s_n_llhttp__internal__n_invoke_update_finish_1;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_pause_1:
    s_n_llhttp__internal__n_pause_1: {
      state->error = 0x16;
      state->reason = "Pause on CONNECT/Upgrade";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__after_message_complete;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_chunk_data_almost_done:
    s_n_llhttp__internal__n_chunk_data_almost_done: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_chunk_data_almost_done;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob0, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_invoke_llhttp__on_chunk_complete;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_chunk_data_almost_done;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_4;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_consume_content_length:
    s_n_llhttp__internal__n_consume_content_length: {
      size_t avail;
      uint64_t need;
      
      avail = endp - p;
      need = state->content_length;
      if (avail >= need) {
        p += need;
        state->content_length = 0;
        goto s_n_llhttp__internal__n_span_end_llhttp__on_body;
      }
      
      state->content_length -= avail;
      return s_n_llhttp__internal__n_consume_content_length;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_body:
    s_n_llhttp__internal__n_span_start_llhttp__on_body: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_body;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_body;
      goto s_n_llhttp__internal__n_consume_content_length;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_is_equal_content_length:
    s_n_llhttp__internal__n_invoke_is_equal_content_length: {
      switch (c_nio_llhttp__internal__c_is_equal_content_length(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_span_start_llhttp__on_body;
        default:
          goto s_n_llhttp__internal__n_invoke_or_flags;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_chunk_size_almost_done:
    s_n_llhttp__internal__n_chunk_size_almost_done: {
      if (p == endp) {
        return s_n_llhttp__internal__n_chunk_size_almost_done;
      }
      switch (*p) {
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_invoke_llhttp__on_chunk_header;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_5;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_name_complete:
    s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_name_complete: {
      switch (c_nio_llhttp__on_chunk_extension_name_complete(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_chunk_size_almost_done;
        case 21:
          goto s_n_llhttp__internal__n_pause_5;
        default:
          goto s_n_llhttp__internal__n_error_15;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_name_complete_1:
    s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_name_complete_1: {
      switch (c_nio_llhttp__on_chunk_extension_name_complete(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_chunk_extensions;
        case 21:
          goto s_n_llhttp__internal__n_pause_6;
        default:
          goto s_n_llhttp__internal__n_error_16;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete:
    s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete: {
      switch (c_nio_llhttp__on_chunk_extension_value_complete(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_chunk_size_almost_done;
        case 21:
          goto s_n_llhttp__internal__n_pause_7;
        default:
          goto s_n_llhttp__internal__n_error_18;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_chunk_extension_quoted_value_done:
    s_n_llhttp__internal__n_chunk_extension_quoted_value_done: {
      if (p == endp) {
        return s_n_llhttp__internal__n_chunk_extension_quoted_value_done;
      }
      switch (*p) {
        case 13: {
          p++;
          goto s_n_llhttp__internal__n_chunk_size_almost_done;
        }
        case ';': {
          p++;
          goto s_n_llhttp__internal__n_chunk_extensions;
        }
        default: {
          goto s_n_llhttp__internal__n_error_20;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete_1:
    s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete_1: {
      switch (c_nio_llhttp__on_chunk_extension_value_complete(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_chunk_extension_quoted_value_done;
        case 21:
          goto s_n_llhttp__internal__n_pause_8;
        default:
          goto s_n_llhttp__internal__n_error_19;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_21:
    s_n_llhttp__internal__n_error_21: {
      state->error = 0x2;
      state->reason = "Invalid character in chunk extensions quoted value";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_chunk_extension_quoted_value:
    s_n_llhttp__internal__n_chunk_extension_quoted_value: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_chunk_extension_quoted_value;
      }
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          p++;
          goto s_n_llhttp__internal__n_chunk_extension_quoted_value;
        }
        case 2: {
          p++;
          goto s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_value_1;
        }
        default: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_value_2;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete_2:
    s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete_2: {
      switch (c_nio_llhttp__on_chunk_extension_value_complete(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_chunk_size_otherwise;
        case 21:
          goto s_n_llhttp__internal__n_pause_9;
        default:
          goto s_n_llhttp__internal__n_error_22;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_23:
    s_n_llhttp__internal__n_error_23: {
      state->error = 0x2;
      state->reason = "Invalid character in chunk extensions value";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_chunk_extension_value:
    s_n_llhttp__internal__n_chunk_extension_value: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 2, 3, 2, 2, 2, 2, 2, 0, 0, 2, 2, 0, 2, 2, 0,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 4, 0, 0, 0, 0,
        0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 2, 0, 2, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_chunk_extension_value;
      }
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_value;
        }
        case 2: {
          p++;
          goto s_n_llhttp__internal__n_chunk_extension_value;
        }
        case 3: {
          p++;
          goto s_n_llhttp__internal__n_chunk_extension_quoted_value;
        }
        case 4: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_value_3;
        }
        default: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_value_4;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_chunk_extension_value:
    s_n_llhttp__internal__n_span_start_llhttp__on_chunk_extension_value: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_chunk_extension_value;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_chunk_extension_value;
      goto s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_name_complete_2;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_24:
    s_n_llhttp__internal__n_error_24: {
      state->error = 0x2;
      state->reason = "Invalid character in chunk extensions name";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_chunk_extension_name:
    s_n_llhttp__internal__n_chunk_extension_name: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 2, 0, 2, 2, 2, 2, 2, 0, 0, 2, 2, 0, 2, 2, 0,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 3, 0, 4, 0, 0,
        0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 2, 0, 2, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_chunk_extension_name;
      }
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_name;
        }
        case 2: {
          p++;
          goto s_n_llhttp__internal__n_chunk_extension_name;
        }
        case 3: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_name_1;
        }
        case 4: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_name_2;
        }
        default: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_name_3;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_chunk_extension_name:
    s_n_llhttp__internal__n_span_start_llhttp__on_chunk_extension_name: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_chunk_extension_name;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_chunk_extension_name;
      goto s_n_llhttp__internal__n_chunk_extension_name;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_chunk_extensions:
    s_n_llhttp__internal__n_chunk_extensions: {
      if (p == endp) {
        return s_n_llhttp__internal__n_chunk_extensions;
      }
      switch (*p) {
        case 13: {
          p++;
          goto s_n_llhttp__internal__n_error_13;
        }
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_error_14;
        }
        default: {
          goto s_n_llhttp__internal__n_span_start_llhttp__on_chunk_extension_name;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_chunk_size_otherwise:
    s_n_llhttp__internal__n_chunk_size_otherwise: {
      if (p == endp) {
        return s_n_llhttp__internal__n_chunk_size_otherwise;
      }
      switch (*p) {
        case 13: {
          p++;
          goto s_n_llhttp__internal__n_chunk_size_almost_done;
        }
        case ';': {
          p++;
          goto s_n_llhttp__internal__n_chunk_extensions;
        }
        default: {
          goto s_n_llhttp__internal__n_error_25;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_chunk_size:
    s_n_llhttp__internal__n_chunk_size: {
      if (p == endp) {
        return s_n_llhttp__internal__n_chunk_size;
      }
      switch (*p) {
        case '0': {
          p++;
          match = 0;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '1': {
          p++;
          match = 1;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '2': {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '3': {
          p++;
          match = 3;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '4': {
          p++;
          match = 4;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '5': {
          p++;
          match = 5;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '6': {
          p++;
          match = 6;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '7': {
          p++;
          match = 7;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '8': {
          p++;
          match = 8;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '9': {
          p++;
          match = 9;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'A': {
          p++;
          match = 10;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'B': {
          p++;
          match = 11;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'C': {
          p++;
          match = 12;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'D': {
          p++;
          match = 13;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'E': {
          p++;
          match = 14;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'F': {
          p++;
          match = 15;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'a': {
          p++;
          match = 10;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'b': {
          p++;
          match = 11;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'c': {
          p++;
          match = 12;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'd': {
          p++;
          match = 13;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'e': {
          p++;
          match = 14;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'f': {
          p++;
          match = 15;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        default: {
          goto s_n_llhttp__internal__n_chunk_size_otherwise;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_chunk_size_digit:
    s_n_llhttp__internal__n_chunk_size_digit: {
      if (p == endp) {
        return s_n_llhttp__internal__n_chunk_size_digit;
      }
      switch (*p) {
        case '0': {
          p++;
          match = 0;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '1': {
          p++;
          match = 1;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '2': {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '3': {
          p++;
          match = 3;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '4': {
          p++;
          match = 4;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '5': {
          p++;
          match = 5;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '6': {
          p++;
          match = 6;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '7': {
          p++;
          match = 7;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '8': {
          p++;
          match = 8;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case '9': {
          p++;
          match = 9;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'A': {
          p++;
          match = 10;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'B': {
          p++;
          match = 11;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'C': {
          p++;
          match = 12;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'D': {
          p++;
          match = 13;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'E': {
          p++;
          match = 14;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'F': {
          p++;
          match = 15;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'a': {
          p++;
          match = 10;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'b': {
          p++;
          match = 11;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'c': {
          p++;
          match = 12;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'd': {
          p++;
          match = 13;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'e': {
          p++;
          match = 14;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        case 'f': {
          p++;
          match = 15;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length;
        }
        default: {
          goto s_n_llhttp__internal__n_error_27;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_update_content_length_1:
    s_n_llhttp__internal__n_invoke_update_content_length_1: {
      switch (c_nio_llhttp__internal__c_update_content_length(state, p, endp)) {
        default:
          goto s_n_llhttp__internal__n_chunk_size_digit;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_is_equal_upgrade:
    s_n_llhttp__internal__n_invoke_is_equal_upgrade: {
      switch (c_nio_llhttp__internal__c_is_equal_upgrade(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_invoke_llhttp__after_message_complete;
        default:
          goto s_n_llhttp__internal__n_pause_1;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__on_message_complete_2:
    s_n_llhttp__internal__n_invoke_llhttp__on_message_complete_2: {
      switch (c_nio_llhttp__on_message_complete(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_invoke_is_equal_upgrade;
        case 21:
          goto s_n_llhttp__internal__n_pause_11;
        default:
          goto s_n_llhttp__internal__n_error_28;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_consume_content_length_1:
    s_n_llhttp__internal__n_consume_content_length_1: {
      size_t avail;
      uint64_t need;
      
      avail = endp - p;
      need = state->content_length;
      if (avail >= need) {
        p += need;
        state->content_length = 0;
        goto s_n_llhttp__internal__n_span_end_llhttp__on_body_1;
      }
      
      state->content_length -= avail;
      return s_n_llhttp__internal__n_consume_content_length_1;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_body_1:
    s_n_llhttp__internal__n_span_start_llhttp__on_body_1: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_body_1;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_body;
      goto s_n_llhttp__internal__n_consume_content_length_1;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_eof:
    s_n_llhttp__internal__n_eof: {
      if (p == endp) {
        return s_n_llhttp__internal__n_eof;
      }
      p++;
      goto s_n_llhttp__internal__n_eof;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_body_2:
    s_n_llhttp__internal__n_span_start_llhttp__on_body_2: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_body_2;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_body;
      goto s_n_llhttp__internal__n_eof;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__after_headers_complete:
    s_n_llhttp__internal__n_invoke_llhttp__after_headers_complete: {
      switch (c_nio_llhttp__after_headers_complete(state, p, endp)) {
        case 1:
          goto s_n_llhttp__internal__n_invoke_llhttp__on_message_complete_1;
        case 2:
          goto s_n_llhttp__internal__n_invoke_update_content_length_1;
        case 3:
          goto s_n_llhttp__internal__n_span_start_llhttp__on_body_1;
        case 4:
          goto s_n_llhttp__internal__n_invoke_update_finish_3;
        case 5:
          goto s_n_llhttp__internal__n_error_29;
        default:
          goto s_n_llhttp__internal__n_invoke_llhttp__on_message_complete;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_5:
    s_n_llhttp__internal__n_error_5: {
      state->error = 0xa;
      state->reason = "Invalid header field char";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_headers_almost_done:
    s_n_llhttp__internal__n_headers_almost_done: {
      if (p == endp) {
        return s_n_llhttp__internal__n_headers_almost_done;
      }
      switch (*p) {
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_invoke_test_flags;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_7;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field_colon_discard_ws:
    s_n_llhttp__internal__n_header_field_colon_discard_ws: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field_colon_discard_ws;
      }
      switch (*p) {
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_header_field_colon_discard_ws;
        }
        default: {
          goto s_n_llhttp__internal__n_header_field_colon;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__on_header_value_complete:
    s_n_llhttp__internal__n_invoke_llhttp__on_header_value_complete: {
      switch (c_nio_llhttp__on_header_value_complete(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_header_field_start;
        case 21:
          goto s_n_llhttp__internal__n_pause_14;
        default:
          goto s_n_llhttp__internal__n_error_37;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_header_value:
    s_n_llhttp__internal__n_span_start_llhttp__on_header_value: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_header_value;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_header_value;
      goto s_n_llhttp__internal__n_span_end_llhttp__on_header_value;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_discard_lws:
    s_n_llhttp__internal__n_header_value_discard_lws: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_discard_lws;
      }
      switch (*p) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_10;
        }
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_10;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_load_header_state;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_discard_ws_almost_done:
    s_n_llhttp__internal__n_header_value_discard_ws_almost_done: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_discard_ws_almost_done;
      }
      switch (*p) {
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_header_value_discard_lws;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_11;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_lws:
    s_n_llhttp__internal__n_header_value_lws: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_lws;
      }
      switch (*p) {
        case 9: {
          goto s_n_llhttp__internal__n_invoke_load_header_state_3;
        }
        case ' ': {
          goto s_n_llhttp__internal__n_invoke_load_header_state_3;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_load_header_state_4;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_almost_done:
    s_n_llhttp__internal__n_header_value_almost_done: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_almost_done;
      }
      switch (*p) {
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_header_value_lws;
        }
        default: {
          goto s_n_llhttp__internal__n_error_40;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_lenient:
    s_n_llhttp__internal__n_header_value_lenient: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_lenient;
      }
      switch (*p) {
        case 10: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_header_value_3;
        }
        case 13: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_header_value_4;
        }
        default: {
          p++;
          goto s_n_llhttp__internal__n_header_value_lenient;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_41:
    s_n_llhttp__internal__n_error_41: {
      state->error = 0xa;
      state->reason = "Invalid header value char";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_otherwise:
    s_n_llhttp__internal__n_header_value_otherwise: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_otherwise;
      }
      switch (*p) {
        case 13: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_header_value_1;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_12;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_connection_token:
    s_n_llhttp__internal__n_header_value_connection_token: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_connection_token;
      }
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          p++;
          goto s_n_llhttp__internal__n_header_value_connection_token;
        }
        case 2: {
          p++;
          goto s_n_llhttp__internal__n_header_value_connection;
        }
        default: {
          goto s_n_llhttp__internal__n_header_value_otherwise;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_connection_ws:
    s_n_llhttp__internal__n_header_value_connection_ws: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_connection_ws;
      }
      switch (*p) {
        case 10: {
          goto s_n_llhttp__internal__n_header_value_otherwise;
        }
        case 13: {
          goto s_n_llhttp__internal__n_header_value_otherwise;
        }
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_header_value_connection_ws;
        }
        case ',': {
          p++;
          goto s_n_llhttp__internal__n_invoke_load_header_state_5;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_5;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_connection_1:
    s_n_llhttp__internal__n_header_value_connection_1: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_connection_1;
      }
      match_seq = llparse__match_sequence_to_lower(state, p, endp, llparse_blob3, 4);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_invoke_update_header_state_3;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_header_value_connection_1;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_header_value_connection_token;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_connection_2:
    s_n_llhttp__internal__n_header_value_connection_2: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_connection_2;
      }
      match_seq = llparse__match_sequence_to_lower(state, p, endp, llparse_blob4, 9);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_invoke_update_header_state_6;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_header_value_connection_2;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_header_value_connection_token;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_connection_3:
    s_n_llhttp__internal__n_header_value_connection_3: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_connection_3;
      }
      match_seq = llparse__match_sequence_to_lower(state, p, endp, llparse_blob5, 6);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_invoke_update_header_state_7;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_header_value_connection_3;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_header_value_connection_token;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_connection:
    s_n_llhttp__internal__n_header_value_connection: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_connection;
      }
      switch (((*p) >= 'A' && (*p) <= 'Z' ? (*p | 0x20) : (*p))) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_header_value_connection;
        }
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_header_value_connection;
        }
        case 'c': {
          p++;
          goto s_n_llhttp__internal__n_header_value_connection_1;
        }
        case 'k': {
          p++;
          goto s_n_llhttp__internal__n_header_value_connection_2;
        }
        case 'u': {
          p++;
          goto s_n_llhttp__internal__n_header_value_connection_3;
        }
        default: {
          goto s_n_llhttp__internal__n_header_value_connection_token;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_43:
    s_n_llhttp__internal__n_error_43: {
      state->error = 0xb;
      state->reason = "Content-Length overflow";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_44:
    s_n_llhttp__internal__n_error_44: {
      state->error = 0xb;
      state->reason = "Invalid character in Content-Length";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_content_length_ws:
    s_n_llhttp__internal__n_header_value_content_length_ws: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_content_length_ws;
      }
      switch (*p) {
        case 10: {
          goto s_n_llhttp__internal__n_invoke_or_flags_15;
        }
        case 13: {
          goto s_n_llhttp__internal__n_invoke_or_flags_15;
        }
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_header_value_content_length_ws;
        }
        default: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_header_value_6;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_content_length:
    s_n_llhttp__internal__n_header_value_content_length: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_content_length;
      }
      switch (*p) {
        case '0': {
          p++;
          match = 0;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length_1;
        }
        case '1': {
          p++;
          match = 1;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length_1;
        }
        case '2': {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length_1;
        }
        case '3': {
          p++;
          match = 3;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length_1;
        }
        case '4': {
          p++;
          match = 4;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length_1;
        }
        case '5': {
          p++;
          match = 5;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length_1;
        }
        case '6': {
          p++;
          match = 6;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length_1;
        }
        case '7': {
          p++;
          match = 7;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length_1;
        }
        case '8': {
          p++;
          match = 8;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length_1;
        }
        case '9': {
          p++;
          match = 9;
          goto s_n_llhttp__internal__n_invoke_mul_add_content_length_1;
        }
        default: {
          goto s_n_llhttp__internal__n_header_value_content_length_ws;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_46:
    s_n_llhttp__internal__n_error_46: {
      state->error = 0xf;
      state->reason = "Invalid `Transfer-Encoding` header value";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_45:
    s_n_llhttp__internal__n_error_45: {
      state->error = 0xf;
      state->reason = "Invalid `Transfer-Encoding` header value";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_te_token_ows:
    s_n_llhttp__internal__n_header_value_te_token_ows: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_te_token_ows;
      }
      switch (*p) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_header_value_te_token_ows;
        }
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_header_value_te_token_ows;
        }
        default: {
          goto s_n_llhttp__internal__n_header_value_te_chunked;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value:
    s_n_llhttp__internal__n_header_value: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value;
      }
      #ifdef __SSE4_2__
      if (endp - p >= 16) {
        __m128i ranges;
        __m128i input;
        int avail;
        int match_len;
      
        /* Load input */
        input = _mm_loadu_si128((__m128i const*) p);
        ranges = _mm_loadu_si128((__m128i const*) llparse_blob7);
      
        /* Find first character that does not match `ranges` */
        match_len = _mm_cmpestri(ranges, 6,
            input, 16,
            _SIDD_UBYTE_OPS | _SIDD_CMP_RANGES |
              _SIDD_NEGATIVE_POLARITY);
      
        if (match_len != 0) {
          p += match_len;
          goto s_n_llhttp__internal__n_header_value;
        }
        goto s_n_llhttp__internal__n_header_value_otherwise;
      }
      #endif  /* __SSE4_2__ */
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          p++;
          goto s_n_llhttp__internal__n_header_value;
        }
        default: {
          goto s_n_llhttp__internal__n_header_value_otherwise;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_te_token:
    s_n_llhttp__internal__n_header_value_te_token: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_te_token;
      }
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          p++;
          goto s_n_llhttp__internal__n_header_value_te_token;
        }
        case 2: {
          p++;
          goto s_n_llhttp__internal__n_header_value_te_token_ows;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_9;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_te_chunked_last:
    s_n_llhttp__internal__n_header_value_te_chunked_last: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_te_chunked_last;
      }
      switch (*p) {
        case 10: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_8;
        }
        case 13: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_8;
        }
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_header_value_te_chunked_last;
        }
        case ',': {
          goto s_n_llhttp__internal__n_invoke_load_type_1;
        }
        default: {
          goto s_n_llhttp__internal__n_header_value_te_token;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_te_chunked:
    s_n_llhttp__internal__n_header_value_te_chunked: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_te_chunked;
      }
      match_seq = llparse__match_sequence_to_lower_unsafe(state, p, endp, llparse_blob6, 7);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_header_value_te_chunked_last;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_header_value_te_chunked;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_header_value_te_token;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_header_value_1:
    s_n_llhttp__internal__n_span_start_llhttp__on_header_value_1: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_header_value_1;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_header_value;
      goto s_n_llhttp__internal__n_invoke_load_header_state_2;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_value_discard_ws:
    s_n_llhttp__internal__n_header_value_discard_ws: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_value_discard_ws;
      }
      switch (*p) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_header_value_discard_ws;
        }
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_9;
        }
        case 13: {
          p++;
          goto s_n_llhttp__internal__n_header_value_discard_ws_almost_done;
        }
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_header_value_discard_ws;
        }
        default: {
          goto s_n_llhttp__internal__n_span_start_llhttp__on_header_value_1;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__on_header_field_complete:
    s_n_llhttp__internal__n_invoke_llhttp__on_header_field_complete: {
      switch (c_nio_llhttp__on_header_field_complete(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_header_value_discard_ws;
        case 21:
          goto s_n_llhttp__internal__n_pause_15;
        default:
          goto s_n_llhttp__internal__n_error_34;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field_general_otherwise:
    s_n_llhttp__internal__n_header_field_general_otherwise: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field_general_otherwise;
      }
      switch (*p) {
        case ':': {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_header_field_2;
        }
        default: {
          goto s_n_llhttp__internal__n_error_47;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field_general:
    s_n_llhttp__internal__n_header_field_general: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 1, 0, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field_general;
      }
      #ifdef __SSE4_2__
      if (endp - p >= 16) {
        __m128i ranges;
        __m128i input;
        int avail;
        int match_len;
      
        /* Load input */
        input = _mm_loadu_si128((__m128i const*) p);
        ranges = _mm_loadu_si128((__m128i const*) llparse_blob8);
      
        /* Find first character that does not match `ranges` */
        match_len = _mm_cmpestri(ranges, 16,
            input, 16,
            _SIDD_UBYTE_OPS | _SIDD_CMP_RANGES |
              _SIDD_NEGATIVE_POLARITY);
      
        if (match_len != 0) {
          p += match_len;
          goto s_n_llhttp__internal__n_header_field_general;
        }
        ranges = _mm_loadu_si128((__m128i const*) llparse_blob9);
      
        /* Find first character that does not match `ranges` */
        match_len = _mm_cmpestri(ranges, 2,
            input, 16,
            _SIDD_UBYTE_OPS | _SIDD_CMP_RANGES |
              _SIDD_NEGATIVE_POLARITY);
      
        if (match_len != 0) {
          p += match_len;
          goto s_n_llhttp__internal__n_header_field_general;
        }
        goto s_n_llhttp__internal__n_header_field_general_otherwise;
      }
      #endif  /* __SSE4_2__ */
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          p++;
          goto s_n_llhttp__internal__n_header_field_general;
        }
        default: {
          goto s_n_llhttp__internal__n_header_field_general_otherwise;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field_colon:
    s_n_llhttp__internal__n_header_field_colon: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field_colon;
      }
      switch (*p) {
        case ' ': {
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_8;
        }
        case ':': {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_header_field_1;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_10;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field_3:
    s_n_llhttp__internal__n_header_field_3: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field_3;
      }
      match_seq = llparse__match_sequence_to_lower(state, p, endp, llparse_blob2, 6);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 1;
          goto s_n_llhttp__internal__n_invoke_store_header_state;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_header_field_3;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_11;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field_4:
    s_n_llhttp__internal__n_header_field_4: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field_4;
      }
      match_seq = llparse__match_sequence_to_lower(state, p, endp, llparse_blob10, 10);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_store_header_state;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_header_field_4;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_11;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field_2:
    s_n_llhttp__internal__n_header_field_2: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field_2;
      }
      switch (((*p) >= 'A' && (*p) <= 'Z' ? (*p | 0x20) : (*p))) {
        case 'n': {
          p++;
          goto s_n_llhttp__internal__n_header_field_3;
        }
        case 't': {
          p++;
          goto s_n_llhttp__internal__n_header_field_4;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_11;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field_1:
    s_n_llhttp__internal__n_header_field_1: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field_1;
      }
      match_seq = llparse__match_sequence_to_lower(state, p, endp, llparse_blob1, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_header_field_2;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_header_field_1;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_11;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field_5:
    s_n_llhttp__internal__n_header_field_5: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field_5;
      }
      match_seq = llparse__match_sequence_to_lower(state, p, endp, llparse_blob11, 15);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 1;
          goto s_n_llhttp__internal__n_invoke_store_header_state;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_header_field_5;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_11;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field_6:
    s_n_llhttp__internal__n_header_field_6: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field_6;
      }
      match_seq = llparse__match_sequence_to_lower(state, p, endp, llparse_blob12, 16);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 3;
          goto s_n_llhttp__internal__n_invoke_store_header_state;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_header_field_6;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_11;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field_7:
    s_n_llhttp__internal__n_header_field_7: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field_7;
      }
      match_seq = llparse__match_sequence_to_lower(state, p, endp, llparse_blob13, 6);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 4;
          goto s_n_llhttp__internal__n_invoke_store_header_state;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_header_field_7;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_11;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field:
    s_n_llhttp__internal__n_header_field: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field;
      }
      switch (((*p) >= 'A' && (*p) <= 'Z' ? (*p | 0x20) : (*p))) {
        case 'c': {
          p++;
          goto s_n_llhttp__internal__n_header_field_1;
        }
        case 'p': {
          p++;
          goto s_n_llhttp__internal__n_header_field_5;
        }
        case 't': {
          p++;
          goto s_n_llhttp__internal__n_header_field_6;
        }
        case 'u': {
          p++;
          goto s_n_llhttp__internal__n_header_field_7;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_update_header_state_11;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_header_field:
    s_n_llhttp__internal__n_span_start_llhttp__on_header_field: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_header_field;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_header_field;
      goto s_n_llhttp__internal__n_header_field;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_header_field_start:
    s_n_llhttp__internal__n_header_field_start: {
      if (p == endp) {
        return s_n_llhttp__internal__n_header_field_start;
      }
      switch (*p) {
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_1;
        }
        case 13: {
          p++;
          goto s_n_llhttp__internal__n_headers_almost_done;
        }
        default: {
          goto s_n_llhttp__internal__n_span_start_llhttp__on_header_field;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_headers_start:
    s_n_llhttp__internal__n_headers_start: {
      if (p == endp) {
        return s_n_llhttp__internal__n_headers_start;
      }
      switch (*p) {
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags;
        }
        default: {
          goto s_n_llhttp__internal__n_header_field_start;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_to_http_09:
    s_n_llhttp__internal__n_url_to_http_09: {
      if (p == endp) {
        return s_n_llhttp__internal__n_url_to_http_09;
      }
      switch (*p) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 12: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_update_http_major;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_skip_to_http09:
    s_n_llhttp__internal__n_url_skip_to_http09: {
      if (p == endp) {
        return s_n_llhttp__internal__n_url_skip_to_http09;
      }
      switch (*p) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 12: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        default: {
          p++;
          goto s_n_llhttp__internal__n_url_to_http_09;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_skip_lf_to_http09_1:
    s_n_llhttp__internal__n_url_skip_lf_to_http09_1: {
      if (p == endp) {
        return s_n_llhttp__internal__n_url_skip_lf_to_http09_1;
      }
      switch (*p) {
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_url_to_http_09;
        }
        default: {
          goto s_n_llhttp__internal__n_error_48;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_skip_lf_to_http09:
    s_n_llhttp__internal__n_url_skip_lf_to_http09: {
      if (p == endp) {
        return s_n_llhttp__internal__n_url_skip_lf_to_http09;
      }
      switch (*p) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 12: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 13: {
          p++;
          goto s_n_llhttp__internal__n_url_skip_lf_to_http09_1;
        }
        default: {
          goto s_n_llhttp__internal__n_error_48;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_pri_upgrade:
    s_n_llhttp__internal__n_req_pri_upgrade: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_req_pri_upgrade;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob15, 10);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_error_55;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_req_pri_upgrade;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_56;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_http_complete_crlf:
    s_n_llhttp__internal__n_req_http_complete_crlf: {
      if (p == endp) {
        return s_n_llhttp__internal__n_req_http_complete_crlf;
      }
      switch (*p) {
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_headers_start;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_16;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_http_complete:
    s_n_llhttp__internal__n_req_http_complete: {
      if (p == endp) {
        return s_n_llhttp__internal__n_req_http_complete;
      }
      switch (*p) {
        case 13: {
          p++;
          goto s_n_llhttp__internal__n_req_http_complete_crlf;
        }
        default: {
          goto s_n_llhttp__internal__n_error_54;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_load_method_1:
    s_n_llhttp__internal__n_invoke_load_method_1: {
      switch (c_nio_llhttp__internal__c_load_method(state, p, endp)) {
        case 34:
          goto s_n_llhttp__internal__n_req_pri_upgrade;
        default:
          goto s_n_llhttp__internal__n_req_http_complete;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__on_version_complete:
    s_n_llhttp__internal__n_invoke_llhttp__on_version_complete: {
      switch (c_nio_llhttp__on_version_complete(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_invoke_load_method_1;
        case 21:
          goto s_n_llhttp__internal__n_pause_17;
        default:
          goto s_n_llhttp__internal__n_error_52;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_51:
    s_n_llhttp__internal__n_error_51: {
      state->error = 0x9;
      state->reason = "Invalid HTTP version";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_57:
    s_n_llhttp__internal__n_error_57: {
      state->error = 0x9;
      state->reason = "Invalid minor version";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_http_minor:
    s_n_llhttp__internal__n_req_http_minor: {
      if (p == endp) {
        return s_n_llhttp__internal__n_req_http_minor;
      }
      switch (*p) {
        case '0': {
          p++;
          match = 0;
          goto s_n_llhttp__internal__n_invoke_store_http_minor;
        }
        case '1': {
          p++;
          match = 1;
          goto s_n_llhttp__internal__n_invoke_store_http_minor;
        }
        case '2': {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_store_http_minor;
        }
        case '3': {
          p++;
          match = 3;
          goto s_n_llhttp__internal__n_invoke_store_http_minor;
        }
        case '4': {
          p++;
          match = 4;
          goto s_n_llhttp__internal__n_invoke_store_http_minor;
        }
        case '5': {
          p++;
          match = 5;
          goto s_n_llhttp__internal__n_invoke_store_http_minor;
        }
        case '6': {
          p++;
          match = 6;
          goto s_n_llhttp__internal__n_invoke_store_http_minor;
        }
        case '7': {
          p++;
          match = 7;
          goto s_n_llhttp__internal__n_invoke_store_http_minor;
        }
        case '8': {
          p++;
          match = 8;
          goto s_n_llhttp__internal__n_invoke_store_http_minor;
        }
        case '9': {
          p++;
          match = 9;
          goto s_n_llhttp__internal__n_invoke_store_http_minor;
        }
        default: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_version_2;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_58:
    s_n_llhttp__internal__n_error_58: {
      state->error = 0x9;
      state->reason = "Expected dot";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_http_dot:
    s_n_llhttp__internal__n_req_http_dot: {
      if (p == endp) {
        return s_n_llhttp__internal__n_req_http_dot;
      }
      switch (*p) {
        case '.': {
          p++;
          goto s_n_llhttp__internal__n_req_http_minor;
        }
        default: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_version_3;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_59:
    s_n_llhttp__internal__n_error_59: {
      state->error = 0x9;
      state->reason = "Invalid major version";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_http_major:
    s_n_llhttp__internal__n_req_http_major: {
      if (p == endp) {
        return s_n_llhttp__internal__n_req_http_major;
      }
      switch (*p) {
        case '0': {
          p++;
          match = 0;
          goto s_n_llhttp__internal__n_invoke_store_http_major;
        }
        case '1': {
          p++;
          match = 1;
          goto s_n_llhttp__internal__n_invoke_store_http_major;
        }
        case '2': {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_store_http_major;
        }
        case '3': {
          p++;
          match = 3;
          goto s_n_llhttp__internal__n_invoke_store_http_major;
        }
        case '4': {
          p++;
          match = 4;
          goto s_n_llhttp__internal__n_invoke_store_http_major;
        }
        case '5': {
          p++;
          match = 5;
          goto s_n_llhttp__internal__n_invoke_store_http_major;
        }
        case '6': {
          p++;
          match = 6;
          goto s_n_llhttp__internal__n_invoke_store_http_major;
        }
        case '7': {
          p++;
          match = 7;
          goto s_n_llhttp__internal__n_invoke_store_http_major;
        }
        case '8': {
          p++;
          match = 8;
          goto s_n_llhttp__internal__n_invoke_store_http_major;
        }
        case '9': {
          p++;
          match = 9;
          goto s_n_llhttp__internal__n_invoke_store_http_major;
        }
        default: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_version_4;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_version:
    s_n_llhttp__internal__n_span_start_llhttp__on_version: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_version;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_version;
      goto s_n_llhttp__internal__n_req_http_major;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_http_start_1:
    s_n_llhttp__internal__n_req_http_start_1: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_req_http_start_1;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob14, 4);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_invoke_load_method;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_req_http_start_1;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_62;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_http_start_2:
    s_n_llhttp__internal__n_req_http_start_2: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_req_http_start_2;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob16, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_invoke_load_method_2;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_req_http_start_2;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_62;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_http_start_3:
    s_n_llhttp__internal__n_req_http_start_3: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_req_http_start_3;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob17, 4);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_invoke_load_method_3;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_req_http_start_3;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_62;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_http_start:
    s_n_llhttp__internal__n_req_http_start: {
      if (p == endp) {
        return s_n_llhttp__internal__n_req_http_start;
      }
      switch (*p) {
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_req_http_start;
        }
        case 'H': {
          p++;
          goto s_n_llhttp__internal__n_req_http_start_1;
        }
        case 'I': {
          p++;
          goto s_n_llhttp__internal__n_req_http_start_2;
        }
        case 'R': {
          p++;
          goto s_n_llhttp__internal__n_req_http_start_3;
        }
        default: {
          goto s_n_llhttp__internal__n_error_62;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_to_http:
    s_n_llhttp__internal__n_url_to_http: {
      if (p == endp) {
        return s_n_llhttp__internal__n_url_to_http;
      }
      switch (*p) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 12: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_llhttp__on_url_complete_1;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_skip_to_http:
    s_n_llhttp__internal__n_url_skip_to_http: {
      if (p == endp) {
        return s_n_llhttp__internal__n_url_skip_to_http;
      }
      switch (*p) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 12: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        default: {
          p++;
          goto s_n_llhttp__internal__n_url_to_http;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_fragment:
    s_n_llhttp__internal__n_url_fragment: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 0, 1, 3, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_url_fragment;
      }
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 2: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_6;
        }
        case 3: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_7;
        }
        case 4: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_8;
        }
        case 5: {
          p++;
          goto s_n_llhttp__internal__n_url_fragment;
        }
        default: {
          goto s_n_llhttp__internal__n_error_63;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_end_stub_query_3:
    s_n_llhttp__internal__n_span_end_stub_query_3: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_end_stub_query_3;
      }
      p++;
      goto s_n_llhttp__internal__n_url_fragment;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_query:
    s_n_llhttp__internal__n_url_query: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 0, 1, 3, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        4, 5, 5, 6, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_url_query;
      }
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 2: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_9;
        }
        case 3: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_10;
        }
        case 4: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_11;
        }
        case 5: {
          p++;
          goto s_n_llhttp__internal__n_url_query;
        }
        case 6: {
          goto s_n_llhttp__internal__n_span_end_stub_query_3;
        }
        default: {
          goto s_n_llhttp__internal__n_error_64;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_query_or_fragment:
    s_n_llhttp__internal__n_url_query_or_fragment: {
      if (p == endp) {
        return s_n_llhttp__internal__n_url_query_or_fragment;
      }
      switch (*p) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 10: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_3;
        }
        case 12: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 13: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_4;
        }
        case ' ': {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_5;
        }
        case '#': {
          p++;
          goto s_n_llhttp__internal__n_url_fragment;
        }
        case '?': {
          p++;
          goto s_n_llhttp__internal__n_url_query;
        }
        default: {
          goto s_n_llhttp__internal__n_error_65;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_path:
    s_n_llhttp__internal__n_url_path: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 2, 2, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_url_path;
      }
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 2: {
          p++;
          goto s_n_llhttp__internal__n_url_path;
        }
        default: {
          goto s_n_llhttp__internal__n_url_query_or_fragment;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_stub_path_2:
    s_n_llhttp__internal__n_span_start_stub_path_2: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_stub_path_2;
      }
      p++;
      goto s_n_llhttp__internal__n_url_path;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_stub_path:
    s_n_llhttp__internal__n_span_start_stub_path: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_stub_path;
      }
      p++;
      goto s_n_llhttp__internal__n_url_path;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_stub_path_1:
    s_n_llhttp__internal__n_span_start_stub_path_1: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_stub_path_1;
      }
      p++;
      goto s_n_llhttp__internal__n_url_path;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_server_with_at:
    s_n_llhttp__internal__n_url_server_with_at: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 0, 1, 3, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        4, 5, 0, 0, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 6,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, 5, 0, 7,
        8, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, 5, 0, 5,
        0, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, 0, 0, 5, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_url_server_with_at;
      }
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 2: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_12;
        }
        case 3: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_13;
        }
        case 4: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_14;
        }
        case 5: {
          p++;
          goto s_n_llhttp__internal__n_url_server;
        }
        case 6: {
          goto s_n_llhttp__internal__n_span_start_stub_path_1;
        }
        case 7: {
          p++;
          goto s_n_llhttp__internal__n_url_query;
        }
        case 8: {
          p++;
          goto s_n_llhttp__internal__n_error_66;
        }
        default: {
          goto s_n_llhttp__internal__n_error_67;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_server:
    s_n_llhttp__internal__n_url_server: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 0, 1, 3, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        4, 5, 0, 0, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 6,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, 5, 0, 7,
        8, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, 5, 0, 5,
        0, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, 0, 0, 5, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_url_server;
      }
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 2: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url;
        }
        case 3: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_1;
        }
        case 4: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_url_2;
        }
        case 5: {
          p++;
          goto s_n_llhttp__internal__n_url_server;
        }
        case 6: {
          goto s_n_llhttp__internal__n_span_start_stub_path;
        }
        case 7: {
          p++;
          goto s_n_llhttp__internal__n_url_query;
        }
        case 8: {
          p++;
          goto s_n_llhttp__internal__n_url_server_with_at;
        }
        default: {
          goto s_n_llhttp__internal__n_error_68;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_schema_delim_1:
    s_n_llhttp__internal__n_url_schema_delim_1: {
      if (p == endp) {
        return s_n_llhttp__internal__n_url_schema_delim_1;
      }
      switch (*p) {
        case '/': {
          p++;
          goto s_n_llhttp__internal__n_url_server;
        }
        default: {
          goto s_n_llhttp__internal__n_error_69;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_schema_delim:
    s_n_llhttp__internal__n_url_schema_delim: {
      if (p == endp) {
        return s_n_llhttp__internal__n_url_schema_delim;
      }
      switch (*p) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 12: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 13: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case '/': {
          p++;
          goto s_n_llhttp__internal__n_url_schema_delim_1;
        }
        default: {
          goto s_n_llhttp__internal__n_error_69;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_end_stub_schema:
    s_n_llhttp__internal__n_span_end_stub_schema: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_end_stub_schema;
      }
      p++;
      goto s_n_llhttp__internal__n_url_schema_delim;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_schema:
    s_n_llhttp__internal__n_url_schema: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0,
        0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0, 0,
        0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_url_schema;
      }
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 2: {
          goto s_n_llhttp__internal__n_span_end_stub_schema;
        }
        case 3: {
          p++;
          goto s_n_llhttp__internal__n_url_schema;
        }
        default: {
          goto s_n_llhttp__internal__n_error_70;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_start:
    s_n_llhttp__internal__n_url_start: {
      static uint8_t lookup_table[] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0, 0,
        0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
      };
      if (p == endp) {
        return s_n_llhttp__internal__n_url_start;
      }
      switch (lookup_table[(uint8_t) *p]) {
        case 1: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 2: {
          goto s_n_llhttp__internal__n_span_start_stub_path_2;
        }
        case 3: {
          goto s_n_llhttp__internal__n_url_schema;
        }
        default: {
          goto s_n_llhttp__internal__n_error_71;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_url_1:
    s_n_llhttp__internal__n_span_start_llhttp__on_url_1: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_url_1;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_url;
      goto s_n_llhttp__internal__n_url_start;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_entry_normal:
    s_n_llhttp__internal__n_url_entry_normal: {
      if (p == endp) {
        return s_n_llhttp__internal__n_url_entry_normal;
      }
      switch (*p) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 12: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        default: {
          goto s_n_llhttp__internal__n_span_start_llhttp__on_url_1;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_url:
    s_n_llhttp__internal__n_span_start_llhttp__on_url: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_url;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_url;
      goto s_n_llhttp__internal__n_url_server;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_url_entry_connect:
    s_n_llhttp__internal__n_url_entry_connect: {
      if (p == endp) {
        return s_n_llhttp__internal__n_url_entry_connect;
      }
      switch (*p) {
        case 9: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        case 12: {
          p++;
          goto s_n_llhttp__internal__n_error_2;
        }
        default: {
          goto s_n_llhttp__internal__n_span_start_llhttp__on_url;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_spaces_before_url:
    s_n_llhttp__internal__n_req_spaces_before_url: {
      if (p == endp) {
        return s_n_llhttp__internal__n_req_spaces_before_url;
      }
      switch (*p) {
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_req_spaces_before_url;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_is_equal_method;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_first_space_before_url:
    s_n_llhttp__internal__n_req_first_space_before_url: {
      if (p == endp) {
        return s_n_llhttp__internal__n_req_first_space_before_url;
      }
      switch (*p) {
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_req_spaces_before_url;
        }
        default: {
          goto s_n_llhttp__internal__n_error_72;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__on_method_complete_1:
    s_n_llhttp__internal__n_invoke_llhttp__on_method_complete_1: {
      switch (c_nio_llhttp__on_method_complete(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_req_first_space_before_url;
        case 21:
          goto s_n_llhttp__internal__n_pause_22;
        default:
          goto s_n_llhttp__internal__n_error_89;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_2:
    s_n_llhttp__internal__n_after_start_req_2: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_2;
      }
      switch (*p) {
        case 'L': {
          p++;
          match = 19;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_3:
    s_n_llhttp__internal__n_after_start_req_3: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_3;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob18, 6);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 36;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_3;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_1:
    s_n_llhttp__internal__n_after_start_req_1: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_1;
      }
      switch (*p) {
        case 'C': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_2;
        }
        case 'N': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_3;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_4:
    s_n_llhttp__internal__n_after_start_req_4: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_4;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob19, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 16;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_4;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_6:
    s_n_llhttp__internal__n_after_start_req_6: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_6;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob20, 6);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 22;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_6;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_8:
    s_n_llhttp__internal__n_after_start_req_8: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_8;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob21, 4);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 5;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_8;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_9:
    s_n_llhttp__internal__n_after_start_req_9: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_9;
      }
      switch (*p) {
        case 'Y': {
          p++;
          match = 8;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_7:
    s_n_llhttp__internal__n_after_start_req_7: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_7;
      }
      switch (*p) {
        case 'N': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_8;
        }
        case 'P': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_9;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_5:
    s_n_llhttp__internal__n_after_start_req_5: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_5;
      }
      switch (*p) {
        case 'H': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_6;
        }
        case 'O': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_7;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_12:
    s_n_llhttp__internal__n_after_start_req_12: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_12;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob22, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 0;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_12;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_13:
    s_n_llhttp__internal__n_after_start_req_13: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_13;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob23, 5);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 35;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_13;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_11:
    s_n_llhttp__internal__n_after_start_req_11: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_11;
      }
      switch (*p) {
        case 'L': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_12;
        }
        case 'S': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_13;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_10:
    s_n_llhttp__internal__n_after_start_req_10: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_10;
      }
      switch (*p) {
        case 'E': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_11;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_14:
    s_n_llhttp__internal__n_after_start_req_14: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_14;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob24, 4);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 45;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_14;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_17:
    s_n_llhttp__internal__n_after_start_req_17: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_17;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob26, 9);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 41;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_17;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_16:
    s_n_llhttp__internal__n_after_start_req_16: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_16;
      }
      switch (*p) {
        case '_': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_17;
        }
        default: {
          match = 1;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_15:
    s_n_llhttp__internal__n_after_start_req_15: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_15;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob25, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_16;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_15;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_18:
    s_n_llhttp__internal__n_after_start_req_18: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_18;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob27, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_18;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_20:
    s_n_llhttp__internal__n_after_start_req_20: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_20;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob28, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 31;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_20;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_21:
    s_n_llhttp__internal__n_after_start_req_21: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_21;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob29, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 9;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_21;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_19:
    s_n_llhttp__internal__n_after_start_req_19: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_19;
      }
      switch (*p) {
        case 'I': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_20;
        }
        case 'O': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_21;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_23:
    s_n_llhttp__internal__n_after_start_req_23: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_23;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob30, 6);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 24;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_23;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_24:
    s_n_llhttp__internal__n_after_start_req_24: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_24;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob31, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 23;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_24;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_26:
    s_n_llhttp__internal__n_after_start_req_26: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_26;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob32, 7);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 21;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_26;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_28:
    s_n_llhttp__internal__n_after_start_req_28: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_28;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob33, 6);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 30;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_28;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_29:
    s_n_llhttp__internal__n_after_start_req_29: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_29;
      }
      switch (*p) {
        case 'L': {
          p++;
          match = 10;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_27:
    s_n_llhttp__internal__n_after_start_req_27: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_27;
      }
      switch (*p) {
        case 'A': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_28;
        }
        case 'O': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_29;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_25:
    s_n_llhttp__internal__n_after_start_req_25: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_25;
      }
      switch (*p) {
        case 'A': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_26;
        }
        case 'C': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_27;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_30:
    s_n_llhttp__internal__n_after_start_req_30: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_30;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob34, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 11;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_30;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_22:
    s_n_llhttp__internal__n_after_start_req_22: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_22;
      }
      switch (*p) {
        case '-': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_23;
        }
        case 'E': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_24;
        }
        case 'K': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_25;
        }
        case 'O': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_30;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_31:
    s_n_llhttp__internal__n_after_start_req_31: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_31;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob35, 5);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 25;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_31;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_32:
    s_n_llhttp__internal__n_after_start_req_32: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_32;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob36, 6);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 6;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_32;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_35:
    s_n_llhttp__internal__n_after_start_req_35: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_35;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob37, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 28;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_35;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_36:
    s_n_llhttp__internal__n_after_start_req_36: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_36;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob38, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 39;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_36;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_34:
    s_n_llhttp__internal__n_after_start_req_34: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_34;
      }
      switch (*p) {
        case 'T': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_35;
        }
        case 'U': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_36;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_37:
    s_n_llhttp__internal__n_after_start_req_37: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_37;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob39, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 38;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_37;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_38:
    s_n_llhttp__internal__n_after_start_req_38: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_38;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob40, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 3;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_38;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_42:
    s_n_llhttp__internal__n_after_start_req_42: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_42;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob41, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 12;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_42;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_43:
    s_n_llhttp__internal__n_after_start_req_43: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_43;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob42, 4);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 13;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_43;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_41:
    s_n_llhttp__internal__n_after_start_req_41: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_41;
      }
      switch (*p) {
        case 'F': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_42;
        }
        case 'P': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_43;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_40:
    s_n_llhttp__internal__n_after_start_req_40: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_40;
      }
      switch (*p) {
        case 'P': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_41;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_39:
    s_n_llhttp__internal__n_after_start_req_39: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_39;
      }
      switch (*p) {
        case 'I': {
          p++;
          match = 34;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case 'O': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_40;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_45:
    s_n_llhttp__internal__n_after_start_req_45: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_45;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob43, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 29;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_45;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_44:
    s_n_llhttp__internal__n_after_start_req_44: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_44;
      }
      switch (*p) {
        case 'R': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_45;
        }
        case 'T': {
          p++;
          match = 4;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_33:
    s_n_llhttp__internal__n_after_start_req_33: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_33;
      }
      switch (*p) {
        case 'A': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_34;
        }
        case 'L': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_37;
        }
        case 'O': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_38;
        }
        case 'R': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_39;
        }
        case 'U': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_44;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_48:
    s_n_llhttp__internal__n_after_start_req_48: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_48;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob44, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 17;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_48;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_49:
    s_n_llhttp__internal__n_after_start_req_49: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_49;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob45, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 44;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_49;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_50:
    s_n_llhttp__internal__n_after_start_req_50: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_50;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob46, 5);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 43;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_50;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_51:
    s_n_llhttp__internal__n_after_start_req_51: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_51;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob47, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 20;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_51;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_47:
    s_n_llhttp__internal__n_after_start_req_47: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_47;
      }
      switch (*p) {
        case 'B': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_48;
        }
        case 'C': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_49;
        }
        case 'D': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_50;
        }
        case 'P': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_51;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_46:
    s_n_llhttp__internal__n_after_start_req_46: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_46;
      }
      switch (*p) {
        case 'E': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_47;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_54:
    s_n_llhttp__internal__n_after_start_req_54: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_54;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob48, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 14;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_54;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_56:
    s_n_llhttp__internal__n_after_start_req_56: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_56;
      }
      switch (*p) {
        case 'P': {
          p++;
          match = 37;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_57:
    s_n_llhttp__internal__n_after_start_req_57: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_57;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob49, 9);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 42;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_57;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_55:
    s_n_llhttp__internal__n_after_start_req_55: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_55;
      }
      switch (*p) {
        case 'U': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_56;
        }
        case '_': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_57;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_53:
    s_n_llhttp__internal__n_after_start_req_53: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_53;
      }
      switch (*p) {
        case 'A': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_54;
        }
        case 'T': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_55;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_58:
    s_n_llhttp__internal__n_after_start_req_58: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_58;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob50, 4);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 33;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_58;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_59:
    s_n_llhttp__internal__n_after_start_req_59: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_59;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob51, 7);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 26;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_59;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_52:
    s_n_llhttp__internal__n_after_start_req_52: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_52;
      }
      switch (*p) {
        case 'E': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_53;
        }
        case 'O': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_58;
        }
        case 'U': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_59;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_61:
    s_n_llhttp__internal__n_after_start_req_61: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_61;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob52, 6);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 40;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_61;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_62:
    s_n_llhttp__internal__n_after_start_req_62: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_62;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob53, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 7;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_62;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_60:
    s_n_llhttp__internal__n_after_start_req_60: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_60;
      }
      switch (*p) {
        case 'E': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_61;
        }
        case 'R': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_62;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_65:
    s_n_llhttp__internal__n_after_start_req_65: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_65;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob54, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 18;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_65;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_67:
    s_n_llhttp__internal__n_after_start_req_67: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_67;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob55, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 32;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_67;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_68:
    s_n_llhttp__internal__n_after_start_req_68: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_68;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob56, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 15;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_68;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_66:
    s_n_llhttp__internal__n_after_start_req_66: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_66;
      }
      switch (*p) {
        case 'I': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_67;
        }
        case 'O': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_68;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_69:
    s_n_llhttp__internal__n_after_start_req_69: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_69;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob57, 8);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 27;
          goto s_n_llhttp__internal__n_invoke_store_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_after_start_req_69;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_64:
    s_n_llhttp__internal__n_after_start_req_64: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_64;
      }
      switch (*p) {
        case 'B': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_65;
        }
        case 'L': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_66;
        }
        case 'S': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_69;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req_63:
    s_n_llhttp__internal__n_after_start_req_63: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req_63;
      }
      switch (*p) {
        case 'N': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_64;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_after_start_req:
    s_n_llhttp__internal__n_after_start_req: {
      if (p == endp) {
        return s_n_llhttp__internal__n_after_start_req;
      }
      switch (*p) {
        case 'A': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_1;
        }
        case 'B': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_4;
        }
        case 'C': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_5;
        }
        case 'D': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_10;
        }
        case 'F': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_14;
        }
        case 'G': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_15;
        }
        case 'H': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_18;
        }
        case 'L': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_19;
        }
        case 'M': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_22;
        }
        case 'N': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_31;
        }
        case 'O': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_32;
        }
        case 'P': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_33;
        }
        case 'R': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_46;
        }
        case 'S': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_52;
        }
        case 'T': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_60;
        }
        case 'U': {
          p++;
          goto s_n_llhttp__internal__n_after_start_req_63;
        }
        default: {
          goto s_n_llhttp__internal__n_error_90;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_method_1:
    s_n_llhttp__internal__n_span_start_llhttp__on_method_1: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_method_1;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_method;
      goto s_n_llhttp__internal__n_after_start_req;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_res_line_almost_done:
    s_n_llhttp__internal__n_res_line_almost_done: {
      if (p == endp) {
        return s_n_llhttp__internal__n_res_line_almost_done;
      }
      switch (*p) {
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_invoke_llhttp__on_status_complete;
        }
        case 13: {
          p++;
          goto s_n_llhttp__internal__n_invoke_llhttp__on_status_complete;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_test_lenient_flags_18;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_res_status:
    s_n_llhttp__internal__n_res_status: {
      if (p == endp) {
        return s_n_llhttp__internal__n_res_status;
      }
      switch (*p) {
        case 10: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_status;
        }
        case 13: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_status_1;
        }
        default: {
          p++;
          goto s_n_llhttp__internal__n_res_status;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_status:
    s_n_llhttp__internal__n_span_start_llhttp__on_status: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_status;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_status;
      goto s_n_llhttp__internal__n_res_status;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_res_status_start:
    s_n_llhttp__internal__n_res_status_start: {
      if (p == endp) {
        return s_n_llhttp__internal__n_res_status_start;
      }
      switch (*p) {
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_invoke_llhttp__on_status_complete;
        }
        case 13: {
          p++;
          goto s_n_llhttp__internal__n_res_line_almost_done;
        }
        default: {
          goto s_n_llhttp__internal__n_span_start_llhttp__on_status;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_res_status_code_otherwise:
    s_n_llhttp__internal__n_res_status_code_otherwise: {
      if (p == endp) {
        return s_n_llhttp__internal__n_res_status_code_otherwise;
      }
      switch (*p) {
        case 10: {
          goto s_n_llhttp__internal__n_res_status_start;
        }
        case 13: {
          goto s_n_llhttp__internal__n_res_status_start;
        }
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_res_status_start;
        }
        default: {
          goto s_n_llhttp__internal__n_error_77;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_res_status_code_digit_3:
    s_n_llhttp__internal__n_res_status_code_digit_3: {
      if (p == endp) {
        return s_n_llhttp__internal__n_res_status_code_digit_3;
      }
      switch (*p) {
        case '0': {
          p++;
          match = 0;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_2;
        }
        case '1': {
          p++;
          match = 1;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_2;
        }
        case '2': {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_2;
        }
        case '3': {
          p++;
          match = 3;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_2;
        }
        case '4': {
          p++;
          match = 4;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_2;
        }
        case '5': {
          p++;
          match = 5;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_2;
        }
        case '6': {
          p++;
          match = 6;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_2;
        }
        case '7': {
          p++;
          match = 7;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_2;
        }
        case '8': {
          p++;
          match = 8;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_2;
        }
        case '9': {
          p++;
          match = 9;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_2;
        }
        default: {
          goto s_n_llhttp__internal__n_error_79;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_res_status_code_digit_2:
    s_n_llhttp__internal__n_res_status_code_digit_2: {
      if (p == endp) {
        return s_n_llhttp__internal__n_res_status_code_digit_2;
      }
      switch (*p) {
        case '0': {
          p++;
          match = 0;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_1;
        }
        case '1': {
          p++;
          match = 1;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_1;
        }
        case '2': {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_1;
        }
        case '3': {
          p++;
          match = 3;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_1;
        }
        case '4': {
          p++;
          match = 4;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_1;
        }
        case '5': {
          p++;
          match = 5;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_1;
        }
        case '6': {
          p++;
          match = 6;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_1;
        }
        case '7': {
          p++;
          match = 7;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_1;
        }
        case '8': {
          p++;
          match = 8;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_1;
        }
        case '9': {
          p++;
          match = 9;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code_1;
        }
        default: {
          goto s_n_llhttp__internal__n_error_81;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_res_status_code_digit_1:
    s_n_llhttp__internal__n_res_status_code_digit_1: {
      if (p == endp) {
        return s_n_llhttp__internal__n_res_status_code_digit_1;
      }
      switch (*p) {
        case '0': {
          p++;
          match = 0;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code;
        }
        case '1': {
          p++;
          match = 1;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code;
        }
        case '2': {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code;
        }
        case '3': {
          p++;
          match = 3;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code;
        }
        case '4': {
          p++;
          match = 4;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code;
        }
        case '5': {
          p++;
          match = 5;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code;
        }
        case '6': {
          p++;
          match = 6;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code;
        }
        case '7': {
          p++;
          match = 7;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code;
        }
        case '8': {
          p++;
          match = 8;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code;
        }
        case '9': {
          p++;
          match = 9;
          goto s_n_llhttp__internal__n_invoke_mul_add_status_code;
        }
        default: {
          goto s_n_llhttp__internal__n_error_83;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_res_after_version:
    s_n_llhttp__internal__n_res_after_version: {
      if (p == endp) {
        return s_n_llhttp__internal__n_res_after_version;
      }
      switch (*p) {
        case ' ': {
          p++;
          goto s_n_llhttp__internal__n_invoke_update_status_code;
        }
        default: {
          goto s_n_llhttp__internal__n_error_84;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__on_version_complete_1:
    s_n_llhttp__internal__n_invoke_llhttp__on_version_complete_1: {
      switch (c_nio_llhttp__on_version_complete(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_res_after_version;
        case 21:
          goto s_n_llhttp__internal__n_pause_21;
        default:
          goto s_n_llhttp__internal__n_error_74;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_73:
    s_n_llhttp__internal__n_error_73: {
      state->error = 0x9;
      state->reason = "Invalid HTTP version";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_85:
    s_n_llhttp__internal__n_error_85: {
      state->error = 0x9;
      state->reason = "Invalid minor version";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_res_http_minor:
    s_n_llhttp__internal__n_res_http_minor: {
      if (p == endp) {
        return s_n_llhttp__internal__n_res_http_minor;
      }
      switch (*p) {
        case '0': {
          p++;
          match = 0;
          goto s_n_llhttp__internal__n_invoke_store_http_minor_1;
        }
        case '1': {
          p++;
          match = 1;
          goto s_n_llhttp__internal__n_invoke_store_http_minor_1;
        }
        case '2': {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_store_http_minor_1;
        }
        case '3': {
          p++;
          match = 3;
          goto s_n_llhttp__internal__n_invoke_store_http_minor_1;
        }
        case '4': {
          p++;
          match = 4;
          goto s_n_llhttp__internal__n_invoke_store_http_minor_1;
        }
        case '5': {
          p++;
          match = 5;
          goto s_n_llhttp__internal__n_invoke_store_http_minor_1;
        }
        case '6': {
          p++;
          match = 6;
          goto s_n_llhttp__internal__n_invoke_store_http_minor_1;
        }
        case '7': {
          p++;
          match = 7;
          goto s_n_llhttp__internal__n_invoke_store_http_minor_1;
        }
        case '8': {
          p++;
          match = 8;
          goto s_n_llhttp__internal__n_invoke_store_http_minor_1;
        }
        case '9': {
          p++;
          match = 9;
          goto s_n_llhttp__internal__n_invoke_store_http_minor_1;
        }
        default: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_version_7;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_86:
    s_n_llhttp__internal__n_error_86: {
      state->error = 0x9;
      state->reason = "Expected dot";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_res_http_dot:
    s_n_llhttp__internal__n_res_http_dot: {
      if (p == endp) {
        return s_n_llhttp__internal__n_res_http_dot;
      }
      switch (*p) {
        case '.': {
          p++;
          goto s_n_llhttp__internal__n_res_http_minor;
        }
        default: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_version_8;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_error_87:
    s_n_llhttp__internal__n_error_87: {
      state->error = 0x9;
      state->reason = "Invalid major version";
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_error;
      return s_error;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_res_http_major:
    s_n_llhttp__internal__n_res_http_major: {
      if (p == endp) {
        return s_n_llhttp__internal__n_res_http_major;
      }
      switch (*p) {
        case '0': {
          p++;
          match = 0;
          goto s_n_llhttp__internal__n_invoke_store_http_major_1;
        }
        case '1': {
          p++;
          match = 1;
          goto s_n_llhttp__internal__n_invoke_store_http_major_1;
        }
        case '2': {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_store_http_major_1;
        }
        case '3': {
          p++;
          match = 3;
          goto s_n_llhttp__internal__n_invoke_store_http_major_1;
        }
        case '4': {
          p++;
          match = 4;
          goto s_n_llhttp__internal__n_invoke_store_http_major_1;
        }
        case '5': {
          p++;
          match = 5;
          goto s_n_llhttp__internal__n_invoke_store_http_major_1;
        }
        case '6': {
          p++;
          match = 6;
          goto s_n_llhttp__internal__n_invoke_store_http_major_1;
        }
        case '7': {
          p++;
          match = 7;
          goto s_n_llhttp__internal__n_invoke_store_http_major_1;
        }
        case '8': {
          p++;
          match = 8;
          goto s_n_llhttp__internal__n_invoke_store_http_major_1;
        }
        case '9': {
          p++;
          match = 9;
          goto s_n_llhttp__internal__n_invoke_store_http_major_1;
        }
        default: {
          goto s_n_llhttp__internal__n_span_end_llhttp__on_version_9;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_version_1:
    s_n_llhttp__internal__n_span_start_llhttp__on_version_1: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_version_1;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_version;
      goto s_n_llhttp__internal__n_res_http_major;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_start_res:
    s_n_llhttp__internal__n_start_res: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_start_res;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob58, 5);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_span_start_llhttp__on_version_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_start_res;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_91;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_llhttp__on_method_complete:
    s_n_llhttp__internal__n_invoke_llhttp__on_method_complete: {
      switch (c_nio_llhttp__on_method_complete(state, p, endp)) {
        case 0:
          goto s_n_llhttp__internal__n_req_first_space_before_url;
        case 21:
          goto s_n_llhttp__internal__n_pause_19;
        default:
          goto s_n_llhttp__internal__n_error_1;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_or_res_method_2:
    s_n_llhttp__internal__n_req_or_res_method_2: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_req_or_res_method_2;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob59, 2);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          match = 2;
          goto s_n_llhttp__internal__n_invoke_store_method;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_req_or_res_method_2;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_88;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_update_type_1:
    s_n_llhttp__internal__n_invoke_update_type_1: {
      switch (c_nio_llhttp__internal__c_update_type_1(state, p, endp)) {
        default:
          goto s_n_llhttp__internal__n_span_start_llhttp__on_version_1;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_or_res_method_3:
    s_n_llhttp__internal__n_req_or_res_method_3: {
      llparse_match_t match_seq;
      
      if (p == endp) {
        return s_n_llhttp__internal__n_req_or_res_method_3;
      }
      match_seq = llparse__match_sequence_id(state, p, endp, llparse_blob60, 3);
      p = match_seq.current;
      switch (match_seq.status) {
        case kMatchComplete: {
          p++;
          goto s_n_llhttp__internal__n_span_end_llhttp__on_method_1;
        }
        case kMatchPause: {
          return s_n_llhttp__internal__n_req_or_res_method_3;
        }
        case kMatchMismatch: {
          goto s_n_llhttp__internal__n_error_88;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_or_res_method_1:
    s_n_llhttp__internal__n_req_or_res_method_1: {
      if (p == endp) {
        return s_n_llhttp__internal__n_req_or_res_method_1;
      }
      switch (*p) {
        case 'E': {
          p++;
          goto s_n_llhttp__internal__n_req_or_res_method_2;
        }
        case 'T': {
          p++;
          goto s_n_llhttp__internal__n_req_or_res_method_3;
        }
        default: {
          goto s_n_llhttp__internal__n_error_88;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_req_or_res_method:
    s_n_llhttp__internal__n_req_or_res_method: {
      if (p == endp) {
        return s_n_llhttp__internal__n_req_or_res_method;
      }
      switch (*p) {
        case 'H': {
          p++;
          goto s_n_llhttp__internal__n_req_or_res_method_1;
        }
        default: {
          goto s_n_llhttp__internal__n_error_88;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_span_start_llhttp__on_method:
    s_n_llhttp__internal__n_span_start_llhttp__on_method: {
      if (p == endp) {
        return s_n_llhttp__internal__n_span_start_llhttp__on_method;
      }
      state->_span_pos0 = (void*) p;
      state->_span_cb0 = c_nio_llhttp__on_method;
      goto s_n_llhttp__internal__n_req_or_res_method;
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_start_req_or_res:
    s_n_llhttp__internal__n_start_req_or_res: {
      if (p == endp) {
        return s_n_llhttp__internal__n_start_req_or_res;
      }
      switch (*p) {
        case 'H': {
          goto s_n_llhttp__internal__n_span_start_llhttp__on_method;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_update_type_2;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_load_type:
    s_n_llhttp__internal__n_invoke_load_type: {
      switch (c_nio_llhttp__internal__c_load_type(state, p, endp)) {
        case 1:
          goto s_n_llhttp__internal__n_span_start_llhttp__on_method_1;
        case 2:
          goto s_n_llhttp__internal__n_start_res;
        default:
          goto s_n_llhttp__internal__n_start_req_or_res;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_invoke_update_finish:
    s_n_llhttp__internal__n_invoke_update_finish: {
      switch (c_nio_llhttp__internal__c_update_finish(state, p, endp)) {
        default:
          goto s_n_llhttp__internal__n_invoke_llhttp__on_message_begin;
      }
      /* UNREACHABLE */;
      abort();
    }
    case s_n_llhttp__internal__n_start:
    s_n_llhttp__internal__n_start: {
      if (p == endp) {
        return s_n_llhttp__internal__n_start;
      }
      switch (*p) {
        case 10: {
          p++;
          goto s_n_llhttp__internal__n_start;
        }
        case 13: {
          p++;
          goto s_n_llhttp__internal__n_start;
        }
        default: {
          goto s_n_llhttp__internal__n_invoke_load_initial_message_completed;
        }
      }
      /* UNREACHABLE */;
      abort();
    }
    default:
      /* UNREACHABLE */
      abort();
  }
  s_n_llhttp__internal__n_error_2: {
    state->error = 0x7;
    state->reason = "Invalid characters in url";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_finish_2: {
    switch (c_nio_llhttp__internal__c_update_finish_1(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_start;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_initial_message_completed: {
    switch (c_nio_llhttp__internal__c_update_initial_message_completed(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_finish_2;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_content_length: {
    switch (c_nio_llhttp__internal__c_update_content_length(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_initial_message_completed;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_7: {
    state->error = 0x5;
    state->reason = "Data after `Connection: close`";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_3: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags_3(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_closed;
      default:
        goto s_n_llhttp__internal__n_error_7;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_2: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags_2(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_invoke_update_initial_message_completed;
      default:
        goto s_n_llhttp__internal__n_closed;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_finish_1: {
    switch (c_nio_llhttp__internal__c_update_finish_1(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_test_lenient_flags_2;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_2: {
    state->error = 0x15;
    state->reason = "on_message_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_pause_1;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_8: {
    state->error = 0x12;
    state->reason = "`on_message_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__on_message_complete_1: {
    switch (c_nio_llhttp__on_message_complete(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_pause_1;
      case 21:
        goto s_n_llhttp__internal__n_pause_2;
      default:
        goto s_n_llhttp__internal__n_error_8;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_26: {
    state->error = 0xc;
    state->reason = "Chunk size overflow";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_3: {
    state->error = 0x15;
    state->reason = "on_chunk_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_update_content_length_1;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_10: {
    state->error = 0x14;
    state->reason = "`on_chunk_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__on_chunk_complete: {
    switch (c_nio_llhttp__on_chunk_complete(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_invoke_update_content_length_1;
      case 21:
        goto s_n_llhttp__internal__n_pause_3;
      default:
        goto s_n_llhttp__internal__n_error_10;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_11: {
    state->error = 0x2;
    state->reason = "Expected LF after chunk data";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_4: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags_4(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_invoke_llhttp__on_chunk_complete;
      default:
        goto s_n_llhttp__internal__n_error_11;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_body: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_body(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_chunk_data_almost_done;
      return s_error;
    }
    goto s_n_llhttp__internal__n_chunk_data_almost_done;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags: {
    switch (c_nio_llhttp__internal__c_or_flags(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_field_start;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_4: {
    state->error = 0x15;
    state->reason = "on_chunk_header pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_is_equal_content_length;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_9: {
    state->error = 0x13;
    state->reason = "`on_chunk_header` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__on_chunk_header: {
    switch (c_nio_llhttp__on_chunk_header(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_invoke_is_equal_content_length;
      case 21:
        goto s_n_llhttp__internal__n_pause_4;
      default:
        goto s_n_llhttp__internal__n_error_9;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_12: {
    state->error = 0x2;
    state->reason = "Expected LF after chunk size";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_5: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags_5(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_invoke_llhttp__on_chunk_header;
      default:
        goto s_n_llhttp__internal__n_error_12;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_13: {
    state->error = 0x2;
    state->reason = "Invalid character in chunk extensions";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_14: {
    state->error = 0x2;
    state->reason = "Invalid character in chunk extensions";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_5: {
    state->error = 0x15;
    state->reason = "on_chunk_extension_name pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_chunk_size_almost_done;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_15: {
    state->error = 0x22;
    state->reason = "`on_chunk_extension_name` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_name: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_chunk_extension_name(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_name_complete;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_name_complete;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_6: {
    state->error = 0x15;
    state->reason = "on_chunk_extension_name pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_chunk_extensions;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_16: {
    state->error = 0x22;
    state->reason = "`on_chunk_extension_name` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_name_1: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_chunk_extension_name(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_name_complete_1;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_name_complete_1;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_7: {
    state->error = 0x15;
    state->reason = "on_chunk_extension_value pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_chunk_size_almost_done;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_18: {
    state->error = 0x23;
    state->reason = "`on_chunk_extension_value` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_value: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_chunk_extension_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_20: {
    state->error = 0x2;
    state->reason = "Invalid character in chunk extensions quote value";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_8: {
    state->error = 0x15;
    state->reason = "on_chunk_extension_value pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_chunk_extension_quoted_value_done;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_19: {
    state->error = 0x23;
    state->reason = "`on_chunk_extension_value` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_value_1: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_chunk_extension_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete_1;
      return s_error;
    }
    goto s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete_1;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_value_2: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_chunk_extension_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_21;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_error_21;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_9: {
    state->error = 0x15;
    state->reason = "on_chunk_extension_value pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_chunk_size_otherwise;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_22: {
    state->error = 0x23;
    state->reason = "`on_chunk_extension_value` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_value_3: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_chunk_extension_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete_2;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_value_complete_2;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_value_4: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_chunk_extension_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_23;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_error_23;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_10: {
    state->error = 0x15;
    state->reason = "on_chunk_extension_name pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_chunk_extension_value;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_17: {
    state->error = 0x22;
    state->reason = "`on_chunk_extension_name` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__on_chunk_extension_name_complete_2: {
    switch (c_nio_llhttp__on_chunk_extension_name_complete(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_chunk_extension_value;
      case 21:
        goto s_n_llhttp__internal__n_pause_10;
      default:
        goto s_n_llhttp__internal__n_error_17;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_name_2: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_chunk_extension_name(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_span_start_llhttp__on_chunk_extension_value;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_span_start_llhttp__on_chunk_extension_value;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_chunk_extension_name_3: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_chunk_extension_name(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_24;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_error_24;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_25: {
    state->error = 0xc;
    state->reason = "Invalid character in chunk size";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_mul_add_content_length: {
    switch (c_nio_llhttp__internal__c_mul_add_content_length(state, p, endp, match)) {
      case 1:
        goto s_n_llhttp__internal__n_error_26;
      default:
        goto s_n_llhttp__internal__n_chunk_size;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_27: {
    state->error = 0xc;
    state->reason = "Invalid character in chunk size";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_11: {
    state->error = 0x15;
    state->reason = "on_message_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_is_equal_upgrade;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_28: {
    state->error = 0x12;
    state->reason = "`on_message_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_body_1: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_body(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_message_complete_2;
      return s_error;
    }
    goto s_n_llhttp__internal__n_invoke_llhttp__on_message_complete_2;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_finish_3: {
    switch (c_nio_llhttp__internal__c_update_finish_3(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_body_2;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_29: {
    state->error = 0xf;
    state->reason = "Request has invalid `Transfer-Encoding`";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause: {
    state->error = 0x15;
    state->reason = "on_message_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__after_message_complete;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_6: {
    state->error = 0x12;
    state->reason = "`on_message_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__on_message_complete: {
    switch (c_nio_llhttp__on_message_complete(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_invoke_llhttp__after_message_complete;
      case 21:
        goto s_n_llhttp__internal__n_pause;
      default:
        goto s_n_llhttp__internal__n_error_6;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_1: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_invoke_llhttp__after_headers_complete;
      default:
        goto s_n_llhttp__internal__n_error_5;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_13: {
    state->error = 0x15;
    state->reason = "on_chunk_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_message_complete_2;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_32: {
    state->error = 0x14;
    state->reason = "`on_chunk_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__on_chunk_complete_1: {
    switch (c_nio_llhttp__on_chunk_complete(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_invoke_llhttp__on_message_complete_2;
      case 21:
        goto s_n_llhttp__internal__n_pause_13;
      default:
        goto s_n_llhttp__internal__n_error_32;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_31: {
    state->error = 0x4;
    state->reason = "Content-Length can't be present with Transfer-Encoding";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_1: {
    switch (c_nio_llhttp__internal__c_or_flags_1(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_llhttp__after_headers_complete;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_2: {
    switch (c_nio_llhttp__internal__c_or_flags_1(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_llhttp__after_headers_complete;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_upgrade: {
    switch (c_nio_llhttp__internal__c_update_upgrade(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_or_flags_2;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_12: {
    state->error = 0x15;
    state->reason = "Paused by on_headers_complete";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__after_headers_complete;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_30: {
    state->error = 0x11;
    state->reason = "User callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__on_headers_complete: {
    switch (c_nio_llhttp__on_headers_complete(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_invoke_llhttp__after_headers_complete;
      case 1:
        goto s_n_llhttp__internal__n_invoke_or_flags_1;
      case 2:
        goto s_n_llhttp__internal__n_invoke_update_upgrade;
      case 21:
        goto s_n_llhttp__internal__n_pause_12;
      default:
        goto s_n_llhttp__internal__n_error_30;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__before_headers_complete: {
    switch (c_nio_llhttp__before_headers_complete(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_llhttp__on_headers_complete;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_6: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags_6(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_error_31;
      default:
        goto s_n_llhttp__internal__n_invoke_llhttp__before_headers_complete;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_flags_1: {
    switch (c_nio_llhttp__internal__c_test_flags_1(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_invoke_test_lenient_flags_6;
      default:
        goto s_n_llhttp__internal__n_invoke_llhttp__before_headers_complete;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_flags: {
    switch (c_nio_llhttp__internal__c_test_flags(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_invoke_llhttp__on_chunk_complete_1;
      default:
        goto s_n_llhttp__internal__n_invoke_test_flags_1;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_33: {
    state->error = 0x2;
    state->reason = "Expected LF after headers";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_7: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags_5(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_invoke_test_flags;
      default:
        goto s_n_llhttp__internal__n_error_33;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_header_field: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_header_field(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_5;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_error_5;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_8: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_header_field_colon_discard_ws;
      default:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_header_field;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_36: {
    state->error = 0xa;
    state->reason = "Invalid header value char";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_10: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_header_value_discard_ws;
      default:
        goto s_n_llhttp__internal__n_error_36;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_38: {
    state->error = 0xb;
    state->reason = "Empty Content-Length";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_14: {
    state->error = 0x15;
    state->reason = "on_header_value_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_header_field_start;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_37: {
    state->error = 0x1d;
    state->reason = "`on_header_value_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_header_value: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_header_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_header_value_complete;
      return s_error;
    }
    goto s_n_llhttp__internal__n_invoke_llhttp__on_header_value_complete;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_header_state: {
    switch (c_nio_llhttp__internal__c_update_header_state(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_header_value;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_3: {
    switch (c_nio_llhttp__internal__c_or_flags_3(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_header_state;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_4: {
    switch (c_nio_llhttp__internal__c_or_flags_4(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_header_state;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_5: {
    switch (c_nio_llhttp__internal__c_or_flags_5(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_header_state;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_6: {
    switch (c_nio_llhttp__internal__c_or_flags_6(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_header_value;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_header_state_1: {
    switch (c_nio_llhttp__internal__c_load_header_state(state, p, endp)) {
      case 5:
        goto s_n_llhttp__internal__n_invoke_or_flags_3;
      case 6:
        goto s_n_llhttp__internal__n_invoke_or_flags_4;
      case 7:
        goto s_n_llhttp__internal__n_invoke_or_flags_5;
      case 8:
        goto s_n_llhttp__internal__n_invoke_or_flags_6;
      default:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_header_value;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_header_state: {
    switch (c_nio_llhttp__internal__c_load_header_state(state, p, endp)) {
      case 2:
        goto s_n_llhttp__internal__n_error_38;
      default:
        goto s_n_llhttp__internal__n_invoke_load_header_state_1;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_35: {
    state->error = 0xa;
    state->reason = "Invalid header value char";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_9: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_header_value_discard_lws;
      default:
        goto s_n_llhttp__internal__n_error_35;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_39: {
    state->error = 0x2;
    state->reason = "Expected LF after CR";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_11: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_header_value_discard_lws;
      default:
        goto s_n_llhttp__internal__n_error_39;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_header_state_1: {
    switch (c_nio_llhttp__internal__c_update_header_state_1(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_header_value_1;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_header_state_3: {
    switch (c_nio_llhttp__internal__c_load_header_state(state, p, endp)) {
      case 8:
        goto s_n_llhttp__internal__n_invoke_update_header_state_1;
      default:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_header_value_1;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_header_state_2: {
    switch (c_nio_llhttp__internal__c_update_header_state(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_llhttp__on_header_value_complete;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_7: {
    switch (c_nio_llhttp__internal__c_or_flags_3(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_header_state_2;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_8: {
    switch (c_nio_llhttp__internal__c_or_flags_4(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_header_state_2;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_9: {
    switch (c_nio_llhttp__internal__c_or_flags_5(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_header_state_2;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_10: {
    switch (c_nio_llhttp__internal__c_or_flags_6(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_llhttp__on_header_value_complete;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_header_state_4: {
    switch (c_nio_llhttp__internal__c_load_header_state(state, p, endp)) {
      case 5:
        goto s_n_llhttp__internal__n_invoke_or_flags_7;
      case 6:
        goto s_n_llhttp__internal__n_invoke_or_flags_8;
      case 7:
        goto s_n_llhttp__internal__n_invoke_or_flags_9;
      case 8:
        goto s_n_llhttp__internal__n_invoke_or_flags_10;
      default:
        goto s_n_llhttp__internal__n_invoke_llhttp__on_header_value_complete;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_40: {
    state->error = 0x3;
    state->reason = "Missing expected LF after header value";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_header_value_1: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_header_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_header_value_almost_done;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_header_value_almost_done;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_header_value_3: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_header_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_header_value_almost_done;
      return s_error;
    }
    goto s_n_llhttp__internal__n_header_value_almost_done;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_header_value_4: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_header_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_header_value_almost_done;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_header_value_almost_done;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_header_value_2: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_header_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_41;
      return s_error;
    }
    goto s_n_llhttp__internal__n_error_41;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_12: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_header_value_lenient;
      default:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_header_value_2;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_header_state_4: {
    switch (c_nio_llhttp__internal__c_update_header_state(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_value_connection;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_11: {
    switch (c_nio_llhttp__internal__c_or_flags_3(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_header_state_4;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_12: {
    switch (c_nio_llhttp__internal__c_or_flags_4(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_header_state_4;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_13: {
    switch (c_nio_llhttp__internal__c_or_flags_5(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_header_state_4;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_14: {
    switch (c_nio_llhttp__internal__c_or_flags_6(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_value_connection;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_header_state_5: {
    switch (c_nio_llhttp__internal__c_load_header_state(state, p, endp)) {
      case 5:
        goto s_n_llhttp__internal__n_invoke_or_flags_11;
      case 6:
        goto s_n_llhttp__internal__n_invoke_or_flags_12;
      case 7:
        goto s_n_llhttp__internal__n_invoke_or_flags_13;
      case 8:
        goto s_n_llhttp__internal__n_invoke_or_flags_14;
      default:
        goto s_n_llhttp__internal__n_header_value_connection;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_header_state_5: {
    switch (c_nio_llhttp__internal__c_update_header_state_1(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_value_connection_token;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_header_state_3: {
    switch (c_nio_llhttp__internal__c_update_header_state_3(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_value_connection_ws;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_header_state_6: {
    switch (c_nio_llhttp__internal__c_update_header_state_6(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_value_connection_ws;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_header_state_7: {
    switch (c_nio_llhttp__internal__c_update_header_state_7(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_value_connection_ws;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_header_value_5: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_header_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_43;
      return s_error;
    }
    goto s_n_llhttp__internal__n_error_43;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_mul_add_content_length_1: {
    switch (c_nio_llhttp__internal__c_mul_add_content_length_1(state, p, endp, match)) {
      case 1:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_header_value_5;
      default:
        goto s_n_llhttp__internal__n_header_value_content_length;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_15: {
    switch (c_nio_llhttp__internal__c_or_flags_15(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_value_otherwise;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_header_value_6: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_header_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_44;
      return s_error;
    }
    goto s_n_llhttp__internal__n_error_44;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_42: {
    state->error = 0x4;
    state->reason = "Duplicate Content-Length";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_flags_2: {
    switch (c_nio_llhttp__internal__c_test_flags_2(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_header_value_content_length;
      default:
        goto s_n_llhttp__internal__n_error_42;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_header_value_8: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_header_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_46;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_error_46;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_header_state_8: {
    switch (c_nio_llhttp__internal__c_update_header_state_8(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_value_otherwise;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_header_value_7: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_header_value(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_45;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_error_45;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_13: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags_13(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_header_value_7;
      default:
        goto s_n_llhttp__internal__n_header_value_te_chunked;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_type_1: {
    switch (c_nio_llhttp__internal__c_load_type(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_invoke_test_lenient_flags_13;
      default:
        goto s_n_llhttp__internal__n_header_value_te_chunked;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_header_state_9: {
    switch (c_nio_llhttp__internal__c_update_header_state_1(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_value;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_and_flags: {
    switch (c_nio_llhttp__internal__c_and_flags(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_value_te_chunked;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_17: {
    switch (c_nio_llhttp__internal__c_or_flags_16(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_and_flags;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_14: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags_13(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_header_value_8;
      default:
        goto s_n_llhttp__internal__n_invoke_or_flags_17;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_type_2: {
    switch (c_nio_llhttp__internal__c_load_type(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_invoke_test_lenient_flags_14;
      default:
        goto s_n_llhttp__internal__n_invoke_or_flags_17;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_16: {
    switch (c_nio_llhttp__internal__c_or_flags_16(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_and_flags;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_flags_3: {
    switch (c_nio_llhttp__internal__c_test_flags_3(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_invoke_load_type_2;
      default:
        goto s_n_llhttp__internal__n_invoke_or_flags_16;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_or_flags_18: {
    switch (c_nio_llhttp__internal__c_or_flags_18(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_header_state_9;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_header_state_2: {
    switch (c_nio_llhttp__internal__c_load_header_state(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_header_value_connection;
      case 2:
        goto s_n_llhttp__internal__n_invoke_test_flags_2;
      case 3:
        goto s_n_llhttp__internal__n_invoke_test_flags_3;
      case 4:
        goto s_n_llhttp__internal__n_invoke_or_flags_18;
      default:
        goto s_n_llhttp__internal__n_header_value;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_15: {
    state->error = 0x15;
    state->reason = "on_header_field_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_header_value_discard_ws;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_34: {
    state->error = 0x1c;
    state->reason = "`on_header_field_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_header_field_1: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_header_field(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_header_field_complete;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_invoke_llhttp__on_header_field_complete;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_header_field_2: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_header_field(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_header_field_complete;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_invoke_llhttp__on_header_field_complete;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_47: {
    state->error = 0xa;
    state->reason = "Invalid header token";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_header_state_10: {
    switch (c_nio_llhttp__internal__c_update_header_state_1(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_field_general;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_store_header_state: {
    switch (c_nio_llhttp__internal__c_store_header_state(state, p, endp, match)) {
      default:
        goto s_n_llhttp__internal__n_header_field_colon;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_header_state_11: {
    switch (c_nio_llhttp__internal__c_update_header_state_1(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_header_field_general;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_4: {
    state->error = 0x1e;
    state->reason = "Unexpected space after start line";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_header_field_start;
      default:
        goto s_n_llhttp__internal__n_error_4;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_16: {
    state->error = 0x15;
    state->reason = "on_url_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_headers_start;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_3: {
    state->error = 0x1a;
    state->reason = "`on_url_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__on_url_complete: {
    switch (c_nio_llhttp__on_url_complete(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_headers_start;
      case 21:
        goto s_n_llhttp__internal__n_pause_16;
      default:
        goto s_n_llhttp__internal__n_error_3;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_http_minor: {
    switch (c_nio_llhttp__internal__c_update_http_minor(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_llhttp__on_url_complete;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_http_major: {
    switch (c_nio_llhttp__internal__c_update_http_major(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_http_minor;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_3: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_to_http09;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_to_http09;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_48: {
    state->error = 0x7;
    state->reason = "Expected CRLF";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_4: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_lf_to_http09;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_lf_to_http09;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_55: {
    state->error = 0x17;
    state->reason = "Pause on PRI/Upgrade";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_56: {
    state->error = 0x9;
    state->reason = "Expected HTTP/2 Connection Preface";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_53: {
    state->error = 0x2;
    state->reason = "Expected CRLF after version";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_16: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags_5(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_headers_start;
      default:
        goto s_n_llhttp__internal__n_error_53;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_54: {
    state->error = 0x9;
    state->reason = "Expected CRLF after version";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_17: {
    state->error = 0x15;
    state->reason = "on_version_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_load_method_1;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_52: {
    state->error = 0x21;
    state->reason = "`on_version_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_version_1: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_version(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_version_complete;
      return s_error;
    }
    goto s_n_llhttp__internal__n_invoke_llhttp__on_version_complete;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_version: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_version(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_51;
      return s_error;
    }
    goto s_n_llhttp__internal__n_error_51;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_http_minor: {
    switch (c_nio_llhttp__internal__c_load_http_minor(state, p, endp)) {
      case 9:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_1;
      default:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_http_minor_1: {
    switch (c_nio_llhttp__internal__c_load_http_minor(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_1;
      case 1:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_1;
      default:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_http_minor_2: {
    switch (c_nio_llhttp__internal__c_load_http_minor(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_1;
      default:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_http_major: {
    switch (c_nio_llhttp__internal__c_load_http_major(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_invoke_load_http_minor;
      case 1:
        goto s_n_llhttp__internal__n_invoke_load_http_minor_1;
      case 2:
        goto s_n_llhttp__internal__n_invoke_load_http_minor_2;
      default:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_15: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags_15(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_1;
      default:
        goto s_n_llhttp__internal__n_invoke_load_http_major;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_store_http_minor: {
    switch (c_nio_llhttp__internal__c_store_http_minor(state, p, endp, match)) {
      default:
        goto s_n_llhttp__internal__n_invoke_test_lenient_flags_15;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_version_2: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_version(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_57;
      return s_error;
    }
    goto s_n_llhttp__internal__n_error_57;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_version_3: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_version(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_58;
      return s_error;
    }
    goto s_n_llhttp__internal__n_error_58;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_store_http_major: {
    switch (c_nio_llhttp__internal__c_store_http_major(state, p, endp, match)) {
      default:
        goto s_n_llhttp__internal__n_req_http_dot;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_version_4: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_version(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_59;
      return s_error;
    }
    goto s_n_llhttp__internal__n_error_59;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_50: {
    state->error = 0x8;
    state->reason = "Invalid method for HTTP/x.x request";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_method: {
    switch (c_nio_llhttp__internal__c_load_method(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 1:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 2:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 3:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 4:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 5:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 6:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 7:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 8:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 9:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 10:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 11:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 12:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 13:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 14:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 15:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 16:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 17:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 18:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 19:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 20:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 21:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 22:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 23:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 24:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 25:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 26:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 27:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 28:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 29:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 30:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 31:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 32:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 33:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 34:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      default:
        goto s_n_llhttp__internal__n_error_50;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_62: {
    state->error = 0x8;
    state->reason = "Expected HTTP/";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_60: {
    state->error = 0x8;
    state->reason = "Expected SOURCE method for ICE/x.x request";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_method_2: {
    switch (c_nio_llhttp__internal__c_load_method(state, p, endp)) {
      case 33:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      default:
        goto s_n_llhttp__internal__n_error_60;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_61: {
    state->error = 0x8;
    state->reason = "Invalid method for RTSP/x.x request";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_method_3: {
    switch (c_nio_llhttp__internal__c_load_method(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 3:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 6:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 35:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 36:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 37:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 38:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 39:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 40:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 41:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 42:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 43:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 44:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      case 45:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_version;
      default:
        goto s_n_llhttp__internal__n_error_61;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_18: {
    state->error = 0x15;
    state->reason = "on_url_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_req_http_start;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_49: {
    state->error = 0x1a;
    state->reason = "`on_url_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__on_url_complete_1: {
    switch (c_nio_llhttp__on_url_complete(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_req_http_start;
      case 21:
        goto s_n_llhttp__internal__n_pause_18;
      default:
        goto s_n_llhttp__internal__n_error_49;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_5: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_to_http;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_to_http;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_6: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_to_http09;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_to_http09;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_7: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_lf_to_http09;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_lf_to_http09;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_8: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_to_http;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_to_http;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_63: {
    state->error = 0x7;
    state->reason = "Invalid char in url fragment start";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_9: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_to_http09;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_to_http09;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_10: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_lf_to_http09;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_lf_to_http09;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_11: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_to_http;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_to_http;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_64: {
    state->error = 0x7;
    state->reason = "Invalid char in url query";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_65: {
    state->error = 0x7;
    state->reason = "Invalid char in url path";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_to_http09;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_to_http09;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_1: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_lf_to_http09;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_lf_to_http09;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_2: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_to_http;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_to_http;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_12: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_to_http09;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_to_http09;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_13: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_lf_to_http09;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_lf_to_http09;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_url_14: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_url(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_url_skip_to_http;
      return s_error;
    }
    goto s_n_llhttp__internal__n_url_skip_to_http;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_66: {
    state->error = 0x7;
    state->reason = "Double @ in url";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_67: {
    state->error = 0x7;
    state->reason = "Unexpected char in url server";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_68: {
    state->error = 0x7;
    state->reason = "Unexpected char in url server";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_69: {
    state->error = 0x7;
    state->reason = "Unexpected char in url schema";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_70: {
    state->error = 0x7;
    state->reason = "Unexpected char in url schema";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_71: {
    state->error = 0x7;
    state->reason = "Unexpected start char in url";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_is_equal_method: {
    switch (c_nio_llhttp__internal__c_is_equal_method(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_url_entry_normal;
      default:
        goto s_n_llhttp__internal__n_url_entry_connect;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_72: {
    state->error = 0x6;
    state->reason = "Expected space after method";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_22: {
    state->error = 0x15;
    state->reason = "on_method_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_req_first_space_before_url;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_89: {
    state->error = 0x20;
    state->reason = "`on_method_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_method_2: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_method(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_method_complete_1;
      return s_error;
    }
    goto s_n_llhttp__internal__n_invoke_llhttp__on_method_complete_1;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_store_method_1: {
    switch (c_nio_llhttp__internal__c_store_method(state, p, endp, match)) {
      default:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_method_2;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_90: {
    state->error = 0x6;
    state->reason = "Invalid method encountered";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_82: {
    state->error = 0xd;
    state->reason = "Invalid status code";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_80: {
    state->error = 0xd;
    state->reason = "Invalid status code";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_78: {
    state->error = 0xd;
    state->reason = "Invalid status code";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_20: {
    state->error = 0x15;
    state->reason = "on_status_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_headers_start;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_75: {
    state->error = 0x1b;
    state->reason = "`on_status_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__on_status_complete: {
    switch (c_nio_llhttp__on_status_complete(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_headers_start;
      case 21:
        goto s_n_llhttp__internal__n_pause_20;
      default:
        goto s_n_llhttp__internal__n_error_75;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_76: {
    state->error = 0x2;
    state->reason = "Expected LF after CR";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_18: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags_5(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_invoke_llhttp__on_status_complete;
      default:
        goto s_n_llhttp__internal__n_error_76;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_status: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_status(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_res_line_almost_done;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_res_line_almost_done;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_status_1: {
    const unsigned char* start;
    int err;
    
    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_status(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) (p + 1);
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_res_line_almost_done;
      return s_error;
    }
    p++;
    goto s_n_llhttp__internal__n_res_line_almost_done;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_77: {
    state->error = 0xd;
    state->reason = "Invalid response status";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_mul_add_status_code_2: {
    switch (c_nio_llhttp__internal__c_mul_add_status_code(state, p, endp, match)) {
      case 1:
        goto s_n_llhttp__internal__n_error_78;
      default:
        goto s_n_llhttp__internal__n_res_status_code_otherwise;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_79: {
    state->error = 0xd;
    state->reason = "Invalid status code";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_mul_add_status_code_1: {
    switch (c_nio_llhttp__internal__c_mul_add_status_code(state, p, endp, match)) {
      case 1:
        goto s_n_llhttp__internal__n_error_80;
      default:
        goto s_n_llhttp__internal__n_res_status_code_digit_3;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_81: {
    state->error = 0xd;
    state->reason = "Invalid status code";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_mul_add_status_code: {
    switch (c_nio_llhttp__internal__c_mul_add_status_code(state, p, endp, match)) {
      case 1:
        goto s_n_llhttp__internal__n_error_82;
      default:
        goto s_n_llhttp__internal__n_res_status_code_digit_2;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_83: {
    state->error = 0xd;
    state->reason = "Invalid status code";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_status_code: {
    switch (c_nio_llhttp__internal__c_update_status_code(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_res_status_code_digit_1;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_84: {
    state->error = 0x9;
    state->reason = "Expected space after version";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_21: {
    state->error = 0x15;
    state->reason = "on_version_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_res_after_version;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_74: {
    state->error = 0x21;
    state->reason = "`on_version_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_version_6: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_version(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_version_complete_1;
      return s_error;
    }
    goto s_n_llhttp__internal__n_invoke_llhttp__on_version_complete_1;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_version_5: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_version(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_73;
      return s_error;
    }
    goto s_n_llhttp__internal__n_error_73;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_http_minor_3: {
    switch (c_nio_llhttp__internal__c_load_http_minor(state, p, endp)) {
      case 9:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_6;
      default:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_5;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_http_minor_4: {
    switch (c_nio_llhttp__internal__c_load_http_minor(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_6;
      case 1:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_6;
      default:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_5;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_http_minor_5: {
    switch (c_nio_llhttp__internal__c_load_http_minor(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_6;
      default:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_5;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_http_major_1: {
    switch (c_nio_llhttp__internal__c_load_http_major(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_invoke_load_http_minor_3;
      case 1:
        goto s_n_llhttp__internal__n_invoke_load_http_minor_4;
      case 2:
        goto s_n_llhttp__internal__n_invoke_load_http_minor_5;
      default:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_5;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_test_lenient_flags_17: {
    switch (c_nio_llhttp__internal__c_test_lenient_flags_15(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_version_6;
      default:
        goto s_n_llhttp__internal__n_invoke_load_http_major_1;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_store_http_minor_1: {
    switch (c_nio_llhttp__internal__c_store_http_minor(state, p, endp, match)) {
      default:
        goto s_n_llhttp__internal__n_invoke_test_lenient_flags_17;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_version_7: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_version(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_85;
      return s_error;
    }
    goto s_n_llhttp__internal__n_error_85;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_version_8: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_version(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_86;
      return s_error;
    }
    goto s_n_llhttp__internal__n_error_86;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_store_http_major_1: {
    switch (c_nio_llhttp__internal__c_store_http_major(state, p, endp, match)) {
      default:
        goto s_n_llhttp__internal__n_res_http_dot;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_version_9: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_version(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_error_87;
      return s_error;
    }
    goto s_n_llhttp__internal__n_error_87;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_91: {
    state->error = 0x8;
    state->reason = "Expected HTTP/";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_19: {
    state->error = 0x15;
    state->reason = "on_method_complete pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_req_first_space_before_url;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_1: {
    state->error = 0x20;
    state->reason = "`on_method_complete` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_method: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_method(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_llhttp__on_method_complete;
      return s_error;
    }
    goto s_n_llhttp__internal__n_invoke_llhttp__on_method_complete;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_type: {
    switch (c_nio_llhttp__internal__c_update_type(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_span_end_llhttp__on_method;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_store_method: {
    switch (c_nio_llhttp__internal__c_store_method(state, p, endp, match)) {
      default:
        goto s_n_llhttp__internal__n_invoke_update_type;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_88: {
    state->error = 0x8;
    state->reason = "Invalid word encountered";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_span_end_llhttp__on_method_1: {
    const unsigned char* start;
    int err;

    start = state->_span_pos0;
    state->_span_pos0 = NULL;
    err = c_nio_llhttp__on_method(state, start, p);
    if (err != 0) {
      state->error = err;
      state->error_pos = (const char*) p;
      state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_update_type_1;
      return s_error;
    }
    goto s_n_llhttp__internal__n_invoke_update_type_1;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_update_type_2: {
    switch (c_nio_llhttp__internal__c_update_type(state, p, endp)) {
      default:
        goto s_n_llhttp__internal__n_span_start_llhttp__on_method_1;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_23: {
    state->error = 0x15;
    state->reason = "on_message_begin pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_load_type;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error: {
    state->error = 0x10;
    state->reason = "`on_message_begin` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__on_message_begin: {
    switch (c_nio_llhttp__on_message_begin(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_invoke_load_type;
      case 21:
        goto s_n_llhttp__internal__n_pause_23;
      default:
        goto s_n_llhttp__internal__n_error;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_pause_24: {
    state->error = 0x15;
    state->reason = "on_reset pause";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_n_llhttp__internal__n_invoke_update_finish;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_error_92: {
    state->error = 0x1f;
    state->reason = "`on_reset` callback error";
    state->error_pos = (const char*) p;
    state->_current = (void*) (intptr_t) s_error;
    return s_error;
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_llhttp__on_reset: {
    switch (c_nio_llhttp__on_reset(state, p, endp)) {
      case 0:
        goto s_n_llhttp__internal__n_invoke_update_finish;
      case 21:
        goto s_n_llhttp__internal__n_pause_24;
      default:
        goto s_n_llhttp__internal__n_error_92;
    }
    /* UNREACHABLE */;
    abort();
  }
  s_n_llhttp__internal__n_invoke_load_initial_message_completed: {
    switch (c_nio_llhttp__internal__c_load_initial_message_completed(state, p, endp)) {
      case 1:
        goto s_n_llhttp__internal__n_invoke_llhttp__on_reset;
      default:
        goto s_n_llhttp__internal__n_invoke_update_finish;
    }
    /* UNREACHABLE */;
    abort();
  }
}

int c_nio_llhttp__internal_execute(c_nio_llhttp__internal_t* state, const char* p, const char* endp) {
  llparse_state_t next;

  /* check lingering errors */
  if (state->error != 0) {
    return state->error;
  }

  /* restart spans */
  if (state->_span_pos0 != NULL) {
    state->_span_pos0 = (void*) p;
  }
  
  next = c_nio_llhttp__internal__run(state, (const unsigned char*) p, (const unsigned char*) endp);
  if (next == s_error) {
    return state->error;
  }
  state->_current = (void*) (intptr_t) next;

  /* execute spans */
  if (state->_span_pos0 != NULL) {
    int error;
  
    error = ((c_nio_llhttp__internal__span_cb) state->_span_cb0)(state, state->_span_pos0, (const char*) endp);
    if (error != 0) {
      state->error = error;
      state->error_pos = endp;
      return error;
    }
  }
  
  return 0;
}