#ifndef UXN_C_H
#define UXN_C_H

enum uxn_result {
  UXN_PAUSED = -1,
  UXN_OK = 0,
  UXN_ERR_ALLOC,
  UXN_ERR_INVALID,
  UXN_ERR_TRAPPED,
};

enum uxn_result uxn_rom_create(size_t page_count, unsigned char **rom);
int uxn_rom_size(unsigned char *rom);
enum uxn_result uxn_rom_destroy(unsigned char *rom);

typedef struct uxn_cpu *uxn_cpu_t;
typedef struct uxn_cpu_stack *uxn_cpu_stack_t;
typedef int (*interrupt_fn)(uxn_cpu_t, unsigned char address, void* ud);

enum uxn_result uxn_cpu_create(unsigned char *rom, uxn_cpu_t *dst);
enum uxn_result uxn_cpu_destroy(uxn_cpu_t cpu);
enum uxn_result uxn_cpu_evaluate(uxn_cpu_t cpu, unsigned short vector);
enum uxn_result uxn_cpu_evaluate_limit(uxn_cpu_t cpu, unsigned short vector, size_t max_steps);
enum uxn_result uxn_cpu_get_pc(uxn_cpu_t cpu, unsigned short *pc);
enum uxn_result uxn_cpu_set_pc(uxn_cpu_t cpu, unsigned short pc);
enum uxn_result uxn_cpu_run(uxn_cpu_t cpu, size_t max_steps);
enum uxn_result uxn_cpu_get_page_ptr(uxn_cpu_t cpu, size_t page, unsigned char **dst[static 0x10000]);
enum uxn_result uxn_cpu_get_device_page_ptr(uxn_cpu_t cpu, unsigned char **dst[static 0x100]);
enum uxn_result uxn_cpu_set_input_interrupt_handler(uxn_cpu_t cpu, interrupt_fn cn);
enum uxn_result uxn_cpu_set_output_interrupt_handler(uxn_cpu_t cpu, interrupt_fn cn);
enum uxn_result uxn_cpu_set_interrupt_data(uxn_cpu_t cpu, void *ud);
enum uxn_result uxn_cpu_set_interrupt_masks(uxn_cpu_t cpu, unsigned short input[static 16], unsigned short output[static 16]);
enum uxn_result uxn_cpu_get_interrupt_masks(uxn_cpu_t cpu, unsigned short input[static 16], unsigned short output[static 16]);
enum uxn_result uxn_cpu_get_wst(uxn_cpu_t cpu, uxn_cpu_stack_t *dst);
enum uxn_result uxn_cpu_get_rst(uxn_cpu_t cpu, uxn_cpu_stack_t *dst);

enum uxn_result uxn_stack_get_top(uxn_cpu_stack_t stack, unsigned char *top);
enum uxn_result uxn_stack_get_ptr(uxn_cpu_stack_t stack, unsigned char **ptr);

#endif /* defined(UXN_C_H) */
