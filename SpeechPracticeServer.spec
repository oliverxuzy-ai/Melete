# Headless FastAPI server bundled inside the native Mac app. Build with ./build_native.sh
from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs, collect_submodules

datas = [("static", "static")] + collect_data_files("faster_whisper")
binaries = (collect_dynamic_libs("ctranslate2") + collect_dynamic_libs("av")
            + collect_dynamic_libs("onnxruntime") + collect_dynamic_libs("tokenizers"))
hiddenimports = (collect_submodules("faster_whisper")
                 + ["uvicorn.logging", "uvicorn.loops.auto", "uvicorn.protocols.http.auto",
                    "uvicorn.protocols.websockets.auto", "uvicorn.lifespan.on", "multipart", "coach", "daily"])
try:   # optional: the Claude clip picker imports it lazily
    hiddenimports += collect_submodules("anthropic")
except Exception:
    pass

a = Analysis(["server_main.py"], datas=datas, binaries=binaries, hiddenimports=hiddenimports,
             excludes=["tkinter", "matplotlib", "PyQt5", "PyQt6", "PySide2", "PySide6", "IPython", "jupyter", "webview"])
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, exclude_binaries=True, name="SpeechPracticeServer", console=True, target_arch="arm64")
coll = COLLECT(exe, a.binaries, a.datas, name="SpeechPracticeServer")
