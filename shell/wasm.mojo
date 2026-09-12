from std.memory import Pointer, alloc, Layout
from shell import Shell
from wire import decode, output, edit_output
from completion import complete
from userspace import latent_fs_size as fs_size, latent_fs_copy as fs_copy


@export("latent_fs_size")
def userspace_size(handle: UInt64, path: UInt64, length: UInt32) abi("C") -> Int64:
    return fs_size(handle, path, length)


@export("latent_fs_copy")
def userspace_copy(handle: UInt64, path: UInt64, length: UInt32, target: UInt64, capacity: UInt64) abi("C") -> Int64:
    return fs_copy(handle, path, length, target, capacity)


@fieldwise_init
struct Bridge(Movable):
    var shell: Shell
    var effect: String


def input_text(address: UInt32, length: UInt32) raises -> String:
    if length > 524288:
        raise Error("input too large")
    var source = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(address))
    var bytes = List[UInt8]()
    for i in range(Int(length)):
        bytes.append(source[unsafe_offset=i])
    return String(unsafe_from_utf8=bytes^)


@export("shell_init")
def shell_init(address: UInt32, length: UInt32) abi("C") -> UInt64:
    try:
        var config = decode(input_text(address, length))
        var shell = Shell(config["image"])
        var initial_effect = output("", "/")
        var allocation = alloc(Layout[Bridge](count=1))
        var bridge = allocation^.unsafe_leak()
        bridge.init_pointee_move(Bridge(shell^, initial_effect^))
        return UInt64(Int(bridge))
    except:
        return 0


@export("shell_eval")
def shell_eval(handle: UInt64, address: UInt32, length: UInt32) abi("C"):
    var bridge = Pointer[Bridge, MutAnyOrigin](unsafe_from_address=Int(handle))
    try:
        bridge[unsafe_offset=0].effect = bridge[unsafe_offset=0].shell.eval(input_text(address, length))
    except:
        bridge[unsafe_offset=0].effect = '{"type":"error","text":"shell: internal error","prompt":"$ "}'


@export("shell_result_len")
def shell_result_len(handle: UInt64) abi("C") -> UInt32:
    var bridge = Pointer[Bridge, MutAnyOrigin](unsafe_from_address=Int(handle))
    return UInt32(bridge[unsafe_offset=0].effect.byte_length())


@export("shell_complete")
def shell_complete(handle: UInt64, address: UInt32, length: UInt32, cursor: UInt32) abi("C"):
    var bridge = Pointer[Bridge, MutAnyOrigin](unsafe_from_address=Int(handle))
    try:
        var line = input_text(address, length)
        var result = complete(bridge[unsafe_offset=0].shell.filesystem, line, Int(cursor))
        bridge[unsafe_offset=0].effect = edit_output(result.line, result.prefix, result.candidates)
    except:
        bridge[unsafe_offset=0].effect = "null"


@export("shell_history")
def shell_history(handle: UInt64, offset: UInt32) abi("C"):
    var bridge = Pointer[Bridge, MutAnyOrigin](unsafe_from_address=Int(handle))
    try:
        var count = len(bridge[unsafe_offset=0].shell.history)
        var line = String()
        if offset > 0 and Int(offset) <= count:
            line = bridge[unsafe_offset=0].shell.history[count - Int(offset)]
        bridge[unsafe_offset=0].effect = edit_output(line, line, List[String]())
    except:
        bridge[unsafe_offset=0].effect = "null"


@export("shell_result_ptr")
def shell_result_ptr(handle: UInt64) abi("C") -> UInt64:
    """Borrow effect bytes until the next operation mutates this bridge."""
    var bridge = Pointer[Bridge, MutAnyOrigin](unsafe_from_address=Int(handle))
    return UInt64(Int(bridge[unsafe_offset=0].effect.unsafe_ptr()))
