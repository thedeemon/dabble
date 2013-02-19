module actions;

import
    std.algorithm,
    std.array,
    std.typecons,
    std.conv,
    std.string;

import
    repl,
    parser;

struct ParseState
{
    int blockDepth = 0;
    int newVars = -1; // index into repl.symbols at which new vars begin
    ReplContext* repl;

    string genImports()
    {
        if (repl.imports.length > 0)
            return "import " ~ std.array.join(repl.imports, ",\n") ~ ";\n\n";
        else return "";
    }

    string genTypes()
    {
        if (repl.userTypes.length > 0)
            return std.array.join(repl.userTypes, "\n\n") ~ "\n\n";
        else return "";
    }

    Tuple!(string,string) genWrapper()
    {
        string prefix, suffix;

        // Declared Vars
        int stop = newVars == -1 ? repl.symbols.length : newVars;
        foreach(idx, sym; repl.symbols[0..stop])
        {
            prefix ~= "auto " ~ sym.name ~ " = (*cast(Ref!(" ~ sym.type ~ ")*)"
                        ~ "_repl_.symbols[" ~ idx.to!string ~ "].addr)._handle();\n";


            if (sym.isClass)
                prefix ~= "memcpy(_repl_.vtbl[" ~ sym.vtblIndex.to!string ~ "].ptr, "
                        ~ "typeid(" ~ sym.type ~ ").vtbl.ptr, "
                        ~ "typeid(" ~ sym.type ~ ").vtbl.length * (void*).sizeof);\n";

            suffix ~= "_repl_.symbols[" ~ idx.to!string
                    ~ "].current = to!string(" ~ sym.name ~ ").idup;\n";
        }

        if (newVars != -1)
        {
            foreach(idx, sym; repl.symbols[newVars..$])
            {

                /++
                prefix ~= "_repl_.symbols[" ~ (idx+newVars).to!string
                        ~ "].addr = heapRef!(" ~ sym.type ~ ");\n";

                prefix ~= "auto " ~ sym.name ~ " = (*cast(Ref!(" ~ sym.type ~ ")*)"
                        ~ "_repl_.symbols[" ~ (idx+newVars).to!string ~ "].addr)._handle();\n";


                prefix ~= checkForClass(sym, idx+newVars);
                prefix ~= dupVtbl(sym, idx+newVars);

                if (sym.type.length > 6 && sym.type[0..6] == "typeof")
                {
                    prefix ~= "_repl_.symbols[" ~ (idx+newVars).to!string ~ "].type = "
                            ~ sym.name ~ "._typeof.stringof.idup;\n";
                }
                ++/

                suffix ~= "_repl_.symbols[" ~ (idx+newVars).to!string
                        ~ "].current = to!string(" ~ sym.name ~ ").idup;\n";
            }
        }

        return tuple(prefix, suffix);
    }
}

import std.stdio;

struct Parser
{
    static ParseState s;
    static bool verbose = false;

    static string go(string input, ref ReplContext repl)
    {
        verbose = repl.verbose;
        s = ParseState();
        s.repl = &repl;

        if (verbose)
            writeln("Calling ReplParse...");

        auto p = ReplParse.Search(input);

        if (verbose)
        {
            writeln("Printing ReplParse...");
            writeln(p);
        }

        p = ReplParse.decimateTree(p);
        auto code = std.array.join(p.matches);
        auto wrap = s.genWrapper();
        return s.genImports() ~
               s.genTypes() ~
               "export extern(C) void _main(ref ReplContext _repl_) {\n" ~
               "gc_setProxy(_repl_.gc);\n" ~
               wrap[0] ~ //"writeln(`A`);\n" ~
               code ~ //"writeln(`B`);\n" ~
               wrap[1] ~ //"writeln(`C`);\n" ~
               "}";
    }

    static T incDepth(T)(T t)
    {
        if (t.successful)
            s.blockDepth ++;

        return t;
    }

    static T decDepth(T)(T t)
    {
        if (t.successful)
            s.blockDepth --;
        return t;
    }

    static T clear(T)(T t)
    {
        if (t.successful)
            t.matches.clear;

        return t;
    }

    static T redirect(T)(T t)
    {
        // now a stub
        return t;
    }

    static T addImport(T)(T t)
    {
        if (t.successful) {

            if (verbose)
                writeln("Import...\n", t);

            s.repl.imports ~= t.matches[0];
        }

        return t;
    }

    static T userType(T)(T t)
    {
        if (t.successful) {

            if (verbose)
                writeln("UserType...\n", t);

            s.repl.userTypes ~= t.matches[0];
            t.matches.clear;
        }

        return t;
    }

    static T dupString(T)(T t)
    {
        if (t.successful) {

            if (verbose)
                writeln("String Dup...\n", t);

            t.matches[0] ~= ".idup";
        }

        return t;
    }

    static T wrapInstanceType(T)(T t)
    {

        if (t.successful) {

            if (verbose)
                writeln("Wrap Instance...\n", t);

            t.matches[0] = "(" ~ t.matches[0] ~ ")";
        }

        return t;
    }

    static T addressOf(T)(T t)
    {
        if (t.successful)
        {
            t = ReplParse.decimateTree(t);
            t.matches[0] = "_addressOf(" ~ join(t.children[0].matches) ~ ")";
        }

        return t;
    }

