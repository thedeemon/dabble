
module repl;

import
    std.array,
    std.typecons,
    std.range,
    std.traits,
    std.c.string,
    std.path,
    core.memory,
    std.file,
    std.process,
    std.string,
    std.stdio,
    std.conv,
    std.c.windows.windows,
    core.runtime,
    std.datetime;

import
    loader,
    actions;

extern(C) void* gc_getProxy();

enum LOADER = "MEMORYMOD";

/**
* Defs that are shared between this module and the compiled dll
*/
enum sharedDefs =
`
    struct Symbol
    {
        string name;
        string type;
        string current;
        string checkType;
        uint vtblIndex;
        bool isClass;
        void* addr;
    }

    struct ReplContext
    {
        string filename = "replDll";
        string[] imports;
        string[] userTypes;
        Symbol[] symbols;
        int[string] symbolSet;
        void*[][] vtbl;
        void* gc;
        bool verbose = false;
    }
`;

struct Symbol
{
    string name;
    string type;
    string current;
    string checkType;
    uint vtblIndex;
    bool isClass;
    void* addr;
}

struct ReplContext
{
    string filename = "replDll";
    string[] imports;
    string[] userTypes;
    Symbol[] symbols;
    int[string] symbolSet;
    void*[][] vtbl;
    void* gc;
    bool verbose = false;
}


void loop(ref ReplContext repl)
{
    if (exists(repl.filename ~ ".dll"))
        remove(repl.filename ~ ".dll");

    string error;
    char[] lineBuffer;
    stdin.readln(lineBuffer);

    while (strip(lineBuffer) != "exit")
    {
        switch(strip(lineBuffer))
        {
            case "print":
            {
                foreach(val; repl.symbols)
                    writeln(val.name, " (", val.type, ") = ", val.current, " isClass?: ", val.isClass);

                break;
            }
            default:
            {
                string result;
                if (eval(lineBuffer.to!string, repl, error))
                    writeln(error);
            }
        }

        stdin.readln(lineBuffer);
    }
    return;
}

bool eval(string code, ref ReplContext repl, ref string error)
{
    auto text = Parser.go(code, repl);

    if (text.length == 0)
        return 0;

    if (repl.verbose)
        writeln("Building...");

    if (buildCode(text, repl, error))
        return 1;

    if (repl.verbose)
        writeln("Calling...");

    if (callCode(loadCode(repl.filename), repl, error))
        return 1;

    //resolveTypes(repl);
    //fixupVtbls(repl);

    return 0;
}

