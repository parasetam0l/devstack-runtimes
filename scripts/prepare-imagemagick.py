#!/usr/bin/env python3
"""Restrict DevStack's ImageMagick config lookup to explicitly supplied runtime paths."""
from pathlib import Path
import sys

source = Path(sys.argv[1]) / "MagickCore/configure.c"
contents = source.read_text()
marker = 'if (getenv("DEVSTACK_MAGICK_CONFIG_ONLY") != (char *) NULL)'
if marker not in contents:
    original = """        configure_path=DestroyString(configure_path);
      }
  }
#if defined(MAGICKCORE_INSTALLED_SUPPORT)"""
    replacement = """        configure_path=DestroyString(configure_path);
        /* Bundled runtimes must not visit the original build-machine prefix. */
        if (getenv("DEVSTACK_MAGICK_CONFIG_ONLY") != (char *) NULL)
          return(paths);
      }
  }
#if defined(MAGICKCORE_INSTALLED_SUPPORT)"""
    if original not in contents:
        raise SystemExit("ImageMagick configure lookup changed; review the runtime patch.")
    source.write_text(contents.replace(original, replacement, 1))