    static T typeOf(T)(T t)
    {
        if (t.successful)
            t.matches[0] = "_typeOf";

        return t;
    }

    static T varDecl(T)(T p)
    {
        if (p.successful)
        {
            if (verbose)
                writeln("VarDecl...\n", p);

            auto type = strip(p.children[0].matches[0]);
            auto name = strip(p.children[1].matches[0]);

            // Typeof expressions may reference defined vars, so redirect them...
            //if (type.length > 6 && type[0..6] == "typeof")
            //    type = redirectStub(type, s);

            if (s.blockDepth == 0) // We only make new vars at top level scope
            {
                if (name in s.repl.symbolSet)
                {} // redifinition, pegged calling actions more than once
                else
                {

                    if (type == "auto")
                    {
                        auto rhs = strip(p.children[2].matches[0]);
                        type = "typeof(_Init(" ~ rhs ~ "))";
                    }

                    auto newSymbol = Symbol(name, type);

                    s.repl.symbols ~= newSymbol;

                    if (s.newVars == -1)
                        s.newVars = s.repl.symbols.length - 1;

                    s.repl.symbolSet[name] = s.repl.symbols.length - 1;

                    auto index = (s.repl.symbols.length - 1).to!string;

                    auto initString = "_repl_.symbols[" ~ index ~ "].addr = heapRef!(" ~ type ~ ");\n"
                                 ~ "auto " ~ name ~ " = (*cast(Ref!(" ~ type ~ ")*)"
                                 ~ "_repl_.symbols[" ~ index ~ "].addr)._handle();\n";

                    initString ~= checkForClass(newSymbol, s.repl.symbols.length-1);
                    initString ~= dupVtbl(newSymbol, s.repl.symbols.length-1);

                    if (p.name == "ReplParse.VarDeclInit")
                        initString ~= join(p.matches[2..$]);

                    p.matches[0] = initString;
                    p.matches = p.matches[0..1];
                }
            }
            else // else, just update the type (in case this is a typeof())
            {

                //p.matches[0] = type;
            }

        }
        return p;
    }
}

T varDecl(T)(T p)
{
    if (p.successful)
        writeln("VARDECL");
    return p;
}

/++
string redirectStub(string input, ref ParseState s)
{
    //writeln("Redirect: ", input);
    auto pi = ReplParse.SymbolSearch(input);
    auto p = ReplParse.decimateTree(pi);
    //writeln(p);
    if (p.successful)
    {
        size_t inserts;
        auto buffer = input.to!(char[]);

        foreach(child; p.children)
        {
            if (child.name == "ReplParse.UFCS")
                child = child.children[0];

            auto name = strip(child.children[0].matches[0]);
            auto ptr = name in s.repl.symbolSet;

            if (ptr != null)
            {
                std.array.insertInPlace(buffer, child.children[0].end + inserts, ')');
                std.array.insertInPlace(buffer, child.children[0].begin + inserts, "(*");
                inserts += 3;
                //writeln(buffer);
            }
        }

        return buffer.to!string;
    }
    return input;
}
++/

/**
* If a symbol with the given name is defined, return
* its index into the symbol array, else return -1.
*/
int isDefined(ref ReplContext r,
              string sym)
{
    auto ptr = sym in r.symbolSet;
    if (ptr)
        return *ptr;
    else
        return -1;
}


/**
* Auto declarations are handled by setting the type
* equal to typeof( rhs expression ). Here we try to
* resolve these into known types (like int[], etc).
*/
void resolveTypes(ref ReplContext repl)
{
    bool knownType(ParseTree t)
    {
        if (t.children[0].name == "ReplParse.Storage")
            return knownType((find!("a.name == \"ReplParse.Type\"")(t.children)).front);
        if (t.children[0].name == "ReplParse.BasicType")
            return true;
        if (t.children[0].name == "ReplParse.Ident")
            return repl.isDefined(t.children[0].matches[0]) != -1;
        return false;
    }

    foreach(ref sym; repl.symbols)
    {
        if (sym.checkType is null)
            continue;

        writeln(sym.checkType);

        auto p = ReplParse.decimateTree(ReplParse.Type(sym.checkType));

        sym.type = sym.checkType;

        // Regardless of whether its a known type, null out the checkType
        sym.checkType = null;
    }
}

string dupVtbl(Symbol sym, uint index)
{
    return
    `static if (__traits(compiles, __traits(classInstanceSize, `~sym.type~`)))
     {
        _repl_.vtbl ~= typeid(`~sym.type~`).vtbl.dup;
        _repl_.symbols[`~index.to!string~`].vtblIndex = _repl_.vtbl.length - 1;
     }
     `;
}

string checkForClass(Symbol sym, uint index)
{
    return
    `_repl_.symbols[`~index.to!string~`].isClass = __traits(compiles, __traits(classInstanceSize, `~sym.type~`));
    `;
}

void fixupVtbls(ref ReplContext repl)
{
    foreach(sym; repl.symbols)
    {
        if (sym.isClass)
        {
            auto _ptr = repl.vtbl[sym.vtblIndex].ptr;
            memcpy(*cast(void***)sym.addr, &_ptr, (void*).sizeof);
        }
    }
}


