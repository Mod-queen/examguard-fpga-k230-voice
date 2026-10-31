"""Run Agent + affected integration tests with a workspace-owned temp directory."""
from pathlib import Path
from datetime import datetime, timezone
import os
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'verification_out' / 'agent_20261030'
WORK.mkdir(parents=True, exist_ok=True)
TEMP = WORK / 'test_tmp'
TEMP.mkdir(exist_ok=True)
tempfile.tempdir = str(TEMP)
os.environ['TEMP'] = os.environ['TMP'] = str(TEMP)
sys.path.insert(0, str(ROOT / 'host'))

if __name__ == '__main__':
    names = sys.argv[1:] or ['app.test_agent', 'app.test_dashboard_session', 'app.test_history_association',
                            'app.test_evidence_v2_receiver', 'app.test_replay_tasks']
    log_path = WORK / ('test_results_' + datetime.now(timezone.utc).strftime('%H%M%S_%f') + '.txt')
    with log_path.open('w', encoding='utf-8') as log:
        suite = unittest.defaultTestLoader.loadTestsFromNames(names)
        result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
    print(f'tests={result.testsRun} failures={len(result.failures)} errors={len(result.errors)}')
    print('log=' + str(log_path))
    raise SystemExit(0 if result.wasSuccessful() else 1)
