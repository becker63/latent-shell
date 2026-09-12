from std.ffi import external_call
from filesystem import Filesystem
from paths import terminal_text


def encoded_arguments(program: String, arguments: List[String]) raises -> List[UInt8]:
    var encoded = List[UInt8]()
    for byte in program.as_bytes():
        encoded.append(byte)
    encoded.append(0)

    for argument in arguments:
        for byte in argument.as_bytes():
            if byte == 0:
                raise Error("argument contains NUL")
            encoded.append(byte)
        encoded.append(0)

    if len(arguments) + 1 > 64 or len(encoded) > 4096:
        raise Error("arguments exceed userspace limit")
    return encoded^


def userspace_output() raises -> String:
    var length = external_call["latent_output_len", UInt32]()
    if length > 65536:
        raise Error("userspace output exceeds limit")

    var address = external_call["latent_output_ptr", UInt64]()
    var source = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(address))
    var bytes = List[UInt8]()
    for index in range(Int(length)):
        bytes.append(source[unsafe_offset=index])
    return terminal_text(String(unsafe_from_utf8=bytes^))


def foreign_text(address: UInt64, length: UInt32) raises -> String:
    var source = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(address))
    var bytes = List[UInt8]()
    for index in range(Int(length)):
        bytes.append(source[unsafe_offset=index])
    return String(unsafe_from_utf8=bytes^)


def latent_fs_size(
    filesystem_address: UInt64,
    path_address: UInt64,
    path_length: UInt32,
) abi("C") -> Int64:
    var filesystem = Pointer[Filesystem, MutAnyOrigin](
        unsafe_from_address=Int(filesystem_address)
    )
    try:
        var path = foreign_text(path_address, path_length)
        var contents = filesystem[unsafe_offset=0].read(path)
        return Int64(contents.byte_length())
    except:
        return -1


def latent_fs_copy(
    filesystem_address: UInt64,
    path_address: UInt64,
    path_length: UInt32,
    destination_address: UInt64,
    capacity: UInt64,
) abi("C") -> Int64:
    var filesystem = Pointer[Filesystem, MutAnyOrigin](
        unsafe_from_address=Int(filesystem_address)
    )
    try:
        var path = foreign_text(path_address, path_length)
        var contents = filesystem[unsafe_offset=0].read(path)
        if UInt64(contents.byte_length()) > capacity:
            return -1

        var destination = Pointer[UInt8, MutAnyOrigin](
            unsafe_from_address=Int(destination_address)
        )
        var source = contents.as_bytes()
        for index in range(contents.byte_length()):
            destination[unsafe_offset=index] = source[index]
        return Int64(contents.byte_length())
    except:
        return -1


def select_filesystem(mut filesystem: Filesystem):
    var pointer = Pointer(to=filesystem).as_unsafe_any_origin()
    external_call["latent_set_filesystem", NoneType](UInt64(Int(pointer)))


def validate_basename(arguments: List[String]) raises:
    if len(arguments) == 0:
        raise Error("usage: basename [-a] [-s SUFFIX] NAME...")

    var all_names = False
    var names = 0
    var index = 0
    while index < len(arguments):
        var argument = arguments[index]
        if argument == "--":
            names += len(arguments) - index - 1
            break
        if argument == "-a":
            all_names = True
            index += 1
            continue
        if argument == "-s":
            if index + 1 >= len(arguments):
                raise Error("usage: basename [-a] [-s SUFFIX] NAME...")
            all_names = True
            index += 2
            continue
        if argument.startswith("-s") and argument.byte_length() > 2:
            all_names = True
            index += 1
            continue
        if argument.startswith("-"):
            raise Error("unsupported option")
        names += 1
        index += 1

    if names == 0 or (not all_names and names > 2):
        raise Error("usage: basename [-a] [-s SUFFIX] NAME...")


def validate_dirname(arguments: List[String]) raises:
    if len(arguments) == 0 or (len(arguments) == 1 and arguments[0] == "--"):
        raise Error("usage: dirname PATH...")

    var options_ended = False
    for argument in arguments:
        if argument == "--" and not options_ended:
            options_ended = True
        elif argument.startswith("-") and not options_ended:
            raise Error("unsupported option")


def toybox_basename(arguments: List[String]) raises -> String:
    validate_basename(arguments)
    var encoded = encoded_arguments("basename", arguments)
    var status = external_call["latent_invoke_basename", Int32](
        encoded.unsafe_ptr(), UInt32(len(encoded))
    )
    if status != 0:
        raise Error("Toybox basename failed")
    return userspace_output()


def toybox_dirname(arguments: List[String]) raises -> String:
    validate_dirname(arguments)
    var encoded = encoded_arguments("dirname", arguments)
    var status = external_call["latent_invoke_dirname", Int32](
        encoded.unsafe_ptr(), UInt32(len(encoded))
    )
    if status != 0:
        raise Error("Toybox dirname failed")
    return userspace_output()


def toybox_cat(
    mut filesystem: Filesystem, arguments: List[String]
) raises -> String:
    validate_file_options(arguments, False)
    select_filesystem(filesystem)
    var encoded = encoded_arguments("cat", arguments)
    var status = external_call["latent_invoke_cat", Int32](
        encoded.unsafe_ptr(), UInt32(len(encoded))
    )
    if status != 0:
        raise Error("Toybox cat failed")
    return userspace_output()


def toybox_head(
    mut filesystem: Filesystem, arguments: List[String]
) raises -> String:
    validate_file_options(arguments, True)
    select_filesystem(filesystem)
    var encoded = encoded_arguments("head", arguments)
    var status = external_call["latent_invoke_head", Int32](
        encoded.unsafe_ptr(), UInt32(len(encoded))
    )
    if status != 0:
        raise Error("Toybox head failed")
    return userspace_output()


def validate_file_options(arguments: List[String], head: Bool) raises:
    """Bound the options accepted by applets whose fatal exit needs a process.

    Toybox still parses and executes these options. Until a guest unwind exists,
    reject unsupported spellings before its error_exit can trap the machine.
    """
    var index = 0
    while index < len(arguments):
        var argument = arguments[index]
        if argument == "--":
            return
        if argument == "-n" or argument == "-c":
            if not head or index + 1 >= len(arguments):
                raise Error("expected a count after option")
            var count = arguments[index + 1]
            if count.byte_length() == 0 or count.byte_length() > 9:
                raise Error("count must be between 0 and 999999999")
            for digit in count.as_bytes():
                if digit < 48 or digit > 57:
                    raise Error("expected a nonnegative count")
            index += 2
            continue
        if argument.startswith("-") and argument != "-":
            var allowed = "-qv" if head else "-etuv"
            for flag in argument.as_bytes():
                var accepted = False
                for candidate in allowed.as_bytes():
                    if flag == candidate:
                        accepted = True
                if not accepted:
                    raise Error("unsupported option spelling")
        index += 1
