# Architecture

```
 WebUI ──► skiactl ──► targets.sh ──► targets.conf
                                            │
                     ┌──────────────────────┘
                     ▼
              Zygisk module
   preAppSpecialize: package in targets?  (companion lookup)
   postAppSpecialize: COW-patch debug.hwui.renderer / ro.hwui.use_vulkan
                     in the process-private copy of the property page(s)
                     │
                     ▼
            HWUI init reads the patched values
```

## Boot

1. `post-fs-data` – global default (`debug.hwui.renderer`; must exist so the
   per-process patch has a prop_info to overwrite)
2. `service` – bootloop counter after `sys.boot_completed`
3. Zygisk – per process at specialize

No polling. No global flip on app launch/exit. No PLT hooks.
