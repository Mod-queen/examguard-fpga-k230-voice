"""Export a host capture-session report after the dashboard has exited.

python session_report.py sessions/capture_....sqlite3 --out report.md
Add --evidence-root <directory> for PGv1 candidates and verified HR/EG review.
"""
import argparse
from pathlib import Path

from app.event_store import load_session
from app.review import export_report, load_evidence_review


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path)
    parser.add_argument("--health-csv", type=Path, help="export all committed canonical ST receipts")
    args = parser.parse_args()
    if args.out.resolve() == args.session.resolve():
        parser.error("Report output cannot overwrite the capture database")
    if args.health_csv and args.health_csv.resolve() in (args.session.resolve(), args.out.resolve()):
        parser.error('Health CSV must differ from database and report')
    session = load_session(args.session)
    windows, errors = load_evidence_review(args.evidence_root) if args.evidence_root else ([], [])
    export_report(args.out, None, windows, errors, session=session)
    if args.health_csv:
        from app.health_history import export_status_csv
        export_status_csv(args.health_csv, session)
    print(f"Exported {len(session.events)} AL + {len(session.transactions)} ET committed receipts from {session.host_session_id}: {args.out}")


if __name__ == "__main__":
    main()
