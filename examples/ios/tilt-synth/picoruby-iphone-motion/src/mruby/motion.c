#include "mruby.h"
#include "mruby/presym.h"

static mrb_value
mrb_motion_pitch(mrb_state *mrb, mrb_value self)
{
  return mrb_float_value(mrb, MOTION_pitch());
}

static mrb_value
mrb_motion_roll(mrb_state *mrb, mrb_value self)
{
  return mrb_float_value(mrb, MOTION_roll());
}

static mrb_value
mrb_motion_available_p(mrb_state *mrb, mrb_value self)
{
  return mrb_bool_value(MOTION_available());
}

void
mrb_picoruby_iphone_motion_gem_init(mrb_state *mrb)
{
  struct RClass *class_Motion = mrb_define_class_id(mrb, MRB_SYM(Motion), mrb->object_class);
  mrb_define_method_id(mrb, class_Motion, MRB_SYM(pitch), mrb_motion_pitch, MRB_ARGS_NONE());
  mrb_define_method_id(mrb, class_Motion, MRB_SYM(roll),  mrb_motion_roll,  MRB_ARGS_NONE());
  mrb_define_method_id(mrb, class_Motion, MRB_SYM_Q(available), mrb_motion_available_p, MRB_ARGS_NONE());
}

void
mrb_picoruby_iphone_motion_gem_final(mrb_state *mrb)
{
}
