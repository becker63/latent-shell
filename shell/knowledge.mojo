from paths import beneath, parent
from world import PathKind, UNKNOWN, FILE, DIRECTORY


@fieldwise_init
struct KnownPath(Copyable, Movable):
    var path: String
    var kind: PathKind
    var was_read: Bool
    var was_inspected: Bool


struct Knowledge(Copyable, Movable):
    """Mutable knowledge about an immutable WorldImage."""

    var paths: List[KnownPath]

    def __init__(out self) raises:
        self.paths = List[KnownPath]()
        self.learn("/", DIRECTORY)

    def known(self, path: String) -> PathKind:
        for known_path in self.paths:
            if known_path.path == path:
                return known_path.kind
        return UNKNOWN

    def learn(mut self, path: String, kind: PathKind) raises:
        var current = path
        var current_kind = kind
        while True:
            var known_kind = self.known(current)
            if known_kind != UNKNOWN and known_kind != current_kind:
                raise Error("knowledge contradicts world structure")
            if known_kind == UNKNOWN:
                self.paths.append(KnownPath(current, current_kind, False, False))
            if current == "/":
                return
            current = parent(current)
            current_kind = DIRECTORY

    def mark_read(mut self, path: String) raises:
        self.learn(path, FILE)
        for index in range(len(self.paths)):
            if self.paths[index].path == path:
                self.paths[index].was_read = True
                return

    def mark_inspected(mut self, path: String, kind: PathKind) raises:
        self.learn(path, kind)
        for index in range(len(self.paths)):
            if self.paths[index].path == path:
                self.paths[index].was_inspected = True
                return

    def forget(mut self, path: String):
        var retained = List[KnownPath]()
        for known_path in self.paths:
            if not beneath(known_path.path, path):
                retained.append(known_path.copy())
        self.paths = retained^

    def describe(self) -> String:
        var text = String()
        for known_path in self.paths:
            var kind = "directory" if known_path.kind == DIRECTORY else "file"
            text += known_path.path + "  " + kind
            if known_path.was_read:
                text += "  read"
            if known_path.was_inspected:
                text += "  inspected"
            text += "\n"
        return text^
