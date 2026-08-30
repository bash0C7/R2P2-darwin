#import "picoruby_bridge.h"
// Stop flag from the picoruby-iphone-torch gem (libmruby.a). Any thread may
// set it; the VM thread polls it inside Kernel#sleep.
void TORCH_request_stop(void);
void TORCH_clear_stop(void);
