#include "EngineSync.h"
#include <stdatomic.h>

// Every word is 8-byte aligned (allocated by Swift as UInt64), so these are lock-free on arm64.
#define A(word) ((_Atomic uint64_t *)(word))

uint64_t ac_load(const uint64_t *word, int order) {
    return atomic_load_explicit((_Atomic uint64_t *)word, (memory_order)order);
}
void ac_store(uint64_t *word, uint64_t value, int order) {
    atomic_store_explicit(A(word), value, (memory_order)order);
}
uint64_t ac_exchange(uint64_t *word, uint64_t value, int order) {
    return atomic_exchange_explicit(A(word), value, (memory_order)order);
}
uint64_t ac_fetch_add(uint64_t *word, uint64_t delta, int order) {
    return atomic_fetch_add_explicit(A(word), delta, (memory_order)order);
}
bool ac_compare_exchange(uint64_t *word, uint64_t *expected, uint64_t desired, int order) {
    return atomic_compare_exchange_strong_explicit(A(word), expected, desired, (memory_order)order, memory_order_relaxed);
}
