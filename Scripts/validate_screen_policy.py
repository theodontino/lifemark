#!/usr/bin/env python3
"""Exercise the actual request gate using isolated preferences and a fake key reader."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
source = (root / 'App/Mac/LifeScreenModule.swift').read_text()
policy = source.split('enum LifeScreenAnalysisPolicy {', 1)[1].split('\n@MainActor final class LifeScreenModule', 1)[0]
policy = ('enum LifeScreenAnalysisPolicy {' + policy).replace('UserDefaults.standard', 'testDefaults')
fixture = (root / 'Scripts/Fixtures/ScreenPolicyChecks.swift').read_text()
with tempfile.TemporaryDirectory(prefix='LifeScreenPolicy-') as directory:
    path = Path(directory) / 'Checks.swift'
    path.write_text(fixture.replace('/* POLICY_IMPLEMENTATION */', policy))
    subprocess.run(['swift', '-module-cache-path', str(Path(directory) / 'Modules'), str(path)], check=True)
