from command import Command
from filesystem import Filesystem
from paths import basename
from userspace import toybox_basename, toybox_cat, toybox_dirname, toybox_head
from world import DirEntry, FILE, DIRECTORY


@fieldwise_init
struct Capabilities(Copyable, Movable, ImplicitlyCopyable):
    """Filesystem authority projected by describe, never hand-authored prose."""

    var getcwd: Bool
    var chdir: Bool
    var readdir: Bool
    var read: Bool
    var stat: Bool
    var knowledge: Bool


comptime NO_FILESYSTEM = Capabilities(False, False, False, False, False, False)
comptime GETCWD = Capabilities(True, False, False, False, False, False)
comptime CHDIR = Capabilities(False, True, False, False, False, False)
comptime READ = Capabilities(False, False, False, True, False, False)
comptime READ_DIRECTORY = Capabilities(False, False, True, False, True, False)
comptime INSPECT = Capabilities(False, False, False, False, True, False)
comptime KNOWLEDGE = Capabilities(False, False, False, False, False, True)


@fieldwise_init
struct Implementation(Copyable, Movable, ImplicitlyCopyable):
    var is_builtin: Bool
    var is_upstream: Bool

    def describe(self) -> String:
        if self.is_builtin:
            return "Latent Shell builtin"
        if self.is_upstream:
            return "Toybox 0.8.13"
        return "temporary Mojo utility"


comptime BUILTIN = Implementation(True, False)
comptime TOYBOX = Implementation(False, True)
comptime TEMPORARY_UTILITY = Implementation(False, False)


@fieldwise_init
struct CommandSpec(Copyable, Movable):
    var name: String
    var usage: String
    var summary: String
    var capabilities: Capabilities
    var implementation: Implementation


def command_catalog() -> List[CommandSpec]:
    """The sole authority for command names and self-description."""

    return [
        CommandSpec(
            "basename",
            "basename PATH...",
            "print final path components",
            NO_FILESYSTEM,
            TOYBOX,
        ),
        CommandSpec("cat", "cat [-etuv] [PATH...]", "print files", READ, TOYBOX),
        CommandSpec("cd", "cd PATH", "change current directory", CHDIR, BUILTIN),
        CommandSpec("clear", "clear", "clear the terminal", NO_FILESYSTEM, BUILTIN),
        CommandSpec(
            "commands",
            "commands",
            "list commands",
            NO_FILESYSTEM,
            BUILTIN,
        ),
        CommandSpec(
            "describe",
            "describe COMMAND",
            "describe command authority",
            NO_FILESYSTEM,
            BUILTIN,
        ),
        CommandSpec(
            "dirname",
            "dirname PATH...",
            "print parent paths",
            NO_FILESYSTEM,
            TOYBOX,
        ),
        CommandSpec(
            "evidence",
            "evidence",
            "show observed knowledge",
            KNOWLEDGE,
            BUILTIN,
        ),
        CommandSpec(
            "head",
            "head [-cn COUNT] [-qv] [PATH...]",
            "print first lines",
            READ,
            TOYBOX,
        ),
        CommandSpec("help", "help", "show command help", NO_FILESYSTEM, BUILTIN),
        CommandSpec(
            "history",
            "history",
            "show shell history",
            NO_FILESYSTEM,
            BUILTIN,
        ),
        CommandSpec(
            "ls",
            "ls [-alhS] [PATH]",
            "list a directory",
            READ_DIRECTORY,
            TEMPORARY_UTILITY,
        ),
        CommandSpec("pwd", "pwd [-LP]", "print current directory", GETCWD, BUILTIN),
        CommandSpec("rm", "rm PATH", "forget knowledge", KNOWLEDGE, BUILTIN),
        CommandSpec("stat", "stat PATH", "inspect a path", INSPECT, TEMPORARY_UTILITY),
        CommandSpec("wc", "wc [-lwc] PATH", "count file data", READ, TEMPORARY_UTILITY),
    ]


def identify(name: String) raises -> CommandSpec:
    for spec in command_catalog():
        if spec.name == name:
            return spec.copy()
    raise Error("command not found")


def capabilities_text(capabilities: Capabilities) -> String:
    var text = String()
    if capabilities.getcwd:
        text += "getcwd"
    if capabilities.chdir:
        text += "chdir"
    if capabilities.readdir:
        text += "readdir"
    if capabilities.read:
        if text != "":
            text += ", "
        text += "read"
    if capabilities.stat:
        if text != "":
            text += ", "
        text += "stat"
    if capabilities.knowledge:
        if text != "":
            text += ", "
        text += "knowledge"
    if text == "":
        return "none"
    return text^


def commands_text() -> String:
    var text = String()
    for spec in command_catalog():
        if text != "":
            text += " "
        text += spec.name
    return text + "\n"


def help_text() -> String:
    var text = String()
    for spec in command_catalog():
        text += spec.usage + "\n    " + spec.summary + "\n"
    return text^


