from json import Value
from command import parse
from commands import (
    commands_text,
    describe_command,
    help_text,
    identify,
    run_command,
)
from filesystem import Filesystem
from paths import terminal_text
from wire import output
from world import WorldImage


struct Shell(Copyable, Movable):
    """Session state: filesystem, current directory, parsing, and history."""

    var filesystem: Filesystem
    var history: List[String]

    def __init__(out self, image: Value) raises:
        var world_image = WorldImage(image)
        self.filesystem = Filesystem(world_image^)
        self.history = List[String]()

    def remember(mut self, line: String):
        if line.strip().byte_length() == 0:
            return
        if len(self.history) == 128:
            var retained = List[String]()
            for index in range(1, len(self.history)):
                retained.append(self.history[index])
            self.history = retained^
        self.history.append(line)

    def history_text(self) -> String:
        var text = String()
        for index in range(len(self.history)):
            text += String(index + 1) + "  " + terminal_text(self.history[index]) + "\n"
        return text^

    def eval(mut self, line: String) raises -> String:
        var command_name = String("shell")
        try:
            if line.byte_length() > 4096:
                raise Error("command too long")
            self.remember(line)

            var command = parse(line)
            command_name = command.name
            if command_name == "":
                return output("", self.filesystem.cwd)

            var spec = identify(command_name)
            if spec.name == "clear":
                if len(command.argv) != 0:
                    raise Error("usage: clear")
                return output("", self.filesystem.cwd, "clear")
            if spec.name == "commands":
                if len(command.argv) != 0:
                    raise Error("usage: commands")
                return output(commands_text(), self.filesystem.cwd)
            if spec.name == "help":
                if len(command.argv) != 0:
                    raise Error("usage: help")
                return output(help_text(), self.filesystem.cwd)
            if spec.name == "describe":
                if len(command.argv) != 1:
                    raise Error("usage: describe COMMAND")
                return output(describe_command(command.argv[0]), self.filesystem.cwd)
            if spec.name == "history":
                if len(command.argv) != 0:
                    raise Error("usage: history")
                return output(self.history_text(), self.filesystem.cwd)

            var text = run_command(spec, command, self.filesystem)
            return output(text, self.filesystem.cwd)
        except error:
            var message = command_name + ": " + String(error) + "\n"
            return output(terminal_text(message), self.filesystem.cwd, "error")
