# -*- mode: python ; coding: utf-8 -*-

from pathlib import Path

project_root = Path(SPECPATH).resolve().parents[1]
backend_root = project_root / "backend"

datas = [
    (str(project_root / "config" / "store_model_config.json"), "config"),
    (str(project_root / "config" / "system.json"), "config"),
    (str(project_root / "config" / "us_universe.json"), "config"),
    (str(project_root / "demo_data"), "demo_data"),
    (str(project_root / "frontend" / "dist"), "frontend/dist"),
]

hiddenimports = []

analysis = Analysis(
    [str(project_root / "packaging" / "windows" / "aegis_sidecar.py")],
    pathex=[str(backend_root), str(project_root)],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        "aegis_quant.moomoo_gateway",
        "aegis_quant.pnl_ledger",
        "aegis_quant.t_trader",
        "aegis_quant.us_pipeline",
        "futu",
        "moomoo",
        "pip",
        "pytest",
        "tkinter",
    ],
    noarchive=False,
    optimize=1,
)
pyz = PYZ(analysis.pure)

exe = EXE(
    pyz,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name="AegisBackend",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
)

collection = COLLECT(
    exe,
    analysis.binaries,
    analysis.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="AegisBackend",
)