def describe_command(name: String) raises -> String:
    var spec = identify(name)
    return (
        "implementation: "
        + spec.implementation.describe()
        + "\nexecution: local WebAssembly\nfilesystem: "
        + capabilities_text(spec.capabilities)
        + "\nmodel inference after initialization: no\n"
    )


def sort_entries(mut entries: List[DirEntry], by_size: Bool):
    for left in range(len(entries)):
        for right in range(left + 1, len(entries)):
            var should_swap = basename(entries[right].path) < basename(entries[left].path)
            if by_size:
                should_swap = entries[right].size > entries[left].size
            if should_swap:
                var saved = entries[left].copy()
                entries[left] = entries[right].copy()
                entries[right] = saved^


def run_ls(mut filesystem: Filesystem, arguments: List[String]) raises -> String:
    var show_all = False
    var long_format = False
    var sort_by_size = False
    var path = String()

    for argument in arguments:
        if argument.startswith("-") and argument != "-":
            for flag in argument.as_bytes():
                if flag == 45:
                    continue
                if flag == 97:
                    show_all = True
                elif flag == 108 or flag == 104:
                    long_format = True
                elif flag == 83:
                    sort_by_size = True
                else:
                    raise Error("unsupported option")
        elif path != "":
            raise Error("too many paths")
        else:
            path = argument

    if path == "":
        path = "."
    var entries = filesystem.readdir(path)
    sort_entries(entries, sort_by_size)

    var text = String()
    if show_all:
        text += ".\n..\n"
    for entry in entries:
        var name = basename(entry.path)
        if not show_all and name.startswith("."):
            continue
        if entry.kind == DIRECTORY:
            name += "/"
        if long_format:
            var mode = "drwxr-xr-x" if entry.kind == DIRECTORY else "-rw-r--r--"
            text += mode + " 1 guest guest " + String(entry.size) + " " + name + "\n"
        else:
            text += name + "\n"
    return text^


def run_wc(mut filesystem: Filesystem, arguments: List[String]) raises -> String:
    var path = String()
    var show_lines = False
    var show_words = False
    var show_bytes = False

    for argument in arguments:
        if argument.startswith("-"):
            for flag in argument.as_bytes():
                if flag == 108:
                    show_lines = True
                elif flag == 119:
                    show_words = True
                elif flag == 99:
                    show_bytes = True
                elif flag != 45:
                    raise Error("unsupported option")
        elif path != "":
            raise Error("too many paths")
        else:
            path = argument
    if path == "":
        raise Error("usage: wc [-lwc] PATH")
    if not show_lines and not show_words and not show_bytes:
        show_lines = True
        show_words = True
        show_bytes = True

    var contents = filesystem.read(path)
    var lines = 0
    var words = 0
    var inside_word = False
    for byte in contents.as_bytes():
        if byte == 10:
            lines += 1
        var is_space = byte == 9 or byte == 10 or byte == 13 or byte == 32
        if is_space:
            inside_word = False
        elif not inside_word:
            words += 1
            inside_word = True

    var text = String()
    if show_lines:
        text += " " + String(lines)
    if show_words:
        text += " " + String(words)
    if show_bytes:
        text += " " + String(contents.byte_length())
    return text + " " + path + "\n"


def run_stat(mut filesystem: Filesystem, arguments: List[String]) raises -> String:
    if len(arguments) != 1:
        raise Error("usage: stat PATH")
    var status = filesystem.stat(arguments[0])
    var kind = "directory" if status.kind == DIRECTORY else "regular file"
    return (
        "  File: "
        + status.path
        + "\n  Size: "
        + String(status.size)
        + "\n  Type: "
        + kind
        + "\n"
    )


def run_command(
    spec: CommandSpec,
    command: Command,
    mut filesystem: Filesystem,
) raises -> String:
    if spec.name == "ls":
        return run_ls(filesystem, command.argv)
    if spec.name == "cat":
        return toybox_cat(filesystem, command.argv)
    if spec.name == "head":
        return toybox_head(filesystem, command.argv)
    if spec.name == "wc":
        return run_wc(filesystem, command.argv)
    if spec.name == "stat":
        return run_stat(filesystem, command.argv)
    if spec.name == "cd":
        if len(command.argv) != 1:
            raise Error("usage: cd PATH")
        filesystem.chdir(command.argv[0])
        return ""
    if spec.name == "rm":
        if len(command.argv) != 1:
            raise Error("usage: rm PATH")
        filesystem.forget(command.argv[0])
        return ""
    if spec.name == "pwd":
        if len(command.argv) > 1:
            raise Error("usage: pwd [-LP]")
        if len(command.argv) == 1 and command.argv[0] != "-L" and command.argv[0] != "-P":
            raise Error("usage: pwd [-LP]")
        return filesystem.cwd + "\n"
    if spec.name == "evidence":
        if len(command.argv) != 0:
            raise Error("usage: evidence")
        return filesystem.evidence()
    if spec.name == "basename":
        return toybox_basename(command.argv)
    if spec.name == "dirname":
        return toybox_dirname(command.argv)
    raise Error("command is handled by the shell")
