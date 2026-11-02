#!/usr/bin/env python3
"""C compiler wrapper for the Windows CI legs: c3c adds -fPIE to every C compile, and clang for the
x86_64-pc-windows-msvc target refuses that one option. Everything else is passed through to clang unchanged.
Used through C3C_CC (see the 'C compiler' step in ci.yml and release.yml)."""
import os, subprocess, sys
cc = os.environ.get("REAL_CC", "clang")
sys.exit(subprocess.call([cc] + [a for a in sys.argv[1:] if a != "-fPIE"]))
