#ifndef UXN_ASM_C_H
#define UXN_ASM_C_H

enum uxn_asm_result {
  UXN_ASM_OK = 0,
  UXN_ASM_BAD_ALLOC = 1,
  UXN_ASM_INVALID_ARGUMENT = 2,
  UXN_ASM_ASSEMBLY_ERROR = 3,
};

typedef struct uxn_asm *uxn_asm_t;

#ifdef UXN_FREESTANDING
  uxn_asm_t uxn_asm_create(void);
#else
  typedef struct uxn_asm_config *uxn_asm_config_t;

  uxn_asm_config_t uxn_asm_config_create(uxn_asm_config_t cfg);
  void uxn_asm_config_destroy(uxn_asm_config_t cfg);

  uxn_asm_t uxn_asm_create(uxn_asm_config_t cfg);
#endif

void uxn_asm_destroy(uxn_asm_t a);

enum uxn_asm_result uxn_asm_assemble(uxn_asm_t a, unsigned char *src, unsigned char *dst, size_t *dst_len, int *error);
enum uxn_asm_result uxn_asm_get_diagnostic(uxn_asm_t a, int code, unsigned char *dst, size_t dst_len);
enum uxn_asm_result uxn_asm_get_symbol_count(uxn_asm_t a, size_t *count);
enum uxn_asm_result uxn_asm_get_symbol(uxn_asm_t a, size_t idx, unsigned short *offset, unsigned char **sym);

#endif /* defined(UXN_ASM_C_H) */
