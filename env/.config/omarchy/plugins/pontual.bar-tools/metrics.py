#!/usr/bin/env python3
"""One bounded read-only /proc sample. No caches, background workers or state."""
import json
import sys
from datetime import datetime
from zoneinfo import ZoneInfo
from pathlib import Path


def sample():
    fields = Path('/proc/stat').read_text().splitlines()[0].split()
    ticks = [int(value) for value in fields[1:9]]  # guest already counted in user
    memory = {}
    for line in Path('/proc/meminfo').read_text().splitlines():
        key, value = line.split(':', 1)
        memory[key] = int(value.split()[0])
    total = memory['MemTotal']
    return {'total': sum(ticks), 'idle': ticks[3] + ticks[4],
            'memory': round(100 * (total - memory['MemAvailable']) / total, 1)}


if __name__ == '__main__':
    try:
        value = {'clock': datetime.now(ZoneInfo('America/Sao_Paulo')).strftime('%H:%M:%S')} if sys.argv[1:] == ['--clock'] else sample()
        print(json.dumps(value, separators=(',', ':')))
    except (OSError, ValueError, KeyError, ZeroDivisionError) as error:
        print(json.dumps({'error': str(error)}))
        raise SystemExit(1)
