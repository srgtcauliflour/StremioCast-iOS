#!/usr/bin/env python3
"""Patch the upstream StremioX Rust Env implementation for the current stremio-core trait."""
from pathlib import Path

env = Path("upstream/core/src/env.rs")
if not env.is_file():
    raise SystemExit(f"Expected upstream core Env source at {env}")

source = env.read_text()
if "fn client_info() -> ClientInfo" in source:
    print("Env::client_info already implemented; nothing to patch.")
    raise SystemExit(0)

import_line = "use stremio_core::types::remote_config::ClientInfo;\n"
if import_line not in source:
    anchor = "use stremio_core::runtime::{Env, EnvError, EnvFuture, EnvFutureExt, TryEnvFuture};\n"
    if anchor not in source:
        raise SystemExit("Could not find stable imports anchor in core/src/env.rs")
    source = source.replace(anchor, anchor + import_line, 1)

method = """    fn client_info() -> ClientInfo {
        ClientInfo {
            platform: "unknown".to_owned(),
            os: Some("ios".to_owned()),
            app_version: Some(env!("CARGO_PKG_VERSION").to_owned()),
            ..Default::default()
        }
    }

"""
anchor = "    fn analytics_context("
if anchor not in source:
    raise SystemExit("Could not find Env::analytics_context insertion anchor")
source = source.replace(anchor, method + anchor, 1)
env.write_text(source)
print("Patched TvosEnv::client_info for current stremio-core Env trait.")
