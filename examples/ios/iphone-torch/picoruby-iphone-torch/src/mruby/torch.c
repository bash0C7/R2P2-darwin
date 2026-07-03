#include "mruby.h"
#include "mruby/presym.h"

static mrb_value
mrb_torch_on(mrb_state *mrb, mrb_value self)
{
  return mrb_bool_value(TORCH_set(true));
}

static mrb_value
mrb_torch_off(mrb_state *mrb, mrb_value self)
{
  return mrb_bool_value(TORCH_set(false));
}

static mrb_value
mrb_torch_available_p(mrb_state *mrb, mrb_value self)
{
  return mrb_bool_value(TORCH_available());
}

void
mrb_picoruby_iphone_torch_gem_init(mrb_state *mrb)
{
  struct RClass *class_Torch = mrb_define_class_id(mrb, MRB_SYM(Torch), mrb->object_class);
  mrb_define_method_id(mrb, class_Torch, MRB_SYM(on),  mrb_torch_on,  MRB_ARGS_NONE());
  mrb_define_method_id(mrb, class_Torch, MRB_SYM(off), mrb_torch_off, MRB_ARGS_NONE());
  mrb_define_method_id(mrb, class_Torch, MRB_SYM_Q(available), mrb_torch_available_p, MRB_ARGS_NONE());
}

void
mrb_picoruby_iphone_torch_gem_final(mrb_state *mrb)
{
}
