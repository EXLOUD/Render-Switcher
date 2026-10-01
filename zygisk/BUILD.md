# Zygisk companion – збірка

## Що потрібно
- Android NDK r25+ ([developer.android.com/ndk](https://developer.android.com/ndk/downloads))
- CMake 3.18+
- Linux / macOS / WSL / Windows

## Збірка

```bash
cd zygisk
export ANDROID_NDK_HOME=$HOME/Android/Sdk/ndk/27.0.12077973   # ваш шлях
./build.sh              # усі ABI (за замовчуванням)
./build.sh all          # те саме
./build.sh arm64-v8a armeabi-v7a   # вибрані ABI
```

Підтримувані ABI:
| ABI           | Пристрої                          |
|---------------|-----------------------------------|
| arm64-v8a     | Сучасні телефони (64-bit ARM)     |
| armeabi-v7a   | Старі 32-bit ARM телефони         |
| x86           | Емулятори 32-bit                  |
| x86_64        | Емулятори 64-bit / деякі планшети |

Результат:
```
zygisk/arm64-v8a.so
zygisk/armeabi-v7a.so
zygisk/x86.so
zygisk/x86_64.so
```

## Упаковка в модуль

Структура ZIP:
```
Render_Switcher.zip
├── module.prop
├── zygisk/
│   ├── arm64-v8a.so      ← обов’язково для modern пристроїв
│   ├── armeabi-v7a.so    ← 32-bit ARM
│   ├── x86.so            ← емулятори
│   ├── x86_64.so         ← емулятори / x86_64
│   └── module.prop
├── webroot/
└── ...
```

Перезібрати ZIP з кореня модуля і встановити в Magisk → **Reboot**.

## Перевірка на пристрої

```bash
# Zygisk ON у Magisk Settings
ls -la /data/adb/modules/render_switcher/zygisk/
# має бути відповідний <abi>.so

# Після reboot — target у WebUI, потім:
getprop debug.hwui.renderer
```

## Без NDK на ПК

1. Встановити Android Studio → SDK Manager → NDK  
2. Або командою:

```bash
sdkmanager "ndk;27.0.12077973"
```

Шлях зазвичай:
`$HOME/Android/Sdk/ndk/<version>`


## Windows (cmd / PowerShell)

```bat
cd zygisk
set ANDROID_NDK_HOME=%LOCALAPPDATA%\Android\Sdk\ndk\27.0.12077973
build.bat
```

Усі ABI:

```bat
build.bat all
```

Потрібні **CMake** у PATH і **NDK**. Типовий шлях NDK після Android Studio:

`%LOCALAPPDATA%\Android\Sdk\ndk\<version>`


## Статичний аналіз (PVS-Studio)

Аналіз винесено в окремий скрипт, а не в `build.bat`: він набагато
повільніший за звичайну збірку.

**Потрібно:** [PVS-Studio для Windows](https://pvs-studio.com/en/pvs-studio/download/)
(стандартна тека `C:\Program Files (x86)\PVS-Studio`, скрипт знаходить
`CompilerCommandsAnalyzer.exe` та `PlogConverter.exe` сам) і активована
[ліцензія](https://pvs-studio.com/en/docs/manual/0046/).

```bat
cd zygisk
build.bat                     :: збірка всіх ABI (створює build\<ABI>\compile_commands.json)
analyze-pvs.bat               :: аналіз усіх ABI (без аргументів = all)
analyze-pvs.bat arm64-v8a     :: або лише вибрані ABI
```

Звіти: `pvs\reports\<ABI>\PVS-Studio.html` (браузер) та `PVS-Studio.json`
(CI / імпорт в IDE).

Як це влаштовано:

- `CMakeLists.txt` вмикає `CMAKE_EXPORT_COMPILE_COMMANDS`, тож Ninja-збірка
  (`build.bat`) кладе `compile_commands.json` у `build\<ABI>\`. Модуль
  `PVS-Studio.cmake` не потрібен.
- Платформа виставляється за ABI: `linux64` (arm64-v8a, x86_64) / `linux32`
  (armeabi-v7a, x86). Збірка має бути успішною.
- `build\`, NDK та сторонній `src\zygisk.hpp` виключені з аналізу.

Налаштування (усі файли необов'язкові):

| Файл | Призначення |
|---|---|
| `pvs\PVS-Studio.cfg` | препроцесор, групи діагностик (`GA`+`OP`+`64`), `lic-file` |
| `pvs\.pvsconfig` | вимкнення/зміна окремих правил, виключення шляхів |
| `pvs\suppress_file.suppress.json` | baseline придушених попереджень |

Змінні середовища: `PVS_JOBS=<N>`; `PVS_COMPILER=clang++=clang` — якщо
аналізатор не розпізнав NDK-компілятор (код виходу 8).
