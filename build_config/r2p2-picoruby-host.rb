# Host build used only to link the bridge smoke test (Task 2). Its gem set is
# kept in EXACT parity with build_config/r2p2-picoruby-ios-sim.rb so the smoke
# test, which links against THIS build, actually predicts what the reduced
# ios-sim libmruby.a can run. Toolchain is host-appropriate (plain MRuby::Build,
# no -arch/-isysroot). PICORB_PLATFORM_POSIX is dropped to mirror ios-sim for
# maximum parity (it builds clean on the host without it).
MRuby::Build.new("host") do |conf|
  conf.toolchain :clang

  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.picoruby

  conf.gem core: "mruby-compiler"
end
