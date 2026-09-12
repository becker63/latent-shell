from commands import command_catalog, identify
from filesystem import Filesystem
from paths import basename
from world import DIRECTORY


@fieldwise_init
struct Completion(Copyable, Movable):
    var line: String
    var prefix: String
    var candidates: List[String]


def span(text: String, start: Int, end: Int) -> String:
    var bytes = List[UInt8]()
    var source = text.as_bytes()
    for index in range(start, end):
        bytes.append(source[index])
    return String(unsafe_from_utf8=bytes^)


def escaped_token(text: String) -> String:
    var bytes = List[UInt8]()
    for byte in text.as_bytes():
        if byte == 32 or byte == 9 or byte == 39 or byte == 34 or byte == 92 or byte == 124 or byte == 59 or byte == 38 or byte == 60 or byte == 62:
            bytes.append(92)
        bytes.append(byte)
    return String(unsafe_from_utf8=bytes^)


def common_prefix(left: String, right: String) -> String:
    var a = left.as_bytes()
    var b = right.as_bytes()
    var length = 0
    while length < len(a) and length < len(b) and a[length] == b[length]:
        length += 1
    while length > 0 and length < len(a) and (a[length] & 192) == 128:
        length -= 1
    return span(left, 0, length)


def complete(mut filesystem: Filesystem, line: String, cursor: Int) raises -> Completion:
    """Find the token at a UTF-8 cursor; enumerate through the filesystem."""
    if cursor < 0 or cursor > line.byte_length() or line.byte_length() > 4096:
        raise Error("invalid completion cursor")
    var bytes = line.as_bytes()
    if cursor < len(bytes) and (bytes[cursor] & 192) == 128:
        raise Error("cursor splits UTF-8")
    var start = 0
    var quote = 0
    var escape = False
    var token = List[UInt8]()
    var command = String()
    var first_word = True
    for index in range(cursor):
        var byte = bytes[index]
        if escape:
            token.append(byte)
            escape = False
        elif byte == 92 and quote != 39:
            escape = True
        elif quote != 0:
            if Int(byte) == quote:
                quote = 0
            else:
                token.append(byte)
        elif byte == 34 or byte == 39:
            quote = Int(byte)
        elif byte == 32 or byte == 9:
            if first_word and len(token) > 0:
                command = String(unsafe_from_utf8=token.copy())
                first_word = False
            token = List[UInt8]()
            start = index + 1
        elif byte == 124 or byte == 59 or byte == 38 or byte == 60 or byte == 62:
            return Completion(line, span(line, 0, cursor), List[String]())
        else:
            token.append(byte)

    var end = cursor
    while end < len(bytes):
        var byte = bytes[end]
        if escape:
            escape = False
        elif byte == 92 and quote != 39:
            escape = True
        elif quote != 0:
            if Int(byte) == quote:
                quote = 0
        elif byte == 34 or byte == 39:
            quote = Int(byte)
        elif byte == 32 or byte == 9:
            break
        end += 1

    var word = String(unsafe_from_utf8=token^)
    var candidates = List[String]()
    if first_word:
        for spec in command_catalog():
            if spec.name.startswith(word):
                candidates.append(spec.name)
    else:
        var directory_only = False
        try:
            directory_only = identify(command).capabilities.chdir
        except:
            pass
        var slash = -1
        for index in range(word.byte_length()):
            if word.as_bytes()[index] == 47:
                slash = index
        var directory = "." if slash < 0 else span(word, 0, slash + 1)
        var base = "" if slash < 0 else directory
        var fragment = span(word, slash + 1, word.byte_length())
        for entry in filesystem.readdir(directory):
            var name = basename(entry.path)
            if not name.startswith(fragment):
                continue
            if directory_only and entry.kind != DIRECTORY:
                continue
            if name.startswith(".") and not fragment.startswith("."):
                continue
            var suffix = "/" if entry.kind == DIRECTORY else ""
            candidates.append(base + name + suffix)

    for left in range(len(candidates)):
        for right in range(left + 1, len(candidates)):
            if candidates[right] < candidates[left]:
                var saved = candidates[left]
                candidates[left] = candidates[right]
                candidates[right] = saved
    if len(candidates) == 0:
        return Completion(line, span(line, 0, cursor), candidates^)
    var replacement = candidates[0]
    for index in range(1, len(candidates)):
        replacement = common_prefix(replacement, candidates[index])
    if replacement.byte_length() < word.byte_length():
        replacement = word
    replacement = escaped_token(replacement)
    if len(candidates) == 1 and not candidates[0].endswith("/"):
        replacement += " "
    var prefix = span(line, 0, start) + replacement
    var updated = prefix + span(line, end, line.byte_length())
    return Completion(updated^, prefix^, candidates^)
