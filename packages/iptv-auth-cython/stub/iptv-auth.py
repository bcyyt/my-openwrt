#!/usr/bin/env python3
# 防反编译加载器（由 build_cython_so.py 生成，请勿手工修改）
# 按架构加载 Cython 编译模块；导入即运行主流程。
import os, platform, sys
_LIB = '/usr/lib/iptv-auth'


def _arch():
    m = platform.machine().lower()
    if m in ('x86_64', 'amd64'):
        return 'x86_64'
    if m in ('aarch64', 'arm64', 'armv8'):
        return 'aarch64'
    if m.startswith('arm') or m.startswith('armv') or 'arm_cortex' in m:
        return 'armv7'
    return m


sys.path.insert(0, os.path.join(_LIB, 'pylib-' + _arch()))
import iptv_auth_core  # noqa: F401 — 顶层即主流程（构建时已展开 __main__ guard）
