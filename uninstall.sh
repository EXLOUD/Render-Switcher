#!/system/bin/sh
# Full cleanup: targets, settings, logs, locks, state
# (and the targets mirror that Zygisk reads from the module dir)

rm -rf /data/adb/render_switcher 2>/dev/null

# Mirror read by the Zygisk companion (module dir is removed by the manager too)
rm -f /data/adb/modules/render_switcher/targets.conf 2>/dev/null
rm -rf /data/adb/modules_update/render_switcher 2>/dev/null

# Clear runtime props set by the module (best-effort)
resetprop -p --delete persist.skia.force_gpu 2>/dev/null
resetprop --delete debug.hwui.renderer 2>/dev/null
setprop persist.skia.force_gpu 0 2>/dev/null

echo "Render Switcher uninstalled (targets and config removed)"
