# TiltSynth — the whole tilt-to-sound behaviour is Ruby. Motion/Synth come
# from the linked picoruby-iphone-motion / picoruby-iphone-synth gems; their
# Darwin ports drive CMDeviceMotion and AVAudioEngine. This app owns the
# scale-quantization and FM-depth mapping that the VMExecutor tick calls.
#
# tilt (pitch) snaps to the nearest note in a 2-octave C major pentatonic
# scale; roll maps continuously to FM depth. Both mappings are pure Ruby —
# no C or Swift rebuild is needed to change the scale or the ranges below.

PENTATONIC_SCALE = [261.6, 293.7, 329.6, 392.0, 440.0,    # C4 D4 E4 G4 A4
                     523.3, 587.3, 659.3, 784.0, 880.0]   # C5 D5 E5 G5 A5

class TiltSynthApp
  attr_reader :motion, :synth

  def initialize
    @motion = Motion.new
    @synth  = Synth.new
    @synth.start
    @log = []
    if @motion.available?
      log "ready: device motion available"
    else
      log "ready: no device motion (Simulator?) -- tick will no-op"
    end
  end

  def tick(arg = nil)
    if @motion.available?
      pitch = @motion.pitch
      roll  = @motion.roll
      note  = quantize(pitch)
      depth = clamp((roll + 45.0) / 90.0, 0.0, 1.0)
      @synth.note = note
      @synth.fm_depth = depth
      log "pitch=#{pitch} roll=#{roll} note=#{note} depth=#{depth}"
    end
    flush_log
  end

  private

  # pitch -30..+30 degrees -> nearest step in PENTATONIC_SCALE
  def quantize(pitch)
    idx = ((pitch + 30.0) / 60.0 * (PENTATONIC_SCALE.size - 1)).round
    idx = 0 if idx < 0
    idx = PENTATONIC_SCALE.size - 1 if idx > PENTATONIC_SCALE.size - 1
    PENTATONIC_SCALE[idx]
  end

  def clamp(v, lo, hi)
    return lo if v < lo
    return hi if v > hi
    v
  end

  def log(msg)
    @log.push(msg)
  end

  def flush_log
    return nil if @log.empty?
    out = @log.join("\n")
    @log = []
    print out
    nil
  end
end

$app = TiltSynthApp.new
