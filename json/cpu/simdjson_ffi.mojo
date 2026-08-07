# simdjson FFI wrapper for Mojo
# Provides high-performance JSON parsing via simdjson C++ library
# Uses OwnedDLHandle for runtime library loading

from std.ffi import OwnedDLHandle, external_call
from std.os import getenv
from std.memory import UnsafePointer
from std.collections import List
from ..errors import json_parse_error, find_error_position


def _find_simdjson_library() -> String:
    """Find the simdjson wrapper library in standard locations."""
    # Check CONDA_PREFIX first (installed via conda/pixi)
    var conda_prefix = getenv("CONDA_PREFIX", "")
    if conda_prefix:
        return conda_prefix + "/lib/libsimdjson_wrapper.so"
    # Fallback to local build directory (development)
    return "build/libsimdjson_wrapper.so"


# Result codes from simdjson_wrapper.h
comptime SIMDJSON_OK: Int = 0
comptime SIMDJSON_ERROR_INVALID_JSON: Int = 1
comptime SIMDJSON_ERROR_CAPACITY: Int = 2
comptime SIMDJSON_ERROR_UTF8: Int = 3
comptime SIMDJSON_ERROR_OTHER: Int = 99

# Type codes from simdjson_wrapper.h
comptime SIMDJSON_TYPE_NULL: Int = 0
comptime SIMDJSON_TYPE_BOOL: Int = 1
comptime SIMDJSON_TYPE_INT64: Int = 2
comptime SIMDJSON_TYPE_UINT64: Int = 3
comptime SIMDJSON_TYPE_DOUBLE: Int = 4
comptime SIMDJSON_TYPE_STRING: Int = 5
comptime SIMDJSON_TYPE_ARRAY: Int = 6
comptime SIMDJSON_TYPE_OBJECT: Int = 7


@fieldwise_init
struct _CFn[R: RegisterPassable](TrivialRegisterPassable):
    """A stored C-function proxy resolved once at init from `SimdjsonFFI`'s
    own library handle.

    `OwnedDLHandle.get_function` returns an origin-bound callable that cannot
    be stored next to the handle it borrows, so `SimdjsonFFI` stores these
    origin-free proxies instead. Safe because `SimdjsonFFI` owns `_lib`: the
    proxies never outlive the handle.
    """

    var _opaque: Pointer[NoneType, MutUntrackedOrigin]

    @always_inline
    def __call__[*T: AnyType](self, *args: *T) -> Self.R:
        # Same reinterpret dance as stdlib `_DLCallable.__call__`: the opaque
        # field's address is viewed as a function-pointer slot and loaded.
        var typed_fn = Pointer(to=self._opaque).unsafe_bitcast[
            def(* a: * T) thin abi("C") -> Self.R
        ]()[]
        return typed_fn(*args)


def _cfn[
    R: RegisterPassable
](lib: OwnedDLHandle, name: StringSlice) raises -> _CFn[R]:
    """Resolves `name` in `lib` and wraps it as a storable `_CFn` proxy."""
    var sym = lib.get_symbol[NoneType](name)
    if not sym:
        raise Error(String("symbol not found: ", name))
    return _CFn[R](
        sym.unsafe_value()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin]()
    )


