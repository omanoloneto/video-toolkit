import Cocoa
import FlutterMacOS
import macos_window_utils

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    var windowFrame = self.frame
    // Desktop-first, landscape-only layout: enforce a wide minimum size.
    self.minSize = NSSize(width: 1100, height: 680)
    if windowFrame.width < 1280 || windowFrame.height < 780 {
      windowFrame.size = NSSize(width: 1280, height: 780)
    }

    // macos_window_utils hosts the Flutter view inside an
    // NSVisualEffectView so themes can enable window translucency.
    let macOSWindowUtilsViewController = MacOSWindowUtilsViewController()
    self.contentViewController = macOSWindowUtilsViewController
    self.setFrame(windowFrame, display: true)

    MainFlutterWindowManipulator.start(mainFlutterWindow: self)

    RegisterGeneratedPlugins(registry: macOSWindowUtilsViewController.flutterViewController)

    super.awakeFromNib()
  }
}
