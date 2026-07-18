def bench_tick(seed, n)
  s = seed & 0x7FFF
  y1 = 0; y2 = 0; ema = 0; sum = 0; i = 0
  while i < n
    s = (s * 75 + 74) & 0x7FFF
    x = s - 16384
    ema = ema + ((x - ema) >> 1)
    y = ((31000 * y1 - 15500 * y2) >> 14) + (ema >> 2)
    y = 32767 if y > 32767
    y = -32767 if y < -32767
    y2 = y1; y1 = y
    sum = ((sum * 31) ^ (y & 0x7FFF)) & 0x7FFF
    i += 1
  end
  (sum << 15) | s
end
