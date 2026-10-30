/* bcrypt through libxcrypt. Each call releases the OCaml runtime lock for its ~50 ms: minor collections stop every
   domain, so a domain holding the lock would stall all of them. Strings are copied first: the GC can move them. */
#define _GNU_SOURCE
#include <crypt.h>
#include <stdlib.h>
#include <string.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>

static value run_crypt(const char *pw, const char *setting) {
  CAMLparam0();
  CAMLlocal1(res);
  struct crypt_data *data = calloc(1, sizeof *data);
  char out[CRYPT_OUTPUT_SIZE] = {0};
  if (data != NULL) {
    caml_enter_blocking_section();
    char *h = crypt_r(pw, setting, data);
    if (h != NULL && h[0] != '*') strncpy(out, h, sizeof out - 1);
    caml_leave_blocking_section();
    explicit_bzero(data, sizeof *data);
    free(data);
  }
  res = caml_copy_string(out);
  CAMLreturn(res);
}

/* Returns "" on failure. */
CAMLprim value conduit_bcrypt_verify(value pw, value hash) {
  CAMLparam2(pw, hash);
  CAMLlocal1(res);
  char *p = strdup(String_val(pw)), *h = strdup(String_val(hash));
  res = (p && h) ? run_crypt(p, h) : caml_copy_string("");
  if (p) { explicit_bzero(p, strlen(p)); free(p); }
  free(h);
  CAMLreturn(res);
}

CAMLprim value conduit_bcrypt_hash(value pw) {
  CAMLparam1(pw);
  CAMLlocal1(res);
  char setting[CRYPT_GENSALT_OUTPUT_SIZE];
  char *p = strdup(String_val(pw));
  res = (p && crypt_gensalt_rn("$2b$", 10, NULL, 0, setting, sizeof setting)) ? run_crypt(p, setting)
                                                                              : caml_copy_string("");
  if (p) { explicit_bzero(p, strlen(p)); free(p); }
  CAMLreturn(res);
}
