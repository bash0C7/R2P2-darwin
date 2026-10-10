require "minitest/autorun"
require_relative "devicectl"

class TestDevicectl < Minitest::Test
  NBSP = " "
  LISTING = <<~TEXT
    Name                           Hostname   Identifier                                    State                Model                                      Reality  
    ----------------------------   --------   -------------------------------------------   ------------------   ----------------------------------------   ---------
    Apple Watch Series 11 (42mm)              989F0FC2-8A57-4D18-BB7F-AA68BBBE159F (UDID)   shutdown             Apple Watch Series 11 (42mm) (Watch7,17)   simulated
    Toshiakiさんの#{NBSP}Apple#{NBSP}Watch                    00008301-E8932C8C210BC02E (UDID)              available (paired)   Apple Watch Series 8 (Watch6,14)           physical 
    bisect-1                                  B82234B5-50A7-40FD-81EE-47CC9BEA7C2C (UDID)   shutdown             iPhone 17 Pro (iPhone18,1)                 simulated
    iPhone 18 Pro                             26644641-89FA-4BF8-9402-F122B631433B (UDID)   connected            iPhone 18 Pro (iPhone19,2)                 simulated
    ゆふのiPhone13Pro                            00008110-001E795834F8801E (UDID)              unavailable          iPhone 13 Pro (iPhone14,2)                 physical 
    ゆふのiPhone16e                              00008140-001D39113668401C (UDID)              available (paired)   iPhone 16e (iPhone17,5)                    physical 
  TEXT

  OLD_LISTING = <<~TEXT
    Name       Hostname              Identifier                             State                Model
    --------   -------------------   ------------------------------------   ------------------   ------------------
    My iPhone  my-iphone.coredevice  AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB   connected            iPhone 16e (iPhone17,5)
    Old Phone  old.coredevice        CCCCCCCC-1111-2222-3333-DDDDDDDDDDDD   unavailable          iPhone 13 (iPhone14,5)
  TEXT

  def test_iphone_picks_the_reachable_physical_phone
    assert_equal "00008140-001D39113668401C", Devicectl.pick_udid(LISTING, /iPhone|iPad/)
  end

  def test_watch_picks_the_reachable_physical_watch
    assert_equal "00008301-E8932C8C210BC02E", Devicectl.pick_udid(LISTING, /Watch/)
  end

  def test_device_name_selects_by_substring
    assert_equal "00008140-001D39113668401C", Devicectl.pick_udid(LISTING, /iPhone|iPad/, name: "iPhone16e")
  end

  def test_device_name_matching_only_an_unreachable_device_finds_nothing
    assert_nil Devicectl.pick_udid(LISTING, /iPhone|iPad/, name: "iPhone13Pro")
  end

  def test_device_name_matching_nothing_raises
    assert_raises(RuntimeError) { Devicectl.pick_udid(LISTING, /iPhone|iPad/, name: "nonexistent") }
  end

  def test_older_listing_without_reality_column_counts_as_physical
    assert_equal "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB", Devicectl.pick_udid(OLD_LISTING, /iPhone/)
  end

  def test_connected_names_are_physical_connected_devices_only
    assert_equal [], Devicectl.connected_names(LISTING)
    assert_equal ["My iPhone"], Devicectl.connected_names(OLD_LISTING)
  end

  def test_nothing_reachable_yields_nil
    assert_nil Devicectl.pick_udid("Name  Identifier  State\n", /iPhone/)
  end
end
