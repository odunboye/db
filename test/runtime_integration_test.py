"""Run the existing repository suite under an external process deadline."""
from pathlib import Path
import os
import subprocess
root = Path(__file__).resolve().parents[1]
app = root / 'test/build/exec/db-test_app'
env = dict(os.environ, IDRIS2_INC_SRC=str(app), LD_LIBRARY_PATH=str(app), DYLD_LIBRARY_PATH=str(app))
subprocess.run([str(app / 'db-test.so')], env=env, check=True, timeout=180)
