#include "../../include/torch.h"

/* Provided by the PicoTorchDarwin Swift package (@c exports), resolved at app
 * link time. Declared here so the cross-build needs no generated -Swift.h. */
extern int ptorch_set(int on);
extern int ptorch_available(void);

bool
TORCH_set(bool on)
{
  return ptorch_set(on ? 1 : 0) != 0;
}

bool
TORCH_available(void)
{
  return ptorch_available() != 0;
}
