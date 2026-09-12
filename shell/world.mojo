from json import Value
from paths import normalize, parent, valid_name
from wire import optional


struct PathKind(Copyable, Movable, ImplicitlyCopyable):
    """Closed path-kind value for Mojo 1.0, which has no native enum syntax."""

    var _value: Int

    def __init__(out self, value: Int):
        # Mojo 1.0 has no enum syntax and raising constructors cannot initialize
        # comptime constants. Only the three constants below cross this boundary.
        self._value = value

    def __eq__(self, other: PathKind) -> Bool:
        return self._value == other._value

    def __ne__(self, other: PathKind) -> Bool:
        return self._value != other._value


comptime UNKNOWN = PathKind(0)
comptime FILE = PathKind(1)
comptime DIRECTORY = PathKind(2)


@fieldwise_init
struct File(Copyable, Movable):
    var path: String
    var contents: String


@fieldwise_init
struct Directory(Copyable, Movable):
    var path: String


@fieldwise_init
struct DirEntry(Copyable, Movable):
    """A structural directory view. File contents live only in File."""

    var path: String
    var kind: PathKind
    var size: Int


struct WorldImage(Copyable, Movable):
    """Immutable generated reality, decoded once from validated JSON."""

    var files: List[File]
    var directories: List[Directory]

    def __init__(out self, encoded: Value) raises:
        var entries = encoded["entries"]
        if not entries.is_array():
            raise Error("world entries must be an array")
        if entries.array_count() == 0 or entries.array_count() > 96:
            raise Error("invalid world entry count")

        self.files = List[File]()
        self.directories = List[Directory]()
        var content_bytes = 0

        for index in range(entries.array_count()):
            var item = entries[index]
            var path = item["path"].string_value()
            self.validate_path(path)
            if self.kind(path) != UNKNOWN:
                raise Error("duplicate world path")

            var kind = item["kind"].string_value()
            if kind == "file":
                var contents = item["contents"].string_value()
                if contents.byte_length() > 4096:
                    raise Error("world file exceeds limit")
                content_bytes += contents.byte_length()
                self.files.append(File(path, contents^))
            elif kind == "directory":
                if not optional(item, "contents").is_null():
                    raise Error("directory cannot have contents")
                self.directories.append(Directory(path))
            else:
                raise Error("invalid world kind")

        if content_bytes > 49152:
            raise Error("world contents exceed limit")
        self.validate_tree()

    def validate_path(self, path: String) raises:
        if path.byte_length() > 512 or normalize("/", path) != path:
            raise Error("invalid world path")
        if path == "/":
            return
        var pieces = path.split("/")
        if len(pieces) > 9:
            raise Error("world path is too deep")
        if not valid_name(String(pieces[len(pieces) - 1])):
            raise Error("invalid world name")

    def validate_tree(self) raises:
        if self.kind("/") != DIRECTORY:
            raise Error("world root is missing")

        for directory in self.directories:
            if directory.path != "/" and self.kind(parent(directory.path)) != DIRECTORY:
                raise Error("world directory parent is missing")
        for file in self.files:
            if self.kind(parent(file.path)) != DIRECTORY:
                raise Error("world file parent is missing")

        for directory_index in range(len(self.directories)):
            var directory = self.directories[directory_index].copy()
            var child_count = 0
            for child in self.entries(directory.path):
                _ = child
                child_count += 1
            if child_count > 32:
                raise Error("world directory fanout exceeds limit")

    def kind(self, path: String) -> PathKind:
        for directory in self.directories:
            if directory.path == path:
                return DIRECTORY
        for file in self.files:
            if file.path == path:
                return FILE
        return UNKNOWN

    def entry(self, path: String) raises -> DirEntry:
        for directory in self.directories:
            if directory.path == path:
                return DirEntry(path, DIRECTORY, 0)
        for file in self.files:
            if file.path == path:
                return DirEntry(path, FILE, file.contents.byte_length())
        raise Error("No such file or directory")

    def entries(self, directory: String) -> List[DirEntry]:
        var result = List[DirEntry]()
        for child in self.directories:
            if child.path != directory and parent(child.path) == directory:
                result.append(DirEntry(child.path, DIRECTORY, 0))
        for child in self.files:
            if parent(child.path) == directory:
                result.append(DirEntry(child.path, FILE, child.contents.byte_length()))
        return result^

    def read(self, path: String) raises -> String:
        for file in self.files:
            if file.path == path:
                return file.contents
        if self.kind(path) == DIRECTORY:
            raise Error("Is a directory")
        raise Error("No such file or directory")
