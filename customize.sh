#!/system/bin/sh
ui_print " "
ui_print "******************************"
ui_print "  Render Switcher - HWUI Renderer"
ui_print "******************************"
ui_print " "
ui_print "- Primary: Zygisk (process isolation)"
ui_print "- Global: post-fs-data default renderer"
ui_print " "

DATA_DIR="/data/adb/render_switcher"
MODS_DIR="/data/adb/modules"
LIVE_MOD="$MODS_DIR/render_switcher"

# Is this a clean install or an update of a working installation?
#  - no live module dir, or it is marked for removal  => clean install
#  - live module dir present and not marked for removal => update (keep data)
FRESH=1
if [ -d "$LIVE_MOD" ] && [ ! -f "$LIVE_MOD/remove" ]; then
    FRESH=0
fi

if [ "$FRESH" = "1" ]; then
    # Drop everything a previously removed copy may have left behind,
    # otherwise the old app list comes back after reinstall.
    if [ -d "$DATA_DIR" ]; then
        ui_print "- Clean install: removing leftover data from previous version"
        rm -rf "$DATA_DIR" 2>/dev/null
    fi
    resetprop -p --delete persist.skia.force_gpu 2>/dev/null
    setprop persist.skia.force_gpu 0 2>/dev/null
fi

rm -f "$MODPATH/targets.conf" 2>/dev/null
mkdir -p "$DATA_DIR/config" "$DATA_DIR/state" "$DATA_DIR/locks"
chmod 700 "$DATA_DIR"

if [ ! -f "$DATA_DIR/config/targets.conf" ]; then
    cp "$MODPATH/config/targets.conf" "$DATA_DIR/config/targets.conf" 2>/dev/null || \
        printf '# package=renderer\n' > "$DATA_DIR/config/targets.conf"
fi
if [ ! -f "$DATA_DIR/config/settings.conf" ]; then
    cp "$MODPATH/config/settings.conf" "$DATA_DIR/config/settings.conf" 2>/dev/null || true
fi
chmod 600 "$DATA_DIR/config/"* 2>/dev/null

for f in post-fs-data.sh service.sh uninstall.sh scripts/boot.sh bin/skiactl common/*.sh; do
    [ -f "$MODPATH/$f" ] && chmod 755 "$MODPATH/$f"
done

ui_print "- Data: $DATA_DIR"
ui_print "- CLI : $MODPATH/bin/skiactl"
ui_print "- Per-app: Zygisk companion reads targets.conf"
ui_print " "
ui_print "Reboot recommended."
