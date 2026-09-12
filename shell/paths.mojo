def beneath(path: String, root: String) -> Bool:
    return path == root or root == "/" or path.startswith(root + "/")


def parent(path: String) -> String:
    if path == "/":
        return "/"
    var pieces = path.split("/")
    var result = String()
    for i in range(1, len(pieces) - 1):
        result += "/" + String(pieces[i])
    return result if result != "" else "/"


def basename(path: String) -> String:
    var pieces = path.split("/")
    return String(pieces[len(pieces) - 1])


def control_free(text: String) -> Bool:
    var bytes = text.as_bytes()
    for i in range(len(bytes)):
        var c = Int(bytes[i])
        if c < 32 or c == 127:
            return False
        if c == 194 and i + 1 < len(bytes) and 128 <= Int(bytes[i + 1]) < 160:
            return False
    return True


def valid_name(name: String) -> Bool:
    return name != "" and name != "." and name != ".." and "/" not in name and control_free(name)


def normalize(cwd: String, argument: String) raises -> String:
    if argument == "" or not control_free(argument):
        raise Error("invalid path")
    var full = argument if argument.startswith("/") else cwd + "/" + argument
    var parts = List[String]()
    for piece in full.split("/"):
        var part = String(piece)
        if part == "" or part == ".":
            continue
        if part == "..":
            if len(parts) > 0:
                _ = parts.pop()
        else:
            parts.append(part^)
    var result = String()
    for part in parts:
        result += "/" + part
    if result == "":
        result = "/"
    if result.byte_length() > 2048:
        raise Error("path too long")
    return result^


def terminal_text(text: String) -> String:
    var bytes = text.as_bytes()
    var clean = List[UInt8]()
    var i = 0
    while i < len(bytes):
        var c = Int(bytes[i])
        if c == 194 and i + 1 < len(bytes) and 128 <= Int(bytes[i + 1]) < 160:
            i += 2
            continue
        if c == 9 or c == 10 or (c >= 32 and c != 127):
            clean.append(bytes[i])
        i += 1
    return String(unsafe_from_utf8=clean^)