bool buildCode(string code, ref ReplContext repl, ref string error)
{
    enum dllHeader =
    `
    import std.stdio, std.conv;
    import std.c.stdio, std.c.string, std.c.stdlib, std.c.windows.windows;
    import core.sys.windows.dll, core.runtime, core.memory;

    extern (C) void gc_setProxy(void*);

    HINSTANCE g_hInst;

    extern(Windows) BOOL DllMain(HINSTANCE hInstance,DWORD ulReason,LPVOID lpvReserved)
    {
        final switch (ulReason)
        {
        case DLL_PROCESS_ATTACH:
            Runtime.initialize();
            break;
        case DLL_PROCESS_DETACH:
            break;
        case DLL_THREAD_ATTACH:
            break;
        case DLL_THREAD_DETACH:
            break;
        }
        g_hInst = hInstance;
        return true;
    }



    struct Ref(T)
    {
        import core.memory, std.c.string, std.traits;

        enum { Value, Array, Class, Mutable, Immutable }

        template isClass(T)
        {
            enum isClass =  __traits(compiles, __traits(classInstanceSize, T));
        }

        template _type(T)
        {
            static if (isClass!T)
                enum _type = Class;
            else static if (isArray!T)
                enum _type = Array;
            else
                enum _type = Value;
        }

        template _qual(T)
        {
            static if (isMutable!T)
                enum _qual = Mutable;
            else
                enum _qual = Immutable;
        }

        alias _type!T _Type;
        alias _qual!T _Qual;

        static if (_Qual == Immutable)
        {
            private T v;
        }
        else
        {
            static if (_Type == Class)
                private T v;
            else
                private T* v;
        }


        this(this)
        {
            static if (_Qual == Mutable)
            {
                static if (_Type == Array)
                {
                    static if (isMutable!(ForeachType!T))
                        auto temp = (*v).dup;
                    else
                        auto temp = (*v).idup;

                    _heapNew();
                    *v = temp;
                }
                else static if (_Type != Class)
                {
                    auto temp = *v;
                    _heapNew();
                    *v = temp;
                }
            }
        }

        static Ref!T opCall(T init = T.init)
        {
            Ref!T r;

            static if (_Qual == Mutable)
            {
                static if (isClass!T)
                    r.v = init;
                else static if (isArray!T)
                {
                    r._heapNew();
                    *r.v = init;
                }
                else static if (!isClass!T)
                {
                    r.v = new T;
                    *r.v = init;
                }
            }
            else
            {
                memcpy(cast(void*)(&(r.v)), &init, init.sizeof);
            }
            return r;
        }

        void _heapNew()
        {
            static if (_Type != Class && _Qual == Mutable)
            {
                T var;
                v = cast(T*)GC.calloc((T).sizeof);
                GC.disable();
                memcpy(v, &var, (T).sizeof);
                GC.enable();
            }
        }

        Ref!T _handle()
        {
            static if (_Qual == Mutable)
            {
                static if (_Type != Class)
                {
                    Ref!T hnd;
                    hnd.v = v;
                    return hnd;
                }
                else
                    return this;
                }
            else
            {
                return this;
            }
        }

        void opAssign()(T t)
        {
            static if (_Qual == Mutable)
            {
                static if (_Type == Class)
                    v = t;
                else
                    *v = t;
            }
            else
            {
                static assert(false, "Cannot assign to " ~ T.stringof);
            }
        }

        string toString()
        {
            static if (_Type == Class || _Qual == Immutable)
            {
                if (v !is null)
                    return v.to!string;
                else
                    return "null";
            }
            else
            {
                if (v !is null)
                    return (*v).to!string;
                else
                    return "null";
            }
        }

        @property ref inout(T) _get() inout pure nothrow @safe
        {
            static if (_Type == Class || _Qual == Immutable)
                return v;
            else
                return *v;
        }

        alias T _typeof;
        alias _get this;
    }

    void* heapRef(T)(T init = T.init)
    {
        import core.memory, std.c.string;

        auto var = Ref!T(init);
        auto ptr = GC.calloc((Ref!T).sizeof);
        GC.disable();
        memcpy(ptr, &var, (Ref!T).sizeof);
        GC.enable();
        return ptr;
    }

    auto _Init(T)(T t)
    {
        static if (is(T _ : Ref!U, U))
            return U.init;
        static if (is(T _ : Ref!U[], U))
            return U.init;
        else
            return T.init;
    }



    ` ~ sharedDefs;

    // The code
    auto file = File(repl.filename ~ ".d", "w");
    file.write(dllHeader ~ code);
    file.close();

    // The .def
    file = File(repl.filename ~ ".def", "w");

    enum def = "LIBRARY replDll\n" ~
               "DESCRIPTION 'replDll'\n" ~
               "EXETYPE	 NT\n" ~
               "CODE PRELOAD DISCARDABLE\n" ~
               "DATA PRELOAD MULTIPLE";

    file.write(def);
    file.close();

    //-Ic:/cal/d/dmd2/src/druntime/src
    //auto include = "-Ic:/cal/d/dmd2/src/druntime/src ";
    auto cmd1 = "dmd -c -g " ~ repl.filename ~ ".d";
    auto cmd2 = "dmd -g " ~ repl.filename ~ ".obj " ~ repl.filename ~ ".def";
    //auto cmd2 = "link /CODEVIEW /DEBUG " ~ filename ~ ".obj,,,phobos.lib+kernel32.lib," ~ filename ~ ".def";

    try{
        error = shell(cmd1);
		writeln(error);
        error = shell(cmd2);
		writeln(error);
        return 0;
    }
    catch(Exception e) {
        return 1;
    }
}


static if (LOADER == "MEMORYMOD")
{
    HMEMORYMODULE loadCode(string filename)
    {
        import std.file;
        auto data = read(filename ~ ".dll");

        HMEMORYMODULE _module;
        _module = MemoryLoadLibrary(data.ptr);

        if (_module == null)
        {
            writeln("Can't load library from memory.\n");
            return null;
        }
        return _module;
    }

    bool callCode(HMEMORYMODULE _module, ref ReplContext repl, ref string error)
    {
        scope(exit) { MemoryFreeLibrary(_module, false); }

        alias extern(C) void function(ref ReplContext) replCode;
        auto fp = cast(replCode)MemoryGetProcAddress(_module, cast(char*)("_main".toStringz));

        try{
            fp(repl);
            GC.removeRange(getSectionBase(_module, ".CRT"));
            return 0;
        }
        catch(Exception e) {
            error = e.msg;
            return 1;
        }
    }

}
