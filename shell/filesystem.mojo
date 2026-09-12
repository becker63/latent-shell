from knowledge import Knowledge
from paths import normalize
from world import DirEntry, PathKind, WorldImage, FILE, DIRECTORY


@fieldwise_init
struct FileStatus(Copyable, Movable):
    var path: String
    var kind: PathKind
    var size: Int


struct Filesystem(Copyable, Movable):
    """Local filesystem operations over immutable truth and mutable knowledge."""

    var image: WorldImage
    var knowledge: Knowledge
    var cwd: String

    def __init__(out self, var image: WorldImage) raises:
        self.image = image^
        self.knowledge = Knowledge()
        self.cwd = "/"

    def resolve(self, path: String) raises -> String:
        return normalize(self.cwd, path)

    def lookup(mut self, path: String) raises -> DirEntry:
        var resolved = self.resolve(path)
        var entry = self.image.entry(resolved)
        self.knowledge.learn(entry.path, entry.kind)
        return entry^

    def readdir(mut self, path: String) raises -> List[DirEntry]:
        var directory = self.lookup(path)
        if directory.kind != DIRECTORY:
            raise Error("Not a directory")

        var entries = self.image.entries(directory.path)
        for entry in entries:
            self.knowledge.learn(entry.path, entry.kind)
        return entries^

    def read(mut self, path: String) raises -> String:
        var resolved = self.resolve(path)
        var contents = self.image.read(resolved)
        self.knowledge.mark_read(resolved)
        return contents^

    def stat(mut self, path: String) raises -> FileStatus:
        var entry = self.lookup(path)
        self.knowledge.mark_inspected(entry.path, entry.kind)
        return FileStatus(entry.path, entry.kind, entry.size)

    def chdir(mut self, path: String) raises:
        var directory = self.lookup(path)
        if directory.kind != DIRECTORY:
            raise Error("Not a directory")
        self.cwd = directory.path

    def forget(mut self, path: String) raises:
        var resolved = self.resolve(path)
        self.knowledge.forget(resolved)

    def evidence(self) -> String:
        return self.knowledge.describe()
