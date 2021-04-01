#include <stdio.h>
#include <math.h>
#include <inttypes.h>

int main() {

  uint64_t N;
  uint64_t D;
  uint64_t Q;

  N = 0xc9649f05a8e1a8bb;
  D = 0x82f6747f707af2c0;
  Q = N/D;

  printf("N = %" PRIx64 "\n", N);
  printf("D = %" PRIx64 "\n", D);
  printf("Q = %" PRIx64 "\n", Q);
  printf("R = %" PRIx64 "\n", N%D);  



}