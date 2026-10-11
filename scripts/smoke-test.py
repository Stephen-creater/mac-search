#!/usr/bin/env python3
"""Exercise the real CLI against an isolated temporary index."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
bin_dir = subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=root, text=True).strip()
cli = str(Path(bin_dir) / 'macsearch-cli')
with tempfile.TemporaryDirectory(prefix='macsearch-smoke-') as temporary:
    base = Path(temporary)
    fixtures = base / 'files'
    fixtures.mkdir()
    (fixtures / '中文测试文档.txt').write_text('Chinese search fixture\n')
    (fixtures / 'search-example.md').write_text('Markdown fixture\n')
    db = str(base / 'test.macsearch')
    subprocess.run([cli, 'scan', '--root', str(fixtures), '--db', db], check=True, capture_output=True)
    for query, expected in [('中文', '中文测试文档.txt'), ('zwcswd', '中文测试文档.txt'), ('ext:md', 'search-example.md')]:
        output = subprocess.check_output([cli, 'search', query, '--db', db], text=True)
        assert expected in output and 'total=1 ' in output, (query, output)
        print(f'PASS {query}: one expected match')
