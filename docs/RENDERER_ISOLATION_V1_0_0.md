# Renderer isolation (v1.0.0 – COW method)

History: earlier PLT-hook approaches on property APIs hooked libhwui/libbase/libcutils
successfully on Android 16, yet the pipeline stayed Vulkan and no hooked library ever read
`debug.hwui.renderer`. The COW method therefore patches the property memory itself.

## Method

1. `__system_property_find(name)` -> `prop_info*` inside `/dev/__properties__/<ctx>`
2. locate its mapping in `/proc/self/maps`
3. `mmap(MAP_PRIVATE|MAP_FIXED)` only the page(s) holding that `prop_info`, same address,
   same file offset (process-private copy-on-write)
4. verify `prop_info.name == name`, write value (NUL padded), set serial
   `(len<<24) | (counter+2)`, `mprotect(PROT_READ)`, read back via `__system_property_get`

Any reader in the process (native or Java) sees the override; the shared area is untouched.
Only the touched page(s) stop tracking later changes to neighbouring properties in that process.

Limits: property must already exist; long (>=92 byte) properties are refused; the
layout is validated by the name check before anything is written.

## Verification

```sh
su -c 'logcat -c; am force-stop com.instagram.android; monkey -p com.instagram.android -c android.intent.category.LAUNCHER 1; sleep 10; logcat -d -s RenderSwitcher; dumpsys gfxinfo com.instagram.android | grep -i pipeline'
```

## Overhead / logging (v1.0.0)

* Companion keeps the parsed `targets.conf` in memory; per app launch it does two `stat()`
  calls and re-reads a file only if its mtime/size changed (or it appeared/disappeared).
* Apps that are not targets produce **no** log lines. Logged: `companion: targets (re)loaded`
  (once per config change), `companion: HIT` + `COW:` lines for targets, and any error.
* Non-target processes: one socket round-trip to the companion, then the module is unloaded.

## No uid filter (v1.0.0)

The uid-range check (10000-19999) was removed. System uids and isolated uids are no longer
skipped by uid; child zygotes and root-granted processes are still skipped. Every other app
process asks the companion, and only packages listed in `targets.conf` are patched. Processes
where `/dev/__properties__` is not accessible (SELinux) log `COW: ... not present` /
`ENFORCEMENT FAILED` and are left unchanged. An isolated process
(e.g. `com.android.chrome:sandboxed_process0`) resolves to its base package name and is
therefore treated as that package.
