// C11 atomics on one 64-bit word, for macOS 14 (Swift's Synchronization module needs macOS 15).
// Orders: 0 relaxed, 2 acquire, 3 release, 4 acquire-release, 5 sequentially consistent (C11 values).
#pragma once
#include <stdint.h>
#include <stdbool.h>

uint64_t ac_load(const uint64_t *word, int order);
void ac_store(uint64_t *word, uint64_t value, int order);
uint64_t ac_exchange(uint64_t *word, uint64_t value, int order);
uint64_t ac_fetch_add(uint64_t *word, uint64_t delta, int order);
bool ac_compare_exchange(uint64_t *word, uint64_t *expected, uint64_t desired, int order);
