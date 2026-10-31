"""执行监考台本地测试；仅使用模拟数据，不访问板卡或云模型。"""
from pathlib import Path
import argparse,datetime,json,sys,tempfile,unittest

ROOT=Path(__file__).resolve().parents[1]
NAMES=['app.test_agent','app.test_dashboard_session','app.test_history_association',
       'app.test_evidence_v2_receiver','app.test_replay_tasks','app.test_agent_fallback',
       'app.test_agent_joycode','app.test_agent_opencode','app.test_agent_settings',
       'app.test_agent_vision','app.test_agent_workflow']

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,help='全新的结果目录，保留已有测试记录')
    args=parser.parse_args()
    out=(args.output or ROOT/'sim/results'/('pc_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S'))).resolve()
    if out.exists():raise SystemExit('输出目录已存在，拒绝覆盖：'+str(out))
    out.mkdir(parents=True)
    temporary=out/'temporary';temporary.mkdir()
    tempfile.tempdir=str(temporary)
    sys.path.insert(0,str(ROOT/'src/pc/host'))
    with (out/'run.log').open('w',encoding='utf-8') as log:
        result=unittest.TextTestRunner(stream=log,verbosity=2).run(unittest.defaultTestLoader.loadTestsFromNames(NAMES))
    data=dict(tests=result.testsRun,failures=len(result.failures),errors=len(result.errors),
              skipped=len(result.skipped),passed=result.wasSuccessful(),suites=NAMES,
              python=sys.version,hardware_access=False,cloud_requests=False)
    (out/'result.json').write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
    print('PC本地测试：'+('通过' if data['passed'] else '失败')+'；共 '+str(data['tests'])+' 项；结果：'+str(out/'result.json'),flush=True)
    raise SystemExit(0 if data['passed'] else 1)

if __name__=='__main__':main()
