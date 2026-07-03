import AVFoundation

// C-callable surface for ports/darwin/torch.c. Uses `@c` (SE-0495) like
// PicoBLEExports. Direction is C -> Swift only.

@c public func ptorch_set(_ on: Int32) -> Int32 {
  guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
    return 0
  }
  do {
    try device.lockForConfiguration()
    device.torchMode = (on != 0) ? .on : .off
    device.unlockForConfiguration()
    return 1
  } catch {
    return 0
  }
}

@c public func ptorch_available() -> Int32 {
  (AVCaptureDevice.default(for: .video)?.hasTorch ?? false) ? 1 : 0
}
