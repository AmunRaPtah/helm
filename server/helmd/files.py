"""File manager for the phone: browse, upload (files and whole folders), download
(files, folder trees, or a folder as a streamed zip), mkdir, rename, delete.

Folder uploads arrive as one request per file carrying a relative path, so the
tree is rebuilt on the box. Deletes go to a trash dir, not unlink, because they
come from a phone screen; trash older than TRASH_DAYS is purged on each delete.
"""
import os
import shutil
import stat
import time
import zipfile
from pathlib import Path, PurePosixPath
from typing import Iterator, Optional

TRASH_DIR = Path.home() / ".helm" / "trash"
TRASH_DAYS = 7
TREE_MAX_FILES = 20000


class FsError(Exception):
    def __init__(self, status: int, msg: str):
        super().__init__(msg)
        self.status = status
        self.msg = msg


def abs_path(p: str) -> Path:
    path = Path(p).expanduser()
    if not path.is_absolute():
        raise FsError(400, "path must be absolute")
    return Path(os.path.normpath(path))


def safe_rel(rel: str) -> PurePosixPath:
    """A client-supplied relative path, refused if it could escape its base dir."""
    r = PurePosixPath(rel.replace("\\", "/"))
    if r.is_absolute() or any(part in ("..", "") for part in r.parts) or not r.parts:
        raise FsError(400, f"bad relative path: {rel!r}")
    return r


def _entry(p: Path) -> dict:
    try:
        st = p.stat()
        is_dir = stat.S_ISDIR(st.st_mode)
        size, mtime = (0 if is_dir else st.st_size), st.st_mtime
    except OSError:  # dangling symlink
        is_dir, size, mtime = False, 0, 0
    return {"name": p.name, "is_dir": is_dir, "size": size, "mtime": mtime, "is_link": p.is_symlink()}


def list_dir(path: str) -> dict:
    p = abs_path(path)
    if not p.is_dir():
        raise FsError(404, "not a directory")
    entries = []
    try:
        for e in p.iterdir():
            entries.append(_entry(e))
    except PermissionError:
        raise FsError(403, "permission denied")
    entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    return {"path": str(p), "parent": str(p.parent) if p != p.parent else None, "entries": entries}


def tree(path: str) -> dict:
    """Every file and dir under path, relative to it, for a folder download."""
    root = abs_path(path)
    if not root.is_dir():
        raise FsError(404, "not a directory")
    files, dirs, total = [], [], 0
    for cur, dnames, fnames in os.walk(root):
        dnames.sort()
        base = Path(cur)
        for d in dnames:
            dirs.append(str((base / d).relative_to(root)))
        for f in sorted(fnames):
            fp = base / f
            try:
                size = fp.stat().st_size
            except OSError:
                continue
            files.append({"rel": str(fp.relative_to(root)), "size": size})
            total += size
            if len(files) > TREE_MAX_FILES:
                raise FsError(413, f"more than {TREE_MAX_FILES} files; download it as a zip")
    return {"root": str(root), "name": root.name, "files": files, "dirs": dirs, "total_size": total}


def unique(dest: Path) -> Path:
    """dest, or dest with a -1, -2 ... suffix if something already has that name."""
    if not dest.exists() and not dest.is_symlink():
        return dest
    stem, suffix = (dest.name, "") if dest.is_dir() else (dest.stem, dest.suffix)
    n = 1
    while True:
        cand = dest.with_name(f"{stem}-{n}{suffix}")
        if not cand.exists() and not cand.is_symlink():
            return cand
        n += 1


def upload_target(dir: str, filename: str, rel: Optional[str], overwrite: bool) -> Path:
    base = abs_path(dir)
    if base.exists() and not base.is_dir():
        raise FsError(400, "destination is not a directory")
    if rel:
        dest = base / safe_rel(rel)
    else:
        name = Path(filename or "").name or f"upload-{int(time.time())}"
        dest = base / name
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.is_dir():
        raise FsError(409, f"{dest} is a directory")
    return dest if overwrite else unique(dest)


def mkdir(path: str, make_unique: bool) -> Path:
    p = abs_path(path)
    if make_unique:
        p = unique(p)
    p.mkdir(parents=True, exist_ok=True)
    return p


def rename(src: str, dst: str) -> Path:
    s, d = abs_path(src), abs_path(dst)
    if not s.exists() and not s.is_symlink():
        raise FsError(404, "source not found")
    if d.exists():
        raise FsError(409, "destination already exists")
    d.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(s), str(d))
    return d


def trash(path: str) -> Path:
    p = abs_path(path)
    if p == Path("/") or p == Path.home() or len(p.parts) < 3:
        raise FsError(403, "refusing to delete a top-level directory")
    if not p.exists() and not p.is_symlink():
        raise FsError(404, "not found")
    TRASH_DIR.mkdir(parents=True, exist_ok=True)
    _purge_trash()
    dest = unique(TRASH_DIR / f"{time.strftime('%Y%m%d-%H%M%S')}--{p.name}")
    shutil.move(str(p), str(dest))
    return dest


def _purge_trash():
    cutoff = time.time() - TRASH_DAYS * 86400
    for e in TRASH_DIR.iterdir():
        try:
            if e.lstat().st_mtime < cutoff:
                shutil.rmtree(e) if e.is_dir() and not e.is_symlink() else e.unlink()
        except OSError:
            pass


class _Pipe:
    """Write-only, non-seekable sink for ZipFile; chunks are drained between writes."""
    def __init__(self):
        self.chunks: list[bytes] = []
        self.pos = 0

    def write(self, b):
        self.chunks.append(bytes(b))
        self.pos += len(b)
        return len(b)

    def tell(self):
        return self.pos

    def flush(self):
        pass

    def drain(self) -> bytes:
        out = b"".join(self.chunks)
        self.chunks.clear()
        return out


def zip_stream(path: str) -> Iterator[bytes]:
    """Streams the folder as a zip without staging it on the (tight) disk. Stored, not
    deflated: documents and media barely compress and the box is CPU-starved."""
    root = abs_path(path)
    if not root.is_dir():
        raise FsError(404, "not a directory")
    pipe = _Pipe()
    with zipfile.ZipFile(pipe, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as zf:
        for cur, dnames, fnames in os.walk(root):
            dnames.sort()
            base = Path(cur)
            arc_base = Path(root.name) / base.relative_to(root)
            if not fnames and not dnames:
                zf.writestr(str(arc_base) + "/", b"")
            for f in sorted(fnames):
                fp = base / f
                if not fp.is_file():
                    continue
                try:
                    with open(fp, "rb") as src, zf.open(zipfile.ZipInfo.from_file(fp, str(arc_base / f)), "w",
                                                       force_zip64=True) as dst:
                        while chunk := src.read(1 << 20):
                            dst.write(chunk)
                            if pipe.pos and len(pipe.chunks) > 4:
                                yield pipe.drain()
                except OSError:
                    continue
                yield pipe.drain()
    yield pipe.drain()
