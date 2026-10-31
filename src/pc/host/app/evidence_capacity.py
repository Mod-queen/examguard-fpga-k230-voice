"""Read-only allocated-file-byte inventory, no validation or deletion policy."""
from collections import Counter
from pathlib import Path
import shutil


def scan_evidence_capacity(root):
    root=Path(root).resolve()
    if not root.is_dir():
        raise ValueError('Evidence root must be an existing directory')
    newest={}
    revisions=Counter()
    for directory in root.glob('egv2_*'):
        if directory.is_symlink() or not directory.is_dir():
            continue
        paths=sorted(p.parent for p in directory.glob('revision_*/manifest.json') if not p.is_symlink())
        if paths:
            newest[directory.name]=paths[-1].name
            revisions[directory.name]=len(paths)
    bytes_by_kind=Counter();files_by_kind=Counter();skipped=[];pending=set()
    # Path.rglob does not descend directory symlinks on supported Python; reject
    # symlink files as well, rather than following evidence into another volume.
    for path in root.rglob('*'):
        if path.is_symlink():
            skipped.append(path.relative_to(root).as_posix());continue
        if not path.is_file():
            continue
        relative=path.relative_to(root);parts=relative.parts
        if any(p.startswith('.pending_') for p in parts):
            kind='unpublished_pending';pending.add('/'.join(parts[:2]))
        elif parts[0].startswith('egv2_') and len(parts)>1 and parts[1].startswith('revision_'):
            kind='latest_published_EG' if newest.get(parts[0])==parts[1] else 'older_or_unpublished_revision'
        elif parts[0]=='history_results': kind='HR_results'
        elif parts[0].startswith('event_'): kind='legacy_PG'
        elif relative.name=='udp_ingress_diagnostics.json': kind='receiver_diagnostics'
        else: kind='other'
        bytes_by_kind[kind]+=path.stat().st_size;files_by_kind[kind]+=1
    disk=shutil.disk_usage(root)
    return dict(root=str(root),total_file_bytes=sum(bytes_by_kind.values()),total_files=sum(files_by_kind.values()),
                bytes_by_kind=dict(sorted(bytes_by_kind.items())),files_by_kind=dict(sorted(files_by_kind.items())),
                EG_identities=len(newest),published_revisions=sum(revisions.values()),pending_directories=len(pending),
                disk_free_bytes=disk.free,skipped_links=skipped,
                reference_budget=dict(width=320,height=180,pixel_format='RGB565',fps=10,window_frames=40,
                                      pixel_bytes_per_second=1152000,pixel_bytes_per_window=4608000,
                                      raw_pixels_45min_bytes=3110400000,
                                      note='Reference payload budget only: not continuous recording, transport/disk throughput or retention duration measured.'),
                interpretation='Logical file lengths only, not filesystem allocation/RSS; newest means lexicographic published revision, not validated healthy evidence. No files changed/deleted. Older revisions/pending are not safe-to-delete recommendations.')
