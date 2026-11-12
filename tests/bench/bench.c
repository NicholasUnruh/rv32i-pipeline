// Bare-metal CPI benchmark: sorting, searching, recursion and bit loops, the branch
// mix of ordinary integer code. Writes 1 to tohost if the checksum matches the one
// computed on the host, else 3.
#include <stdint.h>

#define N 96
#define EXPECTED 2608u  // run() compiled for the host with -DHOST

extern volatile uint32_t tohost;

static uint32_t data[N];
static uint32_t state = 12345u;

static uint32_t next_random(void) {  // xorshift32: no multiply on RV32I
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state;
}

static void insertion_sort(uint32_t *a, int n) {
  for (int i = 1; i < n; i++) {
    uint32_t key = a[i];
    int j = i - 1;
    while (j >= 0 && a[j] > key) {
      a[j + 1] = a[j];
      j--;
    }
    a[j + 1] = key;
  }
}

static int binary_search(const uint32_t *a, int n, uint32_t key) {
  int lo = 0, hi = n - 1;
  while (lo <= hi) {
    int mid = (lo + hi) >> 1;
    if (a[mid] == key) return mid;
    if (a[mid] < key)
      lo = mid + 1;
    else
      hi = mid - 1;
  }
  return -1;
}

static uint32_t fib(uint32_t n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

static uint32_t popcount(uint32_t x) {
  uint32_t count = 0;
  while (x) {
    count += x & 1u;
    x >>= 1;
  }
  return count;
}

uint32_t run(void) {
  uint32_t sum = 0;
  for (int i = 0; i < N; i++) data[i] = next_random() >> 16;
  insertion_sort(data, N);
  for (int i = 0; i < N; i += 3) sum += (uint32_t)binary_search(data, N, data[i]);
  for (int i = 0; i < 32; i++) sum += (uint32_t)binary_search(data, N, next_random() >> 16);
  for (int i = 0; i < N; i++) sum += popcount(data[i]);
  sum += fib(14);
  return sum;
}

#ifndef HOST
int main(void) {
  tohost = run() == EXPECTED ? 1u : 3u;
  for (;;) {
  }
}
#endif
