"""Read-only APK checks, including actual DEX class definitions, not filename guesses."""
import hashlib
import io
import pathlib
import re
import struct
import sys
import zipfile


def dex_classes(data):
    assert data.startswith(b"dex\n")
    string_count, strings_offset, type_count, types_offset = struct.unpack_from("<4I", data, 0x38)
    class_count, classes_offset = struct.unpack_from("<2I", data, 0x60)
    _, protos_offset = struct.unpack_from("<2I", data, 0x48)
    _, methods_offset = struct.unpack_from("<2I", data, 0x58)

    def uleb(pos):
        value, shift = 0, 0
        while True:
            byte = data[pos]
            pos += 1
            value |= (byte & 0x7F) << shift
            if not byte & 0x80:
                return value, pos
            shift += 7

    def string(index):
        assert index < string_count
        pos = struct.unpack_from("<I", data, strings_offset + 4 * index)[0]
        while data[pos] & 0x80:
            pos += 1
        pos += 1
        end = data.index(b"\0", pos)
        return data[pos:end].decode("utf-8", errors="replace")

    def typename(index):
        if index == 0xFFFFFFFF:
            return None
        assert index < type_count
        return string(struct.unpack_from("<I", data, types_offset + 4 * index)[0])

    def method(index):
        _, proto, name = struct.unpack_from("<HHI", data, methods_offset + index * 8)
        _, result, args = struct.unpack_from("<3I", data, protos_offset + proto * 12)
        parameters = []
        if args:
            count = struct.unpack_from("<I", data, args)[0]
            parameters = [typename(struct.unpack_from("<H", data, args + 4 + 2 * i)[0])
                          for i in range(count)]
        return string(name), "(" + "".join(parameters) + ")" + typename(result)

    for index in range(class_count):
        class_idx, _, superclass_idx = struct.unpack_from("<3I", data, classes_offset + index * 32)
        name = typename(class_idx)
        defined = set()
        if name == "Lio/legado/app/ui/book/read/ReadBookActivity;":
            pos = struct.unpack_from("<I", data, classes_offset + index * 32 + 24)[0]
            sizes = []
            for _ in range(4):
                value, pos = uleb(pos)
                sizes.append(value)
            for _ in range(sizes[0] + sizes[1]):
                _, pos = uleb(pos)
                _, pos = uleb(pos)
            for count in sizes[2:]:
                method_index = 0
                for _ in range(count):
                    delta, pos = uleb(pos)
                    method_index += delta
                    _, pos = uleb(pos)
                    _, pos = uleb(pos)
                    defined.add(method(method_index))
        yield name, (typename(superclass_idx), defined)


apk_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(__file__).resolve().parent.parent
with zipfile.ZipFile(apk_path) as apk:
    names = apk.namelist()
    abis = {name.split("/")[1] for name in names if name.startswith("lib/")}
    assert abis == {"armeabi-v7a"}, abis
    for lib in ["libluajit.so", "libluajit-launcher.so"]:
        assert f"lib/armeabi-v7a/{lib}" in names
    runtime = apk.read("assets/ko-runtime.zip")
    expected = apk.read("assets/ko-runtime.version").decode().strip()
    assert hashlib.sha256(runtime).hexdigest() == expected
    with zipfile.ZipFile(io.BytesIO(runtime)) as ko:
        ko_names = ko.namelist()
        assert ko.read("legado.lua") == (root / "ko/legado.lua").read_bytes(), "Stale Lua runtime"
        assert any(name.startswith("plugins/") for name in ko_names), "KO plugins missing"
        assert not any(name.startswith("l10n/") and not name.startswith("l10n/zh_CN/") for name in ko_names)
        assert "reader.lua" not in ko_names and "llapp_main.lua" not in ko_names
        assert "libs/libcrengine.so" in ko_names and "fonts/noto/NotoSansCJKsc-Regular.otf" in ko_names
        assert "COPYING" in ko_names and "LICENSE.launcher" in ko_names
        runtime_bytes = sum(info.file_size for info in ko.infolist())
    classes = dict(item for name in names if name.startswith("classes") and name.endswith(".dex")
                   for item in dex_classes(apk.read(name)))
    activity = "Lio/legado/app/ui/book/read/ReadBookActivity;"
    superclass, activity_methods = classes[activity]
    assert superclass == "Landroid/app/NativeActivity;"
    android_lua = apk.read("assets/android.lua").decode()
    required = set(re.findall(r'jni:call\w+Method\(\s*android\.app\.activity\.clazz,\s*"([^"]+)",\s*"([^"]+)"', android_lua))
    required -= {("getFilesDir", "()Ljava/io/File;"), ("getPackageManager", "()Landroid/content/pm/PackageManager;"),
                 ("getPackageName", "()Ljava/lang/String;")}
    required |= {("canIgnoreBatteryOptimizations", "()Z"), ("canWriteSystemSettings", "()Z"),
                 ("requestIgnoreBatteryOptimizations", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V"),
                 ("requestWriteSystemSettings", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V"),
                 ("onNativeError", "(Ljava/lang/String;)V")}
    required |= set(re.findall(r'java\("(\w+)",\s*"([^"]+)"', (root / "ko/legado.lua").read_text(encoding="utf-8")))
    assert required <= activity_methods, f"Missing JNI API definitions: {required - activity_methods}"
    old_reader = [name for name in classes if name.startswith("Lio/legado/app/ui/book/read/")
                  and not name.startswith("Lio/legado/app/ui/book/read/ReadBookActivity")]
    assert not old_reader, old_reader
    assert "Lio/legado/app/model/ReadAloud;" not in classes
    assert "Lio/legado/app/service/TTSReadAloudService;" not in classes
    for klass in ["KoChapterAdapter", "KoRuntime"]:
        assert f"Lio/legado/app/ko/{klass};" in classes
print(f"PASS: {len(classes)} DEX classes; {len(required)} JNI signatures; old reader absent; NativeActivity host; ARMv7; runtime hash and licenses")
print(f"APK {apk_path.stat().st_size / 1048576:.1f} MiB; KO installed code/fonts/libs {runtime_bytes / 1048576:.1f} MiB")
