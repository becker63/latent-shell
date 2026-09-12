from std.testing import assert_equal, assert_true
from shell import Shell
from command import parse
from paths import normalize
from world import FILE, DIRECTORY, UNKNOWN
from wire import decode
from manifest_fixture import IMAGE
from userspace import latent_fs_size as fs_size, latent_fs_copy as fs_copy
from completion import complete


@export("latent_fs_size")
def userspace_size(handle: UInt64, path: UInt64, length: UInt32) abi("C") -> Int64:
    return fs_size(handle, path, length)


@export("latent_fs_copy")
def userspace_copy(handle: UInt64, path: UInt64, length: UInt32, target: UInt64, capacity: UInt64) abi("C") -> Int64:
    return fs_copy(handle, path, length, target, capacity)


def main() raises:
    assert_equal(normalize("/a/b", "../c//./d/"), "/a/c/d")
    var command = parse("cat 'a file.txt'")
    assert_equal(command.argv[0], "a file.txt")
    var shell = Shell(decode(IMAGE))
    var effect = decode(shell.eval("basename -s .log /var/archive.log"))
    assert_equal(effect["text"].string_value(), "archive\n")
    effect = decode(shell.eval("basename -a /var/log /home/guest"))
    assert_equal(effect["text"].string_value(), "log\nguest\n")
    effect = decode(shell.eval("dirname /var/log /home/guest"))
    assert_equal(effect["text"].string_value(), "/var\n/home\n")
    effect = decode(shell.eval("describe basename"))
    assert_true("implementation: Toybox 0.8.13" in effect["text"].string_value())

    effect = decode(shell.eval("pwd"))
    assert_equal(effect["text"].string_value(), "/\n")
    var completed = complete(shell.filesystem, "pw", 2)
    assert_equal(completed.line, "pwd ")
    completed = complete(shell.filesystem, "cd pro", 6)
    assert_equal(completed.line, "cd projects/")
    completed = complete(shell.filesystem, "cat /pro", 8)
    assert_equal(completed.line, "cat /projects/")
    completed = complete(shell.filesystem, "cat /projects/noXXX", 16)
    assert_equal(completed.line, "cat /projects/notes.txt ")
    effect = decode(shell.eval("ls"))
    assert_true("README" in effect["text"].string_value())
    assert_true(shell.filesystem.knowledge.known("/README") == FILE)
    assert_true(shell.filesystem.knowledge.known("/projects") == DIRECTORY)
    effect = decode(shell.eval("cd projects"))
    assert_equal(effect["prompt"].string_value(), "guest@latent:/projects$ ")
    effect = decode(shell.eval("cat notes.txt"))
    assert_true("three" in effect["text"].string_value())
    effect = decode(shell.eval("head -n 2 notes.txt"))
    assert_equal(effect["text"].string_value(), "one\ntwo\n")
    effect = decode(shell.eval("cat -e notes.txt"))
    assert_equal(effect["text"].string_value(), "one$\ntwo$\nthree$\n")
    effect = decode(shell.eval("head -c 3 notes.txt"))
    assert_equal(effect["text"].string_value(), "one")
    effect = decode(shell.eval("head -n nope notes.txt"))
    assert_equal(effect["type"].string_value(), "error")
    effect = decode(shell.eval("cat -Z notes.txt"))
    assert_equal(effect["type"].string_value(), "error")
    effect = decode(shell.eval("wc -l notes.txt"))
    assert_true(" 3 notes.txt" in effect["text"].string_value())
    effect = decode(shell.eval("stat notes.txt"))
    assert_true("regular file" in effect["text"].string_value())
    _ = shell.eval("cd /moon")
    _ = shell.eval("ls")
    assert_true(shell.filesystem.knowledge.known("/moon/door") == DIRECTORY)
    _ = shell.eval("rm door")
    assert_true(shell.filesystem.knowledge.known("/moon/door") == UNKNOWN)
    completed = complete(shell.filesystem, "cd do", 5)
    assert_equal(completed.line, "cd door/")
    assert_true(shell.filesystem.knowledge.known("/moon/door") == DIRECTORY)
    _ = shell.eval("rm door")
    _ = shell.eval("ls")
    assert_true(shell.filesystem.knowledge.known("/moon/door") == DIRECTORY)
    effect = decode(shell.eval("evidence"))
    assert_true("/moon/door" in effect["text"].string_value())
    effect = decode(shell.eval("describe ls"))
    assert_true("model inference after initialization: no" in effect["text"].string_value())
    print("Mojo WorldImage shell checks passed")
