#!/usr/bin/env python3
"""빌드 결과물(Android APK, Windows zip)을 버전별 폴더로 관리한다.

폴더 구조 (CI의 `builds` 브랜치와 로컬 `dist/` 모두 같다):

    v1.0.3/
      qnap-manager-android.apk
      qnap-manager-windows.zip
      SHA256SUMS.txt
      version.json
    latest/        ← 가장 최근 버전 복사본
    VERSIONS.md    ← 버전 목록

명령:
    python3 tools/buildstore.py fetch
        GitHub `builds` 브랜치에서 새 버전을 받아 작업 폴더 dist/ 에 추가한다.
        (dist/ 에는 받은 버전이 모두 쌓이고, 브랜치에는 최근 몇 개만 남는다)

    python3 tools/buildstore.py add STORE NEWDIR --version 1.0.3 --commit abc1234 --message "..."
        (CI 전용) NEWDIR 의 파일을 STORE/v1.0.3/ 에 넣고 오래된 버전을 정리한다.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tarfile
import io
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ["qnap-manager-android.apk", "qnap-manager-windows.zip"]


def _vkey(p: Path):
    try:
        return tuple(int(x) for x in p.name.lstrip("v").split("."))
    except ValueError:
        return (0,)


def versions(store: Path):
    return sorted((p for p in store.glob("v*") if p.is_dir()), key=_vkey, reverse=True)


def update_latest(store: Path):
    vs = versions(store)
    latest = store / "latest"
    if latest.exists():
        shutil.rmtree(latest)
    if vs:
        shutil.copytree(vs[0], latest)


def write_index(store: Path):
    lines = [
        "# QNAP 매니저 빌드 버전",
        "",
        "`latest/` 폴더에 가장 최근 버전이 있습니다.",
        "",
        "| 버전 | 빌드 날짜 | 커밋 | Android | Windows |",
        "|---|---|---|---|---|",
    ]
    for v in versions(store):
        meta_file = v / "version.json"
        m = json.loads(meta_file.read_text(encoding="utf-8")) if meta_file.exists() else {}
        has = lambda n: "✅" if (v / n).exists() else "—"
        lines.append(
            f"| {v.name} | {m.get('date', '')[:10]} | `{m.get('commit', '')}` {m.get('message', '')} "
            f"| {has(ASSETS[0])} | {has(ASSETS[1])} |"
        )
    lines += ["", f"_갱신: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}_", ""]
    (store / "VERSIONS.md").write_text("\n".join(lines), encoding="utf-8")


def cmd_add(a):
    store, new = Path(a.store), Path(a.newdir)
    vdir = store / f"v{a.version}"
    vdir.mkdir(parents=True, exist_ok=True)
    sums = []
    for name in ASSETS:
        f = new / name
        if f.exists():
            shutil.copy2(f, vdir / name)
            sums.append(f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {name}")
            print(f"+ {vdir.name}/{name} ({f.stat().st_size / 1048576:.1f} MB)")
    if not sums:
        sys.exit("추가할 빌드 파일이 없습니다")
    (vdir / "SHA256SUMS.txt").write_text("\n".join(sums) + "\n", encoding="utf-8")
    meta = {
        "version": a.version,
        "commit": a.commit,
        "message": a.message,
        "date": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    (vdir / "version.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for old in versions(store)[a.keep:]:
        print(f"- {old.name} (브랜치에서 정리, GitHub Releases에는 남음)")
        shutil.rmtree(old)
    update_latest(store)
    write_index(store)


def cmd_fetch(a):
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)

    def git(*args, **kw):
        return subprocess.run(["git", "-C", str(ROOT), *args], check=True, **kw)

    print("builds 브랜치를 받는 중…")
    git("fetch", "--depth", "1", "origin", "+refs/heads/builds:refs/remotes/origin/builds")
    data = git("archive", "--format=tar", "origin/builds", capture_output=True).stdout
    added = []
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        members = [m for m in tar.getmembers() if m.name.startswith("v") and "/" in m.name]
        for m in members:
            vname = m.name.split("/")[0]
            target = dist / m.name
            if not m.isfile():
                continue
            if target.exists() and (dist / vname / "version.json").exists() and vname not in added:
                continue  # 이미 받은 버전
            if vname not in added:
                added.append(vname)
            target.parent.mkdir(parents=True, exist_ok=True)
            with tar.extractfile(m) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)
    update_latest(dist)
    write_index(dist)
    if added:
        print("새로 받은 버전: " + ", ".join(sorted(set(added), key=lambda n: _vkey(Path(n)))))
    else:
        print("새 버전이 없습니다")
    for v in versions(dist):
        files = [f.name for f in v.iterdir() if f.name in ASSETS]
        print(f"  dist/{v.name}/  {', '.join(files)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("fetch", help="builds 브랜치에서 dist/ 로 받기")
    p = sub.add_parser("add", help="(CI) 빌드 결과를 버전 폴더에 추가")
    p.add_argument("store")
    p.add_argument("newdir")
    p.add_argument("--version", required=True)
    p.add_argument("--commit", default="")
    p.add_argument("--message", default="")
    p.add_argument("--keep", type=int, default=3, help="브랜치에 남길 버전 수")
    a = ap.parse_args()
    {"fetch": cmd_fetch, "add": cmd_add}[a.cmd](a)


if __name__ == "__main__":
    main()
