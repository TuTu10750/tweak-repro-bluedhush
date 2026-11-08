# HushMonitor

Passive monitor loaded together with the original BluedHush 5.19 dylib.

- Forces all original feature flags off.
- Keeps `float_ball=1` and `switch_debug_log=1`.
- Loads `Frameworks/OriginalHush.dylib`.
- Records config reads/writes, original log messages, panel actions, module
  navigation, photo viewer, location/tracking actions and pass-through app
  navigation into `Documents/HushMonitor.log`.
- Does not provide any feature itself.

