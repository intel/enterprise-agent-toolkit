# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Shared test helpers: load the operator with kopf/kubernetes stubbed (no cluster)."""
import os
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
CHART_TEMPLATES = os.path.join(HERE, "..", "..", "..", "charts", "claw", "agent-operator", "templates")
STUBBED = ("kopf", "kubernetes", "kubernetes.config", "kubernetes.client")


class _Any(types.ModuleType):
    """Module whose every attribute is another _Any and whose calls are pass-through decorators."""

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        sub = _Any(f"{self.__name__}.{name}")
        setattr(self, name, sub)
        return sub

    def __call__(self, *a, **kw):
        return lambda fn: fn


def load_controller():
    saved = {k: sys.modules.get(k) for k in STUBBED}
    for name in STUBBED:
        sys.modules[name] = _Any(name)
    try:
        mod = types.ModuleType("controller_under_test")
        mod.__file__ = os.path.join(HERE, "controller.py")
        with open(mod.__file__) as fh:
            exec(compile(fh.read(), "controller.py", "exec"), mod.__dict__)
        return mod
    finally:
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v


class ApiException(Exception):
    def __init__(self, status=500):
        super().__init__(f"({status})")
        self.status = status


class Logger:
    def __init__(self):
        self.infos, self.warnings, self.errors = [], [], []

    def info(self, m):
        self.infos.append(str(m))

    def warning(self, m):
        self.warnings.append(str(m))

    def error(self, m):
        self.errors.append(str(m))


class Patch:
    """Stand-in for kopf's patch object."""

    def __init__(self):
        self.status, self.spec = {}, {}


def spec(username, **extra):
    return {"owner": {"principal": f"{username}@example.com", "username": username}, **extra}
