# HushMonitorSafe

Zero-hook monitor loaded beside an already-injected BluedHush dylib.

- Installs no Objective-C or Substrate hooks.
- Never changes feature switches.
- Never loads Substrate or OriginalHush.
- Records compact app-state, page/tab, and feature-switch transitions in
  `Documents/HushMonitor.log`.
- Leaves the original plugin's detailed `Documents/hooo` log untouched.
- Does not provide any feature itself.