struct SimdjsonFFI:
    """Low-level simdjson FFI bindings. All pointer args are passed as Int.

    Function pointers are resolved fresh per call via ``self._lib.get_function``
    rather than cached in fields: the new ``get_function`` returns a callable
    whose type is tied to an origin on ``self._lib``, which a sibling field
    can't reference (self-referential struct), so caching isn't expressible.
    """

    var _lib: OwnedDLHandle
    var _parser: Int  # Opaque pointer as Int

    # Parser functions
    var _create_parser: _CFn[Int]
    var _destroy_parser: _CFn[NoneType]
    var _parse: _CFn[Int]
    var _get_root: _CFn[Int]

    # Value functions
    var _value_get_type: _CFn[Int]
    var _value_get_bool: _CFn[Int]
    var _value_get_int64: _CFn[Int]
    var _value_get_uint64: _CFn[Int]
    var _value_get_double: _CFn[Int]
    var _value_get_string: _CFn[Int]
    var _value_free: _CFn[NoneType]

    # Array functions
    var _array_begin: _CFn[Int]
    var _array_iter_done: _CFn[Int]
    var _array_iter_get: _CFn[Int]
    var _array_iter_next: _CFn[NoneType]
    var _array_iter_free: _CFn[NoneType]
    var _array_count: _CFn[Int]

    # Object functions
    var _object_begin: _CFn[Int]
    var _object_iter_done: _CFn[Int]
    var _object_iter_get_key: _CFn[NoneType]
    var _object_iter_get_value: _CFn[Int]
    var _object_iter_next: _CFn[NoneType]
    var _object_iter_free: _CFn[NoneType]
    var _object_count: _CFn[Int]

    # Memory helper: copies n bytes from src_addr (integer) to dst (pointer as Int).
    # Avoids int-to-UnsafePointer construction in Mojo, which varies across versions.
    var _memcpy_from_addr: _CFn[NoneType]

    def __init__(out self, lib_path: String = "") raises:
        """Initialize by loading the simdjson wrapper library.

        Args:
            lib_path: Path to the library. If empty, searches standard locations:
                      1. $CONDA_PREFIX/lib/libsimdjson_wrapper.so (installed).
                      2. build/libsimdjson_wrapper.so (development).
        """
        var path = lib_path if lib_path else _find_simdjson_library()
        self._lib = OwnedDLHandle(path)

        # Parser functions
        self._create_parser = _cfn[Int](self._lib, "simdjson_create_parser")
        self._destroy_parser = _cfn[NoneType](
            self._lib, "simdjson_destroy_parser"
        )
        self._parse = _cfn[Int](self._lib, "simdjson_parse")
        self._get_root = _cfn[Int](self._lib, "simdjson_get_root")

        # Value functions
        self._value_get_type = _cfn[Int](self._lib, "simdjson_value_get_type")
        self._value_get_bool = _cfn[Int](self._lib, "simdjson_value_get_bool")
        self._value_get_int64 = _cfn[Int](self._lib, "simdjson_value_get_int64")
        self._value_get_uint64 = _cfn[Int](
            self._lib, "simdjson_value_get_uint64"
        )
        self._value_get_double = _cfn[Int](
            self._lib, "simdjson_value_get_double"
        )
        self._value_get_string = _cfn[Int](
            self._lib, "simdjson_value_get_string"
        )
        self._value_free = _cfn[NoneType](self._lib, "simdjson_value_free")

        # Array functions
        self._array_begin = _cfn[Int](self._lib, "simdjson_array_begin")
        self._array_iter_done = _cfn[Int](self._lib, "simdjson_array_iter_done")
        self._array_iter_get = _cfn[Int](self._lib, "simdjson_array_iter_get")
        self._array_iter_next = _cfn[NoneType](
            self._lib, "simdjson_array_iter_next"
        )
        self._array_iter_free = _cfn[NoneType](
            self._lib, "simdjson_array_iter_free"
        )
        self._array_count = _cfn[Int](self._lib, "simdjson_array_count")

        # Object functions
        self._object_begin = _cfn[Int](self._lib, "simdjson_object_begin")
        self._object_iter_done = _cfn[Int](
            self._lib, "simdjson_object_iter_done"
        )
        self._object_iter_get_key = _cfn[NoneType](
            self._lib, "simdjson_object_iter_get_key"
        )
        self._object_iter_get_value = _cfn[Int](
            self._lib, "simdjson_object_iter_get_value"
        )
        self._object_iter_next = _cfn[NoneType](
            self._lib, "simdjson_object_iter_next"
        )
        self._object_iter_free = _cfn[NoneType](
            self._lib, "simdjson_object_iter_free"
        )
        self._object_count = _cfn[Int](self._lib, "simdjson_object_count")
        self._memcpy_from_addr = _cfn[NoneType](
            self._lib, "simdjson_memcpy_from_addr"
        )

        # Create the parser
        self._parser = self._lib.get_function[Int]("simdjson_create_parser")()
        if self._parser == 0:
            raise Error("Failed to create simdjson parser")

    def destroy(mut self) raises:
        """Clean up the parser. Call this explicitly when done."""
        if self._parser != 0:
            self._lib.get_function[NoneType]("simdjson_destroy_parser")(
                self._parser
            )
            self._parser = 0

    def parse(mut self, json: String) raises -> Int:
        """Parse JSON and return root value handle."""
        var json_copy = json
        var c_str = json_copy.as_c_string_slice()
        var ptr = Int(c_str.unsafe_ptr())
        var length = json_copy.byte_length()

        var err = self._lib.get_function[Int]("simdjson_parse")(
            self._parser, ptr, length
        )

        if err != SIMDJSON_OK:
            var pos = find_error_position(json)
            if err == SIMDJSON_ERROR_INVALID_JSON:
                raise Error(json_parse_error("Invalid JSON syntax", json, pos))
            elif err == SIMDJSON_ERROR_UTF8:
                raise Error(
                    json_parse_error("Invalid UTF-8 encoding", json, pos)
                )
            elif err == SIMDJSON_ERROR_CAPACITY:
                raise Error("JSON document too large (exceeds parser capacity)")
            else:
                raise Error(json_parse_error("Unknown parse error", json, pos))

        return self._lib.get_function[Int]("simdjson_get_root")(self._parser)

    def get_type(self, value: Int) raises -> Int:
        """Get the type of a value."""
        return self._lib.get_function[Int]("simdjson_value_get_type")(value)

    def get_bool(self, value: Int) raises -> Bool:
        """Get value as boolean."""
        var result = List[Int32](capacity=1)
        result.append(0)
        var err = self._lib.get_function[Int]("simdjson_value_get_bool")(
            value, Int(result.unsafe_ptr())
        )
        if err != SIMDJSON_OK:
            raise Error("Value is not a boolean")
        return result[0] != 0

    def get_int(self, value: Int) raises -> Int64:
        """Get value as int64."""
        var result = List[Int64](capacity=1)
        result.append(0)
        var err = self._lib.get_function[Int]("simdjson_value_get_int64")(
            value, Int(result.unsafe_ptr())
        )
        if err != SIMDJSON_OK:
            raise Error("Value is not an integer")
        return result[0]

    def get_uint(self, value: Int) raises -> UInt64:
        """Get value as uint64."""
        var result = List[UInt64](capacity=1)
        result.append(0)
        var err = self._lib.get_function[Int]("simdjson_value_get_uint64")(
            value, Int(result.unsafe_ptr())
        )
        if err != SIMDJSON_OK:
            raise Error("Value is not an unsigned integer")
        return result[0]

    def get_float(self, value: Int) raises -> Float64:
        """Get value as double."""
        var result = List[Float64](capacity=1)
        result.append(0.0)
        var err = self._lib.get_function[Int]("simdjson_value_get_double")(
            value, Int(result.unsafe_ptr())
        )
        if err != SIMDJSON_OK:
            raise Error("Value is not a float")
        return result[0]

    def get_string(self, value: Int) raises -> String:
        """Get value as string - uses unsafe_from_utf8 for zero-copy."""
        var data_ptr = List[Int](capacity=1)
        data_ptr.append(0)
        var len_buf = List[Int](capacity=1)
        len_buf.append(0)

        var err = self._lib.get_function[Int]("simdjson_value_get_string")(
            value, Int(data_ptr.unsafe_ptr()), Int(len_buf.unsafe_ptr())
        )

        if err != SIMDJSON_OK:
            raise Error("Value is not a string")

        var addr = data_ptr[0]
        var length = len_buf[0]

        if length == 0:
            return String("")

        # Copy via C shim: avoids UnsafePointer-from-Int construction in Mojo.
        # simdjson guarantees valid UTF-8; unsafe_from_utf8 takes raw bytes.
        var bytes = List[UInt8](capacity=length)
        bytes.resize(length, 0)
        self._lib.get_function[NoneType]("simdjson_memcpy_from_addr")(
            Int(bytes.unsafe_ptr()), addr, length
        )
        return String(unsafe_from_utf8=bytes^)

    def free_value(self, value: Int) raises:
        """Free a value handle."""
        self._lib.get_function[NoneType]("simdjson_value_free")(value)

    def array_count(self, value: Int) raises -> Int:
        """Get array element count."""
        return self._lib.get_function[Int]("simdjson_array_count")(value)

    def array_begin(self, value: Int) raises -> Int:
        """Start iterating over array."""
        return self._lib.get_function[Int]("simdjson_array_begin")(value)

    def array_iter_done(self, iter: Int) raises -> Bool:
        """Check if array iteration is done."""
        return (
            self._lib.get_function[Int]("simdjson_array_iter_done")(iter) != 0
        )

    def array_iter_get(self, iter: Int) raises -> Int:
        """Get current array element."""
        return self._lib.get_function[Int]("simdjson_array_iter_get")(iter)

    def array_iter_next(self, iter: Int) raises:
        """Move to next array element."""
        self._lib.get_function[NoneType]("simdjson_array_iter_next")(iter)

    def array_iter_free(self, iter: Int) raises:
        """Free array iterator."""
        self._lib.get_function[NoneType]("simdjson_array_iter_free")(iter)

    def object_count(self, value: Int) raises -> Int:
        """Get object key count."""
        return self._lib.get_function[Int]("simdjson_object_count")(value)

    def object_begin(self, value: Int) raises -> Int:
        """Start iterating over object."""
        return self._lib.get_function[Int]("simdjson_object_begin")(value)

    def object_iter_done(self, iter: Int) raises -> Bool:
        """Check if object iteration is done."""
        return (
            self._lib.get_function[Int]("simdjson_object_iter_done")(iter) != 0
        )

    def object_iter_get_key(self, iter: Int) raises -> String:
        """Get current object key - uses unsafe_from_utf8 for zero-copy."""
        var data_ptr = List[Int](capacity=1)
        data_ptr.append(0)
        var len_buf = List[Int](capacity=1)
        len_buf.append(0)

        self._lib.get_function[NoneType]("simdjson_object_iter_get_key")(
            iter, Int(data_ptr.unsafe_ptr()), Int(len_buf.unsafe_ptr())
        )

        var addr = data_ptr[0]
        var length = len_buf[0]

        if addr == 0:
            raise Error("Failed to get object key")

        if length == 0:
            return String("")

        # Copy via C shim: avoids UnsafePointer-from-Int construction in Mojo.
        # simdjson guarantees valid UTF-8; unsafe_from_utf8 takes raw bytes.
        var bytes = List[UInt8](capacity=length)
        bytes.resize(length, 0)
        self._lib.get_function[NoneType]("simdjson_memcpy_from_addr")(
            Int(bytes.unsafe_ptr()), addr, length
        )
        return String(unsafe_from_utf8=bytes^)

    def object_iter_get_value(self, iter: Int) raises -> Int:
        """Get current object value."""
        return self._lib.get_function[Int]("simdjson_object_iter_get_value")(
            iter
        )

    def object_iter_next(self, iter: Int) raises:
        """Move to next object key-value pair."""
        self._lib.get_function[NoneType]("simdjson_object_iter_next")(iter)

    def object_iter_free(self, iter: Int) raises:
        """Free object iterator."""
        self._lib.get_function[NoneType]("simdjson_object_iter_free")(iter)
