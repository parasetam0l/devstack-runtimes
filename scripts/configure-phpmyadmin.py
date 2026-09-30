#!/usr/bin/env python3
"""Keep mutable phpMyAdmin configuration and caches outside the signed bundle."""
from pathlib import Path
import sys
p = Path(sys.argv[1]) / "libraries/vendor_config.php"
s = p.read_text()
s = s.replace("'tempDir' => ROOT_PATH . 'tmp' . DIRECTORY_SEPARATOR,", "'tempDir' => getenv('DEVSTACK_PHPMYADMIN_TEMP') ?: ROOT_PATH . 'tmp' . DIRECTORY_SEPARATOR,")
s = s.replace("'cacheDir' => ROOT_PATH . 'libraries' . DIRECTORY_SEPARATOR . 'cache' . DIRECTORY_SEPARATOR,", "'cacheDir' => getenv('DEVSTACK_PHPMYADMIN_TEMP') ?: ROOT_PATH . 'libraries' . DIRECTORY_SEPARATOR . 'cache' . DIRECTORY_SEPARATOR,")
s = s.replace("'configFile' => ROOT_PATH . 'config.inc.php',", "'configFile' => getenv('DEVSTACK_PHPMYADMIN_CONFIG') ?: ROOT_PATH . 'config.inc.php',")
s = s.replace("'versionCheckDefault' => true,", "'versionCheckDefault' => false,")
p.write_text(s)
