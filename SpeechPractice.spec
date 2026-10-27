# PyInstaller spec for the Mac app. Build with ./build_app.sh
from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs, collect_submodules

datas = [("static", "static")] + collect_data_files("faster_whisper")
binaries = (collect_dynamic_libs("ctranslate2") + collect_dynamic_libs("av")
            + collect_dynamic_libs("onnxruntime") + collect_dynamic_libs("tokenizers"))
hiddenimports = (collect_submodules("faster_whisper") + collect_submodules("webview")
                 + ["uvicorn.logging", "uvicorn.loops.auto", "uvicorn.protocols.http.auto",
                    "uvicorn.protocols.websockets.auto", "uvicorn.lifespan.on", "multipart"])

a = Analysis(
    ["app.py"],
    datas=datas,
    binaries=binaries,
    hiddenimports=hiddenimports,
    excludes=["tkinter", "matplotlib", "PyQt5", "PyQt6", "PySide2", "PySide6", "IPython", "jupyter"],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, exclude_binaries=True, name="SpeechPractice", console=False,
          target_arch="arm64", codesign_identity=None, entitlements_file=None)
coll = COLLECT(exe, a.binaries, a.datas, name="SpeechPractice")
app = BUNDLE(
    coll,
    name="SpeechPractice.app",
    icon="build_assets/AppIcon.icns",
    bundle_identifier="com.zhengyangxu.speechpractice",
    info_plist={
        "CFBundleName": "SpeechPractice",
        "CFBundleDisplayName": "口述练习记录",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "12.0",
        "LSApplicationCategoryType": "public.app-category.productivity",
        "NSHighResolutionCapable": True,
        "NSMicrophoneUsageDescription": "录音并分析你的口述练习。音频和转写只保存在这台电脑上。",
    },
)
