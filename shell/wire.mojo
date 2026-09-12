from json import Value, Null, dumps
from json.cpu import parse_cpu_native_tape
from json.config import ParserConfig, preprocess_json


def unique_keys(value: Value) raises:
    if value.is_object():
        var keys = value.object_keys()
        for i in range(len(keys)):
            for j in range(i):
                if keys[i] == keys[j]:
                    raise Error("duplicate JSON key")
            unique_keys(value[keys[i]])
    elif value.is_array():
        for i in range(value.array_count()):
            unique_keys(value[i])


def decode(text: String) raises -> Value:
    if text.byte_length() > 524288:
        raise Error("JSON exceeds size limit")
    var bounded = preprocess_json(text, ParserConfig(max_depth=32))
    var result = parse_cpu_native_tape[force_scalar=True](bounded^)
    unique_keys(result)
    return result^


def output(text: String, cwd: String, kind: String = "output") raises -> String:
    var effect = Value.object()
    effect.set("type", Value(kind))
    effect.set("text", Value(text))
    effect.set("prompt", Value("guest@latent:" + cwd + "$ "))
    return dumps(effect)


def optional(value: Value, key: String) -> Value:
    try:
        return value[key]
    except:
        return Value(Null())


def edit_output(line: String, prefix: String, candidates: List[String]) raises -> String:
    var effect = Value.object()
    effect.set("line", Value(line))
    effect.set("prefix", Value(prefix))
    var values = Value.array()
    for candidate in candidates:
        values.append(Value(candidate))
    effect.set("candidates", values^)
    return dumps(effect)
