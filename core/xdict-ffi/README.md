# xdict-ffi

UniFFI bindings of `xdict-core`: Swift (macOS, iOS) and Kotlin (Android). The core's types are declared here
as UniFFI remote types, checked against the core's own; `ByteSource` and `Progress` are the traits a shell
implements. The exported object is `Core` (a `Library` collides with JNA's in Kotlin, ADR-0007).

`test-swift.sh` and `test-kotlin.sh` run `conformance/` through the generated bindings. For Windows, C# goes
through either UniFFI's C# generator or a plain C ABI; a spike of both decides.
