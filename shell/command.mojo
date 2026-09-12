@fieldwise_init
struct Command(Copyable, Movable):
    var name: String
    var argv: List[String]


def parse(line: String) raises -> Command:
    var words = List[String]()
    var word = List[UInt8]()
    var quote = 0
    var escaped = False
    var started = False
    for byte in line.as_bytes():
        var c = Int(byte)
        if escaped:
            word.append(byte)
            escaped = False
            started = True
        elif c == 92 and quote != 39:
            escaped = True
            started = True
        elif quote != 0:
            if c == quote:
                quote = 0
            else:
                word.append(byte)
        elif c == 34 or c == 39:
            quote = c
            started = True
        elif c == 32 or c == 9:
            if started:
                words.append(String(unsafe_from_utf8=word^))
                word = List[UInt8]()
                started = False
        elif c == 124 or c == 60 or c == 62 or c == 59 or c == 38:
            raise Error("pipelines, redirection, and command chaining are not supported")
        else:
            word.append(byte)
            started = True
    if quote != 0 or escaped:
        raise Error("unfinished quote or escape")
    if started:
        words.append(String(unsafe_from_utf8=word^))
    if len(words) == 0:
        return Command("", List[String]())
    var args = List[String]()
    for i in range(1, len(words)):
        args.append(words[i])
    return Command(words[0], args^)
