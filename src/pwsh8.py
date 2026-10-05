# -*- coding: utf-8 -*-
"""NT PowerShell 8 wrapper for the complete Microsoft PowerShell 7 runtime.
Release builds require the complete bundled engine; developer source can use external PS7.
No unattended installation, no arbitrary runtime DLL injection or privilege bypass.
"""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

NT_VERSION = '0.8.0-embedded-powershell7-preview'


def resource_dir() -> Path:
    frozen = getattr(sys, '_MEIPASS', None)
    return Path(frozen) if frozen else Path(__file__).resolve().parent.parent


ENGINE_FILES = (
    'pwsh.exe', 'System.Management.Automation.dll',
    'pwsh.runtimeconfig.json', 'pwsh.deps.json', 'Modules',
)


def bundled_engine_candidates(assets: Path | None = None) -> list[Path]:
    """Look in the release-adjacent folder and PyInstaller onefile extract folder."""
    assets = resource_dir() if assets is None else assets
    paths: list[Path] = []
    if getattr(sys, 'frozen', False):
        paths.append(Path(sys.executable).resolve().parent / 'vendor' / 'pwsh7')
    paths.append(assets / 'vendor' / 'pwsh7')
    return paths


def valid_engine(path: Path) -> bool:
    """Minimum bundle integrity check; SHA-256 archive verified by preparation step."""
    return all((path / name).exists() for name in ENGINE_FILES)


def locate_bundled_pwsh(assets: Path | None = None) -> Path | None:
    for folder in bundled_engine_candidates(assets):
        if valid_engine(folder):
            return folder / 'pwsh.exe'
    return None


def locate_pwsh(override: str | None = None) -> Path | None:
    """For developer source only, prefer locally bundled PS7, then external PS7."""
    bundled = locate_bundled_pwsh()
    if bundled:
        return bundled
    candidates: list[str] = []
    if override:
        candidates.append(override)
    env_path = os.environ.get('NT_PWSH_EXE')
    if env_path:
        candidates.append(env_path)
    from_path = shutil.which('pwsh.exe') or shutil.which('pwsh')
    if from_path:
        candidates.append(from_path)
    for variable in ('ProgramFiles', 'ProgramW6432'):
        base = os.environ.get(variable)
        if base:
            candidates.append(str(Path(base) / 'PowerShell' / '7' / 'pwsh.exe'))
    candidates += [r'A:\PowerShell\7\pwsh.exe', r'A:\PowerShell7\pwsh.exe']
    for item in candidates:
        candidate = Path(item.strip('"'))
        if candidate.is_file():
            return candidate
    return None


def engine_selection(assets: Path, override: str | None = None) -> tuple[Path | None, str]:
    """Built releases with a marker MUST run the bundled engine, never system PS7."""
    bundled = locate_bundled_pwsh(assets)
    if bundled:
        return bundled, 'bundled'
    if getattr(sys, 'frozen', False) and (assets / 'NTPS8.BUNDLE_MARKER').is_file():
        return None, 'bundle-missing'
    external = locate_pwsh(override)
    return external, 'external' if external else 'missing'


def bootstrap_dependencies(assets: Path, *, install_engine: bool) -> int:
    """Use the built-in Windows PowerShell engine solely for dependency management."""
    script = assets / 'NTPS8.Bootstrap.ps1'
    if os.name != 'nt' or not script.is_file():
        print('Dependency bootstrap requires Windows and NTPS8.Bootstrap.ps1.', file=sys.stderr)
        return 2
    native_ps = str(Path(os.environ.get('WINDIR', r'C:\Windows')) /
                    'System32' / 'WindowsPowerShell' / 'v1.0' / 'powershell.exe')
    options = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)]
    options.append('-InstallPowerShell7' if install_engine else '-Check')
    try:
        return subprocess.call([native_ps, *options])
    except OSError as exc:
        print('Cannot run Windows dependency bootstrap: ' + str(exc), file=sys.stderr)
        return 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='NT PowerShell 8 preview using real Microsoft PowerShell 7')
    parser.add_argument('--pwsh-path', help='Exact pwsh.exe path, including installations on drive A:')
    parser.add_argument('--check-deps', action='store_true', help='Check dependencies or verify the bundled engine')
    parser.add_argument('--engine-info', action='store_true', help='Print engine origin/path and check required native files')
    parser.add_argument('--version', action='version', version='NT PS8 ' + NT_VERSION + ' (not Microsoft PowerShell 8)')
    args = parser.parse_args(argv)
    assets = resource_dir()
    needed = ('NTPS8.Profile.ps1', 'NTPS8.Module.psm1', 'NTPS8.Recovery.psm1',
              'NTPS8.Reinstall.psm1', 'NTPS8.Deps.psm1', 'NTPS8.DepsAdmin.ps1',
              'NTPS8.Bootstrap.ps1', 'NTPS8.Kali.psm1', 'NTPS8.KaliAdmin.ps1', 'NTPS8.Unlock.psm1',
              'NTPS8.GitHub.psm1', 'NTPS8.KaliRemote.psm1', 'NTPS8.Theme.psm1')
    reinstall = assets / 'NTPS8.Reinstall.psm1'
    if not reinstall.is_file() or any(not (assets / item).is_file() for item in needed):
        print('Missing trusted NT PS8 profiles/modules. Re-extract the complete package.', file=sys.stderr)
        return 3
    pwsh, origin = engine_selection(assets, args.pwsh_path)
    if args.engine_info:
        print('[NT PS8] Engine origin: ' + origin)
        print('[NT PS8] Engine path: ' + (str(pwsh) if pwsh else '<missing>'))
        if pwsh and origin == 'bundled':
            print('[NT PS8] Complete runtime directory found: ' + str(pwsh.parent))
        return 0 if pwsh else 5
    if args.check_deps and pwsh:
        print('[NT PS8] PowerShell 7 available (' + origin + ') at: ' + str(pwsh))
        return 0
    if args.check_deps:
        if origin == 'bundle-missing':
            print('Release package is missing the full vendor\\pwsh7 engine folder.', file=sys.stderr)
            return 5
        return bootstrap_dependencies(assets, install_engine=False)
    if origin == 'bundle-missing':
        print('[NT PS8] Incomplete release: required bundled PowerShell 7 DLLs/runtime are missing.', file=sys.stderr)
        print('[NT PS8] Rebuild via PREPARE_BUNDLED_PWSH.ps1 and BUILD_EXE.cmd.', file=sys.stderr)
        return 5
    if not pwsh:
        print('[NT PS8] Microsoft PowerShell 7 is absent in this developer checkout.', file=sys.stderr)
        print('[NT PS8] Bundle the official engine with PREPARE_BUNDLED_PWSH.ps1.', file=sys.stderr)
        if sys.stdin.isatty() and os.name == 'nt':
            choice = input('Search for and offer external PowerShell 7 installation? [Y/N]: ').strip().lower()
            if choice == 'y':
                bootstrap_dependencies(assets, install_engine=True)
                pwsh, origin = engine_selection(assets, args.pwsh_path)
        if not pwsh:
            return 2
    env = os.environ.copy()
    env['NT_PS8_HOME'] = str(assets)
    env['NT_PS8_ENGINE_SOURCE'] = origin
    command = [str(pwsh), '-NoLogo', '-NoExit', '-NoProfile', '-File', str(assets / 'NTPS8.Profile.ps1')]
    try:
        return subprocess.call(command, env=env)
    except OSError as exc:
        print('Could not start installed PowerShell engine: ' + str(exc), file=sys.stderr)
        return 4


if __name__ == '__main__':
    sys.exit(main())
