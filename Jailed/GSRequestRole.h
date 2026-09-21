#pragma once
#include <string.h>

// Keep photo import operations under the host identity accepted by the core.
static inline const char *GSEmbeddedRequestRole(const char *op) {
 if(op && (!strcmp(op,"source_lookup") || !strcmp(op,"begin") ||
           !strcmp(op,"append") || !strcmp(op,"seal") || !strcmp(op,"account_native")))
  return "googlephotos";
 return "settings";
}
