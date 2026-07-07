#include "mruby.h"
#include "mruby/presym.h"

static mrb_value
mrb_synth_start(mrb_state *mrb, mrb_value self)
{
  return mrb_bool_value(SYNTH_start());
}

static mrb_value
mrb_synth_stop(mrb_state *mrb, mrb_value self)
{
  return mrb_bool_value(SYNTH_stop());
}

static mrb_value
mrb_synth_set_note(mrb_state *mrb, mrb_value self)
{
  mrb_float freq;
  mrb_get_args(mrb, "f", &freq);
  return mrb_bool_value(SYNTH_set_note((double)freq));
}

static mrb_value
mrb_synth_set_fm_depth(mrb_state *mrb, mrb_value self)
{
  mrb_float depth;
  mrb_get_args(mrb, "f", &depth);
  return mrb_bool_value(SYNTH_set_fm_depth((double)depth));
}

void
mrb_picoruby_iphone_synth_gem_init(mrb_state *mrb)
{
  struct RClass *class_Synth = mrb_define_class_id(mrb, MRB_SYM(Synth), mrb->object_class);
  mrb_define_method_id(mrb, class_Synth, MRB_SYM(start), mrb_synth_start, MRB_ARGS_NONE());
  mrb_define_method_id(mrb, class_Synth, MRB_SYM(stop),  mrb_synth_stop,  MRB_ARGS_NONE());
  mrb_define_method(mrb, class_Synth, "note=", mrb_synth_set_note, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, class_Synth, "fm_depth=", mrb_synth_set_fm_depth, MRB_ARGS_REQ(1));
}

void
mrb_picoruby_iphone_synth_gem_final(mrb_state *mrb)
{
}
